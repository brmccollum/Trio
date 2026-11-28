import Foundation

/// The state of every setting this private build adds outside Trio's own preferences and app settings,
/// as it is reported in the `trioSettings` snapshot of the Nightscout profile upload (object "baysyl") and in
/// the "Trio launch report:" Note.
///
/// Read-only reporting. Booleans only: no path, no folder name, no text. Nothing reads this back into Trio.
/// Each value is the EFFECTIVE state: a switch that safe mode is holding off is reported as off.
struct BaysylAddOnState: Codable, Equatable {
    /// The launch guard has turned the add-ons off for this run.
    let safeMode: Bool
    /// "Glucose widgets".
    let widgetFeed: Bool
    /// "Watch extras".
    let watchExtras: Bool
    /// "Share sleep and workouts" (one switch covers both).
    let healthShare: Bool
    /// "Heart rate and activity" (needs the switch above).
    let healthDays: Bool
    /// "Baysyl brief".
    let brief: Bool
    /// A folder has been chosen for the brief. Never the folder itself.
    let briefFolderChosen: Bool
    /// "Spoken alerts".
    let spokenAlerts: Bool
    /// "Speak lows" (needs "Spoken alerts").
    let speakLows: Bool
    /// "Speak when the loop stops" (needs "Spoken alerts").
    let speakLoopStopped: Bool
    /// "Respect silent mode", as stored (it is a preference of the spoken alerts, not an add-on).
    let respectSilentMode: Bool
    /// The Off-world appearance.
    let offworldTheme: Bool
    /// What the last Health sync did (state, not a setting): when, the result, notes still waiting.
    /// Only `health.result` counts towards the settings fingerprint, see `fingerprintForm`.
    var health: HealthShareStatus? = nil

    /// This state as it enters the settings fingerprint: without the parts that change on every sync, so a
    /// sync does not re-send the profile, while a change of result (ok, no permission requested, ...) does.
    var fingerprintForm: BaysylAddOnState {
        var copy = self
        copy.health = health.map { HealthShareStatus(lastAttempt: nil, result: $0.result, detail: "", queued: 0) }
        return copy
    }

    /// Every UserDefaults key this state is built from, with the value a missing entry stands for.
    /// `BaysylAddOnStateTests` fails when a key declared in `BaysylAddOns` is missing here.
    static let reportedDefaults: [String: Bool] = [
        BaysylAddOns.widgetFeedKey: true,
        BaysylAddOns.watchExtrasKey: true,
        HealthShareDefaultsStore.enabledKey: false,
        HealthShareDefaultsStore.daysEnabledKey: false,
        BaysylAddOns.briefKey: false,
        BaysylAddOns.spokenAlertsKey: false,
        BaysylAddOns.speakLowsKey: true,
        BaysylAddOns.speakLoopStoppedKey: true,
        BaysylAddOns.respectSilentModeKey: true,
        OffworldTheme.defaultsKey: false
    ]

    /// Reported as "is there a value", not as a switch.
    static let reportedPresenceKeys: [String] = [BaysylBriefStore.bookmarkKey]

    /// Safe mode is reported from the launch guard (stored under `BaysylLaunchGuard.Keys.safeMode`).
    static var reportedKeys: Set<String> {
        Set(reportedDefaults.keys).union(reportedPresenceKeys).union([BaysylLaunchGuard.Keys.safeMode])
    }

    static func current(defaults: UserDefaults, safeMode: Bool) -> BaysylAddOnState {
        func stored(_ key: String) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? (reportedDefaults[key] ?? false)
        }
        func addOn(_ key: String) -> Bool { !safeMode && stored(key) }

        let health = addOn(HealthShareDefaultsStore.enabledKey)
        let spoken = addOn(BaysylAddOns.spokenAlertsKey)
        return BaysylAddOnState(
            safeMode: safeMode,
            widgetFeed: addOn(BaysylAddOns.widgetFeedKey),
            watchExtras: addOn(BaysylAddOns.watchExtrasKey),
            healthShare: health,
            healthDays: health && stored(HealthShareDefaultsStore.daysEnabledKey),
            brief: addOn(BaysylAddOns.briefKey),
            briefFolderChosen: defaults.data(forKey: BaysylBriefStore.bookmarkKey) != nil,
            spokenAlerts: spoken,
            speakLows: spoken && stored(BaysylAddOns.speakLowsKey),
            speakLoopStopped: spoken && stored(BaysylAddOns.speakLoopStoppedKey),
            respectSilentMode: stored(BaysylAddOns.respectSilentModeKey),
            offworldTheme: stored(OffworldTheme.defaultsKey)
        )
    }

    /// The app's state right now. A few UserDefaults reads and one short lock; no I/O of its own.
    static var current: BaysylAddOnState {
        var state = current(defaults: .standard, safeMode: BaysylLaunchGuard.shared.isSafeMode)
        if UserDefaults.standard.bool(forKey: HealthShareDefaultsStore.enabledKey) {
            state.health = HealthShareStatusStore.load()
        }
        return state
    }

    /// One line for the launch report Note, e.g. "widgets on, watch on, health off, ...".
    var reportLine: String {
        func word(_ on: Bool) -> String { on ? "on" : "off" }
        return [
            "widgets \(word(widgetFeed))",
            "watch \(word(watchExtras))",
            "health \(word(healthShare))",
            "health days \(word(healthDays))",
            "brief \(word(brief))",
            "brief folder \(briefFolderChosen ? "chosen" : "none")",
            "speech \(word(spokenAlerts))",
            "speak lows \(word(speakLows))",
            "speak loop \(word(speakLoopStopped))",
            "silent mode \(respectSilentMode ? "respected" : "ignored")",
            "theme \(word(offworldTheme))"
        ].joined(separator: ", ") + (health.map { "; health sync: \($0.line)" } ?? "")
    }
}
