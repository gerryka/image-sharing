import ImgShareCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var loginItem = LoginItem()

    var body: some View {
        if model.config.chats.isEmpty {
            Text("Noch kein Chat eingerichtet")
        }
        ForEach(model.config.chats) { chat in
            Button(title(for: chat)) {
                if model.startErrors[chat.id] != nil {
                    openWindow(id: "edit-chat", value: chat.id)
                } else {
                    openWindow(id: "chat", value: chat.id)
                }
                activateApp()
            }
        }
        if let id = model.chatWithMostUnread(), model.totalUnread > 0 {
            Button("Ungelesene öffnen") {
                openWindow(id: "chat", value: id)
                activateApp()
            }
            .keyboardShortcut("o")
        }
        Divider()
        Button("Neuen Chat einrichten…") {
            openWindow(id: "new-chat")
            activateApp()
        }
        .keyboardShortcut("n")
        Toggle("Mitteilungen pausieren", isOn: Binding(
            get: { model.config.notificationsPaused },
            set: { model.setNotificationsPaused($0) }))
        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }))
        Divider()
        Button("ImgShare beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(for chat: ChatEntry) -> String {
        if model.startErrors[chat.id] != nil { return "\(chat.chatName) – Schlüssel fehlt" }
        let n = model.sessions[chat.id]?.unreadCount ?? 0
        return n > 0 ? "\(chat.chatName) (\(n))" : chat.chatName
    }
}
