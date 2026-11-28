import Foundation
import Testing

@testable import Trio

/// Tests for what the private build reports about its own settings: the "baysyl" object in the `trioSettings`
/// snapshot, its part in the settings fingerprint, and the add-on line of the launch report.
@Suite("Baysyl add-on state tests") struct BaysylAddOnStateTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "BaysylAddOnStateTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    /// Every reported switch turned on, with a folder chosen.
    private func allOn(_ defaults: UserDefaults) {
        for key in BaysylAddOnState.reportedDefaults.keys { defaults.set(true, forKey: key) }
        for key in BaysylAddOnState.reportedPresenceKeys { defaults.set(Data([1]), forKey: key) }
    }

    private func snapshot(_ state: BaysylAddOnState?) -> NightscoutTrioSettingsSnapshot {
        NightscoutTrioSettingsSnapshot(
            preferences: Preferences(),
            pumpSettings: PumpSettings(insulinActionCurve: 7, maxBolus: 6, maxBasal: 3.5),
            appSettings: TrioSettings(),
            appVersion: "1.0.2",
            branchAndSha: "branch abc1234",
            baysyl: state
        )
    }

    @Test("A fresh install: new add-ons off, older ones on, nothing chosen") func freshDefaults() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = BaysylAddOnState.current(defaults: defaults, safeMode: false)
        #expect(state == BaysylAddOnState(
            safeMode: false, widgetFeed: true, watchExtras: true, healthShare: false, healthDays: false,
            brief: false, briefFolderChosen: false, spokenAlerts: false, speakLows: false,
            speakLoopStopped: false, respectSilentMode: true, offworldTheme: false
        ))
    }

    @Test("Safe mode reports every add-on off, whatever the switches say") func safeMode() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        allOn(defaults)
        let state = BaysylAddOnState.current(defaults: defaults, safeMode: true)
        #expect(state.safeMode)
        #expect(!state.widgetFeed && !state.watchExtras && !state.healthShare && !state.healthDays)
        #expect(!state.brief && !state.spokenAlerts && !state.speakLows && !state.speakLoopStopped)
        // Not add-ons: reported as stored.
        #expect(state.briefFolderChosen && state.respectSilentMode && state.offworldTheme)
    }

    @Test("Sub-switches need their main switch") func subSwitches() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        allOn(defaults)
        defaults.set(false, forKey: BaysylAddOns.spokenAlertsKey)
        defaults.set(false, forKey: HealthShareDefaultsStore.enabledKey)
        let state = BaysylAddOnState.current(defaults: defaults, safeMode: false)
        #expect(!state.speakLows && !state.speakLoopStopped && !state.healthDays)
    }

    @Test("Changing any reported setting changes the state and the settings fingerprint") func everyKeyCounts() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        allOn(defaults)
        let base = BaysylAddOnState.current(defaults: defaults, safeMode: false)
        let baseFingerprint = snapshot(base).fingerprint
        #expect(!baseFingerprint.isEmpty)

        for key in BaysylAddOnState.reportedDefaults.keys.sorted() {
            defaults.set(false, forKey: key)
            let changed = BaysylAddOnState.current(defaults: defaults, safeMode: false)
            #expect(changed != base, "\(key) is not reported")
            #expect(snapshot(changed).fingerprint != baseFingerprint, "\(key) does not change the fingerprint")
            defaults.set(true, forKey: key)
        }
        for key in BaysylAddOnState.reportedPresenceKeys {
            defaults.removeObject(forKey: key)
            let changed = BaysylAddOnState.current(defaults: defaults, safeMode: false)
            #expect(snapshot(changed).fingerprint != baseFingerprint, "\(key) does not change the fingerprint")
            defaults.set(Data([1]), forKey: key)
        }
        let safe = BaysylAddOnState.current(defaults: defaults, safeMode: true)
        #expect(snapshot(safe).fingerprint != baseFingerprint)
        #expect(snapshot(nil).fingerprint != baseFingerprint)
        #expect(snapshot(base).fingerprint == baseFingerprint)
    }

    /// Fails when a UserDefaults key is added to `BaysylAddOns` (in BaysylLaunchGuard.swift) without being
    /// added to `BaysylAddOnState`. Reads the source file itself, so it needs no list kept by hand.
    @Test("Every key declared in BaysylAddOns is reported") func everyAddOnKeyIsReported() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Trio/Sources/Modules/Baysyl/BaysylLaunchGuard.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "enum BaysylAddOns {"))
        let body = text[start.upperBound...]
        let end = try #require(body.range(of: "\n}\n"))
        let section = String(body[..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: "static let \\w+Key = \"([^\"]+)\"")
        let declared = pattern
            .matches(in: section, range: NSRange(section.startIndex..., in: section))
            .compactMap { Range($0.range(at: 1), in: section).map { String(section[$0]) } }

        #expect(declared.count >= 7, "the add-on keys were not found in the source file")
        #expect(declared.contains(BaysylAddOns.widgetFeedKey))
        for key in declared {
            #expect(BaysylAddOnState.reportedKeys.contains(key), "\(key) is declared in BaysylAddOns but not reported")
        }
    }

    @Test("The snapshot carries the object, booleans only, and decodes without it") func snapshotJSON() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("secret/path/to/folder".utf8), forKey: BaysylBriefStore.bookmarkKey)
        defaults.set("Baysyl", forKey: BaysylBriefStore.folderNameKey)
        let state = BaysylAddOnState.current(defaults: defaults, safeMode: false)

        let data = try JSONCoding.encoder.encode(snapshot(state))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let baysyl = try #require(json["baysyl"] as? [String: Any])
        #expect(Set(baysyl.keys) == [
            "safeMode", "widgetFeed", "watchExtras", "healthShare", "healthDays", "brief", "briefFolderChosen",
            "spokenAlerts", "speakLows", "speakLoopStopped", "respectSilentMode", "offworldTheme"
        ])
        #expect(baysyl.values.allSatisfy { $0 is Bool })
        #expect(baysyl["briefFolderChosen"] as? Bool == true)
        let whole = try #require(String(data: data, encoding: .utf8))
        #expect(!whole.contains("secret"))
        #expect(!whole.contains("Baysyl"))

        let decoded = try JSONCoding.decoder.decode(NightscoutTrioSettingsSnapshot.self, from: data)
        #expect(decoded.baysyl == state)

        // A snapshot written before this field existed still decodes.
        let oldData = try JSONCoding.encoder.encode(snapshot(nil))
        let oldJSON = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        #expect(oldJSON["baysyl"] == nil)
        #expect(try JSONCoding.decoder.decode(NightscoutTrioSettingsSnapshot.self, from: oldData).baysyl == nil)
    }

    @Test("The launch report names the add-on state before the stages") func launchReport() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let state = BaysylAddOnState.current(defaults: defaults, safeMode: false)
        #expect(
            state.reportLine ==
                "widgets on, watch on, health off, health days off, brief off, brief folder none, speech off, "
                + "speak lows off, speak loop off, silent mode respected, theme off"
        )

        let text = BaysylLaunchReport.text(
            priorUnfinished: 2,
            safeMode: false,
            build: "b/13",
            stages: [BaysylBreadcrumb(time: 100, stage: "app init")],
            addOns: state
        )
        #expect(
            text == "Trio launch report: previous launch did not finish (2 in a row); last stage: app init; "
                + "safe mode: off; build b/13; add-ons now: \(state.reportLine); stages: app init+0s"
        )

        // The add-on line survives a stage list long enough to be cut.
        let many = (0 ..< 200).map { BaysylBreadcrumb(time: Double($0), stage: "stage number \($0)") }
        let long = BaysylLaunchReport.text(priorUnfinished: 2, safeMode: true, build: "b/13", stages: many, addOns: state)
        #expect(long.count == BaysylLaunchReport.noteLimit)
        #expect(long.contains("add-ons now: \(state.reportLine); stages:"))
    }
}
