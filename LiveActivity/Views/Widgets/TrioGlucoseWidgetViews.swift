import SwiftUI
import WidgetKit

// Views of the glucose widget. They take a `TrioWidgetDisplay` (already decided: fresh, aging,
// expired or no snapshot) and the family, so the same code draws in WidgetKit and in a test render.

// MARK: - Text and colour helpers

enum TrioWidgetText {
    /// "10:42 AM", or "10:42" where space is tight.
    static func time(_ date: Date, compact: Bool = false) -> String {
        compact
            ? date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute())
            : date.formatted(date: .omitted, time: .shortened)
    }

    /// Time of the last reading for the expired state; includes the day when it was not today.
    static func lastSeen(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? time(date)
            : date.formatted(Date.FormatStyle().month(.abbreviated).day().hour().minute())
    }

    static func age(_ minutes: Int) -> String {
        minutes == 0 ? "just now" : "\(minutes) min ago"
    }

    /// One line for the lock-screen inline slot. It cannot be dimmed, so an old reading says so first.
    static func inline(_ display: TrioWidgetDisplay, now: Date) -> String {
        switch display.freshness {
        case .noSnapshot:
            return "Trio: no data"
        case .expired:
            guard let date = display.readingDate else { return "Trio: no data" }
            return "Trio: no data since \(lastSeen(date, now: now))"
        case .aging:
            return "\(display.minutesAgo ?? 0) min old: \(display.number) \(display.unit ?? "")"
        case .fresh:
            var parts = [display.number]
            if display.isLow { parts.insert("LOW", at: 0) }
            if let direction = display.direction { parts.append(direction) }
            if let delta = display.delta { parts.append(delta) }
            if let date = display.readingDate { parts.append("· " + time(date)) }
            return parts.joined(separator: " ")
        }
    }
}

extension TrioWidgetTone {
    func color(themed: Bool) -> Color {
        switch self {
        case .low: return Color.staticLow
        case .stockInRange: return Color.staticInRange
        case .stockHigh: return Color.staticHigh
        case .themedInRange: return Color(trioWidgetHex: Self.themedInRangeHex)
        case .themedHigh: return Color(trioWidgetHex: Self.themedHighHex)
        case .dimmed: return themed ? LiveActivityOffworld.muted : Color.secondary
        }
    }
}

extension Color {
    init(trioWidgetHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Colours and fonts for one drawing, theme on or off.
private struct TrioWidgetStyle {
    let display: TrioWidgetDisplay

    var themed: Bool { display.themed }
    var numberColor: Color { display.tone.color(themed: themed) }
    /// An aging number is drawn faint; the age beside it is what stays loud.
    var numberOpacity: Double { display.freshness == .aging ? 0.5 : 1 }
    var label: AnyShapeStyle { themed ? AnyShapeStyle(LiveActivityOffworld.muted) : AnyShapeStyle(.secondary) }
    var value: AnyShapeStyle { themed ? AnyShapeStyle(LiveActivityOffworld.ink) : AnyShapeStyle(.primary) }
    var warning: Color { themed ? LiveActivityOffworld.amber : Color.orange }

    func numberFont(_ size: CGFloat) -> Font {
        themed ? LiveActivityOffworld.display(size: size) : .system(size: size, weight: .bold, design: .rounded)
    }

    func captionFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        themed ? .system(size: size, weight: weight).width(.expanded) : .system(size: size, weight: weight)
    }
}

// MARK: - Content

struct TrioGlucoseWidgetContent: View {
    let display: TrioWidgetDisplay
    let family: WidgetFamily
    /// The moment this drawing is for (the timeline entry's date).
    let now: Date

    private var style: TrioWidgetStyle { TrioWidgetStyle(display: display) }

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: Text(verbatim: TrioWidgetText.inline(display, now: now))
        default: small
        }
    }

    // MARK: Shared pieces

    private func number(size: CGFloat) -> some View {
        Text(verbatim: display.number)
            .font(style.numberFont(size))
            .foregroundStyle(style.numberColor)
            .opacity(style.numberOpacity)
            .shadow(
                color: style.themed && display.freshness == .fresh ? style.numberColor.opacity(0.5) : .clear,
                radius: 4
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .widgetAccentable()
    }

    @ViewBuilder private func arrow(size: CGFloat) -> some View {
        if let direction = display.direction {
            Text(verbatim: direction)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(style.numberColor)
                .opacity(style.numberOpacity)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder private var lowTag: some View {
        if display.isLow {
            Text(verbatim: "LOW")
                .font(.system(size: 11, weight: .heavy).width(.expanded))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.staticLow))
                .accessibilityLabel(Text(verbatim: "Low glucose"))
        }
    }

    /// "+2 mg/dL" under the number, or the plain words for the states without a number.
    @ViewBuilder private var deltaLine: some View {
        switch display.freshness {
        case .aging,
             .fresh:
            Text(verbatim: [display.delta, display.unit].compactMap { $0 }.joined(separator: " "))
                .font(style.captionFont(12))
                .foregroundStyle(style.value)
                .opacity(style.numberOpacity)
        case .expired:
            Text(verbatim: "NO DATA")
                .font(style.captionFont(12, weight: .heavy))
                .foregroundStyle(style.warning)
        case .noSnapshot:
            Text(verbatim: "NO DATA YET")
                .font(style.captionFont(12, weight: .heavy))
                .foregroundStyle(style.label)
        }
    }

    /// Always present: how old the reading is and when it was taken.
    @ViewBuilder private var ageLine: some View {
        switch display.freshness {
        case .fresh:
            Text(verbatim: ageAndTime)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.label)
        case .aging:
            Label {
                Text(verbatim: ageAndTime)
            } icon: {
                Image(systemName: "clock.badge.exclamationmark")
            }
            .labelStyle(TrioWidgetTightLabelStyle())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(style.warning)
        case .expired:
            Text(verbatim: "last " + (display.readingDate.map { TrioWidgetText.lastSeen($0, now: now) } ?? "--"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.label)
        case .noSnapshot:
            Text(verbatim: "Open Trio")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.label)
        }
    }

    private var ageAndTime: String {
        let age = TrioWidgetText.age(display.minutesAgo ?? 0)
        guard let date = display.readingDate else { return age }
        return age + " · " + TrioWidgetText.time(date, compact: true)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(verbatim: style.themed ? "TRIO" : "Trio")
                .font(style.captionFont(11, weight: .bold))
                .foregroundStyle(style.label)
            Spacer(minLength: 0)
            lowTag
        }
        // Same height with or without the tag, so the number does not move when a low starts.
        .frame(height: 18)
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                number(size: style.themed ? 40 : 46)
                arrow(size: 22)
            }
            deltaLine
            Spacer(minLength: 0)
            ageLine
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(alignment: .center, spacing: 12) {
            small.frame(width: 126)
            VStack(alignment: .leading, spacing: 6) {
                if display.showsNumber, display.recent.count > 1 {
                    TrioWidgetSparkline(display: display)
                        .opacity(display.freshness == .aging ? 0.45 : 1)
                } else {
                    Text(verbatim: display.freshness == .noSnapshot ? "Waiting for the first reading" : "No recent readings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.label)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                if display.iob != nil || display.cob != nil {
                    HStack(spacing: 10) {
                        if let iob = display.iob { reading("IOB", iob) }
                        if let cob = display.cob { reading("COB", cob) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reading(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: name)
                .font(style.captionFont(10, weight: .bold))
                .foregroundStyle(style.label)
            Text(verbatim: value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(style.value)
        }
        .lineLimit(1)
    }

    // MARK: Lock screen (drawn monochrome by iOS; the theme is the typeface and the frame)

    private var accessoryNumberFont: (CGFloat) -> Font {
        { size in
            style.themed ? LiveActivityOffworld.display(size: size) : .system(size: size, weight: .bold, design: .rounded)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if style.themed {
                Circle().strokeBorder(lineWidth: 1.5).padding(2).opacity(0.8)
            }
            VStack(spacing: 0) {
                Group {
                    if display.isLow {
                        Text(verbatim: "LOW").font(.system(size: 9, weight: .heavy))
                    } else if let direction = display.direction {
                        Text(verbatim: direction).font(.system(size: 11, weight: .bold))
                    } else {
                        Text(verbatim: " ").font(.system(size: 9))
                    }
                }
                .opacity(style.numberOpacity)
                Text(verbatim: display.number)
                    .font(accessoryNumberFont(style.themed ? 19 : 22))
                    .opacity(style.numberOpacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .widgetAccentable()
                Text(verbatim: circularCaption)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 7)
        }
    }

    /// Fresh: the reading's clock time. Aging: its age. Otherwise the plain words.
    private var circularCaption: String {
        switch display.freshness {
        case .fresh: return display.readingDate.map { TrioWidgetText.time($0, compact: true) } ?? ""
        case .aging: return "\(display.minutesAgo ?? 0)m old"
        case .expired,
             .noSnapshot: return "no data"
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: display.number)
                    .font(accessoryNumberFont(style.themed ? 24 : 28))
                    .opacity(style.numberOpacity)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .widgetAccentable()
                if let direction = display.direction {
                    Text(verbatim: direction)
                        .font(.system(size: 17, weight: .bold))
                        .opacity(style.numberOpacity)
                }
                if display.isLow {
                    Text(verbatim: "LOW")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(lineWidth: 1.5))
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: rectangularDetail)
                .font(.system(size: 12, weight: .semibold))
                .opacity(style.numberOpacity)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: rectangularAge)
                .font(.system(size: 12, weight: display.freshness == .fresh ? .regular : .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, style.themed ? 8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay {
            if style.themed {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(lineWidth: 1.2).opacity(0.8)
            }
        }
    }

    private var rectangularDetail: String {
        switch display.freshness {
        case .aging,
             .fresh:
            var parts = [[display.delta, display.unit].compactMap { $0 }.joined(separator: " ")]
            if let iob = display.iob { parts.append("IOB " + iob) }
            return parts.joined(separator: " · ")
        case .expired: return "No data"
        case .noSnapshot: return "No data yet"
        }
    }

    private var rectangularAge: String {
        switch display.freshness {
        case .fresh: return ageAndTime
        case .aging: return "OLD: " + ageAndTime
        case .expired: return "last " + (display.readingDate.map { TrioWidgetText.lastSeen($0, now: now) } ?? "--")
        case .noSnapshot: return "Open Trio"
        }
    }
}

/// Icon and text closer together than the system label style puts them.
private struct TrioWidgetTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Sparkline

/// About three hours of readings ending at the latest one, over a band from the user's low to high.
struct TrioWidgetSparkline: View {
    let display: TrioWidgetDisplay

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = display.recent
            let values = points.map { Double($0.mgdL) }
            let floor = min(display.low - 15, (values.min() ?? display.low) - 10)
            let ceiling = max(display.high + 15, (values.max() ?? display.high) + 10)
            let end = points.last?.date ?? Date()
            let start = end.addingTimeInterval(-TrioWidgetSnapshotStore.recentWindow)
            let x: (Date) -> CGFloat = { date in
                CGFloat(date.timeIntervalSince(start) / end.timeIntervalSince(start)) * (size.width - 6) + 3
            }
            let y: (Double) -> CGFloat = { value in
                size.height - CGFloat((value - floor) / (ceiling - floor)) * size.height
            }
            let themed = display.themed
            let rangeColor = TrioWidgetTone.of(band: .inRange, themed: themed, freshness: .fresh).color(themed: themed)
            let lineColor: Color = themed ? LiveActivityOffworld.silver : .secondary

            ZStack(alignment: .topLeading) {
                // Range band, low to high.
                Rectangle()
                    .fill(rangeColor.opacity(themed ? 0.10 : 0.14))
                    .frame(width: size.width, height: max(0, y(display.low) - y(display.high)))
                    .offset(y: y(display.high))
                ForEach([display.low, display.high], id: \.self) { edge in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(edge)))
                        path.addLine(to: CGPoint(x: size.width, y: y(edge)))
                    }
                    .stroke(rangeColor.opacity(0.45), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                }
                Path { path in
                    for (index, point) in points.enumerated() {
                        let position = CGPoint(x: x(point.date), y: y(Double(point.mgdL)))
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                }
                .stroke(lineColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let band = TrioWidgetBand.of(mgdL: point.mgdL, low: display.low, high: display.high)
                    let isLast = index == points.count - 1
                    Circle()
                        .fill(TrioWidgetTone.of(band: band, themed: themed, freshness: .fresh).color(themed: themed))
                        .frame(width: isLast ? 6 : 3.2, height: isLast ? 6 : 3.2)
                        .position(x: x(point.date), y: y(Double(point.mgdL)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Background

/// Home-screen surface. Themed: the Off-world dark panel in a brass and gold frame that turns red
/// while the reading is low. Unthemed: the plain system widget surface.
struct TrioGlucoseWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let display: TrioWidgetDisplay
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular,
             .accessoryInline,
             .accessoryRectangular:
            Color.clear
        default:
            if display.themed {
                LinearGradient(
                    colors: [LiveActivityOffworld.backgroundLift, LiveActivityOffworld.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(
                    ContainerRelativeShape()
                        .strokeBorder(
                            display.isLow ? AnyShapeStyle(Color.staticLow) : AnyShapeStyle(LiveActivityOffworld.frameStroke),
                            lineWidth: display.isLow ? 3 : 2
                        )
                )
            } else {
                colorScheme == .dark ? Color(white: 0.11) : Color.white
            }
        }
    }
}
