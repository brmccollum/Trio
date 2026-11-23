import Foundation
import SwiftUI
import UserNotifications
import WatchConnectivity

@MainActor final class Store: ObservableObject {
    static let shared = Store()

    @Published var clods: [Clod] = []
    @Published var error: String?
    @Published var lastLoad: Date?
    @Published var paired = Config.isPaired

    /// Returns false when the text is not a pairing code.
    @discardableResult func pair(_ text: String) -> Bool {
        guard let p = Config.parse(text) else { return false }
        Config.save(p)
        paired = true
        Link.shared.sendPairing()
        NotificationCenter.default.post(name: .clodsPaired, object: nil)
        Task { await load() }
        return true
    }

    var waitingCount: Int { clods.filter(\.needsYou).count }

    func load() async {
        do {
            clods = try await Relay.fetch()
            error = nil
            lastLoad = Date()
        } catch {
            // A load interrupted because the app left the foreground is not a failure.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            self.error = "Can't reach the relay"
        }
    }

    func answer(_ clod: Clod, _ text: String) async {
        guard let id = clod.askID else { return }
        let ok = await Relay.answer(askID: id, text: text)
        if !ok { error = "Reply not sent" }
        await load()
    }
}

/// Notification categories and the handler for buttons tapped on a notification.
/// The same code runs on the phone and on the watch; whichever one shows the buttons answers.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let go = UNNotificationAction(identifier: "GO", title: "Go ahead", options: [])
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"
        )
        let ask = UNNotificationCategory(identifier: "ASK", actions: [go, reply], intentIdentifiers: [], options: [])
        let info = UNNotificationCategory(identifier: "INFO", actions: [], intentIdentifiers: [], options: [])
        center.setNotificationCategories([ask, info])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await Store.shared.load()
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var askID = info["ask"] as? String ?? ""
        if askID.isEmpty, let sealed = info["e"] as? String, let json = Box.open(sealed),
           let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        {
            askID = obj["ask"] as? String ?? ""
        }
        switch response.actionIdentifier {
        case "GO":
            await Relay.answer(askID: askID, text: "go ahead")
        case "REPLY":
            if let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty {
                await Relay.answer(askID: askID, text: text)
            }
        default:
            break
        }
        await Store.shared.load()
    }
}

extension Color {
    static func state(_ clod: Clod) -> Color {
        switch clod.state {
        case "waiting": return .orange
        case "permission": return .yellow
        case "working": return .blue
        case "done": return .green
        default: return .gray
        }
    }
}

func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

extension Notification.Name {
    static let clodsPaired = Notification.Name("clodsPaired")
}

/// Carries the pairing from the phone to the watch, so only the phone has to be paired.
final class Link: NSObject, WCSessionDelegate {
    static let shared = Link()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendPairing() {
        #if os(iOS)
            guard WCSession.isSupported(), WCSession.default.activationState == .activated,
                  let encoded = Config.encoded else { return }
            try? WCSession.default.updateApplicationContext(["pairing": encoded])
        #endif
    }

    private func take(_ context: [String: Any]) {
        #if os(watchOS)
            guard let text = context["pairing"] as? String else { return }
            Task { @MainActor in
                if Config.encoded != text { Store.shared.pair(text) }
            }
        #endif
    }

    func session(_ session: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        sendPairing()
        take(session.receivedApplicationContext)
    }

    func session(_: WCSession, didReceiveApplicationContext context: [String: Any]) {
        take(context)
    }

    #if os(iOS)
        func sessionDidBecomeInactive(_: WCSession) {}
        func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
