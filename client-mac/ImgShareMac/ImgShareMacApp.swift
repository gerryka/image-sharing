import AppKit
import ImgShareCore
import SwiftUI

@main
struct ImgShareMacApp: App {
    @State private var model = AppModel()

    init() {
        let m = _model.wrappedValue
        Task { @MainActor in m.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.totalUnread > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill"
                                                    : "bubble.left.and.bubble.right")
                .accessibilityLabel(model.totalUnread > 0 ? "ImgShare – \(model.totalUnread) ungelesen" : "ImgShare")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Chat", id: "chat", for: String.self) { $chatId in
            if let chatId {
                ChatWindowRoot(chatId: chatId)
                    .environment(model)
            }
        }
        .defaultSize(width: 460, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Neuen Chat einrichten", id: "new-chat") {
            SetupView(chatId: nil)
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.config.chats.isEmpty ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Chat bearbeiten", id: "edit-chat", for: String.self) { $chatId in
            if let chatId {
                SetupView(chatId: chatId)
                    .environment(model)
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Holt die App nach vorne (LSUIElement-Apps werden sonst nicht aktiv).
@MainActor func activateApp() {
    NSApp.activate()
}
