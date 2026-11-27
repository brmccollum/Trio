import Foundation

// Launch guard and safe mode for the private-build add-ons (widget feed, watch extras, sleep/workout sharing).
//
// Display/reporting safety only. Nothing here is read by the algorithm, the pump, the CGM or any dosing code.
//
// How it works: at the earliest point of app start an "unfinished launches" counter in UserDefaults is
// incremented and written through. Once the process has been alive for 20 seconds the counter goes back to 0.
// The 20-second mark is made from the main queue, so a blocked main thread never counts as a finished launch.
// If the counter was already 2 or more when the app starts, this run is in safe mode: the add-ons are off
// and stay off until the user turns them back on in Settings. A short ring of breadcrumbs (time, stage) is
// kept in UserDefaults so the next successful launch can say how far the failed one got.
//
// A main-thread heartbeat (`BaysylMainThreadHeartbeat`) adds one more way for a run to count: if the main
// thread stops answering for about 8 seconds, the run is counted as unfinished again and a breadcrumb is
// written from the background thread. If the main thread comes back, the count is taken off again.
//
// Everything is written so it cannot throw or trap: no force unwraps, no `try!`, no numeric conversions of
// values that have not been checked.

// MARK: - Stages

enum BaysylLaunchStage: String, CaseIterable {
    case appInit = "app init"
    case coreDataReady = "core data ready"
    case servicesAssembled = "services assembled"
    case sceneActive = "first scene active"
    case watchManagerSetUp = "watch manager set up"
    case widgetSnapshot = "first widget snapshot published"
    case healthTick = "first health tick"
    case launchFinished = "launch finished"
    case safeModeCleared = "safe mode cleared"
}

// MARK: - Breadcrumbs

struct BaysylBreadcrumb: Equatable {
    /// Seconds since 1970.
    let time: TimeInterval
    let stage: String

    /// "<whole seconds>|<stage>". The stage never contains a line break or the separator.
    var encoded: String {
        "\(Self.wholeSeconds(time))|\(Self.clean(stage))"
    }

    init(time: TimeInterval, stage: String) {
        self.time = time.isFinite ? time : 0
        self.stage = Self.clean(stage)
    }

    init?(encoded: String) {
        guard let separator = encoded.firstIndex(of: "|") else { return nil }
        let stage = String(encoded[encoded.index(after: separator)...])
        guard !stage.isEmpty, let time = Double(encoded[..<separator]), time.isFinite else { return nil }
        self.init(time: time, stage: stage)
    }

    /// Whole seconds as text without ever converting a Double to an Int.
    static func wholeSeconds(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.0f", value.rounded(.down))
    }

    static func clean(_ stage: String) -> String {
        let flat = stage
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(flat.prefix(100))
    }
}

// MARK: - Pure state machine

/// What is persisted between launches.
struct BaysylLaunchRecord: Equatable {
    /// Launches that started and never reached the 20-second mark, in a row.
    var unfinishedLaunches: Int = 0
    /// Sticky: stays on until the user clears it.
    var safeMode: Bool = false
    /// How many failed starts put the app into safe mode (for the Settings line).
    var safeModeFailures: Int = 0
    /// Encoded breadcrumbs, oldest first, at most `BaysylLaunchGuardCore.ringLimit`.
    var breadcrumbs: [String] = []
}

/// What this run learned at start.
struct BaysylLaunchInfo: Equatable {
    /// Unfinished launches in a row before this one.
    var priorUnfinished: Int = 0
    var safeMode: Bool = false
    var safeModeFailures: Int = 0
    /// Breadcrumbs of the launch before this one, oldest first.
    var previousStages: [BaysylBreadcrumb] = []

    var previousLaunchDidNotFinish: Bool { priorUnfinished > 0 }
}

enum BaysylLaunchGuardCore {
    /// Safe mode starts when this many launches in a row did not finish.
    static let safeModeThreshold = 2
    /// From this many unfinished launches in a row, the diagnostics subscriber is not registered either.
    static let diagnosticsCutoff = 4
    static let ringLimit = 40
    /// The process must stay alive this long for a launch to count as finished.
    static let finishDelay: TimeInterval = 20
    /// How often the finish check is repeated while the loop services do not exist yet.
    static let finishRetry: TimeInterval = 5
    static let stuckPrefix = "main thread stuck after stage "
    /// Joins the stage to the add-on operation the main thread was inside when it stopped answering.
    static let duringInfix = " during "
    static let slowPrefix = "slow: "
    /// A tracked operation that takes at least this long leaves a "slow: ..." breadcrumb.
    static let slowOperationThreshold: TimeInterval = 2
    static let recoveredStage = "main thread recovered"
    /// At most this many stuck breadcrumbs per run, so a stuttering main thread cannot flood the ring.
    static let stuckBreadcrumbLimit = 3
    private static let counterCeiling = 1_000_000

    /// Start of a launch: counts it as unfinished, decides safe mode, opens a new breadcrumb run.
    static func begin(_ record: BaysylLaunchRecord, now: TimeInterval) -> (record: BaysylLaunchRecord, info: BaysylLaunchInfo) {
        let prior = min(max(0, record.unfinishedLaunches), counterCeiling)
        let entersSafeMode = prior >= safeModeThreshold
        let safeMode = record.safeMode || entersSafeMode

        var failures = max(0, record.safeModeFailures)
        if entersSafeMode { failures = max(failures, prior) }
        if !safeMode { failures = 0 }

        let info = BaysylLaunchInfo(
            priorUnfinished: prior,
            safeMode: safeMode,
            safeModeFailures: failures,
            previousStages: lastLaunchStages(decode(record.breadcrumbs))
        )

        var next = record
        next.unfinishedLaunches = prior + 1
        next.safeMode = safeMode
        next.safeModeFailures = failures
        next = append(next, stage: BaysylLaunchStage.appInit.rawValue, now: now)
        return (next, info)
    }

    /// The process stayed alive long enough: the launch counts as finished. Safe mode is not changed.
    static func finish(_ record: BaysylLaunchRecord, now: TimeInterval) -> BaysylLaunchRecord {
        var next = record
        next.unfinishedLaunches = 0
        return append(next, stage: BaysylLaunchStage.launchFinished.rawValue, now: now)
    }

    /// The main thread stopped answering: the run counts as unfinished again (as if it never reached the
    /// 20-second mark), and a breadcrumb names the last stage reached.
    /// `during` is the tracked add-on operation the main thread was inside at that moment, if any.
    static func mainThreadStuck(
        _ record: BaysylLaunchRecord,
        priorUnfinished: Int,
        during operation: String? = nil,
        now: TimeInterval
    ) -> BaysylLaunchRecord {
        var next = record
        next.unfinishedLaunches = max(next.unfinishedLaunches, min(max(0, priorUnfinished), counterCeiling) + 1)
        var stage = stuckPrefix + lastRealStage(decode(record.breadcrumbs))
        if let operation, !operation.isEmpty { stage += duringInfix + operation }
        return append(next, stage: stage, now: now)
    }

    /// The breadcrumb for a tracked operation that took `seconds`, nil when it was quick enough to say nothing.
    static func slowStage(_ name: String, seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= slowOperationThreshold else { return nil }
        return slowPrefix + name + " " + BaysylBreadcrumb.wholeSeconds(seconds) + "s"
    }

    /// The main thread answered again. The count goes back to 0 only if the launch had already finished.
    static func mainThreadRecovered(
        _ record: BaysylLaunchRecord,
        launchFinished: Bool,
        now: TimeInterval
    ) -> BaysylLaunchRecord {
        var next = record
        if launchFinished { next.unfinishedLaunches = 0 }
        return append(next, stage: recoveredStage, now: now)
    }

    /// The newest stage that is not itself a stuck/recovered marker.
    static func lastRealStage(_ crumbs: [BaysylBreadcrumb]) -> String {
        crumbs.last(where: { !$0.stage.hasPrefix(stuckPrefix) && $0.stage != recoveredStage })?.stage ?? "unknown"
    }

    /// The user turned the add-ons back on.
    static func clearSafeMode(_ record: BaysylLaunchRecord, now: TimeInterval) -> BaysylLaunchRecord {
        var next = record
        next.safeMode = false
        next.safeModeFailures = 0
        return append(next, stage: BaysylLaunchStage.safeModeCleared.rawValue, now: now)
    }

    /// Adds one breadcrumb and keeps only the newest `ringLimit`.
    static func append(_ record: BaysylLaunchRecord, stage: String, now: TimeInterval) -> BaysylLaunchRecord {
        var next = record
        next.breadcrumbs.append(BaysylBreadcrumb(time: now, stage: stage).encoded)
        if next.breadcrumbs.count > ringLimit {
            next.breadcrumbs = Array(next.breadcrumbs.suffix(ringLimit))
        }
        return next
    }

    static func decode(_ encoded: [String]) -> [BaysylBreadcrumb] {
        encoded.compactMap(BaysylBreadcrumb.init(encoded:))
    }

    /// The breadcrumbs of the most recent launch: from its last "app init" to the end.
    static func lastLaunchStages(_ crumbs: [BaysylBreadcrumb]) -> [BaysylBreadcrumb] {
        guard let start = crumbs.lastIndex(where: { $0.stage == BaysylLaunchStage.appInit.rawValue }) else {
            return crumbs
        }
        return Array(crumbs[start...])
    }
}

// MARK: - UserDefaults wrapper

final class BaysylLaunchGuard {
    enum Keys {
        static let unfinishedLaunches = "bryan.launchGuard.unfinishedLaunches"
        static let safeMode = "bryan.launchGuard.safeMode"
        static let safeModeFailures = "bryan.launchGuard.safeModeFailures"
        static let breadcrumbs = "bryan.launchGuard.breadcrumbs"
    }

    /// The app's guard. Inert while unit tests host the app, so test runs never count as failed launches.
    static let shared = BaysylLaunchGuard(defaults: .standard, inert: BaysylLaunchGuard.isRunningTests)

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// True while iOS is only prewarming the process: no launch has been asked for yet.
    static var isPrewarming: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    private let defaults: UserDefaults
    private let inert: Bool
    private let lock = NSLock()

    private var started = false
    private var record = BaysylLaunchRecord()
    private var launchInfo = BaysylLaunchInfo()
    private var finished = false
    private var servicesReady = false
    private var markedOnce = Set<String>()
    private var stuckBreadcrumbs = 0
    private var stuckNow = false

    init(defaults: UserDefaults, inert: Bool = false) {
        self.defaults = defaults
        self.inert = inert
    }

    // MARK: Launch

    /// Counts this launch as unfinished and writes it through. Safe to call more than once; only the first counts.
    @discardableResult func start(now: Date = Date()) -> BaysylLaunchInfo {
        lock.lock()
        defer { lock.unlock() }
        return startLocked(now: now)
    }

    private func startLocked(now: Date) -> BaysylLaunchInfo {
        guard !started else { return launchInfo }
        started = true
        guard !inert else { return launchInfo }

        let stored = BaysylLaunchRecord(
            unfinishedLaunches: defaults.integer(forKey: Keys.unfinishedLaunches),
            safeMode: defaults.bool(forKey: Keys.safeMode),
            safeModeFailures: defaults.integer(forKey: Keys.safeModeFailures),
            breadcrumbs: defaults.stringArray(forKey: Keys.breadcrumbs) ?? []
        )
        let begun = BaysylLaunchGuardCore.begin(stored, now: now.timeIntervalSince1970)
        record = begun.record
        launchInfo = begun.info
        markedOnce.insert(BaysylLaunchStage.appInit.rawValue)
        persistLocked()
        return launchInfo
    }

    /// Marks the launch finished (counter back to 0). Returns the launch info the first time, nil afterwards.
    @discardableResult func finish(now: Date = Date()) -> BaysylLaunchInfo? {
        lock.lock()
        defer { lock.unlock() }
        _ = startLocked(now: now)
        guard !finished else { return nil }
        finished = true
        guard !inert else { return nil }
        record = BaysylLaunchGuardCore.finish(record, now: now.timeIntervalSince1970)
        persistLocked()
        return launchInfo
    }

    /// Calls `finish` from the MAIN queue once the process has been running for `delay` seconds, so a blocked
    /// main thread never counts as a finished launch. A responsive main queue is not enough on its own: while the
    /// loop services have not been assembled (Core Data still loading, or failed), the check is repeated and the
    /// launch stays unfinished. `completion` then runs off the main queue.
    func scheduleFinish(
        after delay: TimeInterval = BaysylLaunchGuardCore.finishDelay,
        then completion: @escaping (BaysylLaunchInfo) -> Void = { _ in }
    ) {
        guard !inert else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.areServicesReady else {
                self.scheduleFinish(after: BaysylLaunchGuardCore.finishRetry, then: completion)
                return
            }
            guard let info = self.finish() else { return }
            DispatchQueue.global(qos: .utility).async { completion(info) }
        }
    }

    // MARK: Main-thread heartbeat results (called from the heartbeat's background queue)

    /// The main thread has not answered: count the run as unfinished and leave a breadcrumb. Never waits long
    /// for the lock (the main thread might be the one holding it).
    @discardableResult func noteMainThreadStuck(now: Date = Date()) -> Bool {
        guard !inert, lock.lock(before: Date().addingTimeInterval(1)) else { return false }
        defer { lock.unlock() }
        guard started else { return false }
        stuckNow = true
        if stuckBreadcrumbs < BaysylLaunchGuardCore.stuckBreadcrumbLimit {
            stuckBreadcrumbs += 1
            record = BaysylLaunchGuardCore.mainThreadStuck(
                record,
                priorUnfinished: launchInfo.priorUnfinished,
                during: currentMainOperation,
                now: now.timeIntervalSince1970
            )
        } else {
            record.unfinishedLaunches = max(record.unfinishedLaunches, launchInfo.priorUnfinished + 1)
        }
        persistLocked()
        return true
    }

    /// The main thread answered again after having been reported stuck.
    func noteMainThreadRecovered(now: Date = Date()) {
        guard !inert, lock.lock(before: Date().addingTimeInterval(1)) else { return }
        defer { lock.unlock() }
        guard started, stuckNow else { return }
        stuckNow = false
        record = BaysylLaunchGuardCore.mainThreadRecovered(
            record,
            launchFinished: finished,
            now: now.timeIntervalSince1970
        )
        if record.breadcrumbs.count > BaysylLaunchGuardCore.ringLimit {
            record.breadcrumbs = Array(record.breadcrumbs.suffix(BaysylLaunchGuardCore.ringLimit))
        }
        persistLocked()
    }

    /// Unfinished-launch count as persisted right now (for tests and the Settings line).
    var unfinishedLaunches: Int {
        lock.lock()
        defer { lock.unlock() }
        return record.unfinishedLaunches
    }

    // MARK: State

    var info: BaysylLaunchInfo {
        lock.lock()
        defer { lock.unlock() }
        return startLocked(now: Date())
    }

    /// True while the add-ons must stay off. Becomes false as soon as the user clears safe mode.
    var isSafeMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startLocked(now: Date()).safeMode
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var areServicesReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return servicesReady
    }

    /// The user's "Turn add-ons back on".
    func clearSafeMode(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        _ = startLocked(now: now)
        guard !inert else { return }
        launchInfo.safeMode = false
        launchInfo.safeModeFailures = 0
        record = BaysylLaunchGuardCore.clearSafeMode(record, now: now.timeIntervalSince1970)
        persistLocked()
    }

    // MARK: Breadcrumbs

    /// Records a launch stage, once per run. Cheap, synchronous, cannot throw.
    func mark(_ stage: BaysylLaunchStage, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if stage == .servicesAssembled { servicesReady = true }
        guard !inert, !markedOnce.contains(stage.rawValue) else { return }
        _ = startLocked(now: now)
        markedOnce.insert(stage.rawValue)
        record = BaysylLaunchGuardCore.append(record, stage: stage.rawValue, now: now.timeIntervalSince1970)
        persistLocked()
    }

    var breadcrumbs: [BaysylBreadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        return BaysylLaunchGuardCore.decode(record.breadcrumbs)
    }

    /// Records a free-text breadcrumb, every time it is called (unlike `mark`). For things that happen a few
    /// times an hour at most, such as a Health sync starting and ending. Same cost as `mark`.
    func note(_ text: String, now: Date = Date()) {
        guard !inert else { return }
        lock.lock()
        defer { lock.unlock() }
        _ = startLocked(now: now)
        record = BaysylLaunchGuardCore.append(record, stage: text, now: now.timeIntervalSince1970)
        persistLocked()
    }

    // MARK: Tracked add-on operations

    private let operationLock = NSLock()
    private var mainOperation: String?

    /// The tracked operation the main thread is inside right now, if any. Read by the heartbeat's thread.
    var currentMainOperation: String? {
        operationLock.lock()
        defer { operationLock.unlock() }
        return mainOperation
    }

    /// Runs `body` and names it for the launch report. Costs two short locks and a clock read. On the main
    /// thread the name is held while `body` runs, so a "main thread stuck" breadcrumb can say "during <name>".
    /// On any thread, a `body` that takes `slowOperationThreshold` or longer leaves a "slow: <name> Ns"
    /// breadcrumb. Nothing is written for a quick one.
    @discardableResult func track<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard !inert else { return try body() }
        let onMain = Thread.isMainThread
        var previous: String?
        if onMain {
            operationLock.lock()
            previous = mainOperation
            mainOperation = name
            operationLock.unlock()
        }
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            if onMain {
                operationLock.lock()
                mainOperation = previous
                operationLock.unlock()
            }
            let ended = DispatchTime.now().uptimeNanoseconds
            let seconds = ended >= started ? Double(ended - started) / 1_000_000_000 : 0
            if let stage = BaysylLaunchGuardCore.slowStage(name, seconds: seconds) { note(stage) }
        }
        return try body()
    }

    private func persistLocked() {
        defaults.set(record.unfinishedLaunches, forKey: Keys.unfinishedLaunches)
        defaults.set(record.safeMode, forKey: Keys.safeMode)
        defaults.set(record.safeModeFailures, forKey: Keys.safeModeFailures)
        defaults.set(record.breadcrumbs, forKey: Keys.breadcrumbs)
        // Flushed straight away so a crash a moment later still finds the count on the next launch, but never
        // on the caller's thread: this runs under the guard's lock, often on the main thread, and the loop must
        // not wait behind a preferences write.
        let defaults = self.defaults
        Self.flushQueue.async { defaults.synchronize() }
    }

    private static let flushQueue = DispatchQueue(label: "BaysylLaunchGuard.flush", qos: .utility)
}

// MARK: - Per-add-on switches

/// The on/off switch of each private-build add-on, readable from non-UI code. Safe mode overrides all of them.
enum BaysylAddOns {
    static let widgetFeedKey = "bryan.addons.widgetFeed"
    static let watchExtrasKey = "bryan.addons.watchExtras"

    /// On unless the user turned the switch off (a missing value means on) and never while in safe mode.
    static func isOn(key: String, defaults: UserDefaults, safeMode: Bool) -> Bool {
        guard !safeMode else { return false }
        return (defaults.object(forKey: key) as? Bool) ?? true
    }

    /// Home-screen and lock-screen widget snapshot publishing.
    static var widgetFeed: Bool {
        isOn(key: widgetFeedKey, defaults: .standard, safeMode: BaysylLaunchGuard.shared.isSafeMode)
    }

    /// Watch extras: state built without reachability, today's stats, application context on every send.
    /// Off means the watch manager behaves as it did before those were added.
    static var watchExtras: Bool {
        isOn(key: watchExtrasKey, defaults: .standard, safeMode: BaysylLaunchGuard.shared.isSafeMode)
    }

    /// With watch extras on, an unreachable watch still gets a fresh state through the application context.
    /// That refresh costs several Core Data fetches, so it is held back until the launch has finished and
    /// then runs at most once per this interval (about one loop cycle), not on every IOB update.
    static let backgroundWatchRefreshInterval: TimeInterval = 4 * 60

    static func allowsBackgroundWatchRefresh(lastRefresh: Date?, now: Date, launchFinished: Bool) -> Bool {
        guard launchFinished else { return false }
        guard let lastRefresh else { return true }
        let elapsed = now.timeIntervalSince(lastRefresh)
        // A clock that went backwards must not block refreshes for good.
        return elapsed < 0 || elapsed >= backgroundWatchRefreshInterval
    }

    /// "Share sleep and workouts" keeps its own switch (off by default); this only adds the safe-mode stop.
    static var healthShare: Bool {
        !BaysylLaunchGuard.shared.isSafeMode
    }
}

// MARK: - Main-thread heartbeat

/// The decision part of the heartbeat, pure so it can be tested with a made-up clock (nanoseconds).
struct BaysylHeartbeatMonitor: Equatable {
    enum Action: Equatable {
        case none
        case sendPing
        case reportStuck
        case reportRecovered
    }

    static let pingInterval: UInt64 = 2_000_000_000
    static let stuckAfter: UInt64 = 8_000_000_000
    /// A tick this long after the previous one means the process was suspended (or the device slept):
    /// that time is not held against the main thread.
    static let gapLimit: UInt64 = 6_000_000_000

    private(set) var pingPending = false
    private(set) var pingSentAt: UInt64 = 0
    private(set) var lastTick: UInt64?
    private(set) var reportedStuck = false

    /// - Parameters:
    ///   - now: monotonic time of this tick.
    ///   - answered: the main queue has run the last ping since the previous tick.
    mutating func tick(now: UInt64, answered: Bool) -> Action {
        let previousTick = lastTick
        lastTick = now

        if answered {
            pingPending = false
            if reportedStuck {
                reportedStuck = false
                return .reportRecovered
            }
        }

        if !pingPending {
            pingPending = true
            pingSentAt = now
            return .sendPing
        }

        if let previousTick, now >= previousTick, now - previousTick > Self.gapLimit {
            // Suspended in between: start the wait again from here.
            pingSentAt = now
            return .none
        }

        let waited = now >= pingSentAt ? now - pingSentAt : 0
        if waited >= Self.stuckAfter, !reportedStuck {
            reportedStuck = true
            return .reportStuck
        }
        return .none
    }
}

/// A background timer pings the main queue every 2 seconds. If the main queue has not answered for about
/// 8 seconds, the launch guard is told (from the background thread). Never blocks: it only takes a short
/// lock around two flags and dispatches asynchronously.
final class BaysylMainThreadHeartbeat {
    static let shared = BaysylMainThreadHeartbeat()

    private let queue = DispatchQueue(label: "bryan.baysyl.heartbeat", qos: .utility)
    private let flagLock = NSLock()
    private var answered = false
    private var timer: DispatchSourceTimer?
    private var monitor = BaysylHeartbeatMonitor()

    /// Starts the timer once. Later calls do nothing.
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + .seconds(2),
                repeating: .seconds(2),
                leeway: .milliseconds(500)
            )
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    private func tick() {
        flagLock.lock()
        let wasAnswered = answered
        answered = false
        flagLock.unlock()

        switch monitor.tick(now: DispatchTime.now().uptimeNanoseconds, answered: wasAnswered) {
        case .none:
            break
        case .sendPing:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.flagLock.lock()
                self.answered = true
                self.flagLock.unlock()
            }
        case .reportStuck:
            BaysylLaunchGuard.shared.noteMainThreadStuck()
        case .reportRecovered:
            BaysylLaunchGuard.shared.noteMainThreadRecovered()
        }
    }
}
