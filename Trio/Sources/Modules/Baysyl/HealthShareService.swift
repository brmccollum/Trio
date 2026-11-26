import Foundation
import HealthKit
import Swinject

// "Share sleep and workouts": the service. Reporting only, off by default.
//
// When the toggle is on, sleep and workouts are READ from Apple Health and uploaded to the user's own Nightscout
// as inert Notes (see `HealthShareNote`). Nothing here writes to Health, and nothing here is on the loop's path:
// the work runs in its own low-priority task, started from the app coming to the foreground or from the toggle,
// catches every error, and only ever calls the Nightscout Note upload.

// MARK: - Dependencies (injected so tests need neither HealthKit nor a network)

protocol HealthShareReading {
    /// Shows the Health read-permission sheet if it has not been answered yet. Called only from the toggle.
    func requestReadAuthorization() async -> Bool
    func sleepSamples(from: Date, to: Date) async throws -> [HealthShareSleepSample]
    func workouts(from: Date, to: Date) async throws -> [HealthShareWorkout]
}

protocol HealthShareUploading {
    /// False when Nightscout upload is off or not set up; nothing is read from Health in that case.
    var canUpload: Bool { get }
    /// True only if every record reached Nightscout.
    func upload(_ records: [HealthShareRecord]) async -> Bool
}

protocol HealthShareStateStoring: AnyObject {
    var isEnabled: Bool { get }
    var lastSuccess: Date? { get set }
    var lastAttempt: Date? { get set }
    /// Dedupe: record key -> the record's end date.
    var uploadedKeys: [String: Date] { get set }
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

    static let shared = HealthShareService(
        reader: HealthKitShareReader(),
        uploader: NightscoutHealthShareUploader(),
        store: HealthShareDefaultsStore()
    )

    private let reader: HealthShareReading
    private let uploader: HealthShareUploading
    private let store: HealthShareStateStoring

    init(reader: HealthShareReading, uploader: HealthShareUploading, store: HealthShareStateStoring) {
        self.reader = reader
        self.uploader = uploader
        self.store = store
    }

    /// Fire-and-forget entry point for the app becoming active. Never blocks the caller.
    nonisolated static func appDidBecomeActive() {
        // Safe mode (launch guard) turns every add-on off for the run.
        guard BaysylAddOns.healthShare else { return }
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

    /// Called when the user turns the toggle on: asks for Health read access, then syncs once.
    @discardableResult func enabledByUser(now: Date = Date()) async -> Outcome {
        guard store.isEnabled else { return .disabled }
        _ = await reader.requestReadAuthorization()
        return await sync(now: now, force: true)
    }

    private func sync(now: Date, force: Bool) async -> Outcome {
        guard store.isEnabled else { return .disabled }
        if !force {
            if let last = store.lastSuccess, now.timeIntervalSince(last) < Self.minimumInterval { return .throttled }
            if let last = store.lastAttempt, now.timeIntervalSince(last) < Self.retryInterval { return .throttled }
        }
        guard uploader.canUpload else { return .notReady }
        store.lastAttempt = now

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

        let pending = Self.pendingRecords(
            samples: samples,
            workouts: workouts,
            windowStart: windowStart,
            now: now,
            uploadedKeys: store.uploadedKeys
        )

        // The toggle may have been turned off while Health was being read.
        guard store.isEnabled else { return .disabled }

        guard !pending.isEmpty else {
            store.lastSuccess = now
            return .nothingNew
        }
        guard await uploader.upload(pending) else {
            debug(.service, "HealthShare: upload failed; will retry later")
            return .failed
        }

        var keys = store.uploadedKeys
        for record in pending { keys[record.key] = record.createdAt }
        store.uploadedKeys = keys.filter { now.timeIntervalSince($0.value) < Self.keyRetention }
        store.lastSuccess = now
        debug(.service, "HealthShare: uploaded \(pending.count) record(s)")
        return .uploaded(pending.count)
    }

    /// Since the last successful upload (less an overlap for late watch data); the last 7 days on the first run.
    static func windowStart(lastSuccess: Date?, now: Date) -> Date {
        let firstRun = now.addingTimeInterval(-firstRunWindow)
        guard let lastSuccess else { return firstRun }
        return max(now.addingTimeInterval(-maximumWindow), min(firstRun, lastSuccess.addingTimeInterval(-overlap)))
    }

    /// Everything finished inside the window that has not been uploaded yet, oldest first.
    static func pendingRecords(
        samples: [HealthShareSleepSample],
        workouts: [HealthShareWorkout],
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

        var seen = Set<String>()
        var records = (periods.map(HealthShareRecord.init) + finished.map(HealthShareRecord.init))
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// False until the user turns the toggle on.
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

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

/// Reads sleep analysis and workouts. It requests no write access and saves nothing to Health.
final class HealthKitShareReader: HealthShareReading {
    /// Created on first use, so no Health store exists for this feature while the toggle is off.
    private lazy var healthStore = HKHealthStore()

    static var readTypes: Set<HKObjectType> {
        [HKCategoryType(.sleepAnalysis), HKObjectType.workoutType()]
    }

    func requestReadAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
            return true
        } catch {
            return false
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
                    .sumQuantity()?.doubleValue(for: .kilocalorie())
            )
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
