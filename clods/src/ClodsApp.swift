import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Notifications.shared.setUp()
        Link.shared.start()
        NotificationCenter.default.addObserver(forName: .clodsPaired, object: nil, queue: .main) { _ in
            app.registerForRemoteNotifications()
        }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { await MainActor.run { app.registerForRemoteNotifications() } }
        }
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
            let env = "sandbox"
        #else
            let env = "production"
        #endif
        Task { await Relay.register(token: hex, platform: "ios", env: env) }
    }
}

@main struct ClodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { store.pair($0.absoluteString) }
        }
    }
}
