import AppKit
import ImgShareCore
import SwiftUI

/// Chat einrichten oder bearbeiten (Gegenstück zu SetupWindow.xaml).
struct SetupView: View {
    let chatId: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var serverURL = AppModel.defaultServer
    @State private var myName = NSFullUserName().components(separatedBy: " ").first ?? ""
    @State private var chatName = ""
    @State private var keyText = ""
    @State private var invite = ""
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var confirmRemove = false
    @State private var loaded = false

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    private var parsedKey: Data? { KeyFormat.parse(keyText) }
    private var validURL: URL? { try? ApiClient.validateServerURL(serverURL).get() }
    private var urlError: String? {
        if case .failure(let e) = ApiClient.validateServerURL(serverURL) { return e.message }
        return nil
    }
    private var canSave: Bool {
        parsedKey != nil && validURL != nil && !trim(myName).isEmpty && !trim(chatName).isEmpty
    }

    var body: some View {
        Form {
            Section("Verbindung") {
                TextField("Server-Adresse", text: $serverURL, prompt: Text("https://server.example.com:47000"))
                if let urlError, serverURL != "https://" {
                    Text(urlError).foregroundStyle(.red).font(.caption)
                }
                SecureField("Server-Zugangscode (optional)", text: $invite)
                Text("Nur nötig, wenn der Chat auf dem Server neu angelegt wird.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Namen") {
                TextField("Mein Name", text: $myName)
                TextField("Chat-Name", text: $chatName, prompt: Text("z. B. Anna"))
            }
            Section("Schlüssel") {
                TextField("Schlüssel", text: $keyText, prompt: Text("XXXX-XXXX-…"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...3)
                HStack {
                    Button("Neu erzeugen") { keyText = KeyFormat.format(ChatKeys.generateRootKey()) }
                    Button("Einfügen") { keyText = NSPasteboard.general.string(forType: .string) ?? keyText }
                    Button("Schlüssel kopieren") { copyKeyConcealed() }
                        .disabled(parsedKey == nil)
                }
                if let key = parsedKey, let keys = try? ChatKeys.derive(rootKey: key) {
                    LabeledContent("Sicherheitscode") {
                        Text(keys.safetyCode).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    }
                    Text("Vergleicht den Sicherheitscode mit dem Gegenüber – er muss auf beiden Geräten gleich sein.")
                        .font(.caption).foregroundStyle(.secondary)
                    QRCodeView(text: KeyFormat.format(key))
                        .frame(width: 160, height: 160)
                        .frame(maxWidth: .infinity)
                } else if !keyText.isEmpty {
                    Text("Der Schlüssel ist ungültig.").foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                HStack {
                    Button("Verbindung testen") { Task { await testConnection() } }
                        .disabled(parsedKey == nil || validURL == nil || testState == .running)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Label("Verbindung OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let msg): Text(msg).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            if chatId != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Chat entfernen", role: .destructive) { confirmRemove = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern") { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("„\(chatName)“ wirklich entfernen?", isPresented: $confirmRemove) {
            Button("Entfernen", role: .destructive) {
                if let chatId { model.remove(chatId: chatId) }
                close()
            }
        } message: {
            Text("Der Schlüssel wird von diesem Mac gelöscht. Ohne ihn ist der Chat hier nicht mehr lesbar.")
        }
        .onAppear {
            load()
            activateApp() // beim ersten Start sonst hinter anderen Fenstern
        }
        .onChange(of: keyText) { testState = .idle }
        .onChange(of: serverURL) { testState = .idle }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let chatId, let e = model.entry(chatId) else { return }
        serverURL = e.serverURL
        myName = e.myName
        chatName = e.chatName
        if let key = try? model.keychain.rootKey(chatId: chatId) { keyText = KeyFormat.format(key) }
        invite = model.keychain.invite(chatId: chatId) ?? ""
    }

    private func testConnection() async {
        guard let key = parsedKey, let url = validURL else { return }
        testState = .running
        do {
            try await ChatSession.testConnection(serverURL: url, rootKey: key, invite: trim(invite))
            testState = .ok
        } catch {
            testState = .failed(ErrorText.describe(error))
        }
    }

    private func save() {
        guard let key = parsedKey, let url = validURL else { return }
        var e = chatId.flatMap(model.entry) ?? ChatEntry(serverURL: "", myName: "", chatName: "")
        e.serverURL = url.absoluteString
        e.myName = trim(myName)
        e.chatName = trim(chatName)
        do {
            try model.addOrUpdate(entry: e, rootKey: key, invite: trim(invite))
            let id = e.id
            close()
            openWindow(id: "chat", value: id)
            activateApp()
        } catch {
            saveError = ErrorText.describe(error)
        }
    }

    private func close() {
        if let chatId { dismissWindow(id: "edit-chat", value: chatId) } else { dismissWindow(id: "new-chat") }
    }

    /// Kopiert den Schlüssel als „verborgen“ (Zwischenablage-Manager/Universal Clipboard ignorieren ihn)
    /// und leert die Zwischenablage nach 60 s wieder, wenn sie sich nicht verändert hat.
    private func copyKeyConcealed() {
        guard let key = parsedKey else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                         NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        pb.setString(KeyFormat.format(key), forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}
