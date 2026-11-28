import Foundation
import Testing

@testable import Trio

/// Tests for the Health sharing status (why nothing arrived), the "Allow Health access" path and how the
/// status rides in the settings snapshot.
@Suite("Health share status tests") struct HealthShareStatusTests {
    private final class Reader: HealthShareReading {
        var dayAccessRequested = false
        var days: [HealthShareDay] = []
        var daysThrow = false
        var workoutList: [HealthShareWorkout] = []
        private(set) var requests: [Bool] = []

        func requestReadAuthorization(includingDays: Bool) async -> Bool {
            requests.append(includingDays)
            dayAccessRequested = dayAccessRequested || includingDays
            return true
        }

        func sleepSamples(from _: Date, to _: Date) async throws -> [HealthShareSleepSample] { [] }
        func workouts(from _: Date, to _: Date) async throws -> [HealthShareWorkout] { workoutList }
        func dayAccessWasRequested() async -> Bool { dayAccessRequested }
        func days(from _: Date, to _: Date) async throws -> [HealthShareDay] {
            if daysThrow { throw TestError("no") }
            return days
        }
    }

    private final class Uploader: HealthShareUploading {
        var canUpload = true
        var succeeds = true
        func upload(_: [HealthShareRecord]) async -> Bool { succeeds }
    }

    private final class Store: HealthShareStateStoring {
        var isEnabled = true
        var isDaysEnabled = true
        var lastSuccess: Date?
        var lastAttempt: Date?
        var uploadedKeys: [String: Date] = [:]
        var dayCursor: Date?
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [HealthShareStatus] = []
        func add(_ status: HealthShareStatus) { lock.lock()
            all.append(status)
            lock.unlock() }

        var last: HealthShareStatus? { lock.lock()
            defer { lock.unlock() }
            return all.last }
    }

    private let now = Date(timeIntervalSince1970: 1_795_880_000)

    private func service(_ reader: Reader, _ uploader: Uploader, _ store: Store, _ reports: Reports) -> HealthShareService {
        HealthShareService(reader: reader, uploader: uploader, store: store, report: { reports.add($0) })
    }

    private func workout() -> HealthShareWorkout {
        HealthShareWorkout(
            uuid: UUID(),
            typeName: "Running",
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600),
            distanceKm: 1.6,
            activeKcal: 100
        )
    }

    // MARK: Pure status

    @Test("Status wording for each kind of sync") func statusAfter() {
        typealias Status = HealthShareStatus
        let ok = Status.after(outcome: .uploaded(2), days: .off, queued: 0, now: now)
        #expect(ok.result == "ok" && ok.detail == "uploaded 2" && ok.queued == 0 && ok.lastAttempt == now)

        let noPermission = Status.after(outcome: .nothingNew, days: .noPermissionRequested, queued: 0, now: now)
        #expect(noPermission.result == "no permission requested")
        #expect(noPermission.detail == "nothing new; heart rate and activity not read")

        let noData = Status.after(outcome: .nothingNew, days: .read(0), queued: 0, now: now)
        #expect(noData.result == "no data" && noData.detail == "nothing new; days with data 0")

        let withDays = Status.after(outcome: .uploaded(3), days: .read(3), queued: 0, now: now)
        #expect(withDays.result == "ok" && withDays.detail == "uploaded 3; days with data 3")

        let uploadFailed = Status.after(outcome: .failed, days: .read(3), queued: 4, now: now)
        #expect(uploadFailed.result == "error" && uploadFailed.detail == "upload failed" && uploadFailed.queued == 4)
        let readFailed = Status.after(outcome: .failed, days: .off, queued: 0, now: now)
        #expect(readFailed.result == "error" && readFailed.detail == "health read failed")
        let dayReadFailed = Status.after(outcome: .nothingNew, days: .readFailed, queued: 0, now: now)
        #expect(dayReadFailed.result == "error" && dayReadFailed.detail == "nothing new; day read failed")

        #expect(Status().result == "never run")
        #expect(Status().line == "never run, queued 0, never")
        #expect(uploadFailed.line.hasPrefix("error, upload failed, queued 4, 20"))
    }

    @Test("The status survives a round trip through UserDefaults") func statusStore() throws {
        let name = "HealthShareStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(HealthShareStatusStore.load(from: defaults) == HealthShareStatus())
        let status = HealthShareStatus(lastAttempt: now, result: HealthShareStatus.noData, detail: "nothing new", queued: 2)
        HealthShareStatusStore.save(status, to: defaults)
        #expect(HealthShareStatusStore.load(from: defaults) == status)
    }

    // MARK: Service

    @Test(
        "The switch on with Health never asked: reported as no permission requested, and no day is read"
    ) func switchOnButNeverAsked() async {
        let reader = Reader(), uploader = Uploader(), store = Store(), reports = Reports()
        reader.workoutList = [workout()]
        let outcome = await service(reader, uploader, store, reports).foregroundTick(now: now)

        // Sleep and workouts still go; a sync itself never asks for access.
        #expect(outcome == .uploaded(1))
        #expect(reader.requests.isEmpty)
        #expect(reports.last?.result == HealthShareStatus.noPermissionRequested)
        #expect(reports.last?.detail == "uploaded 1; heart rate and activity not read")
        #expect(store.dayCursor == nil)
    }

    @Test("Allow Health access asks for the day types and syncs, even inside the usual wait") func allowButton() async {
        let reader = Reader(), uploader = Uploader(), store = Store(), reports = Reports()
        let service = service(reader, uploader, store, reports)
        store.lastSuccess = now.addingTimeInterval(-60)
        store.lastAttempt = now.addingTimeInterval(-60)
        let awaited1 = await service.needsAccessRequest()
        #expect(awaited1)

        let outcome = await service.accessRequestedByUser(now: now)
        #expect(reader.requests == [true])
        #expect(outcome == .nothingNew)
        let awaited2 = await service.needsAccessRequest()
        #expect(awaited2 == false)
        // Access answered but Health gave nothing back: this is what a denied read looks like.
        #expect(reports.last?.result == HealthShareStatus.noData)
        #expect(store.dayCursor != nil)
    }

    @Test("Allow Health access with only sleep and workouts on does not ask for day types") func allowWithoutDays() async {
        let reader = Reader(), uploader = Uploader(), store = Store(), reports = Reports()
        store.isDaysEnabled = false
        let service = service(reader, uploader, store, reports)
        let awaited3 = await service.needsAccessRequest()
        #expect(awaited3 == false)
        _ = await service.accessRequestedByUser(now: now)
        #expect(reader.requests == [false])
        #expect(reports.last?.result == HealthShareStatus.ok)

        store.isEnabled = false
        let awaited4 = await service.accessRequestedByUser(now: now)
        #expect(awaited4 == .disabled)
        #expect(reader.requests == [false])
    }

    @Test("A failed upload reports how many notes are waiting; upload off is reported too") func failures() async {
        let reader = Reader(), uploader = Uploader(), store = Store(), reports = Reports()
        store.isDaysEnabled = false
        reader.workoutList = [workout()]
        uploader.succeeds = false
        let awaited5 = await service(reader, uploader, store, reports).foregroundTick(now: now)
        #expect(awaited5 == .failed)
        #expect(reports.last?.result == HealthShareStatus.error)
        #expect(reports.last?.detail == "upload failed")
        #expect(reports.last?.queued == 1)

        let offStore = Store(), offUploader = Uploader()
        offUploader.canUpload = false
        let awaited6 = await service(reader, offUploader, offStore, reports).foregroundTick(now: now)
        #expect(awaited6 == .notReady)
        #expect(reports.last?.result == HealthShareStatus.notReady)
        #expect(reports.last?.detail == "Nightscout upload is off")
    }

    // MARK: Snapshot

    @Test("In the settings fingerprint only the result counts, not the time or the counts") func fingerprint() throws {
        let name = "HealthShareStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func snapshot(_ health: HealthShareStatus?) -> NightscoutTrioSettingsSnapshot {
            var state = BaysylAddOnState.current(defaults: defaults, safeMode: false)
            state.health = health
            return NightscoutTrioSettingsSnapshot(
                preferences: Preferences(),
                pumpSettings: PumpSettings(insulinActionCurve: 7, maxBolus: 6, maxBasal: 3.5),
                appSettings: TrioSettings(),
                appVersion: "1.0.2",
                branchAndSha: "b",
                baysyl: state
            )
        }
        let first = HealthShareStatus(lastAttempt: now, result: "ok", detail: "uploaded 1", queued: 0)
        let later = HealthShareStatus(lastAttempt: now.addingTimeInterval(9000), result: "ok", detail: "nothing new", queued: 0)
        let changed = HealthShareStatus(lastAttempt: now, result: "no permission requested", detail: "nothing new", queued: 0)
        #expect(snapshot(first).fingerprint == snapshot(later).fingerprint)
        #expect(snapshot(first).fingerprint != snapshot(changed).fingerprint)
        #expect(snapshot(first).fingerprint != snapshot(nil).fingerprint)

        // The upload itself carries the whole status.
        let data = try JSONCoding.encoder.encode(snapshot(changed))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let health = try #require((json["baysyl"] as? [String: Any])?["health"] as? [String: Any])
        #expect(health["result"] as? String == "no permission requested")
        #expect(health["detail"] as? String == "nothing new")
        #expect(health["queued"] as? Int == 0)
        #expect(health["lastAttempt"] != nil)
    }

    @Test("The launch report line carries the Health status") func reportLine() throws {
        let name = "HealthShareStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var state = BaysylAddOnState.current(defaults: defaults, safeMode: false)
        #expect(!state.reportLine.contains("health sync"))
        state.health = HealthShareStatus(lastAttempt: nil, result: "safe mode", detail: "add-ons are off", queued: 0)
        #expect(state.reportLine.hasSuffix("; health sync: safe mode, add-ons are off, queued 0, never"))
    }

    @Test("Settings line") func settingsLine() {
        typealias Section = HealthShareSettingsSection
        #expect(Section.statusLine(HealthShareStatus(), safeMode: false) == "")
        #expect(Section.statusLine(HealthShareStatus(), safeMode: true).hasPrefix("Safe mode:"))
        let line = Section.statusLine(
            HealthShareStatus(lastAttempt: now, result: "no data", detail: "nothing new", queued: 0), safeMode: false
        )
        #expect(line.hasPrefix("Last sync ") && line.hasSuffix(": no data, nothing new"))
    }
}
