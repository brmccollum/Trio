import SwiftUI

/// Switches for the private-build add-ons, and the safe-mode line when the launch guard has turned them off.
///
/// Appearance and reporting only: none of these switches changes a therapy setting or anything the loop reads.
struct BaysylAddOnsSettingsSection: View {
    @AppStorage(BaysylAddOns.widgetFeedKey) private var widgetFeed = true
    @AppStorage(BaysylAddOns.watchExtrasKey) private var watchExtras = true
    @AppStorage(BaysylAddOns.briefKey) private var brief = false
    @AppStorage(BaysylAddOns.spokenAlertsKey) private var spokenAlerts = false
    @AppStorage(BaysylAddOns.speakLowsKey) private var speakLows = true
    @AppStorage(BaysylAddOns.speakLoopStoppedKey) private var speakLoopStopped = true
    @AppStorage(BaysylAddOns.respectSilentModeKey) private var respectSilentMode = true

    @State private var safeMode = BaysylLaunchGuard.shared.info.safeMode
    @State private var failures = BaysylLaunchGuard.shared.info.safeModeFailures
    @State private var showingFolderPicker = false
    @State private var briefLine = ""

    static let widgetTitle = "Glucose widgets"
    static let watchTitle = "Watch extras"
    static let clearTitle = "Turn add-ons back on"
    static let footnote =
        "Glucose widgets feeds the home-screen and lock-screen widgets. Watch extras keeps the watch up to date "
            + "while its app is closed and adds the Today and Baysyl pages. Turning one off returns that part to "
            + "stock Trio."

    static let briefTitle = "Baysyl brief"
    static let chooseFolderTitle = "Choose folder"
    static let briefFootnote =
        "Reads brief.json from the folder you choose (read only) and shows it on Baysyl recommends, and on the "
            + "watch when Watch extras is on. Read when Trio is opened and every 15 minutes while it stays open."

    static let spokenTitle = "Spoken alerts"
    static let speakLowsTitle = "Speak lows"
    static let speakLoopTitle = "Speak when the loop stops"
    static let respectSilentTitle = "Respect silent mode"
    static let testVoiceTitle = "Test voice"
    static let spokenFootnote =
        "Says a reading under 70 out loud (at most every 5 minutes) and says when Trio has not looped for 20 "
            + "minutes. Your alarms are not changed, and nothing is spoken while a Trio alarm is sounding."
    static let respectSilentFootnote =
        "With this on, Trio speaks only while it is open on screen. Turn it off to hear lows with the phone "
            + "locked or in your pocket."

    static func safeModeLine(failures: Int) -> String {
        "Safe mode: add-ons are off because Trio failed to start \(max(0, failures)) times"
    }

    /// The line under "Choose folder": the folder, when a brief was last read, and any problem.
    static func briefStatusLine(folderName: String?, lastRead: Date?, status: String) -> String {
        guard let folderName else { return "No folder chosen." }
        var parts = ["Folder: \(folderName)."]
        if let lastRead {
            parts.append("Last brief read \(BaysylBriefFormat.time(lastRead)).")
        } else if status.isEmpty {
            parts.append("No brief read yet.")
        }
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: " ")
    }

    var body: some View {
        Section {
            if safeMode {
                Text(verbatim: Self.safeModeLine(failures: failures))
                Button {
                    BaysylLaunchGuard.shared.clearSafeMode()
                    refresh()
                    BaysylSpeechService.shared.startIfNeeded()
                    BaysylBriefService.userChanged()
                } label: {
                    Text(verbatim: Self.clearTitle)
                }
            }
            Toggle(isOn: $widgetFeed) {
                Text(verbatim: Self.widgetTitle)
            }
            .disabled(safeMode)
            Toggle(isOn: $watchExtras) {
                Text(verbatim: Self.watchTitle)
            }
            .disabled(safeMode)
        } footer: {
            Text(verbatim: Self.footnote)
        }
        .onAppear { refresh() }

        Section {
            Toggle(isOn: $brief) {
                Text(verbatim: Self.briefTitle)
            }
            .disabled(safeMode)
            Button {
                showingFolderPicker = true
            } label: {
                Text(verbatim: Self.chooseFolderTitle)
            }
            .disabled(safeMode || !brief)
            Text(verbatim: briefLine)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        } footer: {
            Text(verbatim: Self.briefFootnote)
        }
        .onChange(of: brief) { _, isOn in
            if isOn { BaysylBriefService.userChanged() }
        }
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: BaysylBriefStore.didChange).receive(on: DispatchQueue.main)
        ) { _ in refresh() }
        .sheet(isPresented: $showingFolderPicker) {
            BaysylFolderPicker { url in
                BaysylBriefService.shared.userChoseFolder(url)
            }
        }

        Section {
            Toggle(isOn: $spokenAlerts) {
                Text(verbatim: Self.spokenTitle)
            }
            .disabled(safeMode)
            Toggle(isOn: $speakLows) {
                Text(verbatim: Self.speakLowsTitle)
            }
            .disabled(safeMode || !spokenAlerts)
            Toggle(isOn: $speakLoopStopped) {
                Text(verbatim: Self.speakLoopTitle)
            }
            .disabled(safeMode || !spokenAlerts)
            Button {
                BaysylSpeaker.shared.speak(
                    BaysylSpeechWording.sample,
                    audio: BaysylSpeechAudio.mode(respectSilentMode: respectSilentMode)
                )
            } label: {
                Text(verbatim: Self.testVoiceTitle)
            }
            .disabled(safeMode || !spokenAlerts)
        } footer: {
            Text(verbatim: Self.spokenFootnote)
        }
        .onChange(of: spokenAlerts) { _, isOn in
            if isOn { BaysylSpeechService.shared.startIfNeeded() }
        }

        // Its own section, so the sentence about what the switch really does sits directly under it.
        Section {
            Toggle(isOn: $respectSilentMode) {
                Text(verbatim: Self.respectSilentTitle)
            }
            .disabled(safeMode || !spokenAlerts)
        } footer: {
            Text(verbatim: Self.respectSilentFootnote)
        }
    }

    private func refresh() {
        let info = BaysylLaunchGuard.shared.info
        safeMode = info.safeMode
        failures = info.safeModeFailures
        let store = BaysylBriefStore.shared
        briefLine = Self.briefStatusLine(
            folderName: store.folderName,
            lastRead: store.lastGoodReadAt,
            status: store.status
        )
    }
}
