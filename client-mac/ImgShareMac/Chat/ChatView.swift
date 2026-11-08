import AppKit
import ImgShareCore
import SwiftUI

/// Wurzel eines Chat-Fensters: findet die Session zum Chat.
struct ChatWindowRoot: View {
    let chatId: String
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let s = model.sessions[chatId], let entry = model.entry(chatId) {
            ChatView(session: s, chatId: chatId, chatName: entry.chatName)
                .id(ObjectIdentifier(s)) // neue Session (Setup geändert) → neues Fenster-Modell
        } else {
            ContentUnavailableView {
                Label("Chat nicht verfügbar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(model.startErrors[chatId] ?? "Der Chat wurde entfernt.")
            } actions: {
                if model.entry(chatId) != nil {
                    Button("Chat bearbeiten…") { openWindow(id: "edit-chat", value: chatId) }
                }
            }
            .frame(minWidth: 360, minHeight: 300)
        }
    }
}

struct ChatView: View {
    let session: ChatSession
    let chatId: String
    let chatName: String

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    @State private var vm: ChatViewModel
    @State private var search = ""
    @State private var atBottom = true
    @State private var loadingOlder = false
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    init(session: ChatSession, chatId: String, chatName: String) {
        self.session = session
        self.chatId = chatId
        self.chatName = chatName
        _vm = State(initialValue: ChatViewModel(session: session))
    }

    private var isActive: Bool { activeState == .key }

    private var visible: [ChatMessage] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return session.messages }
        return session.messages.filter {
            $0.text?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var status: String {
        switch session.state {
        case .online: session.otherOnline ? "online" : "verbunden"
        case .connecting: "verbinde …"
        case .offline: "getrennt" + (session.lastError.map { " – \($0)" } ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            ComposerView(vm: vm)
        }
        .frame(minWidth: 360, minHeight: 400)
        .navigationTitle(chatName)
        .navigationSubtitle(status)
        .searchable(text: $search, placement: .toolbar, prompt: "Im Chat suchen")
        .toolbar {
            ToolbarItem {
                Button { openWindow(id: "edit-chat", value: chatId) } label: { Image(systemName: "gearshape") }
                    .help("Chat bearbeiten")
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff], isTargeted: $dropTargeted) { providers in
            Task { if let r = await PasteboardImage.load(from: providers) { vm.pick(r) } }
            return true
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active { model.chatBecameActive(chatId) } else { model.activeChatIds.remove(chatId) }
            if active { Task { await session.markRead() } }
        }
        .onChange(of: session.messages.last?.id) {
            if isActive { Task { await session.markRead() } }
        }
        .onAppear(perform: installPasteMonitor)
        .onDisappear {
            model.activeChatIds.remove(chatId)
            if let m = pasteMonitor { NSEvent.removeMonitor(m) }
            pasteMonitor = nil
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if session.hasOlder && search.isEmpty && session.isLoaded {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            .onAppear { loadOlder(proxy) }
                    }
                    if !session.isLoaded {
                        ProgressView("Lade Verlauf …").frame(maxWidth: .infinity).padding()
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !Calendar.current.isDate(visible[i - 1].payload.sentAt, inSameDayAs: m.payload.sentAt) {
                            Text(DayLabel.text(for: m.payload.sentAt))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        MessageRow(message: m, session: session) { info in openImage(info) }
                            .id(m.id)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, bottom in atBottom = bottom }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom, let last = visible.last {
                    Button { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(12)
                    .help("Nach unten")
                }
            }
            .onChange(of: session.messages.last?.id) {
                // Eigene neue Nachricht immer sichtbar machen.
                if let last = session.messages.last, last.isMine || atBottom {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard !loadingOlder else { return }
        loadingOlder = true
        let anchor = session.messages.first?.id
        Task {
            defer { loadingOlder = false }
            try? await session.loadOlder()
            if let anchor { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    private func openImage(_ info: ImageInfo) {
        openWindow(id: "image", value: ImageRef(chatId: chatId, info: info))
    }

    /// ⌘V mit Bild in der Zwischenablage: Bild übernehmen, statt (nichts) ins Textfeld einzufügen.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  model.activeChatIds.contains(chatId), activeState == .key,
                  PasteboardImage.hasImage(.general),
                  let picked = PasteboardImage.read(from: .general) else { return event }
            vm.pick(.success(picked))
            return nil
        }
    }
}
