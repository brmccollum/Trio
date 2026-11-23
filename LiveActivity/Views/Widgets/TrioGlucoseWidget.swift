import SwiftUI
import WidgetKit

/// Home-screen and lock-screen glucose widget. Display only: it draws what the app last published
/// to the shared app-group defaults and nothing else. It cannot reach the loop, the pump or the CGM.
///
/// Safety rule (see `TrioWidgetFreshness`): every timeline carries its own later entries, so with no
/// further word from the app the number dims with its age at 15 minutes and becomes dashes at 30.
struct TrioGlucoseEntry: TimelineEntry {
    let date: Date
    let snapshot: TrioWidgetSnapshot?

    var display: TrioWidgetDisplay { TrioWidgetDisplay(snapshot: snapshot, at: date) }
}

struct TrioGlucoseProvider: TimelineProvider {
    /// Made-up values for the widget gallery and the redacted placeholder. Never real data.
    static func sample(at date: Date, offworld: Bool = false) -> TrioWidgetSnapshot {
        let values = [118, 121, 124, 126, 125, 122, 119, 116, 114, 113, 112, 112]
        return TrioWidgetSnapshot(
            glucose: "112",
            glucoseMgdL: 112,
            unit: "mg/dL",
            direction: "→",
            delta: "+0",
            readingDate: date.addingTimeInterval(-120),
            low: 70,
            high: 180,
            offworld: offworld,
            iob: nil,
            cob: nil,
            recent: values.enumerated().map { index, value in
                TrioWidgetSnapshot.Point(
                    date: date.addingTimeInterval(-120 - Double(values.count - 1 - index) * 300),
                    mgdL: value
                )
            }
        )
    }

    func placeholder(in _: Context) -> TrioGlucoseEntry {
        TrioGlucoseEntry(date: Date(), snapshot: Self.sample(at: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioGlucoseEntry) -> Void) {
        let now = Date()
        let stored = TrioWidgetSnapshotStore.read(from: TrioWidgetSnapshotStore.sharedDefaults())
        // The gallery shows sample numbers only when there is nothing real to show.
        let snapshot = stored ?? (context.isPreview ? Self.sample(at: now) : nil)
        completion(TrioGlucoseEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioGlucoseEntry>) -> Void) {
        completion(Self.timeline(
            snapshot: TrioWidgetSnapshotStore.read(from: TrioWidgetSnapshotStore.sharedDefaults()),
            now: Date()
        ))
    }

    static func timeline(snapshot: TrioWidgetSnapshot?, now: Date) -> Timeline<TrioGlucoseEntry> {
        let dates = TrioWidgetFreshness.timelineDates(readingDate: snapshot?.readingDate, now: now)
        let entries = dates.map { TrioGlucoseEntry(date: $0, snapshot: snapshot) }
        return Timeline(
            entries: entries,
            policy: .after(TrioWidgetFreshness.reloadDate(afterLastEntry: dates.last ?? now))
        )
    }
}

struct TrioGlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrioWidgetSnapshotStore.widgetKind, provider: TrioGlucoseProvider()) { entry in
            TrioGlucoseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text(verbatim: "Trio Glucose"))
        .description(Text(verbatim: "Latest glucose reading with its age. Dims when old, blank after 30 minutes."))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TrioGlucoseWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrioGlucoseEntry

    var body: some View {
        let display = entry.display
        TrioGlucoseWidgetContent(display: display, family: family, now: entry.date)
            .containerBackground(for: .widget) {
                TrioGlucoseWidgetBackground(display: display, family: family)
            }
    }
}
