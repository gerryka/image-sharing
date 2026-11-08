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
            MenuBarLabel().environment(model)
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

        WindowGroup("Bild", id: "image", for: ImageRef.self) { $ref in
            if let ref {
                ImageViewerView(ref: ref)
                    .environment(model)
            }
        }
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

/// Symbol in der Menüleiste. Bleibt immer geladen und öffnet daher auch Chats aus Mitteilungen.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.totalUnread > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill"
                                                : "bubble.left.and.bubble.right")
            .accessibilityLabel(model.totalUnread > 0 ? "ImgShare – \(model.totalUnread) ungelesen" : "ImgShare")
            .onChange(of: model.pendingOpenChat) {
                guard let id = model.pendingOpenChat else { return }
                model.pendingOpenChat = nil
                openWindow(id: "chat", value: id)
                activateApp()
            }
    }
}

/// Holt die App nach vorne (LSUIElement-Apps werden sonst nicht aktiv).
@MainActor func activateApp() {
    NSApp.activate()
}
