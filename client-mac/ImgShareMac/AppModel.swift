import Foundation
import ImgShareCore
import Observation

/// Hält die Konfiguration und alle laufenden Chat-Verbindungen.
@MainActor @Observable
final class AppModel {
    private(set) var config: AppConfig
    private(set) var sessions: [String: ChatSession] = [:]
    /// Chats, die nicht starten konnten (z. B. Schlüssel fehlt), mit Fehlertext.
    private(set) var startErrors: [String: String] = [:]
    /// Chats, deren Fenster gerade vorne ist (keine Mitteilungen, automatisch gelesen).
    var activeChatIds: Set<String> = []

    let keychain = KeychainStore()
    let cache = BlobCache()
    @ObservationIgnored var onNewMessage: ((ChatEntry, ChatMessage) -> Void)?

    init() {
        config = AppConfig.load()
    }

    var totalUnread: Int { sessions.values.reduce(0) { $0 + $1.unreadCount } }

    static var defaultServer: String {
        let s = (Bundle.main.object(forInfoDictionaryKey: "IMGSHAREDefaultServer") as? String) ?? ""
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? "https://" : s
    }

    func entry(_ chatId: String) -> ChatEntry? { config.chats.first { $0.id == chatId } }

    func start() {
        for e in config.chats { startSession(e) }
    }

    private func startSession(_ e: ChatEntry) {
        sessions[e.id]?.stop()
        sessions[e.id] = nil
        startErrors[e.id] = nil
        guard let info = e.info else {
            startErrors[e.id] = ApiError.invalidServerURL.message
            return
        }
        do {
            let key = try keychain.rootKey(chatId: e.id)
            let chatId = e.id
            let s = try ChatSession(entry: info, rootKey: key, invite: keychain.invite(chatId: e.id),
                                    cache: cache) { [weak self] id in self?.setLastRead(chatId: chatId, id: id) }
            s.onNewMessage = { [weak self] msg, live in
                guard live, let self, let entry = self.entry(chatId) else { return }
                self.onNewMessage?(entry, msg)
            }
            sessions[e.id] = s
            s.start()
        } catch {
            startErrors[e.id] = ErrorText.describe(error)
        }
    }

    /// Neuen Chat anlegen oder bestehenden ändern. Startet die Verbindung neu.
    func addOrUpdate(entry: ChatEntry, rootKey: Data, invite: String?) throws {
        var e = entry
        if let old = self.entry(e.id), let oldKey = try? keychain.rootKey(chatId: e.id),
           oldKey != rootKey || old.serverURL != e.serverURL {
            e.lastReadId = 0 // anderer Chat → Lesestand gilt nicht mehr
        }
        try keychain.setRootKey(rootKey, chatId: e.id)
        try keychain.setInvite(invite, chatId: e.id)
        if let i = config.chats.firstIndex(where: { $0.id == e.id }) {
            config.chats[i] = e
        } else {
            config.chats.append(e)
        }
        saveConfig()
        startSession(e)
    }

    func remove(chatId: String) {
        sessions[chatId]?.stop()
        sessions[chatId] = nil
        startErrors[chatId] = nil
        keychain.removeAll(chatId: chatId)
        config.chats.removeAll { $0.id == chatId }
        saveConfig()
    }

    func chatWithMostUnread() -> String? {
        config.chats.max { (sessions[$0.id]?.unreadCount ?? 0) < (sessions[$1.id]?.unreadCount ?? 0) }?.id
    }

    func setNotificationsPaused(_ paused: Bool) {
        config.notificationsPaused = paused
        saveConfig()
    }

    private func setLastRead(chatId: String, id: Int64) {
        guard let i = config.chats.firstIndex(where: { $0.id == chatId }) else { return }
        config.chats[i].lastReadId = id
        saveConfig()
    }

    func saveConfig() {
        do { try config.save() } catch { NSLog("ImgShare: Config speichern fehlgeschlagen: \(error)") }
    }
}
