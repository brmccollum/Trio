import CoreText
import Foundation
import SwiftUI
import UIKit

extension Binding where Value == Int {
    func doubleBinding() -> Binding<Double> {
        Binding<Double>(
            get: { Double(self.wrappedValue) },
            set: { self.wrappedValue = Int($0) }
        )
    }
}

/// Optional "Off-world" appearance on the watch, mirrored from the phone's display state.
/// Appearance only: neutral surfaces, a brass rule, a static glow and fixed-width digits.
/// Glucose, loop, insulin and carb colours, and every button, keep their stock colours.
enum WatchOffworldTheme {
    static let defaultsKey = "bryan.theme.offworld"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static let background = Color(red: 0x06 / 255, green: 0x08 / 255, blue: 0x0C / 255)
    static let backgroundLift = Color(red: 0x0A / 255, green: 0x0F / 255, blue: 0x15 / 255)
    static let brass = Color(red: 0x6B / 255, green: 0x53 / 255, blue: 0x26 / 255)
    static let cyan = Color(red: 0x2E / 255, green: 0xF2 / 255, blue: 0xFF / 255)
    static let gold = Color(red: 0xD9 / 255, green: 0xB4 / 255, blue: 0x5A / 255)
    static let silver = Color(red: 0xD6 / 255, green: 0xDC / 255, blue: 0xE2 / 255)

    /// Static brass bezel with silver highlights for the ring around the glucose number.
    static let bezelGradient = AngularGradient(
        colors: [gold, silver, gold, brass, gold, silver, brass, gold],
        center: .center,
        startAngle: .degrees(270),
        endAngle: .degrees(-90)
    )
}

/// Orbitron (SIL Open Font License 1.1) for the watch's main glucose number, theme on only.
enum WatchOffworldFont {
    static let isAvailable: Bool = {
        if let url = Bundle.main.url(forResource: "Orbitron-Variable", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return !UIFont.fontNames(forFamilyName: "Orbitron").isEmpty
    }()
}

extension View {
    /// Orbitron Black at the given text style, only when the theme is on and the font loaded.
    @ViewBuilder func watchOffworldDisplayFont(_ style: Font.TextStyle, active: Bool) -> some View {
        if active, WatchOffworldFont.isAvailable {
            font(Font.custom("Orbitron", size: style == .title ? 30 : 24, relativeTo: style).weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            self
        }
    }
}

extension Color {
    private static let stockBgDarkBlue = Color("Background_DarkBlue")
    private static let stockBgDarkerDarkBlue = Color("Background_DarkerDarkBlue")
    static var bgDarkBlue: Color { WatchOffworldTheme.isEnabled ? WatchOffworldTheme.backgroundLift : stockBgDarkBlue }
    static var bgDarkerDarkBlue: Color { WatchOffworldTheme.isEnabled ? WatchOffworldTheme.background : stockBgDarkerDarkBlue }
}

extension View {
    /// Static halo behind text, only when the Off-world theme is on. Never animated.
    @ViewBuilder func watchOffworldGlow(_ color: Color, active: Bool) -> some View {
        if active {
            shadow(color: color.opacity(0.6), radius: 5)
        } else {
            self
        }
    }

    /// Fixed-width figures, only when the Off-world theme is on.
    @ViewBuilder func watchOffworldDigits(active: Bool) -> some View {
        if active {
            monospacedDigit()
        } else {
            self
        }
    }
}

extension String {
    func toColor() -> Color {
        var hexString = trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)

        let red = Double((rgb & 0xFF0000) >> 16) / 255.0
        let green = Double((rgb & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000FF) / 255.0

        return Color(red: red, green: green, blue: blue)
    }
}
