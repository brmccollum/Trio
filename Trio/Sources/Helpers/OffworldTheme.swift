import CoreText
import SwiftUI
import UIKit

/// Optional "Off-world" appearance (steampunk / Blade Runner palette). Appearance only.
///
/// Default OFF. Stored under its own UserDefaults key, never in TrioSettings or Preferences,
/// so nothing the algorithm, pump, CGM or Nightscout code reads is touched.
///
/// Safety contract: the theme forces dark appearance and only swaps *neutral* surfaces
/// (app background, card/row fill, tab accent, title ink) for darker or brighter values.
/// Semantic colours (glucose in range / high / low, loop status, insulin, carbs, warnings)
/// are never routed through this type and keep their stock values.
enum OffworldTheme {
    static let defaultsKey = "bryan.theme.offworld"

    /// Palette values as 0xRRGGBB.
    enum Swatch: UInt32, CaseIterable {
        case background = 0x06080C
        case backgroundLift = 0x0A0F15
        case panel = 0x0C1218
        case panelRaised = 0x141C24
        case panelTeal = 0x0A1A1E
        case gold = 0xD9B45A
        case silver = 0xD6DCE2
        case brass = 0x6B5326
        case ink = 0xF4E7C6
        case muted = 0xA8946A
        case cyan = 0x2EF2FF
        case amber = 0xFFB000
        case pink = 0xFF3D7F
        case mint = 0x7DFFB2
        // One role per colour on Home: cyan is glucose only.
        /// Insulin: boluses, SMBs, IOB.
        case violet = 0xB56BFF
        case violetGlow = 0xD07BFF
        /// Carbs: carb entries, COB.
        case carbGold = 0xFFC23A
        case carbEdge = 0xFF9E2A
        /// Fat-protein equivalents, and the warm end of the frame metal.
        case copper = 0xC8793A
        /// Basal delivery.
        case steel = 0x9FB4C8
        /// Forecast wave only.
        case magenta = 0xFF3DF0
        case sunset = 0xFF7A3A
        /// Bright silver for small readouts, ticks and button rims.
        case chrome = 0xD9E2EA

        /// sRGB components, each 0...1.
        var components: (red: Double, green: Double, blue: Double) {
            (
                Double((rawValue >> 16) & 0xFF) / 255,
                Double((rawValue >> 8) & 0xFF) / 255,
                Double(rawValue & 0xFF) / 255
            )
        }

        var color: Color {
            let c = components
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
        }

        var uiColor: UIColor {
            let c = components
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        }

        /// WCAG 2.x relative luminance.
        var relativeLuminance: Double {
            func linear(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let c = components
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
    }

    /// WCAG contrast ratio between two swatches (1...21).
    static func contrastRatio(_ a: Swatch, _ b: Swatch) -> Double {
        let la = a.relativeLuminance
        let lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: - Flag storage

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    static var isEnabled: Bool {
        get { isEnabled(in: .standard) }
        set { setEnabled(newValue, in: .standard) }
    }

    // MARK: - Glucose colours (Home only, static colour scheme only)

    enum GlucoseBand: Equatable {
        case low
        case inRange
        case high
    }

    /// Same comparisons as the stock Home views: at or below low is low, at or above high is high.
    static func band(value: Decimal, low: Decimal, high: Decimal) -> GlucoseBand {
        if value <= low { return .low }
        if value >= high { return .high }
        return .inRange
    }

    /// Off-world glucose colour for the Home number and chart.
    /// Low always keeps the stock colour. With the static colour scheme, in-range takes `inRange`
    /// and high takes amber; with the dynamic scheme only the neutral in-range colour is replaced
    /// (when `replacesDynamicInRange` is true), so the user's gradient is left alone.
    static func glucoseColor(
        stock: Color,
        band: GlucoseBand,
        isStaticScheme: Bool,
        inRange: Swatch,
        replacesDynamicInRange: Bool,
        enabled: Bool = OffworldTheme.isEnabled
    ) -> Color {
        guard enabled else { return stock }
        switch band {
        case .low:
            return stock
        case .inRange:
            return (isStaticScheme || replacesDynamicInRange) ? inRange.color : stock
        case .high:
            return isStaticScheme ? Swatch.amber.color : stock
        }
    }

    /// Stock colour for a reading, then the Off-world mapping for Home (same inputs the stock views use).
    static func homeGlucoseColor(
        value: Decimal,
        low: Decimal,
        high: Decimal,
        target: Decimal,
        scheme: GlucoseColorScheme,
        inRange: Swatch
    ) -> Color {
        let isDynamic = scheme == .dynamicColor
        let stock = Trio.getDynamicGlucoseColor(
            glucoseValue: value,
            highGlucoseColorValue: isDynamic ? Decimal(220) : high,
            lowGlucoseColorValue: isDynamic ? Decimal(55) : low,
            targetGlucose: target,
            glucoseColorScheme: scheme
        )
        return glucoseColor(
            stock: stock,
            band: band(value: value, low: low, high: high),
            isStaticScheme: scheme == .staticColor,
            inRange: inRange,
            replacesDynamicInRange: false
        )
    }

    // MARK: - Metals

    /// Gold to brass to a silver highlight and back, for hairlines.
    static var metalStroke: LinearGradient {
        LinearGradient(
            colors: [Swatch.gold.color, Swatch.brass.color, Swatch.silver.color, Swatch.brass.color, Swatch.gold.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Brass and gold with silver highlights, for the ring around the Home glucose number.
    static var bezelGradient: AngularGradient {
        AngularGradient(
            colors: [
                Swatch.gold.color, Swatch.silver.color, Swatch.gold.color, Swatch.brass.color,
                Swatch.gold.color, Swatch.silver.color, Swatch.brass.color, Swatch.gold.color
            ],
            center: .center,
            startAngle: .degrees(270),
            endAngle: .degrees(-90)
        )
    }

    /// Small monospaced axis lettering when the theme is on, otherwise the stock font untouched.
    static func axisLabelFont(stock: Font, enabled: Bool = OffworldTheme.isEnabled) -> Font {
        enabled ? .system(size: 10, weight: .semibold, design: .monospaced) : stock
    }

    /// Text style for a stat label: tan when the theme is on, otherwise the stock secondary style.
    static var statLabelStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(Swatch.muted.color) : AnyShapeStyle(.secondary)
    }

    /// Text style for a stat value: cyan when the theme is on, otherwise the stock primary style.
    static var statValueStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(Swatch.cyan.color) : AnyShapeStyle(.primary)
    }

    // MARK: - Lookup

    /// Returns the themed swatch when the theme is on, otherwise the stock colour untouched.
    static func resolve(_ stock: Color, themed: Swatch, enabled: Bool = OffworldTheme.isEnabled) -> Color {
        enabled ? themed.color : stock
    }

    /// The colour scheme the theme forces, or `stock` when the theme is off.
    static func colorScheme(stock: ColorScheme?, enabled: Bool = OffworldTheme.isEnabled) -> ColorScheme? {
        enabled ? .dark : stock
    }

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [Swatch.backgroundLift.color, Swatch.background.color]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - UIKit chrome (tab bar, navigation titles)

    private static var chromeApplied = false

    /// Applies title ink, the amber rule under navigation bars and the brass tab bar edge through
    /// UIAppearance. A no-op while the theme has never been on, so a stock install keeps exactly the
    /// stock UIKit configuration.
    /// UIAppearance only reaches bars created afterwards, and screens whose inputs did not change
    /// are not redrawn by SwiftUI, so a switch is only complete after the next launch.
    static func applyUIKitChrome(enabled: Bool = OffworldTheme.isEnabled) {
        let navigationBar = UINavigationBar.appearance()
        let tabBar = UITabBar.appearance()

        guard enabled else {
            guard chromeApplied else { return }
            chromeApplied = false
            navigationBar.standardAppearance = UINavigationBarAppearance()
            navigationBar.compactAppearance = nil
            navigationBar.scrollEdgeAppearance = nil
            let stockTabBar = tabBarAppearance(edge: nil)
            tabBar.standardAppearance = stockTabBar
            tabBar.scrollEdgeAppearance = stockTabBar
            return
        }
        chromeApplied = true

        let ink = Swatch.ink.uiColor
        let rule = Swatch.amber.uiColor.withAlphaComponent(0.55)
        let largeTitle = UIFontMetrics(forTextStyle: .largeTitle)
            .scaledFont(for: UIFont.systemFont(ofSize: 28, weight: .heavy, width: .expanded))
        let inlineTitle = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .bold, width: .expanded))

        func bar(transparent: Bool) -> UINavigationBarAppearance {
            let appearance = UINavigationBarAppearance()
            if transparent {
                appearance.configureWithTransparentBackground()
            } else {
                appearance.configureWithDefaultBackground()
            }
            appearance.shadowColor = rule
            appearance.largeTitleTextAttributes = [.foregroundColor: ink, .font: largeTitle]
            appearance.titleTextAttributes = [.foregroundColor: ink, .font: inlineTitle]
            return appearance
        }
        navigationBar.standardAppearance = bar(transparent: false)
        navigationBar.compactAppearance = bar(transparent: false)
        navigationBar.scrollEdgeAppearance = bar(transparent: true)

        let themedTabBar = tabBarAppearance(edge: Swatch.brass.uiColor)
        tabBar.standardAppearance = themedTabBar
        tabBar.scrollEdgeAppearance = themedTabBar
    }

    /// Same configuration as `TrioApp.configureTabBarAppearance`, plus an optional top edge colour.
    private static func tabBarAppearance(edge: UIColor?) -> UITabBarAppearance {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = UIColor.clear
        if let edge {
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = Swatch.panel.uiColor
            appearance.shadowColor = edge
        }
        return appearance
    }
}

// MARK: - View flourishes

private struct OffworldGlow: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            // Additive halo behind the glyphs; the text itself keeps its colour and weight.
            content
                .shadow(color: color.opacity(0.7), radius: 6)
                .shadow(color: color.opacity(0.35), radius: 14)
        } else {
            content
        }
    }
}

private struct OffworldHairline<S: InsettableShape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            content.overlay(
                shape.strokeBorder(OffworldTheme.Swatch.brass.color, lineWidth: 1)
                    .shadow(color: OffworldTheme.Swatch.cyan.color.opacity(0.22), radius: 5)
                    .allowsHitTesting(false)
            )
        } else {
            content
        }
    }
}

extension View {
    /// Soft static glow, only when the Off-world theme is on. Never animated.
    func offworldGlow(_ color: Color) -> some View {
        modifier(OffworldGlow(color: color))
    }

    /// Brass 1pt border, only when the Off-world theme is on.
    func offworldHairline(_ shape: some InsettableShape) -> some View {
        modifier(OffworldHairline(shape: shape))
    }
}

// MARK: - Second pass: rows, headers, haze, digits (non-dosing surfaces only)

/// List row fill: the stock card colour, plus a brass hairline while the theme is on.
struct OffworldRowFill: View {
    var body: some View {
        if OffworldTheme.isEnabled {
            Color.chart.overlay(
                Rectangle().strokeBorder(OffworldTheme.Swatch.brass.color.opacity(0.9), lineWidth: 0.5)
            )
        } else {
            Color.chart
        }
    }
}

/// Faint cyan and amber corner haze. Kept dim enough that secondary grey text keeps 4.5:1 over it.
struct OffworldHaze: View {
    var body: some View {
        if OffworldTheme.isEnabled {
            ZStack {
                RadialGradient(
                    colors: [OffworldTheme.Swatch.cyan.color.opacity(0.10), .clear],
                    center: UnitPoint(x: -0.1, y: -0.05),
                    startRadius: 0,
                    endRadius: 380
                )
                RadialGradient(
                    colors: [OffworldTheme.Swatch.amber.color.opacity(0.08), .clear],
                    center: UnitPoint(x: 1.1, y: 1.05),
                    startRadius: 0,
                    endRadius: 380
                )
            }
            .background(
                RadialGradient(
                    colors: [OffworldTheme.Swatch.pink.color.opacity(0.07), .clear],
                    center: UnitPoint(x: 1.1, y: -0.05),
                    startRadius: 0,
                    endRadius: 320
                )
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct OffworldSectionHeader: ViewModifier {
    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            // Brass-tan rather than amber: amber/orange already means "warning" in Trio.
            HStack(spacing: 6) {
                // Decorative amber slashes; the words themselves stay brass-tan.
                Text(verbatim: "//")
                    .foregroundStyle(OffworldTheme.Swatch.amber.color)
                    .accessibilityHidden(true)
                content
                    .foregroundStyle(OffworldTheme.Swatch.muted.color)
            }
            .font(.caption.weight(.heavy).width(.expanded))
            .tracking(1.8)
            .textCase(.uppercase)
        } else {
            content
        }
    }
}

private struct OffworldMonoDigits: ViewModifier {
    var swatch: OffworldTheme.Swatch = .cyan

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            // Fixed-width figures in the stock face: no slashed zero, so digits read as before.
            content.monospacedDigit().foregroundStyle(swatch.color)
        } else {
            content
        }
    }
}

private struct OffworldTint: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active, OffworldTheme.isEnabled {
            content.tint(OffworldTheme.Swatch.cyan.color)
        } else {
            content
        }
    }
}

extension View {
    /// Small tracked brass caps for list section headers, only when the theme is on.
    func offworldSectionHeader() -> some View {
        modifier(OffworldSectionHeader())
    }

    /// Fixed-width numerals, only when the theme is on.
    func offworldMonoDigits(_ swatch: OffworldTheme.Swatch = .cyan) -> some View {
        modifier(OffworldMonoDigits(swatch: swatch))
    }

    /// Cyan accent for a presented sheet, only when the theme is on and `active` is true.
    func offworldTint(active: Bool = true) -> some View {
        modifier(OffworldTint(active: active))
    }
}

// MARK: - Home: panels and rain

/// Rectangle with the top-leading and bottom-trailing corners cut off.
struct OffworldClippedPanelShape: InsettableShape {
    var cut: CGFloat = 12
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cut, min(r.width, r.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> OffworldClippedPanelShape {
        OffworldClippedPanelShape(cut: cut, inset: inset + amount)
    }
}

/// Background-only panel for the Home header rows and chart: dark gradient fill, brass clipped
/// frame, faint cyan outer glow and (optionally) a light that sweeps the top edge every 5 s.
/// Drawn behind the content, so it never changes layout. Nothing when the theme is off.
struct OffworldHomePanel: View {
    var tint: OffworldTheme.Swatch = .panelRaised
    /// A soft vertical bar that sweeps across the panel (chart only).
    var scan: Bool = false
    /// How much of the rain behind is hidden; higher is quieter.
    var fillOpacity: Double = 0.5
    /// Pass the same gating inputs as the rain to allow the top-edge sweep; nil means no sweep.
    var motion: OffworldMotionInputs?

    var body: some View {
        if OffworldTheme.isEnabled {
            OffworldClippedPanelShape()
                // Slightly translucent so the rain shows through only as a trace.
                // Translucent on purpose: the rain behind stays visible across the panel.
                .fill(LinearGradient(
                    colors: [tint.color.opacity(fillOpacity), OffworldTheme.Swatch.background.color.opacity(fillOpacity)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    // inner bevel
                    OffworldClippedPanelShape(inset: 1.5)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
                .overlay(
                    OffworldClippedPanelShape()
                        .strokeBorder(OffworldTheme.frameStroke, lineWidth: 1.2)
                        .shadow(color: OffworldTheme.Swatch.copper.color.opacity(0.22), radius: 4)
                )
                .overlay {
                    if scan, let motion {
                        OffworldScanBar(motion: motion).clipShape(OffworldClippedPanelShape())
                    }
                }
                .overlay(alignment: .top) {
                    if let motion {
                        OffworldEdgeSweep(motion: motion)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// What the Home screen knows about whether decoration may move.
struct OffworldMotionInputs: Equatable {
    var modalPresented: Bool
    var homeVisible: Bool
}

/// Debug aid: `-OffworldDisableMotion rain,sweep,scan,pulse,sheen` removes those layers. Empty in release.
enum OffworldMotionDebug {
    static let disabledKinds: Set<String> = {
        #if DEBUG
            return Set(
                (UserDefaults.standard.string(forKey: "OffworldDisableMotion") ?? "")
                    .split(separator: ",").map(String.init)
            )
        #else
            return []
        #endif
    }()
}

/// Runs `content` only while decoration is allowed to animate (see `OffworldRainPolicy`);
/// otherwise the animated view is not in the tree at all.
struct OffworldMotionGate<Content: View>: View {
    let motion: OffworldMotionInputs
    /// Which decoration this is; lets a debug launch argument switch layers off one by one.
    var kind: String = ""
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var isActive: Bool {
        OffworldRainPolicy.isActive(
            themeOn: OffworldTheme.isEnabled,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPowerMode,
            sceneActive: scenePhase == .active,
            modalPresented: motion.modalPresented,
            homeVisible: motion.homeVisible
        ) && !OffworldMotionDebug.disabledKinds.contains(kind)
    }

    var body: some View {
        Group {
            if isActive { content() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// A short cyan light that crosses a panel's top edge once every `period` seconds. 2pt tall.
struct OffworldEdgeSweep: View {
    let motion: OffworldMotionInputs
    static let period: TimeInterval = 5
    static let travel: TimeInterval = 1.4

    /// 0...1 while the light is crossing, nil while it rests. Pure.
    static func progress(at time: TimeInterval) -> Double? {
        let phase = time.truncatingRemainder(dividingBy: period)
        return phase < travel ? phase / travel : nil
    }

    var body: some View {
        OffworldMotionGate(motion: motion, kind: "sweep") {
            TimelineView(.animation(minimumInterval: 1.0 / OffworldRainPolicy.framesPerSecond)) { timeline in
                Canvas { context, size in
                    guard let progress = Self.progress(at: timeline.date.timeIntervalSinceReferenceDate) else { return }
                    let length: CGFloat = 70
                    let x = CGFloat(progress) * (size.width + length) - length
                    let rect = CGRect(x: x, y: 0, width: length, height: 2)
                    context.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [.clear, OffworldTheme.Swatch.cyan.color.opacity(0.9), .clear]),
                            startPoint: CGPoint(x: rect.minX, y: 0),
                            endPoint: CGPoint(x: rect.maxX, y: 0)
                        )
                    )
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
        }
    }
}

/// When the Home rain may run. Pure, so it can be tested.
enum OffworldRainPolicy {
    static let framesPerSecond: Double = 15
    static let dropCount = 64

    static func isActive(
        themeOn: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        sceneActive: Bool,
        modalPresented: Bool,
        homeVisible: Bool = true
    ) -> Bool {
        themeOn && !reduceMotion && !lowPowerMode && sceneActive && !modalPresented && homeVisible
    }

    /// Position of one streak's head in unit space (0...1 both axes) at a time. Deterministic.
    static func dropPosition(index: Int, time: TimeInterval) -> CGPoint {
        func unit(_ seed: Double) -> Double {
            let value = sin(seed * 12.9898 + 78.233) * 43758.5453
            return value - value.rounded(.down)
        }
        let i = Double(index)
        let speed = 0.16 + 0.14 * unit(i + 0.31) // screen heights per second
        let phase = unit(i + 0.77)
        let fall = (time * speed + phase).truncatingRemainder(dividingBy: 1.0)
        let x = (unit(i + 0.13) * 1.3 - 0.15) - fall * 0.18 // drifts left as it falls
        return CGPoint(x: x, y: fall * 1.15 - 0.1)
    }
}

/// Faint diagonal rain for the Home background. One Canvas at 24 fps, behind all content.
/// Not in the view tree at all with the theme off, Reduce Motion or Low Power Mode on, while the
/// app is not active, while another tab is selected, or while any sheet (Treatments included) is up.
struct OffworldRain: View {
    let motion: OffworldMotionInputs

    var body: some View {
        OffworldMotionGate(motion: motion, kind: "rain") {
            TimelineView(.animation(minimumInterval: 1.0 / OffworldRainPolicy.framesPerSecond)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    var path = Path()
                    for index in 0 ..< OffworldRainPolicy.dropCount {
                        let head = OffworldRainPolicy.dropPosition(index: index, time: time)
                        let x = head.x * size.width
                        let y = head.y * size.height
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x + 6, y: y - 34))
                    }
                    context.stroke(path, with: .color(OffworldTheme.Swatch.cyan.color.opacity(0.34)), lineWidth: 1.2)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Third pass: display type and chips

/// Orbitron (SIL Open Font License 1.1, see Orbitron-OFL.txt beside the font file).
/// Registered at run time the first time the theme asks for it, so a theme-off app never loads it.
enum OffworldFont {
    static let fileName = "Orbitron-Variable"
    static let familyName = "Orbitron"

    /// True once the bundled font is registered and resolvable; false means "use the SF fallback".
    static let isAvailable: Bool = {
        if let url = Bundle.main.url(forResource: fileName, withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return !UIFont.fontNames(forFamilyName: familyName).isEmpty
    }()

    /// The hero-number face: Orbitron Black, or SF Expanded Black when the font could not be loaded.
    static func display(size: CGFloat) -> Font {
        isAvailable
            ? Font.custom(familyName, fixedSize: size).weight(.black)
            : Font.system(size: size, weight: .black).width(.expanded)
    }
}

private struct OffworldDisplayNumber: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            // Scales down rather than clipping ("HIGH", mmol/L values).
            content
                .font(OffworldFont.display(size: size))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        } else {
            content
        }
    }
}

private struct OffworldChip: ViewModifier {
    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            content
                .font(.caption2.weight(.bold).monospaced())
                .textCase(.uppercase)
        } else {
            content
        }
    }
}

extension View {
    /// Wide heavy display digits, only when the theme is on. Apply directly to the `Text`,
    /// before its stock `.font`, so the stock font stays in force when the theme is off.
    func offworldDisplayNumber(size: CGFloat) -> some View {
        modifier(OffworldDisplayNumber(size: size))
    }

    /// Small uppercase mono lettering for non-dosing tags, only when the theme is on.
    func offworldChipText() -> some View {
        modifier(OffworldChip())
    }
}

// MARK: - Home: bezel around the glucose number

private struct OffworldMotionKey: EnvironmentKey {
    static let defaultValue: OffworldMotionInputs? = nil
}

extension EnvironmentValues {
    /// Set by Home so nested decoration knows when it may move; nil means "stay static".
    var offworldMotion: OffworldMotionInputs? {
        get { self[OffworldMotionKey.self] }
        set { self[OffworldMotionKey.self] = newValue }
    }
}

/// Tick marks just inside the ring and a specular sheen that travels round it every 6 s.
/// Purely decorative, drawn over the ring only; nothing when the theme is off.
struct OffworldBezelDecor: View {
    let diameter: CGFloat
    let ringWidth: CGFloat

    @Environment(\.offworldMotion) private var motion

    static let sheenPeriod: TimeInterval = 6

    static func sheenAngle(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: sheenPeriod) / sheenPeriod * 360
    }

    private var sheen: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.80),
                        .init(color: Color.white.opacity(0.9), location: 0.9),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center
                ),
                lineWidth: ringWidth
            )
    }

    var body: some View {
        if OffworldTheme.isEnabled {
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let outer = size.width / 2 - ringWidth - 2
                    var path = Path()
                    for index in 0 ..< 48 {
                        let angle = Double(index) / 48 * 2 * Double.pi
                        let length: CGFloat = index % 4 == 0 ? 4 : 2
                        let dx = CGFloat(cos(angle))
                        let dy = CGFloat(sin(angle))
                        path.move(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
                        path.addLine(to: CGPoint(x: center.x + dx * (outer - length), y: center.y + dy * (outer - length)))
                    }
                    context.stroke(path, with: .color(OffworldTheme.Swatch.gold.color.opacity(0.75)), lineWidth: 1)
                }
                if let motion {
                    OffworldMotionGate(motion: motion, kind: "sheen") {
                        TimelineView(.animation(minimumInterval: 1.0 / OffworldRainPolicy.framesPerSecond)) { timeline in
                            sheen.rotationEffect(.degrees(Self.sheenAngle(at: timeline.date.timeIntervalSinceReferenceDate)))
                        }
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct OffworldReadout: ViewModifier {
    var swatch: OffworldTheme.Swatch = .cyan

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            content
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(swatch.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            content
        }
    }
}

extension View {
    /// Fixed-width digits with no colour change, only when the theme is on.
    @ViewBuilder func offworldTabularDigits() -> some View {
        if OffworldTheme.isEnabled {
            monospacedDigit()
        } else {
            self
        }
    }

    /// Cyan monospaced secondary readout (delta, minutes ago), only when the theme is on.
    func offworldReadout(_ swatch: OffworldTheme.Swatch = .cyan) -> some View {
        modifier(OffworldReadout(swatch: swatch))
    }
}

// MARK: - Fourth pass: trace runs, newest reading, scan bar, stat labels, pills

/// Splits CGM readings into drawable line runs. Pure, so the gap rule can be tested.
enum OffworldTrace {
    /// Readings further apart than this are never joined by a line (two missed 5-minute readings).
    static let maxGap: TimeInterval = 11 * 60

    struct Sample: Equatable {
        var id: Int
        var date: Date
        var band: OffworldTheme.GlucoseBand
        /// Reading in the chart's own unit; only used for the line's colour stops.
        var value: Double = 0
    }

    /// Gap-free stretches of two or more readings, plus the readings that have no close neighbour.
    /// `samples` must be sorted by date. Nothing is interpolated across a gap longer than `maxGap`.
    static func groups(_ samples: [Sample]) -> (runs: [[Sample]], isolated: [Sample]) {
        var runs: [[Sample]] = []
        var isolated: [Sample] = []
        var group: [Sample] = []
        func flush() {
            if group.count > 1 { runs.append(group) } else { isolated.append(contentsOf: group) }
            group = []
        }
        for sample in samples {
            if let last = group.last, sample.date.timeIntervalSince(last.date) > maxGap { flush() }
            group.append(sample)
        }
        flush()
        return (runs, isolated)
    }

    struct BandStop: Equatable {
        var location: Double
        var band: OffworldTheme.GlucoseBand
    }

    /// Hard colour stops for a bottom-to-top gradient over a line that spans `minValue...maxValue`,
    /// so the colour changes exactly at the thresholds: low at or below `low`, high at or above `high`.
    static func bandStops(minValue: Double, maxValue: Double, low: Double, high: Double) -> [BandStop] {
        guard maxValue > minValue else {
            let band: OffworldTheme.GlucoseBand = minValue <= low ? .low : (minValue >= high ? .high : .inRange)
            return [BandStop(location: 0, band: band), BandStop(location: 1, band: band)]
        }
        func unit(_ value: Double) -> Double { min(max((value - minValue) / (maxValue - minValue), 0), 1) }
        let lowEdge = unit(low)
        let highEdge = max(unit(high), lowEdge)
        var stops: [BandStop] = []
        for (
            start,
            end,
            band
        ) in [(0, lowEdge, OffworldTheme.GlucoseBand.low), (lowEdge, highEdge, .inRange), (highEdge, 1, .high)]
                where end > start
            {
                stops.append(BandStop(location: start, band: band))
                stops.append(BandStop(location: end, band: band))
            }
            return stops
    }

    /// Two or more consecutive samples drawn as one line in one colour.
    struct Run: Equatable {
        var band: OffworldTheme.GlucoseBand
        var samples: [Sample]
    }

    /// `samples` must be sorted by date. A segment takes the band of the reading it ends at; when
    /// the band changes the next run starts at the shared reading, so the line stays continuous.
    static func build(_ samples: [Sample]) -> (runs: [Run], isolated: [Sample]) {
        var runs: [Run] = []
        var isolated: [Sample] = []
        var group: [Sample] = []

        func flush() {
            defer { group = [] }
            guard group.count > 1 else {
                isolated.append(contentsOf: group)
                return
            }
            var current = Run(band: group[1].band, samples: [group[0]])
            for index in 1 ..< group.count {
                let sample = group[index]
                if sample.band != current.band {
                    runs.append(current)
                    current = Run(band: sample.band, samples: [group[index - 1]])
                }
                current.samples.append(sample)
            }
            runs.append(current)
        }

        for sample in samples {
            if let last = group.last, sample.date.timeIntervalSince(last.date) > maxGap {
                flush()
            }
            group.append(sample)
        }
        flush()
        return (runs, isolated)
    }
}

/// The newest reading on the Home chart: a filled dot with a dark ring, its value beside it, and a
/// halo that pulses only while motion is allowed. Lives in a chart overlay, so the pulse never
/// makes the chart itself redraw.
struct OffworldNewestReading: View {
    let position: CGPoint
    let plotWidth: CGFloat
    let color: Color
    let label: String
    /// A faint violet outer ring on the pulse; decoration, shown only for an in-range reading.
    var showsAccentRing = false

    @Environment(\.offworldMotion) private var motion

    static let period: TimeInterval = 2.4

    /// 0...1 phase of the pulse. Pure.
    static func phase(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    var body: some View {
        let labelOnRight = position.x + 44 < plotWidth
        ZStack {
            if let motion {
                OffworldMotionGate(motion: motion, kind: "pulse") {
                    TimelineView(.animation(minimumInterval: 1.0 / OffworldRainPolicy.framesPerSecond)) { timeline in
                        let phase = Self.phase(at: timeline.date.timeIntervalSinceReferenceDate)
                        ZStack {
                            Circle()
                                .fill(color.opacity(0.45 * (1 - phase)))
                                .frame(width: 10 + 22 * phase, height: 10 + 22 * phase)
                            if showsAccentRing {
                                Circle()
                                    .stroke(OffworldTheme.Swatch.magenta.color.opacity(0.35 * (1 - phase)), lineWidth: 1)
                                    .frame(width: 14 + 26 * phase, height: 14 + 26 * phase)
                            }
                        }
                    }
                }
            }
            Circle().fill(OffworldTheme.Swatch.background.color).frame(width: 13, height: 13)
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.8), radius: 4)
            Text(verbatim: label)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(OffworldTheme.Swatch.ink.color)
                .fixedSize()
                .offset(x: labelOnRight ? 24 : -24)
        }
        .frame(width: 34, height: 34)
        .position(position)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Soft vertical teal bar that crosses a panel every `period` seconds. Behind the chart marks.
struct OffworldScanBar: View {
    let motion: OffworldMotionInputs
    static let period: TimeInterval = 7
    static let travel: TimeInterval = 3.5

    static func progress(at time: TimeInterval) -> Double? {
        let phase = time.truncatingRemainder(dividingBy: period)
        return phase < travel ? phase / travel : nil
    }

    var body: some View {
        OffworldMotionGate(motion: motion, kind: "scan") {
            TimelineView(.animation(minimumInterval: 1.0 / OffworldRainPolicy.framesPerSecond)) { timeline in
                Canvas { context, size in
                    guard let progress = Self.progress(at: timeline.date.timeIntervalSinceReferenceDate) else { return }
                    let width: CGFloat = 54
                    let x = CGFloat(progress) * (size.width + width) - width
                    let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                    context.fill(
                        Path(rect),
                        with: .linearGradient(
                            Gradient(colors: [.clear, OffworldTheme.Swatch.cyan.color.opacity(0.13), .clear]),
                            startPoint: CGPoint(x: rect.minX, y: 0),
                            endPoint: CGPoint(x: rect.maxX, y: 0)
                        )
                    )
                }
            }
        }
    }
}

private struct OffworldStatLabel: ViewModifier {
    let label: String
    let alignment: Alignment

    func body(content: Content) -> some View {
        if OffworldTheme.isEnabled {
            // Value nudged up, small tan caption hung beneath it. Overlay only: the row keeps its size.
            content
                .offset(y: -7)
                .overlay(alignment: alignment) {
                    Text(verbatim: label)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(OffworldTheme.Swatch.muted.color)
                        .fixedSize()
                        .offset(y: 9)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

extension View {
    /// Reference-style stat: small tan uppercase caption under a value, only when the theme is on.
    func offworldStatLabel(_ label: String, alignment: Alignment = .bottom) -> some View {
        modifier(OffworldStatLabel(label: label, alignment: alignment))
    }
}

/// Off-world replacement for the Home glass pills: the panel gradient instead of grey glass.
/// A tinted pill (for example a warning row) keeps its tint and tinted rim.
struct OffworldPillBackground: View {
    let tint: Color?
    let tintOpacity: Double
    let strokeOpacity: Double

    var body: some View {
        GlassChrome.panelShape
            .fill(LinearGradient(
                colors: [OffworldTheme.Swatch.panelRaised.color.opacity(0.9), OffworldTheme.Swatch.panel.color.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(GlassChrome.panelShape.fill((tint ?? .clear).opacity(tintOpacity)))
            .overlay(
                GlassChrome.panelShape.strokeBorder(
                    tint.map { AnyShapeStyle($0.opacity(max(strokeOpacity, 0.5))) } ?? AnyShapeStyle(OffworldTheme.brassRim),
                    lineWidth: 1
                )
            )
    }
}

// MARK: - Chart elements: treatments, basal, forecast (appearance only, theme on only)

/// A plain triangle, apex down (insulin) or up (carbs).
struct OffworldTriangle: Shape {
    var pointsUp = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsUp {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Treatment glyphs for the Home chart. Sizes derive from the stock glyph size, so a larger dose still
/// draws a larger mark; a manual bolus is always drawn larger than an SMB of the same amount.
struct OffworldChartGlyph: View {
    enum Kind: Equatable {
        case manualBolus
        case smb
        case carb
    }

    let kind: Kind
    /// The stock glyph's point size for this amount.
    let stockSize: CGFloat

    /// Drawn width in points.
    static func width(kind: Kind, stockSize: CGFloat) -> CGFloat {
        switch kind {
        case .manualBolus: return stockSize * 1.25 + 5
        case .smb: return max(stockSize, 6)
        case .carb: return max(stockSize * 1.15, 8)
        }
    }

    /// Half the drawn height: how far an amount label must sit from the mark's centre to clear the glyph.
    static func labelClearance(kind: Kind, stockSize: CGFloat) -> CGFloat {
        width(kind: kind, stockSize: stockSize) * 0.43 + 1
    }

    var body: some View {
        let width = Self.width(kind: kind, stockSize: stockSize)
        let isCarb = kind == .carb
        let fill = isCarb
            ? AnyShapeStyle(LinearGradient(
                colors: [OffworldTheme.Swatch.carbGold.color, OffworldTheme.Swatch.carbEdge.color],
                startPoint: .top,
                endPoint: .bottom
            ))
            : AnyShapeStyle(OffworldTheme.Swatch.violet.color)
        let glow = isCarb ? OffworldTheme.Swatch.carbEdge.color : OffworldTheme.Swatch.violetGlow.color
        let rim = LinearGradient(
            colors: isCarb
                ? [OffworldTheme.Swatch.chrome.color, OffworldTheme.Swatch.carbGold.color, OffworldTheme.Swatch.copper.color]
                : [OffworldTheme.Swatch.silver.color, OffworldTheme.Swatch.silver.color.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        OffworldTriangle(pointsUp: isCarb)
            .fill(fill)
            .overlay(OffworldTriangle(pointsUp: isCarb).stroke(rim, lineWidth: kind == .smb ? 0.5 : 0.9))
            .frame(width: width, height: width * 0.86)
            .shadow(color: glow.opacity(isCarb ? 0.5 : (kind == .smb ? 0.6 : 0.8)), radius: kind == .smb ? 2.5 : 4)
            .allowsHitTesting(false)
    }
}

/// Fat-protein carb equivalent: a hollow copper ring, so it cannot be mistaken for entered carbs.
struct OffworldFpuGlyph: View {
    var diameter: CGFloat = 6.5

    var body: some View {
        Circle()
            .strokeBorder(OffworldTheme.Swatch.copper.color.opacity(0.9), lineWidth: 1.1)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }
}

extension OffworldTheme {
    /// Small monospaced lettering for treatment amounts on the chart.
    static let chartAmountFont = Font.system(size: 9.5, weight: .semibold, design: .monospaced)

    /// Brass to copper and back, for the Home panel frames.
    static var frameStroke: LinearGradient {
        LinearGradient(
            colors: [Swatch.gold.color, Swatch.copper.color, Swatch.brass.color, Swatch.copper.color, Swatch.gold.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Brass rim for the pills under the chart.
    static var brassRim: LinearGradient {
        LinearGradient(
            colors: [Swatch.gold.color, Swatch.brass.color, Swatch.gold.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Rim of the small round Home buttons (alarm bell, chart legend): chrome when the theme is on.
    static var roundButtonRim: Color {
        isEnabled ? Swatch.chrome.color.opacity(0.75) : Color.primary.opacity(0.4)
    }

    /// Line colour of one oref forecast curve ("iob", "cob", "uam", "zt").
    static func forecastLineColor(type: String?) -> Color {
        switch type {
        case "iob": return Swatch.violet.color
        case "cob": return Swatch.carbGold.color
        case "uam": return Swatch.chrome.color
        case "zt": return Swatch.pink.color
        default: return Swatch.muted.color
        }
    }
}

/// The decorative wave inside the forecast cone. It only ever travels between the real lower and upper
/// forecast bounds at each time; it adds no value of its own and never leaves the envelope.
enum OffworldForecastWave {
    /// One full oscillation.
    static let period: TimeInterval = 20 * 60
    /// Samples per 5-minute forecast step.
    static let samplesPerStep = 5
    /// Share of the half-width the wave reaches, so it stays just inside the drawn edges.
    static let reach = 0.9

    struct Sample: Equatable {
        let id: Int
        /// Seconds after the first forecast point.
        let offset: TimeInterval
        let value: Double
    }

    /// `low` and `high` are the envelope bounds at consecutive `step`-second intervals.
    static func samples(low: [Double], high: [Double], step: TimeInterval = 300) -> [Sample] {
        let count = min(low.count, high.count)
        guard count > 1 else { return [] }
        var result = [Sample]()
        result.reserveCapacity((count - 1) * samplesPerStep + 1)
        for segment in 0 ..< (count - 1) {
            let last = segment == count - 2
            for sub in 0 ..< (last ? samplesPerStep + 1 : samplesPerStep) {
                let fraction = Double(sub) / Double(samplesPerStep)
                let lower = low[segment] + (low[segment + 1] - low[segment]) * fraction
                let upper = high[segment] + (high[segment + 1] - high[segment]) * fraction
                let offset = (Double(segment) + fraction) * step
                let middle = (lower + upper) / 2
                let half = max(upper - lower, 0) / 2
                let value = middle + half * reach * sin(2 * .pi * offset / period)
                result.append(Sample(id: result.count, offset: offset, value: min(max(value, lower), upper)))
            }
        }
        return result
    }
}

/// The centre tab-bar button while the theme is on: a gold disc with a chrome rim, a dark plus and a
/// warm glow. Same footprint as the stock 40 pt symbol.
struct OffworldPlusDisc: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [
                    Color(.sRGB, red: 1, green: 0.9, blue: 0.6, opacity: 1),
                    OffworldTheme.Swatch.carbGold.color,
                    OffworldTheme.Swatch.copper.color
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [
                            OffworldTheme.Swatch.chrome.color,
                            OffworldTheme.Swatch.gold.color,
                            OffworldTheme.Swatch.chrome.color.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(OffworldTheme.Swatch.background.color)
            )
            .frame(width: 40, height: 40)
            .shadow(color: OffworldTheme.Swatch.carbEdge.color.opacity(0.5), radius: 6)
            .padding(.vertical, 4)
    }
}
