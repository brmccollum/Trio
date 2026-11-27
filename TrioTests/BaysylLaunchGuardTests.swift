import Foundation
import Testing

@testable import Trio

/// Tests for the private-build launch guard: the counter and safe-mode state machine, the breadcrumb ring,
/// the main-thread heartbeat decisions, the add-on switches and the launch report text.
/// Pure where possible; the UserDefaults wrapper is exercised against throwaway suites.
@Suite("Baysyl launch guard tests") struct BaysylLaunchGuardTests {
    private typealias Core = BaysylLaunchGuardCore

    private func crumb(_ time: TimeInterval, _ stage: String) -> BaysylBreadcrumb {
        BaysylBreadcrumb(time: time, stage: stage)
    }

    // MARK: Counter and safe mode

    @Test("A first launch counts one unfinished launch and is not in safe mode") func firstLaunch() {
        let begun = Core.begin(BaysylLaunchRecord(), now: 100)
        #expect(begun.record.unfinishedLaunches == 1)
        #expect(begun.info.priorUnfinished == 0)
        #expect(begun.info.safeMode == false)
        #expect(begun.info.previousLaunchDidNotFinish == false)
        #expect(Core.decode(begun.record.breadcrumbs).map(\.stage) == ["app init"])
    }

    @Test("Finishing sets the counter back to zero") func finishing() {
        let begun = Core.begin(BaysylLaunchRecord(), now: 100)
        let finished = Core.finish(begun.record, now: 120)
        #expect(finished.unfinishedLaunches == 0)
        #expect(Core.decode(finished.breadcrumbs).last?.stage == "launch finished")
        #expect(Core.begin(finished, now: 200).info.priorUnfinished == 0)
    }

    @Test("One unfinished launch is not enough; two in a row start safe mode") func threshold() {
        var record = BaysylLaunchRecord()
        record = Core.begin(record, now: 1).record // launch 1, never finishes
        let second = Core.begin(record, now: 2) // launch 2 sees 1 unfinished
        #expect(second.info.priorUnfinished == 1)
        #expect(second.info.safeMode == false)
        let third = Core.begin(second.record, now: 3) // launch 3 sees 2 unfinished
        #expect(third.info.priorUnfinished == 2)
        #expect(third.info.safeMode == true)
        #expect(third.info.safeModeFailures == 2)
        #expect(third.record.safeMode == true)
    }

    @Test("Safe mode stays on after a finished launch, until it is cleared") func safeModeIsSticky() {
        var record = BaysylLaunchRecord(unfinishedLaunches: 2)
        record = Core.finish(Core.begin(record, now: 1).record, now: 21)
        #expect(record.unfinishedLaunches == 0)
        #expect(record.safeMode == true)

        let next = Core.begin(record, now: 100)
        #expect(next.info.safeMode == true)
        #expect(next.info.safeModeFailures == 2)

        let cleared = Core.clearSafeMode(Core.finish(next.record, now: 120), now: 130)
        #expect(cleared.safeMode == false)
        #expect(cleared.safeModeFailures == 0)
        let afterClear = Core.begin(cleared, now: 200)
        #expect(afterClear.info.safeMode == false)
        #expect(afterClear.info.safeModeFailures == 0)
    }

    @Test("A corrupt negative counter is treated as zero") func negativeCounter() {
        let begun = Core.begin(BaysylLaunchRecord(unfinishedLaunches: -5), now: 1)
        #expect(begun.info.priorUnfinished == 0)
        #expect(begun.record.unfinishedLaunches == 1)
        #expect(begun.info.safeMode == false)
    }

    @Test("A huge counter does not overflow") func hugeCounter() {
        let begun = Core.begin(BaysylLaunchRecord(unfinishedLaunches: Int.max), now: 1)
        #expect(begun.info.safeMode == true)
        #expect(begun.record.unfinishedLaunches > 0)
    }

    // MARK: Main thread stuck

    @Test("A stuck main thread after a finished launch counts the run as unfinished again") func stuckCounts() {
        var record = Core.finish(Core.begin(BaysylLaunchRecord(), now: 1).record, now: 21)
        record = Core.append(record, stage: BaysylLaunchStage.sceneActive.rawValue, now: 30)
        #expect(record.unfinishedLaunches == 0)

        let stuck = Core.mainThreadStuck(record, priorUnfinished: 0, now: 80)
        #expect(stuck.unfinishedLaunches == 1)
        #expect(Core.decode(stuck.breadcrumbs).last?.stage == "main thread stuck after stage first scene active")

        // Killed while stuck: the next launch sees one unfinished launch; a second such run starts safe mode.
        let second = Core.begin(stuck, now: 200)
        #expect(second.info.priorUnfinished == 1)
        let stuckAgain = Core.mainThreadStuck(Core.finish(second.record, now: 220), priorUnfinished: 1, now: 300)
        #expect(stuckAgain.unfinishedLaunches == 2)
        #expect(Core.begin(stuckAgain, now: 400).info.safeMode == true)
    }

    @Test("A main thread that comes back takes the count off again, only if the launch had finished") func recovered() {
        let begun = Core.begin(BaysylLaunchRecord(), now: 1)
        let stuckEarly = Core.mainThreadStuck(begun.record, priorUnfinished: 0, now: 10)
        #expect(Core.mainThreadRecovered(stuckEarly, launchFinished: false, now: 15).unfinishedLaunches == 1)

        let stuckLate = Core.mainThreadStuck(Core.finish(begun.record, now: 21), priorUnfinished: 0, now: 60)
        let back = Core.mainThreadRecovered(stuckLate, launchFinished: true, now: 70)
        #expect(back.unfinishedLaunches == 0)
        #expect(Core.decode(back.breadcrumbs).last?.stage == "main thread recovered")
    }

    @Test("The stuck breadcrumb names the last real stage, not an earlier stuck marker") func stuckNamesRealStage() {
        var record = Core.begin(BaysylLaunchRecord(), now: 1).record
        record = Core.append(record, stage: "services assembled", now: 2)
        record = Core.mainThreadStuck(record, priorUnfinished: 0, now: 10)
        record = Core.mainThreadRecovered(record, launchFinished: false, now: 12)
        record = Core.mainThreadStuck(record, priorUnfinished: 0, now: 30)
        #expect(Core.decode(record.breadcrumbs).last?.stage == "main thread stuck after stage services assembled")
    }

    @Test("A stuck breadcrumb names the add-on operation the main thread was inside") func stuckNamesOperation() {
        var record = Core.finish(Core.begin(BaysylLaunchRecord(), now: 1).record, now: 21)
        record = Core.append(record, stage: "health sync start", now: 30)
        let plain = Core.mainThreadStuck(record, priorUnfinished: 0, now: 40)
        #expect(Core.decode(plain.breadcrumbs).last?.stage == "main thread stuck after stage health sync start")

        let named = Core.mainThreadStuck(record, priorUnfinished: 0, during: "widget publish", now: 40)
        #expect(
            Core.decode(named.breadcrumbs).last?.stage
                == "main thread stuck after stage health sync start during widget publish"
        )
        // Still a stuck marker: the next one names the real stage again, not this one.
        #expect(Core.lastRealStage(Core.decode(named.breadcrumbs)) == "health sync start")
        #expect(named.unfinishedLaunches == 1)
    }

    @Test("Only a slow tracked operation leaves a breadcrumb") func slowOperations() {
        #expect(Core.slowStage("widget publish", seconds: 0.01) == nil)
        #expect(Core.slowStage("widget publish", seconds: 1.9) == nil)
        #expect(Core.slowStage("widget publish", seconds: 9.4) == "slow: widget publish 9s")
        #expect(Core.slowStage("widget publish", seconds: .nan) == nil)
    }

    @Test(
        "Notes repeat, tracked operations are named while they run, and quick ones write nothing"
    ) @MainActor func notesAndTracking() throws {
        let name = "BaysylLaunchGuardTests.track.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let launchGuard = BaysylLaunchGuard(defaults: defaults)
        launchGuard.start()

        launchGuard.note("health sync start")
        launchGuard.note("health sync end: nothing new")
        launchGuard.note("health sync start")
        #expect(launchGuard.breadcrumbs.map(\.stage) == [
            "app init", "health sync start", "health sync end: nothing new", "health sync start"
        ])

        #expect(launchGuard.currentMainOperation == nil)
        let value = launchGuard.track("outer") { () -> Int in
            #expect(launchGuard.currentMainOperation == "outer")
            launchGuard.track("inner") { #expect(launchGuard.currentMainOperation == "inner") }
            #expect(launchGuard.currentMainOperation == "outer")
            return 7
        }
        #expect(value == 7)
        #expect(launchGuard.currentMainOperation == nil)
        #expect(launchGuard.breadcrumbs.count == 4)

        // Stuck while inside a tracked operation: the breadcrumb says which.
        launchGuard.track("watch context update") { _ = launchGuard.noteMainThreadStuck() }
        #expect(
            launchGuard.breadcrumbs.last?.stage
                == "main thread stuck after stage health sync start during watch context update"
        )
    }

    // MARK: Heartbeat decisions

    private let second: UInt64 = 1_000_000_000

    @Test("A main thread that answers every ping is never reported") func heartbeatHealthy() {
        var monitor = BaysylHeartbeatMonitor()
        #expect(monitor.tick(now: 0, answered: false) == .sendPing)
        for step in 1 ... 20 {
            #expect(monitor.tick(now: UInt64(step) * 2 * second, answered: true) == .sendPing)
        }
    }

    @Test("No answer for 8 seconds is reported once, then recovery is reported") func heartbeatStuck() {
        var monitor = BaysylHeartbeatMonitor()
        #expect(monitor.tick(now: 0, answered: false) == .sendPing)
        #expect(monitor.tick(now: 2 * second, answered: false) == .none)
        #expect(monitor.tick(now: 4 * second, answered: false) == .none)
        #expect(monitor.tick(now: 6 * second, answered: false) == .none)
        #expect(monitor.tick(now: 8 * second, answered: false) == .reportStuck)
        #expect(monitor.tick(now: 10 * second, answered: false) == .none)
        #expect(monitor.tick(now: 12 * second, answered: true) == .reportRecovered)
        #expect(monitor.tick(now: 14 * second, answered: false) == .sendPing)
    }

    @Test("Time spent suspended is not held against the main thread") func heartbeatIgnoresSuspension() {
        var monitor = BaysylHeartbeatMonitor()
        #expect(monitor.tick(now: 0, answered: false) == .sendPing)
        #expect(monitor.tick(now: 2 * second, answered: false) == .none)
        // Suspended for ten minutes: the next tick restarts the wait instead of reporting.
        let resumed = 602 * second
        #expect(monitor.tick(now: resumed, answered: false) == .none)
        #expect(monitor.tick(now: resumed + 2 * second, answered: false) == .none)
        #expect(monitor.tick(now: resumed + 4 * second, answered: true) == .sendPing)
        // Still stuck for a full 8 seconds of running time after the resume: reported.
        var stuck = BaysylHeartbeatMonitor()
        _ = stuck.tick(now: 0, answered: false)
        _ = stuck.tick(now: resumed, answered: false)
        #expect(stuck.tick(now: resumed + 2 * second, answered: false) == .none)
        #expect(stuck.tick(now: resumed + 4 * second, answered: false) == .none)
        #expect(stuck.tick(now: resumed + 6 * second, answered: false) == .none)
        #expect(stuck.tick(now: resumed + 8 * second, answered: false) == .reportStuck)
    }

    // MARK: Breadcrumb ring

    @Test("The ring keeps only the newest 40 breadcrumbs") func ringIsBounded() {
        var record = BaysylLaunchRecord()
        for index in 0 ..< 100 {
            record = Core.append(record, stage: "stage \(index)", now: TimeInterval(index))
        }
        #expect(record.breadcrumbs.count == Core.ringLimit)
        let stages = Core.decode(record.breadcrumbs).map(\.stage)
        #expect(stages.first == "stage 60")
        #expect(stages.last == "stage 99")
    }

    @Test("Breadcrumbs survive encoding, odd characters and bad times") func breadcrumbEncoding() {
        let plain = crumb(1_764_000_000.7, "services assembled")
        #expect(plain.encoded == "1764000000|services assembled")
        #expect(BaysylBreadcrumb(encoded: plain.encoded) == crumb(1_764_000_000, "services assembled"))

        #expect(crumb(5, "a|b\nc").stage == "a/b c")
        #expect(crumb(.nan, "x").encoded == "0|x")
        #expect(crumb(.infinity, "x").encoded == "0|x")
        #expect(BaysylBreadcrumb(encoded: "no separator") == nil)
        #expect(BaysylBreadcrumb(encoded: "abc|stage") == nil)
        #expect(BaysylBreadcrumb(encoded: "12|") == nil)
        #expect(crumb(1, String(repeating: "x", count: 500)).stage.count == 100)
    }

    @Test("The previous launch's stages run from its last app init to the end") func previousStages() {
        var record = BaysylLaunchRecord()
        record = Core.begin(record, now: 10).record
        record = Core.append(record, stage: "services assembled", now: 12)
        record = Core.finish(record, now: 30)
        record = Core.begin(record, now: 100).record
        record = Core.append(record, stage: "core data ready", now: 103)

        let next = Core.begin(record, now: 200)
        #expect(next.info.previousStages.map(\.stage) == ["app init", "core data ready"])
        #expect(next.info.previousStages.first?.time == 100)
    }

    // MARK: UserDefaults wrapper

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "BaysylLaunchGuardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("The wrapper writes the count through at start and clears it at finish") func wrapperCounts() throws {
        try withDefaults { defaults in
            let first = BaysylLaunchGuard(defaults: defaults)
            #expect(first.start().priorUnfinished == 0)
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 1)
            // A second call in the same run does not count again.
            first.start()
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 1)

            #expect(first.isFinished == false)
            #expect(first.finish() != nil)
            #expect(first.finish() == nil)
            #expect(first.isFinished == true)
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 0)
        }
    }

    @Test(
        "Two runs that never finish put the third in safe mode; clearing turns it off at once and for good"
    ) func wrapperSafeMode() throws {
        try withDefaults { defaults in
            BaysylLaunchGuard(defaults: defaults).start()
            #expect(BaysylLaunchGuard(defaults: defaults).start().safeMode == false)

            let third = BaysylLaunchGuard(defaults: defaults)
            #expect(third.isSafeMode == true)
            #expect(third.info.safeModeFailures == 2)
            #expect(BaysylAddOns.isOn(key: BaysylAddOns.widgetFeedKey, defaults: defaults, safeMode: third.isSafeMode) == false)

            third.clearSafeMode()
            #expect(third.isSafeMode == false)
            third.finish()
            #expect(BaysylLaunchGuard(defaults: defaults).isSafeMode == false)
        }
    }

    @Test("Stages are recorded once per run and in order") func wrapperBreadcrumbs() throws {
        try withDefaults { defaults in
            let launchGuard = BaysylLaunchGuard(defaults: defaults)
            launchGuard.start()
            #expect(launchGuard.areServicesReady == false)
            launchGuard.mark(.servicesAssembled)
            launchGuard.mark(.widgetSnapshot)
            launchGuard.mark(.widgetSnapshot)
            launchGuard.mark(.servicesAssembled)
            #expect(launchGuard.areServicesReady == true)
            #expect(launchGuard.breadcrumbs.map(\.stage) == [
                "app init", "services assembled", "first widget snapshot published"
            ])
            #expect((defaults.stringArray(forKey: BaysylLaunchGuard.Keys.breadcrumbs) ?? []).count == 3)
        }
    }

    @Test("A stuck main thread is persisted from the wrapper, capped, and undone on recovery") func wrapperStuck() throws {
        try withDefaults { defaults in
            let launchGuard = BaysylLaunchGuard(defaults: defaults)
            launchGuard.start()
            launchGuard.finish()
            #expect(launchGuard.unfinishedLaunches == 0)

            #expect(launchGuard.noteMainThreadStuck() == true)
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 1)
            #expect(launchGuard.breadcrumbs.last?.stage == "main thread stuck after stage launch finished")

            launchGuard.noteMainThreadRecovered()
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 0)

            for _ in 0 ..< 10 { launchGuard.noteMainThreadStuck() }
            let stuckCrumbs = launchGuard.breadcrumbs.filter { $0.stage.hasPrefix(BaysylLaunchGuardCore.stuckPrefix) }
            #expect(stuckCrumbs.count == BaysylLaunchGuardCore.stuckBreadcrumbLimit)
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 1)
        }
    }

    @Test("An inert guard (unit-test host) never counts, never enters safe mode, writes nothing") func inertGuard() throws {
        try withDefaults { defaults in
            defaults.set(5, forKey: BaysylLaunchGuard.Keys.unfinishedLaunches)
            let launchGuard = BaysylLaunchGuard(defaults: defaults, inert: true)
            #expect(launchGuard.start().safeMode == false)
            launchGuard.mark(.servicesAssembled)
            #expect(launchGuard.noteMainThreadStuck() == false)
            #expect(launchGuard.finish() == nil)
            #expect(defaults.integer(forKey: BaysylLaunchGuard.Keys.unfinishedLaunches) == 5)
            #expect(defaults.stringArray(forKey: BaysylLaunchGuard.Keys.breadcrumbs) == nil)
        }
    }

    // MARK: Add-on switches

    @Test("Add-on switches default to on, follow the stored value, and are off in safe mode") func addOnSwitches() throws {
        try withDefaults { defaults in
            let key = BaysylAddOns.watchExtrasKey
            #expect(BaysylAddOns.isOn(key: key, defaults: defaults, safeMode: false) == true)
            defaults.set(false, forKey: key)
            #expect(BaysylAddOns.isOn(key: key, defaults: defaults, safeMode: false) == false)
            defaults.set(true, forKey: key)
            #expect(BaysylAddOns.isOn(key: key, defaults: defaults, safeMode: false) == true)
            #expect(BaysylAddOns.isOn(key: key, defaults: defaults, safeMode: true) == false)
        }
    }

    @Test(
        "The background watch refresh waits for the launch to finish and runs at most every 4 minutes"
    ) func backgroundWatchRefresh() {
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        #expect(BaysylAddOns.allowsBackgroundWatchRefresh(lastRefresh: nil, now: now, launchFinished: false) == false)
        #expect(BaysylAddOns.allowsBackgroundWatchRefresh(lastRefresh: nil, now: now, launchFinished: true) == true)
        #expect(BaysylAddOns.allowsBackgroundWatchRefresh(
            lastRefresh: now.addingTimeInterval(-60), now: now, launchFinished: true
        ) == false)
        #expect(BaysylAddOns.allowsBackgroundWatchRefresh(
            lastRefresh: now.addingTimeInterval(-240), now: now, launchFinished: true
        ) == true)
        // A clock set backwards does not block refreshes for good.
        #expect(BaysylAddOns.allowsBackgroundWatchRefresh(
            lastRefresh: now.addingTimeInterval(3600), now: now, launchFinished: true
        ) == true)
    }

    @Test("The Settings line names the number of failed starts") func settingsLine() {
        let line = BaysylAddOnsSettingsSection.safeModeLine(failures: 3)
        #expect(line == "Safe mode: add-ons are off because Trio failed to start 3 times")
    }

    // MARK: Launch report text

    @Test("The launch report carries the count, last stage, safe mode, build and stages") func reportText() {
        let text = BaysylLaunchReport.text(
            priorUnfinished: 2,
            safeMode: true,
            build: BaysylLaunchReport.buildLabel(branchAndSha: "bryan-readonly-reporting 6eee2aa", buildNumber: "9"),
            stages: [crumb(100, "app init"), crumb(102.4, "core data ready"), crumb(109, "services assembled")]
        )
        let expected: String = [
            "Trio launch report: previous launch did not finish (2 in a row)",
            "last stage: services assembled",
            "safe mode: on",
            "build bryan-readonly-reporting 6eee2aa/9",
            "stages: app init+0s > core data ready+2s > services assembled+9s"
        ].joined(separator: "; ")
        #expect(text == expected)
    }

    @Test("A report with no breadcrumbs still reads properly") func reportWithoutStages() {
        let text = BaysylLaunchReport.text(
            priorUnfinished: 1,
            safeMode: false,
            build: BaysylLaunchReport.buildLabel(branchAndSha: nil, buildNumber: " "),
            stages: []
        )
        let expected: String = [
            "Trio launch report: previous launch did not finish (1 in a row)",
            "last stage: unknown",
            "safe mode: off",
            "build unknown/unknown",
            "stages: none"
        ].joined(separator: "; ")
        #expect(text == expected)
    }

    @Test("Reports are cut to the limit and marked as cut") func truncation() {
        let stages = (0 ..< 40).map { crumb(TimeInterval($0), String(repeating: "s", count: 90) + "\($0)") }
        let text = BaysylLaunchReport.text(priorUnfinished: 4, safeMode: true, build: "b/1", stages: stages)
        #expect(text.count == BaysylLaunchReport.noteLimit)
        #expect(text.hasSuffix("..."))
        #expect(text.hasPrefix("Trio launch report: previous launch did not finish (4 in a row)"))

        #expect(BaysylLaunchReport.truncate("abcdef", limit: 6) == "abcdef")
        #expect(BaysylLaunchReport.truncate("abcdefg", limit: 6) == "abc...")
        #expect(BaysylLaunchReport.truncate("abcdefg", limit: 2) == "ab")
        #expect(BaysylLaunchReport.truncate("abcdefg", limit: -1) == "")
    }

    // MARK: Outbox

    @Test("The outbox keeps notes until an upload succeeds, and only the newest 12") func outbox() async throws {
        let name = "BaysylLaunchGuardTests.outbox.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let outbox = BaysylNoteOutbox(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_764_000_000)
        for index in 0 ..< 15 {
            outbox.enqueue("note \(index)", at: start)
        }
        #expect(outbox.entries.count == BaysylNoteOutbox.limit)
        #expect(outbox.entries.first?.note == "note 3")

        let failed = await outbox.flush { _ in false }
        #expect(failed == false)
        #expect(outbox.entries.count == BaysylNoteOutbox.limit)

        var sent: [(note: String, createdAt: Date)] = []
        let succeeded = await outbox.flush { notes in
            sent = notes
            return true
        }
        #expect(succeeded == true)
        #expect(sent.count == BaysylNoteOutbox.limit)
        #expect(Set(sent.map(\.createdAt)).count == BaysylNoteOutbox.limit) // distinct times
        #expect(outbox.entries.isEmpty)

        // Survives a restart: a new outbox on the same store sees what was queued.
        outbox.enqueue("line one\nline two", at: start)
        #expect(BaysylNoteOutbox(defaults: defaults).entries.map(\.note) == ["line one line two"])
    }

    @Test("A note queued while an upload is in the air goes out in the same flush") func outboxPicksUpLateNote() async throws {
        let name = "BaysylLaunchGuardTests.outboxLate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let outbox = BaysylNoteOutbox(defaults: defaults)
        outbox.enqueue("first", at: Date(timeIntervalSince1970: 1_764_000_000))

        var batches: [[String]] = []
        let done = await outbox.flush { notes in
            batches.append(notes.map(\.note))
            if batches.count == 1 {
                outbox.enqueue("second", at: Date(timeIntervalSince1970: 1_764_000_060))
            }
            return true
        }
        #expect(done == true)
        #expect(batches == [["first"], ["second"]])
        #expect(outbox.entries.isEmpty)
    }
}
