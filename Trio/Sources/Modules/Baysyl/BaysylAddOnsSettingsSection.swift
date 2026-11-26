import SwiftUI

/// Switches for the private-build add-ons, and the safe-mode line when the launch guard has turned them off.
///
/// Appearance and reporting only: none of these switches changes a therapy setting or anything the loop reads.
struct BaysylAddOnsSettingsSection: View {
    @AppStorage(BaysylAddOns.widgetFeedKey) private var widgetFeed = true
    @AppStorage(BaysylAddOns.watchExtrasKey) private var watchExtras = true

    @State private var safeMode = BaysylLaunchGuard.shared.info.safeMode
    @State private var failures = BaysylLaunchGuard.shared.info.safeModeFailures

    static let widgetTitle = "Glucose widgets"
    static let watchTitle = "Watch extras"
    static let clearTitle = "Turn add-ons back on"
    static let footnote =
        "Glucose widgets feeds the home-screen and lock-screen widgets. Watch extras keeps the watch up to date "
            + "while its app is closed and adds the Today page. Turning one off returns that part to stock Trio."

    static func safeModeLine(failures: Int) -> String {
        "Safe mode: add-ons are off because Trio failed to start \(max(0, failures)) times"
    }

    var body: some View {
        Section {
            if safeMode {
                Text(verbatim: Self.safeModeLine(failures: failures))
                Button {
                    BaysylLaunchGuard.shared.clearSafeMode()
                    refresh()
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
    }

    private func refresh() {
        let info = BaysylLaunchGuard.shared.info
        safeMode = info.safeMode
        failures = info.safeModeFailures
    }
}
