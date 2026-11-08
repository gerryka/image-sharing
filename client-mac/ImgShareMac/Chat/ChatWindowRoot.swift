import ImgShareCore
import SwiftUI

/// Platzhalter bis Task 9: zeigt Status des Chats.
struct ChatWindowRoot: View {
    let chatId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.sessions[chatId] {
            List(s.messages) { m in Text(m.text ?? "📷 Bild") }
                .navigationTitle(model.entry(chatId)?.chatName ?? "Chat")
        } else {
            ContentUnavailableView("Chat nicht verfügbar", systemImage: "exclamationmark.triangle",
                                   description: Text(model.startErrors[chatId] ?? ""))
        }
    }
}
