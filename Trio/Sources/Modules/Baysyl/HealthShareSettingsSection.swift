import SwiftUI

/// The switches for "Share sleep and workouts" and, under it, "Heart rate and activity". Both off by default.
///
/// Turning one on shows the Apple Health read-permission sheet (first time only, and only for the types that
/// switch reads) and starts a sync. The sheet is only ever asked for from a switch or from the "Allow Health
/// access" button below, never by a sync. While a switch is off nothing it covers is asked of Health and
/// nothing is uploaded. Neither changes a therapy setting.
struct HealthShareSettingsSection: View {
    @AppStorage(HealthShareDefaultsStore.enabledKey) private var isEnabled = false
    @AppStorage(HealthShareDefaultsStore.daysEnabledKey) private var isDaysEnabled = false

    @State private var safeMode = BaysylLaunchGuard.shared.isSafeMode
    @State private var needsAccess = false
    @State private var statusLine = ""

    static let title = "Share sleep and workouts"
    static let daysTitle = "Heart rate and activity"
    static let allowTitle = "Allow Health access"
    static let footnote =
        "Reads your sleep and workouts from Apple Health (read only) and sends them to your Nightscout site as "
            + "notes. Heart rate and activity adds a daily summary: heart rate, heart rate variability, steps and "
            + "active energy, with past days sent a few at a time. "
            + "Needs Nightscout upload turned on. While a switch is off, nothing it covers is read or sent."

    /// "Last sync Nov 28, 4:35 AM: ok, uploaded 1". Empty until a sync has been tried.
    static func statusLine(_ status: HealthShareStatus, safeMode: Bool) -> String {
        if safeMode { return "Safe mode: nothing is read or sent until add-ons are turned back on." }
        guard let attempt = status.lastAttempt else { return "" }
        let time = attempt.formatted(date: .abbreviated, time: .shortened)
        return "Last sync \(time): \(status.result)\(status.detail.isEmpty ? "" : ", " + status.detail)"
    }

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text(verbatim: Self.title)
            }
            // A switch turned on in safe mode could not ask Health for access, and nothing said so.
            .disabled(safeMode)
            Toggle(isOn: $isDaysEnabled) {
                Text(verbatim: Self.daysTitle)
            }
            .disabled(!isEnabled || safeMode)
            if needsAccess, !safeMode {
                Button {
                    Task.detached(priority: .utility) {
                        _ = await HealthShareService.shared.accessRequestedByUser()
                        await refresh()
                    }
                } label: {
                    Text(verbatim: Self.allowTitle)
                }
            }
            if isEnabled, !statusLine.isEmpty {
                Text(verbatim: statusLine)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        } footer: {
            Text(verbatim: Self.footnote)
        }
        .task { await refresh() }
        .onChange(of: isEnabled) { _, isOn in
            guard isOn, BaysylAddOns.healthShare else { return }
            Task.detached(priority: .utility) {
                _ = await HealthShareService.shared.enabledByUser()
                await refresh()
            }
        }
        .onChange(of: isDaysEnabled) { _, isOn in
            guard isOn, isEnabled, BaysylAddOns.healthShare else { return }
            Task.detached(priority: .utility) {
                _ = await HealthShareService.shared.daysEnabledByUser()
                await refresh()
            }
        }
    }

    /// Asks Health nothing of the user: only whether the sheet for the day types was ever answered.
    @MainActor private func refresh() async {
        safeMode = BaysylLaunchGuard.shared.isSafeMode
        statusLine = Self.statusLine(HealthShareStatusStore.load(), safeMode: safeMode)
        guard !BaysylLaunchGuard.isRunningTests else { return }
        needsAccess = await HealthShareService.shared.needsAccessRequest()
    }
}
