import Foundation
import Testing
@testable import ImgShareCore

struct NotificationTextTests {
    func msg(_ kind: String, text: String? = nil) -> ChatMessage {
        let img = kind == "image" ? ImageInfo(blobId: "b", mime: "image/png", filename: "a.png", size: 1, width: 1, height: 1) : nil
        return ChatMessage(id: 1, serverTs: Date(),
                           payload: Payload(kind: kind, sender: "o", senderName: "Anna", sentAt: Date(), text: text, image: img),
                           isMine: false)
    }

    @Test func singleText() {
        let n = NotificationText.make(chatId: "c1", chatName: "Anna", message: msg("text", text: "Hallo"), unread: 1)
        #expect(n == NotificationContent(title: "Anna", body: "Hallo", threadId: "c1"))
    }

    @Test func longTextIsCut() {
        let n = NotificationText.make(chatId: "c1", chatName: "Anna", message: msg("text", text: String(repeating: "x", count: 200)), unread: 1)
        #expect(n.body == String(repeating: "x", count: 120) + " …")
    }

    @Test func image() {
        #expect(NotificationText.make(chatId: "c1", chatName: "Anna", message: msg("image"), unread: 1).body == "hat ein Bild geteilt")
    }

    @Test func bundlesUnread() {
        let n = NotificationText.make(chatId: "c1", chatName: "Anna", message: msg("text", text: "Hi"), unread: 3)
        #expect(n.body == "3 neue Nachrichten – zuletzt: Hi")
    }
}
