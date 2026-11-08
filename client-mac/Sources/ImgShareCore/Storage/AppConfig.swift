import Foundation

public func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

/// Ein eingerichteter Chat. Root-Key und Invite liegen im Keychain (KeychainStore).
public struct ChatEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var serverURL: String
    public var myName: String
    public var chatName: String
    /// Zufällige Geräte-ID: unterscheidet eigene von fremden Nachrichten.
    public var deviceId: String
    /// Höchste gelesene fremde Nachricht (lokal, für Ungelesen-Zähler).
    public var lastReadId: Int64

    public init(id: String = newId(), serverURL: String, myName: String, chatName: String,
                deviceId: String = newId(), lastReadId: Int64 = 0) {
        self.id = id; self.serverURL = serverURL; self.myName = myName; self.chatName = chatName
        self.deviceId = deviceId; self.lastReadId = lastReadId
    }

    public var info: ChatEntryInfo? {
        guard let url = try? ApiClient.validateServerURL(serverURL).get() else { return nil }
        return ChatEntryInfo(id: id, serverURL: url, myName: myName, chatName: chatName,
                             deviceId: deviceId, lastReadId: lastReadId)
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var chats: [ChatEntry] = []
    public var notificationsPaused = false

    public init() {}

    /// Optional: IMGSHARE_HOME legt Config und Cache in einen eigenen Ordner (Tests, zweite Instanz).
    static var homeOverride: URL? {
        ProcessInfo.processInfo.environment["IMGSHARE_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
    }

    public static var configDir: URL {
        homeOverride ?? URL.applicationSupportDirectory.appending(path: "ImgShare")
    }

    public static var cacheDir: URL {
        homeOverride.map { $0.appending(path: "cache") } ?? URL.cachesDirectory.appending(path: "ImgShare")
    }

    public static func load(from dir: URL = configDir) -> AppConfig {
        let path = dir.appending(path: "config.json")
        guard let data = try? Data(contentsOf: path) else { return AppConfig() }
        if let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) { return cfg }
        // Kaputte Config: neu anfangen, alte bleibt als .bak.
        let bak = dir.appending(path: "config.json.bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: path, to: bak)
        return AppConfig()
    }

    public func save(to dir: URL = configDir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .atomic schreibt in eine temporäre Datei und benennt dann um.
        try enc.encode(self).write(to: dir.appending(path: "config.json"), options: .atomic)
    }
}

extension ChatEntry {
    /// Nur Namen geändert → bestehende Verbindung behalten (Entwurf, Warteschlange und Verlauf bleiben).
    public static func needsReconnect(old: ChatEntry, new: ChatEntry, keyChanged: Bool, inviteChanged: Bool) -> Bool {
        keyChanged || inviteChanged || old.serverURL != new.serverURL || old.deviceId != new.deviceId
    }
}
