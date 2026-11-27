import Foundation
import HealthKit
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
        var dayList: [HealthShareDay] = []
        var daysShouldThrow = false
        private(set) var dayQueries = 0
        private(set) var lastDayStart: Date?

        /// What `dayAccessWasRequested` answers: the Health sheet for the day types has been answered.
        var dayAccessRequested = true
        private(set) var dayAccessChecks = 0
        private(set) var authorizationIncludedDays: [Bool] = []
        private(set) var dayWindows: [DateInterval] = []
        /// When set, `days` answers with one day per local day of the window asked for (plus `dayList`).
        var generatesDays = false

        var totalCalls: Int { authorizationRequests + sleepQueries + workoutQueries + dayQueries + dayAccessChecks }

        func requestReadAuthorization(includingDays: Bool) async -> Bool {
            authorizationRequests += 1
            authorizationIncludedDays.append(includingDays)
            return true
        }

        func dayAccessWasRequested() async -> Bool {
            dayAccessChecks += 1
            return dayAccessRequested
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

        func days(from: Date, to: Date) async throws -> [HealthShareDay] {
            dayQueries += 1
            lastDayStart = from
            dayWindows.append(DateInterval(start: from, end: max(from, to)))
            if shouldThrow || daysShouldThrow { throw TestError("Health unavailable") }
            guard generatesDays else { return dayList }
            var generated: [HealthShareDay] = []
            var start = HealthShareTests.pacific.startOfDay(for: from)
            while start < to {
                generated.append(HealthShareTests.day(HealthShareTests.dayName(start)))
                start = start.addingTimeInterval(24 * 3600)
            }
            return generated + dayList
        }
    }

    /// Fixed UTC-8, so a local day starts at 08:00Z, as in `day(_:)`.
    fileprivate static let pacific: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        return calendar
    }()

    fileprivate static func dayName(_ start: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = pacific
        formatter.timeZone = pacific.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }

    /// Collects the service's breadcrumbs.
    private final class Crumbs: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ text: String) { lock.withLock { list.append(text) } }
        var all: [String] { lock.withLock { list } }
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
        var isDaysEnabled: Bool
        var dayCursor: Date?

        init(isEnabled: Bool, isDaysEnabled: Bool = false) {
            self.isEnabled = isEnabled
            self.isDaysEnabled = isDaysEnabled
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

    @Test("A workout with heart rate carries its average and maximum") func workoutWithHeartRate() {
        var run = Self.workout("2026-01-05T17:00:00Z", "2026-01-05T17:11:00Z", km: 1.609, kcal: 117.6)
        run.averageHeartRate = 151.6
        run.maximumHeartRate = 171.2
        let note = HealthShareNote.text(for: run)
        #expect(
            note ==
                "Health workout: type=Running start=2026-01-05T17:00:00Z end=2026-01-05T17:11:00Z min=11 km=1.61 kcal=118"
                + " hrAvg=152 hrMax=171"
        )
        // The older fields still parse; the extra ones are ignored by this parser.
        #expect(HealthShareNote.parse(note) == .workout(
            type: "Running", start: run.start, end: run.end, minutes: 11, km: 1.61, kcal: 118
        ))
    }

    // MARK: - Day summaries (heart rate, variability, steps, energy)

    fileprivate static func day(
        _ date: String = "2026-01-04",
        resting: Int? = 52,
        hours: [HealthShareHourHeart] = [
            HealthShareHourHeart(hour: 1, min: 47, avg: 50, max: 58),
            HealthShareHourHeart(hour: 0, min: 48, avg: 52, max: 60)
        ]
    ) -> HealthShareDay {
        let start = t("\(date)T08:00:00Z")
        return HealthShareDay(
            date: date,
            start: start,
            end: start.addingTimeInterval(24 * 3600),
            restingHeartRate: resting,
            hrvMs: resting == nil ? nil : 48,
            steps: resting == nil ? nil : 8421,
            activeKcal: resting == nil ? nil : 612,
            hours: hours
        )
    }

    @Test("Day note text is exact, hours in order, and parses back") func dayNoteRoundTrip() {
        let day = Self.day()
        let note = HealthShareNote.text(for: day)
        #expect(
            note ==
                "Health day: date=2026-01-04 start=2026-01-04T08:00:00Z end=2026-01-05T08:00:00Z restingHR=52 hrv=48"
                + " steps=8421 kcal=612 hr=00:48/52/60,01:47/50/58"
        )
        var sorted = day
        sorted.hours = day.hours.sorted { $0.hour < $1.hour }
        #expect(HealthShareNote.parse(note) == .day(sorted))
    }

    @Test("A day with only some values leaves the rest out; an empty day is never sent") func partialAndEmptyDays() {
        let partial = Self.day(resting: nil)
        #expect(
            HealthShareNote.text(for: partial) ==
                "Health day: date=2026-01-04 start=2026-01-04T08:00:00Z end=2026-01-05T08:00:00Z hr=00:48/52/60,01:47/50/58"
        )
        let empty = Self.day(resting: nil, hours: [])
        #expect(empty.isEmpty)
        let records = HealthShareService.pendingRecords(
            samples: [], workouts: [], days: [empty, partial],
            windowStart: Self.now.addingTimeInterval(-7 * 24 * 3600), now: Self.now, uploadedKeys: [:]
        )
        #expect(records.map(\.note) == [HealthShareNote.text(for: partial)])
    }

    @Test("A day still in progress waits; a changed day is sent again, an unchanged one is not") func dayTimingAndDedupe() {
        let finished = Self.day("2026-01-04")
        let today = Self.day("2026-01-05")
        let window = Self.now.addingTimeInterval(-7 * 24 * 3600)
        let first = HealthShareService.pendingRecords(
            samples: [], workouts: [], days: [finished, today], windowStart: window, now: Self.now, uploadedKeys: [:]
        )
        #expect(first.map(\.note) == [HealthShareNote.text(for: finished)])
        #expect(first.first?.createdAt == finished.end)

        let sent = [first[0].key: first[0].createdAt]
        let again = HealthShareService.pendingRecords(
            samples: [], workouts: [], days: [finished], windowStart: window, now: Self.now, uploadedKeys: sent
        )
        #expect(again.isEmpty)

        var corrected = finished
        corrected.steps = 9000
        let resent = HealthShareService.pendingRecords(
            samples: [], workouts: [], days: [corrected], windowStart: window, now: Self.now, uploadedKeys: sent
        )
        #expect(resent.count == 1)
        #expect(HealthShareRecord.checksum("abc") == HealthShareRecord.checksum("abc"))
        #expect(HealthShareRecord.checksum("abc") != HealthShareRecord.checksum("abd"))
    }

    // MARK: - "Heart rate and activity": its own switch, a few days at a time, never asks from a sync

    private static let dayNotes = "Health day:"

    @Test("Heart rate and activity is off by default, and has its own stored switch") func daysDefaultOff() throws {
        let name = "HealthShareTests.days.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HealthShareDefaultsStore(defaults: defaults)
        #expect(store.isDaysEnabled == false)
        #expect(store.dayCursor == nil)

        defaults.set(true, forKey: HealthShareDefaultsStore.enabledKey)
        #expect(store.isEnabled == true)
        #expect(store.isDaysEnabled == false)
        defaults.set(true, forKey: HealthShareDefaultsStore.daysEnabledKey)
        #expect(store.isDaysEnabled == true)
        #expect(HealthShareDefaultsStore.daysEnabledKey != HealthShareDefaultsStore.enabledKey)

        store.dayCursor = Self.now
        #expect(HealthShareDefaultsStore(defaults: defaults).dayCursor == Self.now)
    }

    @Test("Switch off: no day type is asked for or read, and sleep and workouts still go") func daysOffReadsNoDays() async {
        let reader = FakeReader()
        reader.samples = Self.night
        reader.generatesDays = true
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true, isDaysEnabled: false)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store, calendar: Self.pacific)

        #expect(await service.enabledByUser(now: Self.now) == .uploaded(1))
        #expect(reader.authorizationIncludedDays == [false])
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(4 * 3600)) == .nothingNew)
        // Turning the day switch "on" in the service while the stored switch is off does nothing either.
        #expect(await service.daysEnabledByUser(now: Self.now.addingTimeInterval(8 * 3600)) == .disabled)

        #expect(reader.dayQueries == 0)
        #expect(reader.dayAccessChecks == 0)
        #expect(reader.authorizationRequests == 1)
        #expect(store.dayCursor == nil)
        #expect(uploader.uploaded.map(\.note) == [
            "Health sleep: start=2026-01-04T23:00:00Z end=2026-01-05T06:00:00Z asleepMin=400"
        ])
        #expect(!HealthKitShareReader.readTypes(includingDays: false).contains(HKQuantityType(.heartRate)))
        #expect(HealthKitShareReader.readTypes(includingDays: false) == HealthKitShareReader.baseTypes)
        #expect(HealthKitShareReader.readTypes(includingDays: true).isSuperset(of: HealthKitShareReader.dayTypes))
        #expect(HealthKitShareReader.baseTypes.isDisjoint(with: HealthKitShareReader.dayTypes))
    }

    @Test("Turning the day switch on asks for the day types once and sends the oldest three days") func daysSwitchOn() async {
        let reader = FakeReader()
        reader.generatesDays = true
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true, isDaysEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store, calendar: Self.pacific)

        #expect(await service.daysEnabledByUser(now: Self.now) == .uploaded(3))
        #expect(reader.authorizationIncludedDays == [true])
        // 60 days before 2026-01-05T20:00Z is 2025-11-06T20:00Z, local day 2025-11-06 (starts 08:00Z).
        #expect(reader.dayWindows == [DateInterval(start: Self.t("2025-11-06T08:00:00Z"), end: Self.t("2025-11-09T08:00:00Z"))])
        #expect(uploader.uploaded.map { String($0.note.prefix(27)) } == [
            "Health day: date=2025-11-06", "Health day: date=2025-11-07", "Health day: date=2025-11-08"
        ])
        #expect(store.dayCursor == Self.t("2025-11-09T08:00:00Z"))
    }

    @Test("The back-fill is incremental: at most three days per sync, oldest first, until caught up") func backfillIsIncremental() async {
        let reader = FakeReader()
        reader.generatesDays = true
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true, isDaysEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store, calendar: Self.pacific)

        var now = Self.now
        var sent: [String] = []
        var syncs = 0
        while HealthShareService.isBackfillPending(cursor: store.dayCursor, now: now), syncs < 40 {
            let before = uploader.uploaded.count
            // Sooner than the catch-up interval: nothing happens.
            if syncs > 0 {
                #expect(await service.foregroundTick(now: now.addingTimeInterval(-60)) == .throttled)
            }
            let outcome = await service.foregroundTick(now: now)
            let batch = uploader.uploaded[before...].map(\.note)
            #expect(batch.count <= HealthShareService.maximumDaysPerSync)
            #expect(outcome == .uploaded(batch.count))
            sent.append(contentsOf: batch)
            syncs += 1
            now = now.addingTimeInterval(HealthShareService.backfillInterval)
        }

        // Every read was at most three local days wide and started where the one before stopped.
        #expect(reader.dayWindows.allSatisfy { $0.duration <= 3 * 24 * 3600 })
        for (earlier, later) in zip(reader.dayWindows, reader.dayWindows.dropFirst()) {
            #expect(later.start == earlier.end)
        }
        #expect(syncs >= 18 && syncs <= 21)
        #expect(sent == sent.sorted())
        #expect(Set(sent).count == sent.count)
        #expect(sent.first?.hasPrefix("Health day: date=2025-11-06") == true)
        #expect(reader.authorizationRequests == 0)

        // Caught up: back to one sync every few hours, each re-reading only the last three days.
        #expect(await service.foregroundTick(now: now) == .throttled)
        let later = now.addingTimeInterval(HealthShareService.minimumInterval)
        let before = uploader.uploaded.count
        _ = await service.foregroundTick(now: later)
        #expect(uploader.uploaded.count - before <= HealthShareService.maximumDaysPerSync)
        #expect((reader.dayWindows.last?.duration ?? .infinity) <= 3 * 24 * 3600)
        #expect((reader.dayWindows.last?.start ?? .distantPast) >= later.addingTimeInterval(-4 * 24 * 3600))
    }

    @Test("Day windows and batches stay inside their bounds") func dayWindowBounds() {
        let now = Self.now
        let first = HealthShareService.dayWindow(cursor: nil, now: now, calendar: Self.pacific)
        #expect(first.start == Self.t("2025-11-06T08:00:00Z"))
        #expect(first.duration == 3 * 24 * 3600)

        // A cursor older than the back-fill window is pulled up to it; a recent one re-reads the last days.
        let ancient = HealthShareService.dayWindow(cursor: .distantPast, now: now, calendar: Self.pacific)
        #expect(ancient == first)
        let caughtUp = HealthShareService.dayWindow(cursor: now, now: now, calendar: Self.pacific)
        #expect(caughtUp.start == Self.t("2026-01-02T08:00:00Z"))
        #expect(caughtUp.end == Self.t("2026-01-05T08:00:00Z"))
        #expect(caughtUp.end <= now)

        // A reader that returns far more than it was asked for still yields three days, oldest first,
        // and the cursor stops after the last one kept.
        let many = (1 ... 9).map { Self.day("2025-11-0\($0)") } + [Self.day("2025-11-10")]
        let wide = DateInterval(start: Self.t("2025-11-01T08:00:00Z"), end: Self.t("2025-11-11T08:00:00Z"))
        let batch = HealthShareService.dayBatch(many.reversed(), window: wide, now: now)
        #expect(batch.days.map(\.date) == ["2025-11-01", "2025-11-02", "2025-11-03"])
        #expect(batch.cursor == Self.t("2025-11-04T08:00:00Z"))

        // Days outside the window, or not over for an hour yet, are left for a later sync.
        let window = DateInterval(start: Self.t("2026-01-03T08:00:00Z"), end: now)
        let recent = HealthShareService.dayBatch(
            [Self.day("2026-01-02"), Self.day("2026-01-03"), Self.day("2026-01-04"), Self.day("2026-01-05")],
            window: window,
            now: now
        )
        #expect(recent.days.map(\.date) == ["2026-01-03", "2026-01-04"])
        #expect(recent.cursor == now)

        #expect(HealthShareService.isBackfillPending(cursor: nil, now: now))
        #expect(HealthShareService.isBackfillPending(cursor: now.addingTimeInterval(-10 * 24 * 3600), now: now))
        #expect(!HealthShareService.isBackfillPending(cursor: now.addingTimeInterval(-2 * 24 * 3600), now: now))
        #expect(HealthShareService.maximumDaysPerSync == 3)
    }

    @Test("A sync never asks for Health permission, whatever state it finds") func syncNeverAsks() async {
        for daysEnabled in [false, true] {
            for accessRequested in [false, true] {
                for cursor in [nil, Self.now.addingTimeInterval(-30 * 24 * 3600), Self.now] as [Date?] {
                    let reader = FakeReader()
                    reader.samples = Self.night
                    reader.generatesDays = true
                    reader.dayAccessRequested = accessRequested
                    let store = FakeStore(isEnabled: true, isDaysEnabled: daysEnabled)
                    store.dayCursor = cursor
                    let service = HealthShareService(
                        reader: reader, uploader: FakeUploader(), store: store, calendar: Self.pacific
                    )
                    var now = Self.now
                    for _ in 0 ..< 4 {
                        _ = await service.foregroundTick(now: now)
                        now = now.addingTimeInterval(HealthShareService.minimumInterval + 60)
                    }
                    #expect(reader.authorizationRequests == 0)
                    // Access not answered yet (or the switch off): the day types are not read at all.
                    if !daysEnabled || !accessRequested { #expect(reader.dayQueries == 0) }
                }
            }
        }
    }

    @Test("App not active or device locked: Health is not touched, even from a switch") func notActiveDoesNothing() async {
        let reader = FakeReader()
        reader.samples = Self.night
        reader.generatesDays = true
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true, isDaysEnabled: true)
        let crumbs = Crumbs()
        let service = HealthShareService(
            reader: reader,
            uploader: uploader,
            store: store,
            isAppReady: { false },
            breadcrumb: { crumbs.add($0) },
            calendar: Self.pacific
        )

        #expect(await service.foregroundTick(now: Self.now) == .notReady)
        #expect(await service.enabledByUser(now: Self.now) == .notReady)
        #expect(await service.daysEnabledByUser(now: Self.now) == .notReady)

        #expect(reader.totalCalls == 0)
        #expect(uploader.attempts == 0)
        // Not counted as an attempt, so the next time the app is active the sync runs straight away.
        #expect(store.lastAttempt == nil)
        #expect(crumbs.all.isEmpty)
    }

    @Test("Each sync that reads Health leaves a start and an end breadcrumb with its outcome") func syncBreadcrumbs() async {
        let reader = FakeReader()
        reader.samples = Self.night
        let uploader = FakeUploader()
        let crumbs = Crumbs()
        let service = HealthShareService(
            reader: reader,
            uploader: uploader,
            store: FakeStore(isEnabled: true),
            breadcrumb: { crumbs.add($0) }
        )

        _ = await service.foregroundTick(now: Self.now)
        _ = await service.foregroundTick(now: Self.now.addingTimeInterval(60)) // throttled: no breadcrumb
        reader.shouldThrow = true
        _ = await service.foregroundTick(now: Self.now.addingTimeInterval(4 * 3600))

        #expect(crumbs.all == [
            "health sync start", "health sync end: uploaded 1", "health sync start", "health sync end: failed"
        ])
    }

    @Test("A failed day read never blocks sleep and workouts, and the back-fill stays where it was") func dayReadNeverBlocks() async {
        let reader = FakeReader()
        reader.samples = Self.night
        reader.daysShouldThrow = true
        let uploader = FakeUploader()
        let store = FakeStore(isEnabled: true, isDaysEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store, calendar: Self.pacific)

        #expect(await service.foregroundTick(now: Self.now) == .uploaded(1))
        #expect(uploader.uploaded.map(\.note) == [
            "Health sleep: start=2026-01-04T23:00:00Z end=2026-01-05T06:00:00Z asleepMin=400"
        ])
        #expect(reader.dayQueries == 1)
        #expect(store.dayCursor == nil)
    }

    @Test("A failed upload leaves the day cursor alone, so the same days are tried again") func failedUploadKeepsCursor() async {
        let reader = FakeReader()
        reader.generatesDays = true
        let uploader = FakeUploader()
        uploader.succeeds = false
        let store = FakeStore(isEnabled: true, isDaysEnabled: true)
        let service = HealthShareService(reader: reader, uploader: uploader, store: store, calendar: Self.pacific)

        #expect(await service.foregroundTick(now: Self.now) == .failed)
        #expect(store.dayCursor == nil)

        uploader.succeeds = true
        #expect(await service.foregroundTick(now: Self.now.addingTimeInterval(11 * 60)) == .uploaded(3))
        #expect(reader.dayWindows.count == 2)
        #expect(reader.dayWindows.first == reader.dayWindows.last)
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
        // "Heart rate and activity" is off: the request names sleep and workouts only.
        #expect(reader.authorizationIncludedDays == [false])
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
