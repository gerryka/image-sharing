import Foundation

public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Gruppiert und ersetzt Mitteilungen desselben Chats.
    public var threadId: String
}

/// Mitteilungstext wie im Windows-Client (App.xaml.cs, OnMessage).
public enum NotificationText {
    public static func make(chatId: String, chatName: String, message: ChatMessage, unread: Int) -> NotificationContent {
        let preview: String
        if message.kind == .image {
            preview = "hat ein Bild geteilt"
        } else {
            let t = message.text ?? ""
            preview = t.count > 120 ? String(t.prefix(120)) + " …" : t
        }
        let body = unread > 1 ? "\(unread) neue Nachrichten – zuletzt: \(preview)" : preview
        return NotificationContent(title: chatName, body: body, threadId: chatId)
    }
}
