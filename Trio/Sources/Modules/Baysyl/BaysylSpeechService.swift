import AVFoundation
import Combine
import CoreData
import Foundation

// Spoken alerts: says a low glucose reading and a stopped loop out loud. Off by default.
//
// Announcements only. This listens to the same "new glucose" and "loop finished" signals the watch and the
// stock alarms listen to, and reads a few glucose rows. It writes nothing, and nothing here is read by the
// algorithm, the pump, the CGM or any dosing code. The phone's own alarms are untouched.

// MARK: - Alarm audio flag

/// True while Trio's own critical-alarm sound is playing. Set by `CriticalAlertAudioPlayer`, read by the
/// speaker, so speech never changes or releases the audio session underneath a sounding alarm.
enum BaysylAlarmAudio {
    private static let lock = NSLock()
    private static var playing = false

    static var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playing
    }

    static func set(_ value: Bool) {
        lock.lock()
        playing = value
        lock.unlock()
    }
}

// MARK: - Speaker

@MainActor final class BaysylSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = BaysylSpeaker()

    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    /// True while this speaker holds an active `.playback` session that must be released after the utterance.
    private var holdsPlaybackSession = false

    /// Speaks one line. Returns false, saying nothing, while Trio's alarm sound is playing or a line is
    /// already being spoken, or when the audio session cannot be set up.
    @discardableResult func speak(_ text: String, audio: BaysylSpeechAudio) -> Bool {
        guard !BaysylAlarmAudio.isPlaying, !synthesizer.isSpeaking, !text.isEmpty else { return false }
        let ready: Bool = BaysylLaunchGuard.shared.track("speech session") { () -> Bool in
            let session = AVAudioSession.sharedInstance()
            do {
                switch audio {
                case .ambient:
                    try session.setCategory(.ambient, mode: .default, options: [])
                case .playbackDucking:
                    try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                }
                try session.setActive(true, options: [])
                return true
            } catch {
                debug(.service, "Baysyl speech: audio session not available: \(error)")
                return false
            }
        }
        guard ready else { return false }
        holdsPlaybackSession = audio == .playbackDucking
        synthesizer.speak(AVSpeechUtterance(string: text))
        return true
    }

    private func finished() {
        guard holdsPlaybackSession else { return }
        holdsPlaybackSession = false
        // Releasing the session is what lets other audio come back up. Never while Trio's alarm is sounding:
        // deactivating would stop it. (The alarm player and this run on the main actor, so the check holds.)
        guard !BaysylAlarmAudio.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}

// MARK: - Service

final class BaysylSpeechService: @unchecked Sendable {
    static let shared = BaysylSpeechService()

    /// How often the "has the loop stopped" check runs on a timer. The timer only runs while iOS lets the app
    /// run (in practice: while it is open); every new glucose reading runs the same check as well.
    static let loopCheckInterval: TimeInterval = 60

    private let queue = DispatchQueue(label: "bryan.baysyl.speech", qos: .utility)
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private var timer: DispatchSourceTimer?
    private var lowThrottle = BaysylLowSpeechThrottle()
    private var loopThrottle = BaysylLoopSpeechThrottle()
    private var lastLoop: Date?
    private var fetchingGlucose = false
    private var apsManager: APSManager?
    private var settingsManager: SettingsManager?

    /// Subscribes once, and only when "Spoken alerts" is on (so never in safe mode), the launch has finished
    /// and the services exist. Called when the launch finishes and when the switch is turned on. Returns at once.
    func startIfNeeded() {
        let launchGuard = BaysylLaunchGuard.shared
        guard !BaysylLaunchGuard.isRunningTests, BaysylAddOns.spokenAlerts,
              launchGuard.isFinished, launchGuard.areServicesReady else { return }
        queue.async { [weak self] in self?.start() }
    }

    private func start() {
        guard !started,
              let glucoseStorage = TrioApp.resolver.resolve(GlucoseStorage.self),
              let apsManager = TrioApp.resolver.resolve(APSManager.self) else { return }
        started = true
        self.apsManager = apsManager
        settingsManager = TrioApp.resolver.resolve(SettingsManager.self)
        lastLoop = apsManager.lastLoopDate

        glucoseStorage.updatePublisher
            .receive(on: queue)
            .sink { [weak self] _ in self?.glucoseUpdated() }
            .store(in: &subscriptions)

        apsManager.lastLoopDateSubject
            .receive(on: queue)
            .sink { [weak self] date in self?.lastLoop = date }
            .store(in: &subscriptions)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.loopCheckInterval,
            repeating: Self.loopCheckInterval,
            leeway: .seconds(10)
        )
        timer.setEventHandler { [weak self] in self?.checkLoop() }
        self.timer = timer
        timer.resume()
        // Once per run: lets a launch report show that this add-on was running.
        BaysylLaunchGuard.shared.note("spoken alerts started")
    }

    // MARK: Lows (on `queue`)

    private func glucoseUpdated() {
        // Each CGM reading wakes Trio in the background, where the timer below does not run: this is the
        // check that still happens with the phone locked. The timer covers the app being open with no readings.
        checkLoop()
        guard BaysylAddOns.speakLows, !fetchingGlucose else { return }
        fetchingGlucose = true
        Task.detached(priority: .utility) { [weak self] in
            let readings = await Self.recentReadings()
            self?.queue.async { self?.evaluateLow(readings) }
        }
    }

    private func evaluateLow(_ readings: [(date: Date, glucose: Int)]) {
        fetchingGlucose = false
        guard BaysylAddOns.speakLows, let latest = readings.max(by: { $0.date < $1.date }) else { return }
        let now = Date()
        guard lowThrottle.wantsToSpeak(glucose: latest.glucose, readingDate: latest.date, now: now) else { return }
        let line = BaysylSpeechWording.lowLine(
            glucoseText: BaysylSpeechWording.glucoseText(
                mgdL: latest.glucose,
                mmol: settingsManager?.settings.units == .mmolL
            ),
            trend: BaysylSpeechWording.trend(readings: readings, now: now)
        )
        // Marked before the hop so two readings close together cannot both speak; taken back if nothing was said.
        let previous = lowThrottle
        lowThrottle.spoke(at: now)
        say(line) { [weak self] spoken in
            if !spoken { self?.lowThrottle = previous }
        }
    }

    /// The readings of the last 20 minutes, as plain values. One small fetch on its own background context,
    /// the same pattern the stock glucose alarms use.
    private static func recentReadings() async -> [(date: Date, glucose: Int)] {
        let cutoff = Date().addingTimeInterval(-20 * 60)
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "BaysylSpeechService.recentReadings"
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: GlucoseStored.self,
                onContext: context,
                predicate: NSPredicate(format: "date >= %@", cutoff as NSDate),
                key: "date",
                ascending: false,
                fetchLimit: 6
            )
            return await context.perform {
                ((results as? [GlucoseStored]) ?? []).compactMap { stored in
                    stored.date.map { (date: $0, glucose: Int(stored.glucose)) }
                }
            }
        } catch {
            debug(.service, "Baysyl speech: glucose fetch failed: \(error)")
            return []
        }
    }

    // MARK: Loop stopped (on `queue`)

    private func checkLoop() {
        guard BaysylAddOns.speakLoopStopped else { return }
        // Same exceptions as the stock "not looping" alarm: nothing is said while Trio is not expected to loop.
        guard settingsManager?.settings.dosingMode.automation != AutomationLevel.off,
              apsManager?.isManualTempBasal != true,
              apsManager?.isSuspended != true else { return }
        let now = Date()
        guard let minutes = loopThrottle.minutesToAnnounce(lastLoop: lastLoop, now: now) else { return }
        let previous = loopThrottle
        loopThrottle.spoke(at: now)
        say(BaysylSpeechWording.loopLine(minutes: minutes)) { [weak self] spoken in
            if !spoken { self?.loopThrottle = previous }
        }
    }

    private func say(_ line: String, then completion: @escaping (Bool) -> Void) {
        let audio = BaysylSpeechAudio.mode(respectSilentMode: BaysylAddOns.respectSilentMode)
        let queue = self.queue
        Task { @MainActor in
            let spoken = BaysylSpeaker.shared.speak(line, audio: audio)
            queue.async { completion(spoken) }
        }
    }
}
