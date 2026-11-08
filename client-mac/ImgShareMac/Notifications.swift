import Foundation
import ImgShareCore
import UserNotifications

/// Mitteilungen über die Mitteilungszentrale. Eine Mitteilung pro Chat, die bei neuen Nachrichten ersetzt wird.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var asked = false
    /// Wird beim Klick auf eine Mitteilung mit der Chat-ID aufgerufen.
    var onOpenChat: ((String) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ c: NotificationContent) {
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.body = c.body
        content.threadIdentifier = c.threadId
        content.sound = .default
        content.userInfo = ["chatId": c.threadId]
        // Gleicher Identifier → ersetzt die vorige Mitteilung dieses Chats.
        center.add(UNNotificationRequest(identifier: c.threadId, content: content, trigger: nil))
    }

    func clear(chatId: String) {
        center.removeDeliveredNotifications(withIdentifiers: [chatId])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let chatId = response.notification.request.content.userInfo["chatId"] as? String else { return }
        await MainActor.run { onOpenChat?(chatId) }
    }
}
