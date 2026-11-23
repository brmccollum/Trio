import SwiftUI
import UserNotifications
import WatchKit

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Notifications.shared.setUp()
        Link.shared.start()
    }
}

@main struct ClodsWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
        }
    }
}
