import Foundation
import WidgetKit

/// Publishes the display snapshot the home-screen and lock-screen widgets read. App target only.
///
/// Display only and failure-proof by construction: `publish` does not throw, does no I/O beyond one
/// `UserDefaults.set` of a small blob, and asks WidgetKit for a reload without waiting for it.
/// A missing app group simply means nothing is written.
final class TrioWidgetSnapshotPublisher {
    enum Outcome: Equatable {
        /// No shared defaults (no app group in this build), or the snapshot could not be encoded.
        case unavailable
        /// Same content as last time: nothing written, no reload.
        case unchanged
        /// Written. `reloaded` is true when a widget reload was requested as well.
        case written(reloaded: Bool)
    }

    static let shared = TrioWidgetSnapshotPublisher()

    private let defaults: () -> UserDefaults?
    private let reload: (String) -> Void
    private let lock = NSLock()
    private var lastWritten: TrioWidgetSnapshot?
    private var lastReloadKey: ReloadKey?

    /// What has to change before the widgets are asked to redraw. IOB and COB are left out on purpose:
    /// they move several times per loop cycle, and one reload per glucose reading is the budget.
    private struct ReloadKey: Equatable {
        let readingDate: Date
        let glucose: String
        let unit: String
        let low: Double
        let high: Double
        let offworld: Bool
    }

    init(
        defaults: @escaping () -> UserDefaults? = { TrioWidgetSnapshotStore.sharedDefaults() },
        reload: @escaping (String) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0) }
    ) {
        self.defaults = defaults
        self.reload = reload
    }

    private static let queue = DispatchQueue(label: "bryan.widgetSnapshot.publish", qos: .utility)

    /// `publish`, off the caller's thread. The caller is the main actor (once per Live Activity refresh), and
    /// the shared-defaults write and the WidgetKit reload request both talk to other processes: neither may
    /// hold the main thread. One at a time, in order. A slow one leaves a "slow: widget publish" breadcrumb.
    func publishInBackground(_ snapshot: TrioWidgetSnapshot) {
        Self.queue.async { [self] in
            BaysylLaunchGuard.shared.track("widget publish") { _ = publish(snapshot) }
        }
    }

    @discardableResult func publish(_ snapshot: TrioWidgetSnapshot) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        if snapshot == lastWritten { return .unchanged }
        guard let defaults = defaults(), TrioWidgetSnapshotStore.write(snapshot, to: defaults) else {
            return .unavailable
        }
        lastWritten = snapshot

        let key = ReloadKey(
            readingDate: snapshot.readingDate,
            glucose: snapshot.glucose,
            unit: snapshot.unit,
            low: snapshot.low,
            high: snapshot.high,
            offworld: snapshot.offworld
        )
        guard key != lastReloadKey else { return .written(reloaded: false) }
        lastReloadKey = key
        reload(TrioWidgetSnapshotStore.widgetKind)
        return .written(reloaded: true)
    }
}

extension TrioWidgetSnapshot {
    /// Builds the snapshot from values the app already holds for the Live Activity.
    /// `readings` is newest first, as fetched. Nil when there is no reading.
    static func make(
        readings: [GlucoseData],
        units: GlucoseUnits,
        low: Decimal,
        high: Decimal,
        iob: Decimal?,
        cob: Int?,
        offworld: Bool
    ) -> TrioWidgetSnapshot? {
        guard let newest = readings.first else { return nil }
        typealias State = LiveActivityAttributes.ContentState

        let iobText: String? = iob.map {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 2
            return (formatter.string(from: $0 as NSDecimalNumber) ?? "\($0)") + " U"
        }

        return TrioWidgetSnapshot(
            glucose: State.formatGlucose(newest.glucose, units: units, forceSign: false),
            glucoseMgdL: newest.glucose,
            unit: units.rawValue,
            direction: newest.direction?.symbol,
            delta: State.calculateChange(chart: readings, units: units).trimmingCharacters(in: .whitespaces),
            readingDate: newest.date,
            low: NSDecimalNumber(decimal: low).doubleValue,
            high: NSDecimalNumber(decimal: high).doubleValue,
            offworld: offworld,
            iob: iobText,
            cob: cob.map { "\($0) g" },
            recent: TrioWidgetSnapshotStore.recentPoints(
                from: readings.map { Point(date: $0.date, mgdL: $0.glucose) }
            )
        )
    }
}
