import SwiftUI

/// The switches for "Share sleep and workouts" and, under it, "Heart rate and activity". Both off by default.
///
/// Turning one on shows the Apple Health read-permission sheet (first time only, and only for the types that
/// switch reads) and starts a sync. That is the only place the sheet is ever asked for. While a switch is off
/// nothing it covers is asked of Health and nothing is uploaded. Neither changes a therapy setting.
struct HealthShareSettingsSection: View {
    @AppStorage(HealthShareDefaultsStore.enabledKey) private var isEnabled = false
    @AppStorage(HealthShareDefaultsStore.daysEnabledKey) private var isDaysEnabled = false

    static let title = "Share sleep and workouts"
    static let daysTitle = "Heart rate and activity"
    static let footnote =
        "Reads your sleep and workouts from Apple Health (read only) and sends them to your Nightscout site as "
            + "notes. Heart rate and activity adds a daily summary: heart rate, heart rate variability, steps and "
            + "active energy, with past days sent a few at a time. "
            + "Needs Nightscout upload turned on. While a switch is off, nothing it covers is read or sent."

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text(verbatim: Self.title)
            }
            Toggle(isOn: $isDaysEnabled) {
                Text(verbatim: Self.daysTitle)
            }
            .disabled(!isEnabled)
        } footer: {
            Text(verbatim: Self.footnote)
        }
        .onChange(of: isEnabled) { _, isOn in
            guard isOn, BaysylAddOns.healthShare else { return }
            Task.detached(priority: .utility) {
                _ = await HealthShareService.shared.enabledByUser()
            }
        }
        .onChange(of: isDaysEnabled) { _, isOn in
            guard isOn, isEnabled, BaysylAddOns.healthShare else { return }
            Task.detached(priority: .utility) {
                _ = await HealthShareService.shared.daysEnabledByUser()
            }
        }
    }
}
