import Foundation

// Wording and timing of the spoken alerts. Pure: no audio, no storage, no clock of its own.
//
// Announcements only. Nothing here is read by the algorithm, the pump, the CGM or any dosing code, and the
// phone's own glucose and loop alarms are not changed by it.

enum BaysylSpeechWording {
    enum Trend: String, Equatable {
        case falling
        case rising
        case steady
    }

    /// A reading under this (mg/dL) is spoken.
    static let lowLimit = 70
    /// The trend compares the newest reading with the oldest one inside this window.
    static let trendWindow: TimeInterval = 15 * 60
    /// A change of at least this many mg/dL over the window counts as rising or falling.
    static let trendThreshold = 5

    static let sample = "This is Baysyl. Glucose 57 and falling."

    /// Falling, rising or steady over the last 15 minutes; nil when there is only one reading to go on.
    static func trend(readings: [(date: Date, glucose: Int)], now: Date) -> Trend? {
        let recent = readings
            .filter { $0.glucose > 0 && $0.date <= now.addingTimeInterval(60) && now.timeIntervalSince($0.date) <= trendWindow }
            .sorted { $0.date < $1.date }
        guard let first = recent.first, let last = recent.last, last.date > first.date else { return nil }
        let change = last.glucose - first.glucose
        if change <= -trendThreshold { return .falling }
        if change >= trendThreshold { return .rising }
        return .steady
    }

    /// "Glucose 57 and falling". Without a trend: "Glucose 57".
    static func lowLine(glucoseText: String, trend: Trend?) -> String {
        guard let trend else { return "Glucose \(glucoseText)" }
        return "Glucose \(glucoseText) and \(trend.rawValue)"
    }

    /// The number as the user reads it: whole mg/dL, or mmol/L with one decimal.
    static func glucoseText(mgdL: Int, mmol: Bool) -> String {
        guard mmol else { return "\(mgdL)" }
        return String(format: "%.1f", (Double(mgdL) * 0.0555 * 10).rounded() / 10)
    }

    static func loopLine(minutes: Int) -> String {
        "Trio has not looped for \(max(0, minutes)) minutes"
    }
}

/// When a low is spoken: a fresh reading under 70, at most once every 5 minutes, and not again once glucose
/// is back at 70 or above (the next low then speaks straight away).
struct BaysylLowSpeechThrottle: Equatable {
    static let interval: TimeInterval = 5 * 60
    /// A reading older than this is not announced as if it were current.
    static let staleAfter: TimeInterval = 12 * 60

    private(set) var lastSpoken: Date?

    /// Call for every new reading. Returns true when it should be spoken now; call `spoke(at:)` once it was.
    mutating func wantsToSpeak(glucose: Int, readingDate: Date, now: Date) -> Bool {
        guard glucose > 0 else { return false }
        guard glucose < BaysylSpeechWording.lowLimit else {
            lastSpoken = nil
            return false
        }
        let age = now.timeIntervalSince(readingDate)
        guard age <= Self.staleAfter, age >= -60 else { return false }
        guard let lastSpoken else { return true }
        let elapsed = now.timeIntervalSince(lastSpoken)
        return elapsed < 0 || elapsed >= Self.interval
    }

    mutating func spoke(at date: Date) {
        lastSpoken = date
    }
}

/// When a stopped loop is spoken: first at 20 minutes without a successful loop, then at most every 20 minutes.
struct BaysylLoopSpeechThrottle: Equatable {
    static let threshold: TimeInterval = 20 * 60
    static let interval: TimeInterval = 20 * 60
    /// A "last loop" older than this is a phone that has not looped at all (new install, loop never set up),
    /// not a loop that stopped: nothing is said.
    static let ceiling: TimeInterval = 24 * 60 * 60

    private(set) var lastSpoken: Date?

    /// The whole minutes to announce now, or nil. Call `spoke(at:)` once it was spoken.
    mutating func minutesToAnnounce(lastLoop: Date?, now: Date) -> Int? {
        guard let lastLoop else { return nil }
        let stalled = now.timeIntervalSince(lastLoop)
        guard stalled.isFinite, stalled >= Self.threshold else {
            lastSpoken = nil
            return nil
        }
        guard stalled <= Self.ceiling else { return nil }
        if let lastSpoken {
            let elapsed = now.timeIntervalSince(lastSpoken)
            guard elapsed < 0 || elapsed >= Self.interval else { return nil }
        }
        return Int((stalled / 60).rounded(.down))
    }

    mutating func spoke(at date: Date) {
        lastSpoken = date
    }
}

/// Which audio session the speech uses.
enum BaysylSpeechAudio: Equatable {
    /// Follows the ring/silent switch and mixes with other audio.
    case ambient
    /// Plays with the switch on silent and lowers other audio while speaking.
    case playbackDucking

    static func mode(respectSilentMode: Bool) -> BaysylSpeechAudio {
        respectSilentMode ? .ambient : .playbackDucking
    }
}
