import Foundation

// Launch report, the note outbox and the start-up glue for the launch guard.
//
// Reporting only. The only thing that ever leaves the phone from here is an inert Nightscout Note (text only,
// through the existing Note upload). No glucose, insulin or personal data is put in the text.

// MARK: - Report text (pure)

enum BaysylLaunchReport {
    /// Upper bound for one Note, in characters.
    static let noteLimit = 1500
    static let prefix = "Trio launch report:"

    static func text(
        priorUnfinished: Int,
        safeMode: Bool,
        build: String,
        stages: [BaysylBreadcrumb],
        limit: Int = noteLimit
    ) -> String {
        let lastStage = stages.last?.stage ?? "unknown"
        let text = "\(prefix) previous launch did not finish (\(max(0, priorUnfinished)) in a row); "
            + "last stage: \(lastStage); safe mode: \(safeMode ? "on" : "off"); build \(build); "
            + "stages: \(compactStages(stages))"
        return truncate(text, limit: limit)
    }

    /// "app init+0s > services assembled+2s": each stage with whole seconds since the first one.
    static func compactStages(_ stages: [BaysylBreadcrumb]) -> String {
        guard let first = stages.first else { return "none" }
        return stages.map { crumb in
            let offset = max(0, crumb.time - first.time)
            return "\(crumb.stage)+\(BaysylBreadcrumb.wholeSeconds(offset))s"
        }.joined(separator: " > ")
    }

    /// "<branch and sha>/<build number>", with "unknown" for a missing part.
    static func buildLabel(branchAndSha: String?, buildNumber: String?) -> String {
        let branch = (branchAndSha ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let number = (buildNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(branch.isEmpty ? "unknown" : branch)/\(number.isEmpty ? "unknown" : number)"
    }

    /// Never longer than `limit` characters; a cut text ends in "...".
    static func truncate(_ text: String, limit: Int) -> String {
        let ending = "..."
        guard limit > ending.count else { return String(text.prefix(max(0, limit))) }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - ending.count)) + ending
    }

    static var currentBuildLabel: String {
        buildLabel(branchAndSha: BuildDetails.shared.branchAndSha, buildNumber: Bundle.main.buildVersionNumber)
    }
}

// MARK: - Outbox

/// Notes waiting to be uploaded, kept in UserDefaults so they survive until Nightscout can be reached.
final class BaysylNoteOutbox {
    struct Entry: Equatable {
        let createdAt: Date
        let note: String

        var encoded: String {
            BaysylBreadcrumb.wholeSeconds(createdAt.timeIntervalSince1970) + "|" + note
        }

        init(createdAt: Date, note: String) {
            self.createdAt = createdAt
            self.note = note
        }

        init?(encoded: String) {
            guard let separator = encoded.firstIndex(of: "|"),
                  let time = Double(encoded[..<separator]), time.isFinite else { return nil }
            let note = String(encoded[encoded.index(after: separator)...])
            guard !note.isEmpty else { return nil }
            self.init(createdAt: Date(timeIntervalSince1970: time), note: note)
        }
    }

    static let key = "bryan.diagnostics.noteOutbox"
    /// Oldest entries are dropped beyond this.
    static let limit = 12

    static let shared = BaysylNoteOutbox(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var isFlushing = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    func enqueue(_ note: String, at date: Date = Date()) {
        let text = BaysylLaunchReport.truncate(
            note.replacingOccurrences(of: "\n", with: " "),
            limit: BaysylLaunchReport.noteLimit
        )
        guard !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = readLocked()
        all.append(Entry(createdAt: date, note: text))
        writeLocked(Array(all.suffix(Self.limit)))
    }

    func remove(_ sent: [Entry]) {
        lock.lock()
        defer { lock.unlock() }
        let sentKeys = Set(sent.map(\.encoded))
        writeLocked(readLocked().filter { !sentKeys.contains($0.encoded) })
    }

    /// Uploads what is waiting. Entries are removed only when `upload` reports success.
    /// `upload` receives each note with a distinct time (Nightscout merges same-time treatments of one type).
    @discardableResult func flush(upload: ([(note: String, createdAt: Date)]) async -> Bool) async -> Bool {
        guard beginFlush() else { return false }
        defer { endFlush() }
        let waiting = entries
        guard !waiting.isEmpty else { return true }
        guard await upload(Self.distinctTimes(waiting)) else { return false }
        remove(waiting)
        return true
    }

    static func distinctTimes(_ entries: [Entry]) -> [(note: String, createdAt: Date)] {
        var result: [(note: String, createdAt: Date)] = []
        for entry in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            var date = entry.createdAt
            if let previous = result.last?.createdAt, date <= previous {
                date = previous.addingTimeInterval(0.001)
            }
            result.append((note: entry.note, createdAt: date))
        }
        return result
    }

    private func beginFlush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFlushing else { return false }
        isFlushing = true
        return true
    }

    private func endFlush() {
        lock.lock()
        defer { lock.unlock() }
        isFlushing = false
    }

    private func readLocked() -> [Entry] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap(Entry.init(encoded:))
    }

    private func writeLocked(_ entries: [Entry]) {
        defaults.set(entries.map(\.encoded), forKey: Self.key)
    }
}

// MARK: - Start-up glue

/// The few calls the app makes into the launch guard. Each one is cheap and cannot throw.
enum BaysylStartup {
    /// Earliest point of app start. Safe to call again (the app delegate does, to cover a prewarmed process).
    static func appInit() {
        // A prewarmed process has not been asked to launch yet; the app delegate starts the guard when it is.
        guard !BaysylLaunchGuard.isPrewarming else { return }
        startOnce()
    }

    /// The app delegate's `didFinishLaunching`: a real launch, prewarmed or not.
    static func didFinishLaunching() {
        startOnce()
    }

    private static func startOnce() {
        guard beginOnce() else { return }
        let launchGuard = BaysylLaunchGuard.shared
        let info = launchGuard.start()
        launchGuard.scheduleFinish { finishedInfo in
            launchFinished(finishedInfo)
        }
        guard !BaysylLaunchGuard.isRunningTests else { return }
        BaysylMainThreadHeartbeat.shared.start()
        // After several failed starts in a row even the diagnostics subscriber stays out of the way.
        if info.priorUnfinished < BaysylLaunchGuardCore.diagnosticsCutoff {
            BaysylDiagnosticsSubscriber.shared.register()
        }
    }

    static func servicesAssembled() {
        BaysylLaunchGuard.shared.mark(.servicesAssembled)
        flushOutbox()
    }

    static func sceneActive() {
        BaysylLaunchGuard.shared.mark(.sceneActive)
        flushOutbox()
    }

    /// Queues the one launch report when the previous launch did not finish, then tries to upload.
    static func launchFinished(_ info: BaysylLaunchInfo) {
        if info.previousLaunchDidNotFinish {
            BaysylNoteOutbox.shared.enqueue(
                BaysylLaunchReport.text(
                    priorUnfinished: info.priorUnfinished,
                    safeMode: info.safeMode,
                    build: BaysylLaunchReport.currentBuildLabel,
                    stages: info.previousStages
                )
            )
        }
        flushOutbox()
    }

    /// Uploads waiting notes in its own low-priority task. Does nothing until this launch has finished and the
    /// services exist (resolving them earlier would build the service graph before Core Data is ready).
    static func flushOutbox() {
        let launchGuard = BaysylLaunchGuard.shared
        guard !BaysylLaunchGuard.isRunningTests, launchGuard.isFinished, launchGuard.areServicesReady else { return }
        Task.detached(priority: .utility) {
            await BaysylNoteOutbox.shared.flush { notes in
                guard TrioApp.resolver.resolve(SettingsManager.self)?.settings.isUploadEnabled ?? false,
                      let nightscout = TrioApp.resolver.resolve(NightscoutManager.self) else { return false }
                return await nightscout.uploadDatedNoteTreatments(notes)
            }
        }
    }

    private static let startLock = NSLock()
    private static var started = false

    private static func beginOnce() -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }
}
