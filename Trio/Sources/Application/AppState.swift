import Foundation
import Observation
import SwiftUI
import UIKit

@Observable class AppState {
    /// Mirror of `OffworldTheme.isEnabled`. Observed, so every screen that asks for the
    /// background below redraws when the theme is switched. Appearance only.
    var offworldEnabled: Bool = OffworldTheme.isEnabled {
        didSet {
            guard offworldEnabled != oldValue else { return }
            OffworldTheme.isEnabled = offworldEnabled
            OffworldTheme.applyUIKitChrome(enabled: offworldEnabled)
        }
    }

    /// True while a sheet is up. Only used to stop the Off-world Home rain behind sheets.
    var modalPresented: Bool = false

    func trioBackgroundColor(for colorScheme: ColorScheme) -> LinearGradient {
        if offworldEnabled { return OffworldTheme.backgroundGradient }
        return colorScheme == .dark
            ? LinearGradient(
                gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
                startPoint: .top,
                endPoint: .bottom
            )
            : LinearGradient(
                gradient: Gradient(colors: [Color.gray.opacity(0.1)]),
                startPoint: .top,
                endPoint: .bottom
            )
    }
}
