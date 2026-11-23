import Foundation
import UserNotifications

/// Swaps the generic push text for the real title and body, which arrive encrypted.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        best = request.content.mutableCopy() as? UNMutableNotificationContent
        guard let best else { return contentHandler(request.content) }
        if let sealed = request.content.userInfo["e"] as? String, let json = Box.open(sealed),
           let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        {
            if let title = obj["title"] as? String { best.title = title }
            if let body = obj["body"] as? String { best.body = body }
            if let ask = obj["ask"] as? String { best.userInfo["ask"] = ask }
        }
        contentHandler(best)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let best { handler(best) }
    }
}
