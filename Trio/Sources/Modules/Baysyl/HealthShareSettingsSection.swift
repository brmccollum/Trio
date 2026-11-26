import SwiftUI

/// The one switch for "Share sleep and workouts". Off by default.
///
/// Turning it on shows the Apple Health read-permission sheet (first time only) and starts a sync. While it is
/// off nothing is asked of Health and nothing is uploaded. It changes no therapy setting.
struct HealthShareSettingsSection: View {
    @AppStorage(HealthShareDefaultsStore.enabledKey) private var isEnabled = false

    static let title = "Share sleep and workouts"
    static let footnote =
        "Reads your sleep and workouts from Apple Health (read only) and sends them to your Nightscout site as notes. "
            + "Needs Nightscout upload turned on. While this is off, nothing is read and nothing is sent."

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text(verbatim: Self.title)
            }
        } footer: {
            Text(verbatim: Self.footnote)
        }
        .onChange(of: isEnabled) { _, isOn in
            guard isOn, BaysylAddOns.healthShare else { return }
            Task.detached(priority: .utility) {
                _ = await HealthShareService.shared.enabledByUser()
            }
        }
    }
}
