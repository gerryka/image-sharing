import Foundation
import Observation

/// Werte eines Chats, die die Session braucht (ohne Geheimnisse).
public struct ChatEntryInfo: Sendable, Equatable {
    public var id: String
    public var serverURL: URL
    public var myName: String
    public var chatName: String
    public var deviceId: String
    public var lastReadId: Int64

    public init(id: String, serverURL: URL, myName: String, chatName: String, deviceId: String, lastReadId: Int64) {
        self.id = id; self.serverURL = serverURL; self.myName = myName
        self.chatName = chatName; self.deviceId = deviceId; self.lastReadId = lastReadId
    }
}

/// Verschlüsselter Bild-Cache (Implementierung: BlobCache).
public protocol BlobCaching: Sendable {
    func read(room: String, blobId: String) -> Data?
    func write(room: String, blobId: String, data: Data)
    func remove(room: String, blobId: String)
}

public struct Backoff: Sendable {
    public var initial: Duration
    public var max: Duration
    public init(initial: Duration, max: Duration) { self.initial = initial; self.max = max }
    public static let `default` = Backoff(initial: .seconds(1), max: .seconds(30))
}

public enum ImageError: Error, Equatable, Sendable, UserFacingError {
    case unsupportedFormat, tooLarge, tooManyPixels, invalidImage, invalidBlobId

    public var message: String {
        switch self {
        case .unsupportedFormat: "Nur PNG und JPG werden unterstützt."
        case .tooLarge: "Bild ist größer als 24 MB."
        case .tooManyPixels: "Das Bild ist zu groß zum Anzeigen."
        case .invalidImage: "Kein gültiges Bild."
        case .invalidBlobId: "Ungültige Bild-ID."
        }
    }
}

/// Eine Chat-Verbindung: entschlüsselter Verlauf, WebSocket, Senden, Lesebestätigungen.
/// Port von client/ImgShare.Core/ChatSession.cs.
@MainActor @Observable
public final class ChatSession {
    public private(set) var entry: ChatEntryInfo
    public let keys: ChatKeys

    public private(set) var messages: [ChatMessage] = []
    public private(set) var state: ConnectionState = .connecting
    public private(set) var otherOnline = false
    public private(set) var otherReadUpTo: Int64 = 0
    public private(set) var hasOlder = true
    public private(set) var isLoaded = false
    public private(set) var lastError: String?

    /// Neue fremde Nachricht (live = kam nach dem ersten Laden). Für Mitteilungen.
    @ObservationIgnored public var onNewMessage: ((ChatMessage, _ live: Bool) -> Void)?

    @ObservationIgnored private let transport: ChatTransport
    @ObservationIgnored private let cache: BlobCaching?
    @ObservationIgnored private let backoff: Backoff
    @ObservationIgnored private let onLastReadChanged: (Int64) -> Void
    @ObservationIgnored private var byId: [Int64: ChatMessage] = [:]
    @ObservationIgnored private var seen = Set<Int64>()
    @ObservationIgnored private var minSeenId = Int64.max
    @ObservationIgnored private var maxSeenId: Int64 = 0
    @ObservationIgnored private var myReadUpTo: Int64 = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?

    static let safeBlobId = /^[A-Za-z0-9-]{1,64}$/

    public init(entry: ChatEntryInfo, rootKey: Data, invite: String?, transport: ChatTransport? = nil,
                cache: BlobCaching? = nil, backoff: Backoff = .default,
                onLastReadChanged: @escaping (Int64) -> Void) throws {
        self.entry = entry
        keys = try ChatKeys.derive(rootKey: rootKey)
        self.transport = transport ?? ApiClient(serverURL: entry.serverURL, keys: keys, invite: invite)
        self.cache = cache
        self.backoff = backoff
        self.onLastReadChanged = onLastReadChanged
    }

    public var unreadCount: Int {
        messages.reduce(0) { $0 + (!$1.isMine && $1.id > entry.lastReadId ? 1 : 0) }
    }

    /// Aktualisiert Namen (nach Bearbeiten im Setup), ohne neu zu verbinden.
    public func updateNames(myName: String, chatName: String) {
        entry.myName = myName; entry.chatName = chatName
    }

    // MARK: Verbindung

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
    }

    public func run() async {
        var delay = backoff.initial
        while !Task.isCancelled {
            do {
                state = .connecting
                try await catchUp()                                // Verlauf auch ohne WebSocket
                let events = try await transport.connectEvents()
                try await catchUp()                                // Lücke zwischen GET und WS schließen
                lastError = nil
                state = .online
                delay = backoff.initial
                for try await e in events { handle(e) }
                if Task.isCancelled { break }
                lastError = "Die Verbindung zum Server wurde unterbrochen."
            } catch {
                if Task.isCancelled { break }
                lastError = ErrorText.describe(error)
            }
            otherOnline = false
            state = .offline
            do { try await Task.sleep(for: delay) } catch { break }
            delay = min(delay * 2, backoff.max)
        }
    }

    private func catchUp() async throws {
        if !isLoaded {
            let page = try await transport.getMessages(after: nil, before: Int64.max, limit: 200)
            for em in page.messages { process(em, live: false) }
            hasOlder = page.hasMore
            isLoaded = true
            return
        }
        while true {
            let page = try await transport.getMessages(after: maxSeenId, before: nil, limit: 500)
            for em in page.messages { process(em, live: true) }
            if !page.hasMore || page.messages.isEmpty { break }
        }
    }

    private func handle(_ e: ServerEvent) {
        switch e {
        case .message(let em): process(em, live: true)
        case .presence(let n): otherOnline = n >= 2
        }
    }

    // MARK: Verarbeitung

    @discardableResult
    private func process(_ em: EncryptedMessage, live: Bool) -> Bool {
        guard seen.insert(em.id).inserted else { return false }
        minSeenId = min(minSeenId, em.id)
        maxSeenId = max(maxSeenId, em.id)

        guard let raw = Data(base64Encoded: em.ciphertext),
              let plain = try? keys.decrypt(raw),
              let p = try? WireJSON.decoder().decode(Payload.self, from: plain) else { return false }

        let mine = p.sender == entry.deviceId
        switch p.messageKind {
        case .read:
            let upTo = p.readUpTo ?? 0
            if mine { myReadUpTo = max(myReadUpTo, upTo) } else if upTo > otherReadUpTo { otherReadUpTo = upTo }
            return false
        case .text where !(p.text ?? "").isEmpty:
            break
        case .image where p.image.map { $0.blobId.wholeMatch(of: Self.safeBlobId) != nil } == true:
            break
        default:
            return false
        }
        let msg = ChatMessage(id: em.id, serverTs: em.serverTs, payload: p, isMine: mine)
        byId[em.id] = msg
        messages = byId.values.sorted { $0.id < $1.id }
        if isLoaded && !mine { onNewMessage?(msg, live) }
        return true
    }

    public func loadOlder() async throws {
        guard hasOlder, isLoaded else { return }
        let page = try await transport.getMessages(after: nil, before: minSeenId, limit: 100)
        for em in page.messages where !seen.contains(em.id) {
            // ältere Nachrichten ohne Hook einsortieren
            let wasLoaded = isLoaded
            isLoaded = false
            process(em, live: false)
            isLoaded = wasLoaded
        }
        hasOlder = page.hasMore && !page.messages.isEmpty
    }

    // MARK: Senden

    private func newPayload(_ kind: MessageKind) -> Payload {
        Payload(kind: kind.rawValue, sender: entry.deviceId, senderName: entry.myName, sentAt: Date())
    }

    private func post(_ p: Payload) async throws -> Int64 {
        let ct = try keys.encrypt(try WireJSON.encoder().encode(p))
        let res = try await transport.postMessage(ct)
        // Server pusht die Nachricht auch per WebSocket zurück; process dedupliziert über die ID.
        process(EncryptedMessage(id: res.id, serverTs: res.serverTs, ciphertext: ct.base64EncodedString()), live: true)
        return res.id
    }

    @discardableResult
    public func sendText(_ text: String) async throws -> Int64 {
        var p = newPayload(.text)
        p.text = text
        return try await post(p)
    }

    @discardableResult
    public func sendImage(_ data: Data, fileName: String, progress: (@Sendable (Double) -> Void)?) async throws -> Int64 {
        guard let mime = ImageFormat.detectMime(data) else { throw ImageError.unsupportedFormat }
        guard Int64(data.count) <= ImageFormat.maxImageBytes else { throw ImageError.tooLarge }
        let dims = ImageFormat.dimensions(of: data) ?? (0, 0)
        let blob = try keys.encrypt(data)
        let up = try await transport.uploadBlob(blob, progress: progress)
        cache?.write(room: keys.roomId, blobId: up.blobId, data: blob)
        var p = newPayload(.image)
        p.image = ImageInfo(blobId: up.blobId, mime: mime, filename: fileName, size: Int64(data.count),
                            width: dims.width, height: dims.height)
        return try await post(p)
    }

    /// Lokal als gelesen markieren und ggf. Lesebestätigung senden.
    public func markRead() async {
        let latest = messages.filter { !$0.isMine }.map(\.id).max() ?? 0
        if latest > entry.lastReadId {
            entry.lastReadId = latest
            onLastReadChanged(latest)
        }
        if latest > myReadUpTo {
            myReadUpTo = latest
            var p = newPayload(.read)
            p.readUpTo = latest
            do { _ = try await post(p) } catch { myReadUpTo = 0 }
        }
    }

    // MARK: Bilder

    /// Lädt (oder liest aus dem verschlüsselten Cache) und entschlüsselt ein Bild.
    public func imageData(for info: ImageInfo) async throws -> Data {
        guard info.blobId.wholeMatch(of: Self.safeBlobId) != nil else { throw ImageError.invalidBlobId }
        if let cached = cache?.read(room: keys.roomId, blobId: info.blobId) {
            if let plain = try? decryptImage(cached) { return plain }
            cache?.remove(room: keys.roomId, blobId: info.blobId) // kaputter Eintrag
        }
        let enc = try await transport.getBlob(info.blobId)
        let plain = try decryptImage(enc)                              // erst prüfen …
        cache?.write(room: keys.roomId, blobId: info.blobId, data: enc) // … dann cachen
        return plain
    }

    private func decryptImage(_ enc: Data) throws -> Data {
        let plain = try keys.decrypt(enc)
        guard ImageFormat.detectMime(plain) != nil, let d = ImageFormat.dimensions(of: plain) else {
            throw ImageError.invalidImage
        }
        guard Int64(d.width) * Int64(d.height) <= ImageFormat.maxPixels else { throw ImageError.tooManyPixels }
        return plain
    }

    // MARK: Verbindungstest

    public static func testConnection(serverURL: URL, rootKey: Data, invite: String?) async throws {
        let api = ApiClient(serverURL: serverURL, keys: try ChatKeys.derive(rootKey: rootKey), invite: invite)
        _ = try await api.getMessages(after: 0, before: nil, limit: 1)
    }
}
