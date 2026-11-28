import Foundation
import HealthKit
import Swinject
import UIKit

// "Share sleep and workouts": the service. Reporting only, off by default.
//
// When the toggle is on, sleep and workouts are READ from Apple Health and uploaded to the user's own Nightscout
// as inert Notes (see `HealthShareNote`). Nothing here writes to Health, and nothing here is on the loop's path:
// the work runs in its own low-priority task, started from the app coming to the foreground or from the toggle,
// catches every error, and only ever calls the Nightscout Note upload.
//
// "Heart rate and activity" (day summaries) is a second switch, also off by default. While it is off no heart
// rate, variability, step or energy type is asked for or read, and sleep and workouts behave as they did before
// day summaries existed. While it is on, past days are sent a few at a time (`maximumDaysPerSync` per sync).
//
// Rules this file keeps:
// - The Health permission sheet is asked for ONLY from a switch the user has just turned on
//   (`enabledByUser`, `daysEnabledByUser`). A sync never asks.
// - A sync runs only while the app is active and the device is unlocked (`isAppReady`).
// - Nothing here starts a UIApplication background task, and nothing here runs on the main thread except the
//   one short question "is the app active and unlocked".

// MARK: - Dependencies (injected so tests need neither HealthKit nor a network)

protocol HealthShareReading {
    /// Shows the Health read-permission sheet if it has not been answered yet. Called only from a switch the
    /// user has just turned on. The day types are part of the request only when `includingDays` is true.
    func requestReadAuthorization(includingDays: Bool) async -> Bool
    func sleepSamples(from: Date, to: Date) async throws -> [HealthShareSleepSample]
    func workouts(from: Date, to: Date) async throws -> [HealthShareWorkout]
    /// True once the Health sheet for the day types has been shown and answered. Asks nothing of the user.
    func dayAccessWasRequested() async -> Bool
    /// One entry per local day touched by the window: heart rate, variability, steps, active energy.
    func days(from: Date, to: Date) async throws -> [HealthShareDay]
}

protocol HealthShareUploading {
    /// False when Nightscout upload is off or not set up; nothing is read from Health in that case.
    var canUpload: Bool { get }
    /// True only if every record reached Nightscout.
    func upload(_ records: [HealthShareRecord]) async -> Bool
}

protocol HealthShareStateStoring: AnyObject {
    var isEnabled: Bool { get }
    /// "Heart rate and activity": day summaries. Only looked at while `isEnabled` is true.
    var isDaysEnabled: Bool { get }
    var lastSuccess: Date? { get set }
    var lastAttempt: Date? { get set }
    /// Dedupe: record key -> the record's end date.
    var uploadedKeys: [String: Date] { get set }
    /// Day summaries have been handled up to here (a local midnight, or the time of the last sync once caught
    /// up). Nil until the first day sync; the back-fill then starts `dayBackfillWindow` ago.
    var dayCursor: Date? { get set }
}

// MARK: - Status (reporting only)

/// What the last Health sync did, kept so the phone can say why nothing arrived. Reported in the `baysyl`
/// object of the settings snapshot, in the launch report and under the switches. No health values in it.
struct HealthShareStatus: Codable, Equatable {
    static let ok = "ok"
    /// "Heart rate and activity" is on but the Health sheet for those types has never been answered.
    static let noPermissionRequested = "no permission requested"
    /// Access was answered, yet Health returned nothing for the days asked for. Health never says "denied":
    /// this is what a denied read looks like.
    static let noData = "no data"
    static let error = "error"
    static let safeMode = "safe mode"
    static let notReady = "not ready"
    static let never = "never run"

    /// When the last sync was attempted (or last refused, for safe mode and not ready).
    var lastAttempt: Date?
    /// One of the constants above.
    var result: String = HealthShareStatus.never
    /// A few words more: "uploaded 3", "nothing new", "upload failed", ...
    var detail: String = ""
    /// Notes read from Health that are still waiting because the upload failed.
    var queued: Int = 0

    /// What the day summaries did in one sync.
    enum Days: Equatable {
        case off
        case noPermissionRequested
        case readFailed
        /// Number of days with any data in the window that was read.
        case read(Int)
    }

    /// The status of a sync that got as far as reading Health. Pure.
    static func after(outcome: HealthShareService.Outcome, days: Days, queued: Int, now: Date) -> HealthShareStatus {
        var status = HealthShareStatus(lastAttempt: now)
        switch outcome {
        case .failed:
            status.result = error
            status.detail = queued > 0 ? "upload failed" : "health read failed"
            status.queued = queued
            return status
        case .disabled,
             .notReady,
             .throttled:
            status.result = notReady
            status.detail = HealthShareService.label(outcome)
            return status
        case .nothingNew,
             .uploaded:
            status.detail = HealthShareService.label(outcome)
        }
        switch days {
        case .off:
            status.result = ok
        case .noPermissionRequested:
            status.result = noPermissionRequested
            status.detail += "; heart rate and activity not read"
        case .readFailed:
            status.result = error
            status.detail += "; day read failed"
        case let .read(count):
            status.result = count == 0 ? noData : ok
            status.detail += "; days with data \(count)"
        }
        return status
    }

    /// "ok, uploaded 1; days with data 3, queued 0, 2026-11-28T12:35:00Z".
    var line: String {
        let time = lastAttempt.map(HealthShareNote.iso) ?? "never"
        return "\(result)\(detail.isEmpty ? "" : ", " + detail), queued \(queued), \(time)"
    }
}

/// The last status, in UserDefaults. State, not a setting.
enum HealthShareStatusStore {
    static let key = "bryan.healthShare.status"

    static func load(from defaults: UserDefaults = .standard) -> HealthShareStatus {
        guard let data = defaults.data(forKey: key),
              let status = try? JSONDecoder().decode(HealthShareStatus.self, from: data) else { return HealthShareStatus() }
        return status
    }

    static func save(_ status: HealthShareStatus, to defaults: UserDefaults = .standard) {
        var capped = status
        capped.detail = String(capped.detail.prefix(120))
        if let data = try? JSONEncoder().encode(capped) { defaults.set(data, forKey: key) }
    }
}

// MARK: - Service

actor HealthShareService {
    enum Outcome: Equatable {
        case disabled
        case throttled
        case notReady
        case nothingNew
        case uploaded(Int)
        case failed
    }

    /// At most one sync this often after a success.
    static let minimumInterval: TimeInterval = 3 * 60 * 60
    /// After a failed attempt, wait this long before trying again.
    static let retryInterval: TimeInterval = 10 * 60
    static let firstRunWindow: TimeInterval = 7 * 24 * 60 * 60
    /// Re-read this far before the last success, to pick up samples a watch delivered late.
    static let overlap: TimeInterval = 2 * 24 * 60 * 60
    static let maximumWindow: TimeInterval = 30 * 24 * 60 * 60
    /// A sleep period is sent once it has been over for this long, so a night still in progress is not sent.
    static let sleepSettle: TimeInterval = HealthShareCollapser.mergeGap
    static let keyRetention: TimeInterval = 45 * 24 * 60 * 60
    /// Day summaries go back this far, a few days per sync (never in one go).
    static let dayBackfillWindow: TimeInterval = 60 * 24 * 60 * 60
    /// At most this many day summaries are read and sent by one sync, oldest first.
    static let maximumDaysPerSync = 3
    /// While past days are still waiting, a sync may run this often instead of every `minimumInterval`.
    static let backfillInterval: TimeInterval = 15 * 60
    /// A day is sent once it has been over for this long, so late watch data has mostly arrived.
    static let daySettle: TimeInterval = 60 * 60

    static let shared = HealthShareService(
        reader: HealthKitShareReader(),
        uploader: NightscoutHealthShareUploader(),
        store: HealthShareDefaultsStore(),
        isAppReady: { await HealthShareService.appIsActiveAndUnlocked() },
        breadcrumb: { BaysylLaunchGuard.shared.note($0) },
        report: { HealthShareStatusStore.save($0) }
    )

    private let reader: HealthShareReading
    private let uploader: HealthShareUploading
    private let store: HealthShareStateStoring
    private let isAppReady: @Sendable() async -> Bool
    private let breadcrumb: @Sendable(String) -> Void
    private let report: @Sendable(HealthShareStatus) -> Void
    private let calendar: Calendar
    /// Set by `readAndUpload` for the status of the sync in progress.
    private var lastDays = HealthShareStatus.Days.off
    private var lastQueued = 0

    /// - Parameters:
    ///   - isAppReady: true only while the app is active and protected data can be read. Health is not touched
    ///     otherwise.
    ///   - breadcrumb: receives "health sync start" and "health sync end: <outcome>" for each sync that gets as
    ///     far as reading Health.
    init(
        reader: HealthShareReading,
        uploader: HealthShareUploading,
        store: HealthShareStateStoring,
        isAppReady: @escaping @Sendable() async -> Bool = { true },
        breadcrumb: @escaping @Sendable(String) -> Void = { _ in },
        report: @escaping @Sendable(HealthShareStatus) -> Void = { _ in },
        calendar: Calendar = .current
    ) {
        self.reader = reader
        self.uploader = uploader
        self.store = store
        self.isAppReady = isAppReady
        self.breadcrumb = breadcrumb
        self.report = report
        self.calendar = calendar
    }

    /// The app is in the foreground and the device is unlocked. One short hop to the main actor; if the main
    /// thread is busy this waits for it, it never blocks it.
    nonisolated static func appIsActiveAndUnlocked() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
        }
    }

    /// Fire-and-forget entry point for the app becoming active. Never blocks the caller.
    nonisolated static func appDidBecomeActive() {
        // Safe mode (launch guard) turns every add-on off for the run.
        guard BaysylAddOns.healthShare else {
            // Said out loud, so "nothing arrived" can be told apart from "never tried".
            if UserDefaults.standard.bool(forKey: HealthShareDefaultsStore.enabledKey) {
                HealthShareStatusStore.save(
                    HealthShareStatus(lastAttempt: Date(), result: HealthShareStatus.safeMode, detail: "add-ons are off")
                )
            }
            return
        }
        if UserDefaults.standard.bool(forKey: HealthShareDefaultsStore.enabledKey) {
            BaysylLaunchGuard.shared.mark(.healthTick)
        }
        Task.detached(priority: .utility) {
            _ = await HealthShareService.shared.foregroundTick()
        }
    }

    /// Called when the app comes to the foreground. Does nothing while the toggle is off.
    @discardableResult func foregroundTick(now: Date = Date()) async -> Outcome {
        await sync(now: now, force: false)
    }

    /// Called when the user turns "Share sleep and workouts" on: asks for Health read access, then syncs once.
    /// The day types are part of the request only if "Heart rate and activity" is already on.
    @discardableResult func enabledByUser(now: Date = Date()) async -> Outcome {
        guard store.isEnabled else { return .disabled }
        guard await isAppReady() else { return .notReady }
        _ = await reader.requestReadAuthorization(includingDays: store.isDaysEnabled)
        return await sync(now: now, force: true)
    }

    /// Called when the user turns "Heart rate and activity" on: asks for read access to the day types, then
    /// syncs once (which starts the back-fill, `maximumDaysPerSync` days at a time).
    @discardableResult func daysEnabledByUser(now: Date = Date()) async -> Outcome {
        guard store.isEnabled, store.isDaysEnabled else { return .disabled }
        guard await isAppReady() else { return .notReady }
        _ = await reader.requestReadAuthorization(includingDays: true)
        return await sync(now: now, force: true)
    }

    /// Called when the user taps "Allow Health access" in Settings: asks for whatever the switches that are on
    /// need, then syncs once. For a switch that was turned on at a moment the sheet could not be shown (safe
    /// mode, an earlier build): without this the day types were never asked for and never read.
    @discardableResult func accessRequestedByUser(now: Date = Date()) async -> Outcome {
        guard store.isEnabled else { return .disabled }
        guard await isAppReady() else { return .notReady }
        _ = await reader.requestReadAuthorization(includingDays: store.isDaysEnabled)
        return await sync(now: now, force: true)
    }

    /// True while "Heart rate and activity" is on but Health has never been asked for those types. Asks nothing.
    func needsAccessRequest() async -> Bool {
        guard store.isEnabled, store.isDaysEnabled else { return false }
        let asked = await reader.dayAccessWasRequested()
        return !asked
    }

    /// Never asks for Health permission: that happens only in the `...ByUser` calls above.
    private func sync(now: Date, force: Bool) async -> Outcome {
        guard store.isEnabled else { return .disabled }
        if !force {
            if let last = store.lastAttempt, now.timeIntervalSince(last) < Self.retryInterval { return .throttled }
            if let last = store.lastSuccess, now.timeIntervalSince(last) < Self.minimumInterval {
                // Sooner than usual only to work through past days, and only once access has been answered.
                guard store.isDaysEnabled,
                      now.timeIntervalSince(last) >= Self.backfillInterval,
                      Self.isBackfillPending(cursor: store.dayCursor, now: now),
                      await reader.dayAccessWasRequested()
                else { return .throttled }
            }
        }
        guard uploader.canUpload else {
            report(HealthShareStatus(
                lastAttempt: now, result: HealthShareStatus.notReady, detail: "Nightscout upload is off"
            ))
            return .notReady
        }
        // Health is unreadable while the device is locked, and a sync has no business in the background.
        guard await isAppReady() else { return .notReady }
        store.lastAttempt = now

        breadcrumb("health sync start")
        lastDays = .off
        lastQueued = 0
        let outcome = await readAndUpload(now: now)
        let status = HealthShareStatus.after(outcome: outcome, days: lastDays, queued: lastQueued, now: now)
        report(status)
        // "uploaded 1", "nothing new; heart rate and activity not read", "failed", ...
        breadcrumb("health sync end: \(outcome == .failed ? Self.label(outcome) : status.detail)")
        return outcome
    }

    static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .disabled: return "disabled"
        case .throttled: return "throttled"
        case .notReady: return "not ready"
        case .nothingNew: return "nothing new"
        case let .uploaded(count): return "uploaded \(count)"
        case .failed: return "failed"
        }
    }

    private func readAndUpload(now: Date) async -> Outcome {
        let windowStart = Self.windowStart(lastSuccess: store.lastSuccess, now: now)

        let samples: [HealthShareSleepSample]
        let workouts: [HealthShareWorkout]
        do {
            samples = try await reader.sleepSamples(from: windowStart, to: now)
            workouts = try await reader.workouts(from: windowStart, to: now)
        } catch {
            debug(.service, "HealthShare: Health read failed; will retry later")
            return .failed
        }

        // Day summaries: only with their own switch on, only once the user has answered the Health sheet for
        // them (a sync never asks), and only a few days at a time. They never hold up sleep and workouts: a
        // failed read is simply no days, and the cursor stays where it was.
        var days: [HealthShareDay] = []
        var nextDayCursor: Date?
        if store.isDaysEnabled {
            if await reader.dayAccessWasRequested() {
                if await isAppReady() {
                    let window = Self.dayWindow(cursor: store.dayCursor, now: now, calendar: calendar)
                    if let read = try? await reader.days(from: window.start, to: window.end) {
                        let batch = Self.dayBatch(read, window: window, now: now)
                        days = batch.days
                        nextDayCursor = batch.cursor
                        lastDays = .read(read.filter { !$0.isEmpty }.count)
                    } else {
                        lastDays = .readFailed
                    }
                }
            } else {
                lastDays = .noPermissionRequested
            }
        }

        let pending = Self.pendingRecords(
            samples: samples,
            workouts: workouts,
            days: days,
            windowStart: windowStart,
            now: now,
            uploadedKeys: store.uploadedKeys
        )

        // The toggle may have been turned off while Health was being read.
        guard store.isEnabled else { return .disabled }

        guard !pending.isEmpty else {
            store.lastSuccess = now
            if let nextDayCursor { store.dayCursor = nextDayCursor }
            return .nothingNew
        }
        guard await uploader.upload(pending) else {
            debug(.service, "HealthShare: upload failed; will retry later")
            lastQueued = pending.count
            return .failed
        }

        var keys = store.uploadedKeys
        for record in pending { keys[record.key] = record.createdAt }
        store.uploadedKeys = keys.filter { now.timeIntervalSince($0.value) < Self.keyRetention }
        store.lastSuccess = now
        if let nextDayCursor { store.dayCursor = nextDayCursor }
        debug(.service, "HealthShare: uploaded \(pending.count) record(s)")
        return .uploaded(pending.count)
    }

    /// Since the last successful upload (less an overlap for late watch data); the last 7 days on the first run.
    static func windowStart(lastSuccess: Date?, now: Date) -> Date {
        let firstRun = now.addingTimeInterval(-firstRunWindow)
        guard let lastSuccess else { return firstRun }
        return max(now.addingTimeInterval(-maximumWindow), min(firstRun, lastSuccess.addingTimeInterval(-overlap)))
    }

    // MARK: Day summaries, a few at a time (pure)

    /// The whole local days one sync reads: at most `maximumDaysPerSync` of them, starting at a local midnight.
    /// While past days are waiting it starts at the cursor (oldest first); once caught up it is the last few
    /// days again, so a day changed by late watch data is sent again. Never earlier than `dayBackfillWindow` ago.
    static func dayWindow(cursor: Date?, now: Date, calendar: Calendar = .current) -> DateInterval {
        let span = TimeInterval(maximumDaysPerSync) * 24 * 60 * 60
        let earliest = now.addingTimeInterval(-dayBackfillWindow)
        let from = max(earliest, min(cursor ?? earliest, now.addingTimeInterval(-span)))
        let start = calendar.startOfDay(for: from)
        let fullEnd = calendar.date(byAdding: .day, value: maximumDaysPerSync, to: start) ?? start.addingTimeInterval(span)
        return DateInterval(start: start, end: max(start, min(now, fullEnd)))
    }

    /// The days of one read that may be sent (whole, inside the window, over for `daySettle`), oldest first and
    /// at most `maximumDaysPerSync`, with the cursor to store once they have been handled.
    static func dayBatch(
        _ read: [HealthShareDay],
        window: DateInterval,
        now: Date
    ) -> (days: [HealthShareDay], cursor: Date) {
        let finished = read
            .filter {
                $0.start >= window.start && $0.end <= window.end && $0.end <= now.addingTimeInterval(-daySettle)
            }
            .sorted { $0.start < $1.start }
        let kept = Array(finished.prefix(maximumDaysPerSync))
        // More than the limit came back (a reader that ignored the window): stop after the last day kept.
        let cursor = finished.count > kept.count ? (kept.last?.end ?? window.start) : window.end
        return (kept.filter { !$0.isEmpty }, cursor)
    }

    /// Past days are still waiting to be sent.
    static func isBackfillPending(cursor: Date?, now: Date) -> Bool {
        guard let cursor else { return true }
        return cursor < now.addingTimeInterval(-TimeInterval(maximumDaysPerSync + 1) * 24 * 60 * 60)
    }

    /// Everything finished inside the window that has not been uploaded yet, oldest first.
    static func pendingRecords(
        samples: [HealthShareSleepSample],
        workouts: [HealthShareWorkout],
        days: [HealthShareDay] = [],
        windowStart: Date,
        now: Date,
        uploadedKeys: [String: Date]
    ) -> [HealthShareRecord] {
        let periods = HealthShareCollapser.sleepPeriods(from: samples).filter {
            // Over for long enough to be complete, and not cut in half by the start of the window
            // (such a period was sent whole by an earlier run).
            $0.end <= now.addingTimeInterval(-sleepSettle)
                && $0.start >= windowStart.addingTimeInterval(HealthShareCollapser.mergeGap)
        }
        let finished = workouts.filter { $0.end <= now && $0.end > $0.start }
        let finishedDays = days.filter { !$0.isEmpty && $0.end <= now.addingTimeInterval(-daySettle) }

        var seen = Set<String>()
        var records = (
            periods.map(HealthShareRecord.init) + finished.map(HealthShareRecord.init)
                + finishedDays.map(HealthShareRecord.init)
        )
        .filter { uploadedKeys[$0.key] == nil && seen.insert($0.key).inserted }
        .sorted { $0.createdAt < $1.createdAt }

        // Nightscout treats two treatments of one type with the same created_at as one. Keep each record's
        // timestamp distinct within the batch; the exact times are in the note text.
        for index in records.indices.dropFirst() where records[index].createdAt <= records[index - 1].createdAt {
            records[index] = HealthShareRecord(
                key: records[index].key,
                note: records[index].note,
                createdAt: records[index - 1].createdAt.addingTimeInterval(0.001)
            )
        }
        return records
    }
}

// MARK: - UserDefaults state

final class HealthShareDefaultsStore: HealthShareStateStoring {
    static let enabledKey = "bryan.healthShare.enabled"
    static let lastSuccessKey = "bryan.healthShare.lastSuccess"
    static let lastAttemptKey = "bryan.healthShare.lastAttempt"
    static let uploadedKeysKey = "bryan.healthShare.uploadedKeys"
    static let daysEnabledKey = "bryan.healthShare.daysEnabled"
    static let dayCursorKey = "bryan.healthShare.dayCursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// False until the user turns the toggle on.
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// False until the user turns "Heart rate and activity" on.
    var isDaysEnabled: Bool { defaults.bool(forKey: Self.daysEnabledKey) }

    var lastSuccess: Date? {
        get { defaults.object(forKey: Self.lastSuccessKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastSuccessKey) }
    }

    var lastAttempt: Date? {
        get { defaults.object(forKey: Self.lastAttemptKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastAttemptKey) }
    }

    var uploadedKeys: [String: Date] {
        get { (defaults.dictionary(forKey: Self.uploadedKeysKey) as? [String: Date]) ?? [:] }
        set { defaults.set(newValue, forKey: Self.uploadedKeysKey) }
    }

    var dayCursor: Date? {
        get { defaults.object(forKey: Self.dayCursorKey) as? Date }
        set { defaults.set(newValue, forKey: Self.dayCursorKey) }
    }
}

// MARK: - Nightscout upload

/// Hands the records to the existing Nightscout Note upload. Resolved at call time, so nothing is built at launch.
struct NightscoutHealthShareUploader: HealthShareUploading {
    var canUpload: Bool {
        TrioApp.resolver.resolve(SettingsManager.self)?.settings.isUploadEnabled ?? false
    }

    func upload(_ records: [HealthShareRecord]) async -> Bool {
        guard let nightscout = TrioApp.resolver.resolve(NightscoutManager.self) else { return false }
        return await nightscout.uploadDatedNoteTreatments(records.map { (note: $0.note, createdAt: $0.createdAt) })
    }
}

// MARK: - HealthKit (read only)

/// Reads sleep analysis and workouts and, only with "Heart rate and activity" on, heart rate, heart rate
/// variability, steps and active energy. It requests no write access and saves nothing to Health.
final class HealthKitShareReader: HealthShareReading {
    /// Created on first use, so no Health store exists for this feature while the toggle is off.
    private lazy var healthStore = HKHealthStore()

    /// "Share sleep and workouts" on its own.
    static var baseTypes: Set<HKObjectType> {
        [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
    }

    /// Added by "Heart rate and activity".
    static var dayTypes: Set<HKObjectType> {
        [
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned)
        ]
    }

    static func readTypes(includingDays: Bool) -> Set<HKObjectType> {
        includingDays ? baseTypes.union(dayTypes) : baseTypes
    }

    func requestReadAuthorization(includingDays: Bool) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes(includingDays: includingDays))
            return true
        } catch {
            return false
        }
    }

    /// Asks Health whether the sheet for the day types has already been answered. Shows nothing.
    func dayAccessWasRequested() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: Self.dayTypes) { status, _ in
                continuation.resume(returning: status == .unnecessary)
            }
        }
    }

    func sleepSamples(from: Date, to: Date) async throws -> [HealthShareSleepSample] {
        try await samples(of: HKCategoryType(.sleepAnalysis), from: from, to: to).compactMap { sample in
            guard let category = sample as? HKCategorySample,
                  let value = HKCategoryValueSleepAnalysis(rawValue: category.value) else { return nil }
            let stage: HealthShareSleepStage
            switch value {
            case .inBed: stage = .inBed
            case .awake: stage = .awake
            default: stage = .asleep
            }
            return HealthShareSleepSample(start: category.startDate, end: category.endDate, stage: stage)
        }
    }

    func workouts(from: Date, to: Date) async throws -> [HealthShareWorkout] {
        try await samples(of: HKObjectType.workoutType(), from: from, to: to).compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            return HealthShareWorkout(
                uuid: workout.uuid,
                typeName: Self.name(for: workout.workoutActivityType),
                start: workout.startDate,
                end: workout.endDate,
                distanceKm: Self.distanceKm(of: workout),
                activeKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie()),
                averageHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?
                    .averageQuantity()?.doubleValue(for: Self.beatsPerMinute),
                maximumHeartRate: workout.statistics(for: HKQuantityType(.heartRate))?
                    .maximumQuantity()?.doubleValue(for: Self.beatsPerMinute)
            )
        }
    }

    private static var beatsPerMinute: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    func days(from: Date, to: Date) async throws -> [HealthShareDay] {
        guard HKHealthStore.isHealthDataAvailable(), to > from else { return [] }
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: from)
        let hour = DateComponents(hour: 1)
        let day = DateComponents(day: 1)

        let heart = try await statistics(
            .heartRate, [.discreteAverage, .discreteMin, .discreteMax], anchor: anchor, to: to, every: hour
        )
        let resting = try await statistics(.restingHeartRate, .discreteAverage, anchor: anchor, to: to, every: day)
        let variability = try await statistics(
            .heartRateVariabilitySDNN, .discreteAverage, anchor: anchor, to: to, every: day
        )
        let steps = try await statistics(.stepCount, .cumulativeSum, anchor: anchor, to: to, every: day)
        let energy = try await statistics(.activeEnergyBurned, .cumulativeSum, anchor: anchor, to: to, every: day)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var byDay: [Date: HealthShareDay] = [:]
        func update(_ date: Date, _ change: (inout HealthShareDay) -> Void) {
            let start = calendar.startOfDay(for: date)
            var entry = byDay[start] ?? HealthShareDay(
                date: formatter.string(from: start),
                start: start,
                end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
            )
            change(&entry)
            byDay[start] = entry
        }

        let bpm = Self.beatsPerMinute
        for item in heart {
            guard let average = item.averageQuantity()?.doubleValue(for: bpm),
                  let low = item.minimumQuantity()?.doubleValue(for: bpm),
                  let high = item.maximumQuantity()?.doubleValue(for: bpm) else { continue }
            let offset = Int(item.startDate.timeIntervalSince(calendar.startOfDay(for: item.startDate)) / 3600)
            update(item.startDate) {
                $0.hours.append(HealthShareHourHeart(
                    hour: offset,
                    min: Int(low.rounded()),
                    avg: Int(average.rounded()),
                    max: Int(high.rounded())
                ))
            }
        }
        for item in resting {
            guard let value = item.averageQuantity()?.doubleValue(for: bpm) else { continue }
            update(item.startDate) { $0.restingHeartRate = Int(value.rounded()) }
        }
        for item in variability {
            guard let value = item.averageQuantity()?.doubleValue(for: .secondUnit(with: .milli)) else { continue }
            update(item.startDate) { $0.hrvMs = Int(value.rounded()) }
        }
        for item in steps {
            guard let value = item.sumQuantity()?.doubleValue(for: .count()), value > 0 else { continue }
            update(item.startDate) { $0.steps = Int(value.rounded()) }
        }
        for item in energy {
            guard let value = item.sumQuantity()?.doubleValue(for: .kilocalorie()), value > 0 else { continue }
            update(item.startDate) { $0.activeKcal = Int(value.rounded()) }
        }
        return byDay.values.sorted { $0.start < $1.start }
    }

    private func statistics(
        _ identifier: HKQuantityTypeIdentifier,
        _ options: HKStatisticsOptions,
        anchor: Date,
        to: Date,
        every interval: DateComponents
    ) async throws -> [HKStatistics] {
        let predicate = HKQuery.predicateForSamples(withStart: anchor, end: to, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: collection?.statistics() ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private func samples(of type: HKSampleType, from: Date, to: Date) async throws -> [HKSample] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    /// The first distance total the workout carries (walking/running, cycling, swimming, paddling and so on).
    private static func distanceKm(of workout: HKWorkout) -> Double? {
        let kilometers = HKUnit.meterUnit(with: .kilo)
        return workout.allStatistics
            .filter { $0.key.identifier.hasPrefix("HKQuantityTypeIdentifierDistance") }
            .sorted { $0.key.identifier < $1.key.identifier }
            .compactMap { $0.value.sumQuantity() }
            .first { $0.is(compatibleWith: kilometers) }?
            .doubleValue(for: kilometers)
    }

    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .paddleSports: return "PaddleSports"
        case .rowing: return "Rowing"
        case .sailing: return "Sailing"
        case .surfingSports: return "SurfingSports"
        case .waterFitness: return "WaterFitness"
        case .waterSports: return "WaterSports"
        case .traditionalStrengthTraining: return "StrengthTraining"
        case .functionalStrengthTraining: return "FunctionalStrengthTraining"
        case .coreTraining: return "CoreTraining"
        case .highIntensityIntervalTraining: return "HIIT"
        case .crossTraining: return "CrossTraining"
        case .mixedCardio: return "MixedCardio"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "StairClimbing"
        case .stairs: return "Stairs"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .flexibility: return "Flexibility"
        case .cooldown: return "Cooldown"
        case .mindAndBody: return "MindAndBody"
        case .golf: return "Golf"
        case .tennis: return "Tennis"
        case .pickleball: return "Pickleball"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .downhillSkiing: return "DownhillSkiing"
        case .crossCountrySkiing: return "CrossCountrySkiing"
        case .snowboarding: return "Snowboarding"
        case .climbing: return "Climbing"
        case .dance: return "Dance"
        case .other: return "Other"
        default: return "Other\(type.rawValue)"
        }
    }
}
