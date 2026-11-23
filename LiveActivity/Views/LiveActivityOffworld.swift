import ActivityKit
import CoreText
import SwiftUI
import UIKit
import WidgetKit

/// Optional "Off-world" look for the Live Activity. Appearance only.
///
/// The widget extension shares no storage with the app, so the theme flag arrives in the activity's
/// content state (`ContentState.offworld`). Nil or false means every view draws exactly as stock.
///
/// The hex values are copied from `OffworldTheme.Swatch` in the app target (which cannot be compiled
/// into the extension, it depends on app-only code). Keep the two in sync.
enum LiveActivityOffworld {
    static func isOn(_ state: LiveActivityAttributes.ContentState) -> Bool {
        state.offworld == true
    }

    // MARK: - Palette (mirrors OffworldTheme.Swatch)

    static let background = color(0x06080C)
    static let backgroundLift = color(0x0A0F15)
    static let panel = color(0x0C1218)
    static let gold = color(0xD9B45A)
    static let silver = color(0xD6DCE2)
    static let brass = color(0x6B5326)
    static let ink = color(0xF4E7C6)
    static let muted = color(0xA8946A)
    static let amber = color(0xFFB000)
    static let mint = color(0x7DFFB2)
    static let violet = color(0xD07BFF)
    static let carbGold = color(0xFFC23A)
    static let magenta = color(0xFF3DF0)

    /// In-range glucose colour for the Live Activity.
    static let inRange = mint

    private static func color(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static var frameStroke: LinearGradient {
        LinearGradient(
            colors: [gold, brass, silver, brass, gold],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Glucose band

    enum Band: Equatable {
        case low
        case inRange
        case high
    }

    /// Same comparisons as the stock static scheme: at or below low is low, at or above high is high.
    static func band(value: Decimal, low: Decimal, high: Decimal) -> Band {
        if value <= low { return .low }
        if value >= high { return .high }
        return .inRange
    }

    /// Band of the current reading against the user's own low and high, or nil when there is no number.
    static func band(_ state: LiveActivityAttributes.ContentState) -> Band? {
        guard let value = Decimal(string: state.bg) else { return nil }
        let isMgdL = state.unit == "mg/dL"
        return band(
            value: value,
            low: isMgdL ? state.lowGlucose : state.lowGlucose.asMmolL,
            high: isMgdL ? state.highGlucose : state.highGlucose.asMmolL
        )
    }

    static func isLow(_ state: LiveActivityAttributes.ContentState) -> Bool {
        band(state) == .low
    }

    /// Themed colour for a glucose value. Low is always the stock red. With the dynamic colour scheme
    /// the user's gradient (`stock`) is kept for everything that is not low.
    static func glucoseColor(band: Band?, isStaticScheme: Bool, stock: Color) -> Color {
        switch band {
        case .low:
            return Color.staticLow
        case .inRange:
            return isStaticScheme ? inRange : stock
        case .high:
            return isStaticScheme ? amber : stock
        case nil:
            return ink
        }
    }

    /// Colour of the current reading: themed when the theme is on, otherwise nil (caller keeps stock).
    static func currentGlucoseColor(_ state: LiveActivityAttributes.ContentState, stock: Color) -> Color? {
        guard isOn(state) else { return nil }
        return glucoseColor(band: band(state), isStaticScheme: state.glucoseColorScheme == "staticColor", stock: stock)
    }

    // MARK: - Text styles

    /// Small captions ("IOB", "Updated"): tan when themed, otherwise the given stock style.
    static func labelStyle(
        _ state: LiveActivityAttributes.ContentState,
        stock: some ShapeStyle = HierarchicalShapeStyle.primary
    ) -> AnyShapeStyle {
        isOn(state) ? AnyShapeStyle(muted) : AnyShapeStyle(stock)
    }

    /// Values: the given accent when themed, otherwise stock primary. Stale always falls back to secondary.
    static func valueStyle(_ state: LiveActivityAttributes.ContentState, themed: Color, isStale: Bool) -> AnyShapeStyle {
        if isStale { return AnyShapeStyle(.secondary) }
        return isOn(state) ? AnyShapeStyle(themed) : AnyShapeStyle(.primary)
    }

    // MARK: - Font

    /// Orbitron (SIL Open Font License 1.1), bundled in the extension and listed under UIAppFonts.
    /// Also registered here in case the plist entry was not picked up.
    private static let orbitronAvailable: Bool = {
        let family = "Orbitron"
        if UIFont.fontNames(forFamilyName: family).isEmpty,
           let url = Bundle.main.url(forResource: "Orbitron-Variable", withExtension: "ttf")
        {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return !UIFont.fontNames(forFamilyName: family).isEmpty
    }()

    /// The big-number face: Orbitron Black, or SF Expanded Black when the font could not be loaded.
    static func display(size: CGFloat) -> Font {
        orbitronAvailable
            ? Font.custom("Orbitron", fixedSize: size).weight(.black)
            : Font.system(size: size, weight: .black).width(.expanded)
    }
}

extension View {
    /// Big-number face and a soft glow in the reading's colour, only when the theme is on.
    @ViewBuilder func liveActivityOffworldNumber(
        _ state: LiveActivityAttributes.ContentState,
        size: CGFloat,
        color: Color
    ) -> some View {
        if LiveActivityOffworld.isOn(state) {
            font(LiveActivityOffworld.display(size: size))
                .shadow(color: color.opacity(0.55), radius: 5)
        } else {
            self
        }
    }
}

/// Red "LOW" tag beside the number while the theme is on and the reading is at or below the user's low.
struct LiveActivityOffworldLowTag: View {
    let state: LiveActivityAttributes.ContentState

    var body: some View {
        if LiveActivityOffworld.isOn(state), LiveActivityOffworld.isLow(state) {
            Text(verbatim: "LOW")
                .font(.system(size: 12, weight: .heavy).width(.expanded))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.staticLow))
                .accessibilityLabel(Text(verbatim: "Low glucose"))
        }
    }
}

/// Lock-screen surface for the themed Live Activity: near-black fill and a metal frame that
/// turns solid red while the reading is low.
struct LiveActivityOffworldSurface: ViewModifier {
    let state: LiveActivityAttributes.ContentState
    let isWatchOS: Bool

    func body(content: Content) -> some View {
        let low = LiveActivityOffworld.isLow(state)
        content
            .padding(.all, isWatchOS ? 10 : 14)
            .frame(minHeight: 0, maxHeight: .infinity)
            .privacySensitive()
            .foregroundStyle(LiveActivityOffworld.ink)
            .background(
                LinearGradient(
                    colors: [LiveActivityOffworld.backgroundLift, LiveActivityOffworld.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                ContainerRelativeShape()
                    .strokeBorder(
                        low ? AnyShapeStyle(Color.staticLow) : AnyShapeStyle(LiveActivityOffworld.frameStroke),
                        lineWidth: low ? 2.5 : 1.5
                    )
                    .allowsHitTesting(false)
            )
            .activityBackgroundTint(LiveActivityOffworld.background)
            .activitySystemActionForegroundColor(LiveActivityOffworld.ink)
            // Primary and secondary text must read as light on the dark surface in either system appearance.
            .environment(\.colorScheme, .dark)
    }
}
