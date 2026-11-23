import Foundation
import Testing

@testable import Trio

/// Tests for "Share sleep and workouts" (reporting only): collapsing Health samples, the note text, dedupe,
/// and that nothing is read or sent while the toggle is off.
/// Pure: HealthKit, Nightscout and UserDefaults.standard are never touched. All samples are invented.
@Suite("Health share tests") struct HealthShareTests {
    // MARK: - Helpers

    private static func t(_ iso: String) -> Date {
        HealthShareNote.date(fromISO: iso)!
    }

    private static func sample(_ start: String, _ end: String, _ stage: HealthShareSleepStage) -> HealthShareSleepSample {
        HealthShareSleepSample(start: t(start), end: t(end), stage: stage)
    }

    private static func workout(
        _ start: String,
        _ end: String,
        type: String = "Running",
        km: Double? = nil,
        kcal: Double? = nil,
        uuid: UUID = UUID()
    ) -> HealthShareWorkout {
        HealthShareWorkout(uuid: uuid, typeName: type, start: t(start), end: t(end), distanceKm: km, activeKcal: kcal)
    }

    private final class FakeReader: HealthShareReading {
        var samples: [HealthShareSleepSample] = []
        var workoutList: [HealthShareWorkout] = []
        var shouldThrow = false
        private(set) var authorizationRequests = 0
        private(set) var sleepQueries = 0
        private(set) var workoutQueries = 0
        private(set) var lastWindowStart: Date?

        var totalCalls: Int { authorizationRequests + sleepQueries + workoutQueries }

        func requestReadAuthorization() async -> Bool {
            authorizationRequests += 1
            return true
        }

        func sleepSamples(from: Date, to _: Date) async throws -> [HealthShareSleepSample] {
            sleepQueries += 1
            lastWindowStart = from
            if shouldThrow { throw TestError("Health unavailable") }
            return samples
        }

        func workouts(from _: Date, to _: Date) async throws -> [HealthShareWorkout] {
            workoutQueries += 1
            if shouldThrow { throw TestError("Health unavailable") }
            return workoutList
        }
    }

    private final class FakeUploader: HealthShareUploading {
        var canUpload = true
        var succeeds = true
        private(set) var attempts = 0
        private(set) var uploaded: [HealthShareRecord] = []

        func upload(_ records: [HealthShareRecord]) async -> Bool {
            attempts += 1
            guard succeeds else { return false }
            uploaded.append(contentsOf: records)
            return true
        }
    }

    private final class FakeStore: HealthShareStateStoring {
        var isEnabled: Bool
        var lastSuccess: Date?
        var lastAttempt: Date?
        var uploadedKeys: [String: Date] = [:]

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }
    }

    /// One ordinary night that crosses midnight (UTC), one nap, and two workouts.
    private static let night: [HealthShareSleepSample] = [
        sample("2026-01-04T22:30:00Z", "2026-01-05T06:10:00Z", .inBed),
        sample("2026-01-04T23:00:00Z", "2026-01-05T01:00:00Z", .asleep),
        sample("2026-01-05T01:00:00Z", "2026-01-05T01:20:00Z", .awake),
        sample("2026-01-05T01:20:00Z", "2026-01-05T06:00:00Z", .asleep)
    ]

    private static let nap = sample("2026-01-05T14:00:00Z", "2026-01-05T14:40:00Z", .asleep)
    private static let now = t("2026-01-05T20:00:00Z")

    // MARK: - Collapsing sleep

    @Test("A night crossing midnight becomes one period; awake time is not counted") func nightCrossingMidnight() {
        let periods = HealthShareCollapser.sleepPeriods(from: Self.night)
        #expect(periods == [
            HealthShareSleepPeriod(
                start: Self.t("2026-01-04T23:00:00Z"),
                end: Self.t("2026-01-05T06:00:00Z"),
                asleepMinutes: 400,
                source: .asleep
            )
        ])
    }

    @Test("Overlapping stages and a second device are counted once") func overlappingStages() {
        let samples = [
            Self.sample("2026-01-04T23:00:00Z", "2026-01-05T01:00:00Z", .asleep), // core
            Self.sample("2026-01-05T00:30:00Z", "2026-01-05T01:30:00Z", .asleep), // deep, overlaps core
            Self.sample("2026-01-05T01:30:00Z", "2026-01-05T02:00:00Z", .asleep), // REM, touches deep
            Self.sample("2026-01-04T23:00:00Z", "2026-01-05T02:00:00Z", .asleep), // the same night from another device
            Self.sample("2026-01-04T23:10:00Z", "2026-01-04T23:10:00Z", .asleep) // zero length, ignored
        ]
        let periods = HealthShareCollapser.sleepPeriods(from: samples.shuffled())
        #expect(periods.count == 1)
        #expect(periods.first?.asleepMinutes == 180)
        #expect(periods.first?.start == Self.t("2026-01-04T23:00:00Z"))
        #expect(periods.first?.end == Self.t("2026-01-05T02:00:00Z"))
    }

    @Test("A nap is its own period") func napIsSeparate() {
        let periods = HealthShareCollapser.sleepPeriods(from: Self.night + [Self.nap])
        #expect(periods.count == 2)
        #expect(periods.last == HealthShareSleepPeriod(
            start: Self.t("2026-01-05T14:00:00Z"),
            end: Self.t("2026-01-05T14:40:00Z"),
            asleepMinutes: 40,
            source: .asleep
        ))
    }

    @Test("In-bed samples are ignored when asleep stages exist, and used when they do not") func inBedFallback() {
        let withStages = HealthShareCollapser.sleepPeriods(from: Self.night)
        #expect(withStages.first?.source == .asleep)
        #expect(withStages.first?.start == Self.t("2026-01-04T23:00:00Z")) // not the 22:30 in-bed start

        let inBedOnly = HealthShareCollapser.sleepPeriods(from: [
            Self.sample("2026-01-04T22:30:00Z", "2026-01-05T06:10:00Z", .inBed)
        ])
        #expect(inBedOnly == [
            HealthShareSleepPeriod(
                start: Self.t("2026-01-04T22:30:00Z"),
                end: Self.t("2026-01-05T06:10:00Z"),
                asleepMinutes: 460,
                source: .inBed
            )
        ])
    }

    @Test("Awake-only samples and no samples give no period") func nothingToCollapse() {
        #expect(HealthShareCollapser.sleepPeriods(from: []).isEmpty)
        #expect(HealthShareCollapser.sleepPeriods(from: [
            Self.sample("2026-01-05T01:00:00Z", "2026-01-05T01:20:00Z", .awake)
        ]).isEmpty)
    }

    // MARK: - Note text

    @Test("Sleep note text is exact and parses back") func sleepNoteRoundTrip() throws {
        let period = try #require(HealthShareCollapser.sleepPeriods(from: Self.night).first)
        let note = HealthShareNote.text(for: period)
        #expect(note == "Health sleep: start=2026-01-04T23:00:00Z end=2026-01-05T06:00:00Z asleepMin=400")
        #expect(HealthShareNote.parse(note) == .sleep(
            start: period.start,
            end: period.end,
            asleepMinutes: 400,
            source: .asleep
        ))

        let inBed = HealthShareSleepPeriod(start: period.start, end: period.end, asleepMinutes: 420, source: .inBed)
        let inBedNote = HealthShareNote.text(for: inBed)
        #expect(inBedNote.hasSuffix("asleepMin=420 source=inBed"))
        #expect(HealthShareNote.parse(inBedNote) == .sleep(
            start: period.start,
            end: period.end,
            asleepMinutes: 420,
            source: .inBed
        ))
    }

    @Test("Workout note text is exact and parses back") func workoutNoteRoundTrip() {
        let run = Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z", km: 1.609, kcal: 117.6)
        let note = HealthShareNote.text(for: run)
        #expect(
            note ==
                "Health workout: type=Running start=2026-01-05T17:00:00Z end=2026-01-05T17:11:00Z min=11 km=1.61 kcal=118"
        )
        #expect(HealthShareNote.parse(note) == .workout(
            type: "Running",
            start: run.start,
            end: run.end,
            minutes: 11,
            km: 1.61,
            kcal: 118
        ))
    }

    @Test("A workout with no distance or energy leaves those fields out") func workoutWithoutDistance() {
        let lift = Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:45:30Z", type: "Strength Training!")
        let note = HealthShareNote.text(for: lift)
        #expect(note == "Health workout: type=StrengthTraining start=2026-01-05T17:00:00Z end=2026-01-05T17:45:30Z min=46")
        #expect(!note.contains("km="))
        #expect(!note.contains("kcal="))
        #expect(HealthShareNote.parse(note) == .workout(
            type: "StrengthTraining",
            start: lift.start,
            end: lift.end,
            minutes: 46,
            km: nil,
            kcal: nil
        ))
    }

    @Test("Other notes are not parsed as health notes") func parseRejectsOtherNotes() {
        #expect(HealthShareNote.parse("Bolus calc: option none; recommended 1 U; requested 1 U") == nil)
        #expect(HealthShareNote.parse("Health sleep: start=nonsense end=2026-01-05T06:00:00Z asleepMin=1") == nil)
        #expect(HealthShareNote.parse("Health workout: start=2026-01-05T06:00:00Z end=2026-01-05T06:30:00Z") == nil)
    }

    // MARK: - The uploaded record is inert

    @Test("The Nightscout record is a Note entered by Trio with text and time only") func recordIsInert() throws {
        let createdAt = Self.t("2026-01-05T06:00:00Z")
        let treatment = BaseNightscoutManager.datedNoteTreatment(note: "Health sleep: example", createdAt: createdAt)
        let data = try JSONCoding.encoder.encode([treatment])
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try #require(array.first)

        // Exactly these four fields go over the wire: nothing a carb, insulin, temp-target or override reader uses.
        #expect(Set(object.keys) == ["eventType", "created_at", "enteredBy", "notes"])
        #expect(object["eventType"] as? String == "Note")
        // Trio's own downloads exclude everything entered by "Trio".
        #expect(object["enteredBy"] as? String == "Trio")
        #expect(object["notes"] as? String == "Health sleep: example")
        #expect((object["created_at"] as? String)?.hasPrefix("2026-01-05T06:00:00") == true)
        for field in ["carbs", "insulin", "duration", "rate", "absolute", "targetTop", "targetBottom", "fat", "protein"] {
            #expect(object[field] == nil)
        }
    }

    // MARK: - Service: toggle off

    @Test("Toggle off: no HealthKit call and no upload") func toggleOffDoesNothing() async {
        let reader = FakeReader()
        reader.samples = Self.night
        reader.workoutList = [Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z")]
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: false)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store)

        #expect(await service.foregroundTick(now: Self.now) == .disabled)
        #expect(await service.enabledByUser(now: Self.now) == .disabled)

        #expect(reader.totalCalls == 0)
        #expect(uploader.attempts == 0)
        #expect(store.lastAttempt == nil)
        #expect(store.uploadedKeys.isEmpty)
    }

    @Test("The default is off") func defaultIsOff() throws {
        let name = "HealthShareTests.default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(HealthShareDefaultsStore(defaults: defaults).isEnabled == false)
    }

    @Test("The foreground tick never asks for permission; turning the toggle on does, once") func permissionOnlyFromToggle() async {
        let reader = FakeReader()
        let service = HealthShareService(reader: reader, uploader: FakeUploader(), store: FakeStore(isEnabled: true))

        _ = await service.foregroundTick(now: Self.now)
        #expect(reader.authorizationRequests == 0)

        _ = await service.enabledByUser(now: Self.now)
        #expect(reader.authorizationRequests == 1)
    }

    @Test("Nightscout upload off: Health is not read") func notReadyReadsNothing() async {
        let reader = FakeReader()
        reader.samples = Self.night
        let uploader = FakeUploader()
        uploader.canUpload = false
        let service = HealthShareService(reader: reader, uploader: uploader, store: FakeStore(isEnabled: true))

        #expect(await service.foregroundTick(now: Self.now) == .notReady)
        #expect(reader.sleepQueries == 0)
        #expect(reader.workoutQueries == 0)
        #expect(uploader.attempts == 0)
    }

    // MARK: - Service: upload and dedupe

    @Test("First run looks back 7 days and uploads each period and workout once") func firstRunUploads() async {
        let reader = FakeReader()
        reader.samples = Self.night + [Self.nap]
        reader.workoutList = [Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z", km: 1.609, kcal: 117.6)]
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store)

        #expect(await service.foregroundTick(now: Self.now) == .uploaded(3))
        #expect(reader.lastWindowStart == Self.now.addingTimeInterval(-7 * 24 * 3600))
        #expect(uploader.uploaded.map(\.note) == [
            "Health sleep: start=2026-01-04T23:00:00Z end=2026-01-05T06:00:00Z asleepMin=400",
            "Health sleep: start=2026-01-05T14:00:00Z end=2026-01-05T14:40:00Z asleepMin=40",
            "Health workout: type=Running start=2026-01-05T17:00:00Z end=2026-01-05T17:11:00Z min=11 km=1.61 kcal=118"
        ])
        // created_at is the end of each period.
        #expect(uploader.uploaded.map(\.createdAt) == [
            Self.t("2026-01-05T06:00:00Z"),
            Self.t("2026-01-05T14:40:00Z"),
            Self.t("2026-01-05T17:11:00Z")
        ])
        #expect(store.lastSuccess == Self.now)
    }

    @Test("Nothing is uploaded twice, and no more than one sync every few hours") func dedupeAndThrottle() async {
        let reader = FakeReader()
        reader.samples = Self.night
        let runID = UUID()
        reader.workoutList = [Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z", uuid: runID)]
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store)

        #expect(await service.foregroundTick(now: Self.now) == .uploaded(2))

        // Coming to the foreground again an hour later: throttled, Health is not read.
        let queriesAfterFirst = reader.sleepQueries
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(3600)) == .throttled)
        #expect(reader.sleepQueries == queriesAfterFirst)

        // Four hours later Health returns the same data (the window overlaps): nothing is sent again.
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(4 * 3600)) == .nothingNew)
        #expect(uploader.uploaded.count == 2)
        #expect(uploader.attempts == 1)

        // A new workout arrives: only it is sent.
        reader.workoutList.append(Self.workout("2026-01-06T02:00:00Z", "2026-01-06T02:30:00Z", type: "PaddleSports"))
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(8 * 3600)) == .uploaded(1))
        #expect(uploader.uploaded.count == 3)
        #expect(uploader.uploaded.last?.note.contains("type=PaddleSports") == true)
    }

    @Test("Dedupe survives an app restart") func dedupeSurvivesRestart() async throws {
        let name = "HealthShareTests.restart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: HealthShareDefaultsStore.enabledKey)

        let reader = FakeReader()
        reader.samples = Self.night
        reader.workoutList = [Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z")]
        let uploader = FakeUploader()

        let first = HealthShareService(
            reader: reader,
            uploader: uploader,
            store: HealthShareDefaultsStore(defaults: defaults)
        )
        #expect(await first.foregroundTick(now: Self.now) == .uploaded(2))

        // A new service and a new store over the same defaults, as after a relaunch.
        let restartedStore = HealthShareDefaultsStore(defaults: defaults)
        #expect(restartedStore.uploadedKeys.count == 2)
        #expect(restartedStore.lastSuccess == Self.now)
        let second = HealthShareService(reader: reader, uploader: uploader, store: restartedStore)
        #expect(await second.foregroundTick(now: Self.now.addingTimeInterval(4 * 3600)) == .nothingNew)
        #expect(uploader.uploaded.count == 2)
    }

    @Test("A failed upload marks nothing and is retried") func failedUploadIsRetried() async {
        let reader = FakeReader()
        reader.samples = Self.night
        let uploader = FakeUploader()
        uploader.succeeds = false
        let store = FakeStore(isEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store)

        #expect(await service.foregroundTick(now: Self.now) == .failed)
        #expect(store.uploadedKeys.isEmpty)
        #expect(store.lastSuccess == nil)

        // Straight away: held back. After the retry interval: sent.
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(60)) == .throttled)
        uploader.succeeds = true
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(11 * 60)) == .uploaded(1))
        #expect(uploader.uploaded.count == 1)
    }

    @Test("A Health read error fails quietly and is retried") func healthErrorIsRetried() async {
        let reader = FakeReader()
        reader.samples = Self.night
        reader.shouldThrow = true
        let uploader = FakeUploader()
        let service = HealthShareService(reader: reader, uploader: uploader, store: FakeStore(isEnabled: true))

        #expect(await service.foregroundTick(now: Self.now) == .failed)
        #expect(uploader.attempts == 0)
        reader.shouldThrow = false
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(11 * 60)) == .uploaded(1))
    }

    @Test("Sleep still in progress waits; a period cut by the window start is skipped") func unfinishedAndTruncated() {
        let windowStart = Self.t("2026-01-04T23:30:00Z")
        let samples = [
            // Began before the window: an earlier run sent the whole night.
            Self.sample("2026-01-04T23:00:00Z", "2026-01-05T06:00:00Z", .asleep),
            // Ended 20 minutes ago: may still be going.
            Self.sample("2026-01-05T19:00:00Z", "2026-01-05T19:40:00Z", .asleep)
        ]
        let early = HealthShareService.pendingRecords(
            samples: samples, workouts: [], windowStart: windowStart, now: Self.now, uploadedKeys: [:]
        )
        #expect(early.isEmpty)

        let later = HealthShareService.pendingRecords(
            samples: samples,
            workouts: [],
            windowStart: windowStart,
            now: Self.now.addingTimeInterval(3600),
            uploadedKeys: [:]
        )
        #expect(later.map(\.note) == ["Health sleep: start=2026-01-05T19:00:00Z end=2026-01-05T19:40:00Z asleepMin=40"])
    }

    @Test("Two records ending at the same instant get distinct timestamps") func distinctTimestamps() {
        let records = HealthShareService.pendingRecords(
            samples: [Self.nap],
            workouts: [Self.workout("2026-01-05T14:10:00Z", "2026-01-05T14:40:00Z", type: "Yoga")],
            windowStart: Self.now.addingTimeInterval(-7 * 24 * 3600),
            now: Self.now,
            uploadedKeys: [:]
        )
        #expect(records.count == 2)
        #expect(Set(records.map(\.createdAt)).count == 2)
        #expect(records[1].createdAt.timeIntervalSince(records[0].createdAt) < 0.01)
    }

    @Test("The window follows the last success, with overlap, capped at 30 days") func windowStart() {
        let day: TimeInterval = 24 * 3600
        #expect(HealthShareService.windowStart(lastSuccess: nil, now: Self.now) == Self.now.addingTimeInterval(-7 * day))
        #expect(
            HealthShareService.windowStart(lastSuccess: Self.now.addingTimeInterval(-3600), now: Self.now)
                == Self.now.addingTimeInterval(-7 * day)
        )
        #expect(
            HealthShareService.windowStart(lastSuccess: Self.now.addingTimeInterval(-10 * day), now: Self.now)
                == Self.now.addingTimeInterval(-12 * day)
        )
        #expect(
            HealthShareService.windowStart(lastSuccess: Self.now.addingTimeInterval(-90 * day), now: Self.now)
                == Self.now.addingTimeInterval(-30 * day)
        )
    }
}
