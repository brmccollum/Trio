import Foundation
import UIKit

// Storage and reading of the Baysyl brief (`brief.json` in a folder the user chose, normally in iCloud Drive).
//
// Display only, and read-only: the app never writes into the folder and makes no network call of its own
// (iOS downloads the file from iCloud when asked). Nothing here is read by the algorithm, the pump, the CGM or
// any dosing code.

// MARK: - Store

/// The folder bookmark, the last good brief and the last read status, in UserDefaults.
final class BaysylBriefStore {
    static let bookmarkKey = "bryan.brief.folderBookmark"
    /// The folder's display name, for the Settings line only. Never uploaded.
    static let folderNameKey = "bryan.brief.folderName"
    static let lastGoodKey = "bryan.brief.lastGood"
    static let lastGoodReadAtKey = "bryan.brief.lastGoodReadAt"
    static let statusKey = "bryan.brief.status"

    /// Posted (on any thread) after the stored brief, the folder or the status changed.
    static let didChange = Notification.Name("bryan.brief.didChange")

    static let shared = BaysylBriefStore(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: BaysylBrief?
    private var cacheLoaded = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The last brief that decoded cleanly, whatever the switch says.
    var lastGood: BaysylBrief? {
        lock.lock()
        defer { lock.unlock() }
        if !cacheLoaded {
            cacheLoaded = true
            if let data = defaults.data(forKey: Self.lastGoodKey) {
                cached = try? JSONDecoder().decode(BaysylBrief.self, from: data)
            }
        }
        return cached
    }

    /// The brief to show: the last good one while the "Baysyl brief" add-on is on, otherwise none.
    var displayBrief: BaysylBrief? {
        #if DEBUG && targetEnvironment(simulator)
            if BaysylDebug.wantsSampleBrief { return BaysylDebug.sampleBrief }
        #endif
        return BaysylAddOns.brief ? lastGood : nil
    }

    var lastGoodReadAt: Date? { defaults.object(forKey: Self.lastGoodReadAtKey) as? Date }
    var status: String { defaults.string(forKey: Self.statusKey) ?? "" }
    var folderName: String? { defaults.string(forKey: Self.folderNameKey) }
    var bookmark: Data? { defaults.data(forKey: Self.bookmarkKey) }
    var hasFolder: Bool { bookmark != nil }

    func save(_ brief: BaysylBrief, readAt: Date) {
        lock.lock()
        cached = brief
        cacheLoaded = true
        if let data = try? JSONEncoder().encode(brief) { defaults.set(data, forKey: Self.lastGoodKey) }
        defaults.set(readAt, forKey: Self.lastGoodReadAtKey)
        lock.unlock()
    }

    func setStatus(_ text: String) {
        defaults.set(String(text.prefix(200)), forKey: Self.statusKey)
        Foundation.NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func setFolder(bookmark: Data, name: String) {
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(String(name.prefix(80)), forKey: Self.folderNameKey)
        Foundation.NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func refreshBookmark(_ bookmark: Data) {
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }
}

// MARK: - Read policy (pure)

enum BaysylBriefReadPolicy {
    enum Trigger: Equatable {
        /// The app came to the foreground.
        case foreground
        /// The periodic check while the app stays open.
        case timer
        /// The user just chose a folder or turned the switch on.
        case user
    }

    /// The periodic read happens at most this often.
    static let interval: TimeInterval = 15 * 60
    /// Coming to the foreground reads again, but not more often than this (quick app switching).
    static let foregroundFloor: TimeInterval = 60

    static func allowsRead(
        trigger: Trigger,
        addOnOn: Bool,
        launchFinished: Bool,
        hasFolder: Bool,
        lastAttempt: Date?,
        now: Date
    ) -> Bool {
        guard addOnOn, launchFinished, hasFolder else { return false }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // A clock that went backwards must not block reads for good.
        guard elapsed >= 0 else { return true }
        switch trigger {
        case .user: return true
        case .foreground: return elapsed >= foregroundFloor
        case .timer: return elapsed >= interval
        }
    }
}

// MARK: - Service

/// Reads `brief.json` on its own utility queue: never on the main thread, never during launch, only while the
/// app is active and the device is unlocked, one read at a time.
final class BaysylBriefService: @unchecked Sendable {
    static let shared = BaysylBriefService(store: .shared)

    private let store: BaysylBriefStore
    private let queue = DispatchQueue(label: "bryan.baysyl.brief", qos: .utility)
    private let stateLock = NSLock()
    private var lastAttempt: Date?
    private var reading = false
    private var timer: DispatchSourceTimer?

    init(store: BaysylBriefStore) {
        self.store = store
    }

    /// Fire-and-forget entry points. Each returns at once.
    static func appDidBecomeActive() {
        shared.tick(.foreground)
    }

    static func launchFinished() {
        shared.tick(.foreground)
    }

    static func userChanged() {
        shared.tick(.user)
    }

    func tick(_ trigger: BaysylBriefReadPolicy.Trigger, now: Date = Date()) {
        guard !BaysylLaunchGuard.isRunningTests else { return }
        guard claim(trigger, now: now) else { return }
        startTimerIfNeeded()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // One short hop to the main actor; a busy main thread delays this, this never blocks it.
            let ready = await MainActor.run {
                UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
            }
            guard ready else {
                self.release(attempted: false, at: now)
                return
            }
            self.queue.async {
                BaysylLaunchGuard.shared.track("brief read") { self.read() }
                self.release(attempted: true, at: Date())
            }
        }
    }

    /// Decides and, when a read may start, marks one as in flight.
    private func claim(_ trigger: BaysylBriefReadPolicy.Trigger, now: Date) -> Bool {
        let launchGuard = BaysylLaunchGuard.shared
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !reading, BaysylBriefReadPolicy.allowsRead(
            trigger: trigger,
            addOnOn: BaysylAddOns.brief,
            // A read the user asked for from Settings does not wait for the 20-second launch mark.
            launchFinished: launchGuard.isFinished || trigger == .user,
            hasFolder: store.hasFolder,
            lastAttempt: lastAttempt,
            now: now
        ) else { return false }
        reading = true
        return true
    }

    private func release(attempted: Bool, at date: Date) {
        stateLock.lock()
        reading = false
        if attempted { lastAttempt = date }
        stateLock.unlock()
    }

    /// One timer for the life of the process, created the first time a read is allowed. Every 15 minutes it
    /// asks for a read; the same checks apply (switch, app active, unlocked), so it does nothing in the background.
    private func startTimerIfNeeded() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = BaysylBriefReadPolicy.interval
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in self?.tick(.timer) }
            self.timer = timer
            timer.resume()
        }
    }

    // MARK: Reading (on `queue`)

    private func read() {
        guard let bookmark = store.bookmark else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale) else {
            store.setStatus("The folder could not be opened. Choose it again.")
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? folder.bookmarkData() { store.refreshBookmark(fresh) }

        let file = folder.appendingPathComponent(BaysylBriefDecoder.fileName)
        // Asks iCloud for the file if it is not on the phone yet. Fails harmlessly for a local folder.
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)

        var data: Data?
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: file,
            options: [.withoutChanges],
            error: &coordinationError
        ) { url in
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BaysylBriefDecoder.maxBytes else {
                    readError = BaysylBriefDecodeError.tooLarge
                    return
                }
                data = try Data(contentsOf: url)
            } catch {
                readError = error
            }
        }

        if let failure = readError as? BaysylBriefDecodeError {
            store.setStatus(failure.message + ". Showing the last good brief.")
            return
        }
        guard let data else {
            let missing = [readError as NSError?, coordinationError].compactMap { $0 }.contains {
                $0.domain == NSCocoaErrorDomain
                    && ($0.code == NSFileReadNoSuchFileError || $0.code == NSFileNoSuchFileError)
            }
            store.setStatus(
                missing
                    ? "No brief.json in that folder yet."
                    : "brief.json could not be read (not downloaded yet, or the folder needs choosing again)."
            )
            return
        }

        switch BaysylBriefDecoder.decode(data) {
        case let .success(brief):
            store.save(brief, readAt: Date())
            store.setStatus("")
        case let .failure(failure):
            store.setStatus(failure.message + ". Showing the last good brief.")
        }
    }

    // MARK: Folder choice (called from Settings, on the main thread)

    /// Stores a bookmark for the folder the picker returned, then reads. The bookmark is made off the main thread.
    func userChoseFolder(_ url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData() else {
                self.store.setStatus("That folder could not be remembered. Choose it again.")
                return
            }
            self.store.setFolder(bookmark: bookmark, name: url.lastPathComponent)
            self.tick(.user)
        }
    }
}
