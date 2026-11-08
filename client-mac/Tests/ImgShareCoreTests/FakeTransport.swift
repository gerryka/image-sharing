import Foundation
@testable import ImgShareCore

struct FakeError: Error {}

/// In-Memory-Server mit derselben Paging-Semantik wie der Go-Server.
actor FakeTransport: ChatTransport {
    var messages: [EncryptedMessage] = []
    var blobs: [String: Data] = [:]
    var nextId: Int64 = 1
    var postedCount = 0
    var connectCount = 0
    var postError: Error?
    private var cont: AsyncThrowingStream<ServerEvent, Error>.Continuation?

    /// Legt eine Nachricht ab, ohne sie per WebSocket zu senden.
    @discardableResult
    func store(_ ciphertext: Data, id: Int64? = nil) -> EncryptedMessage {
        let i = id ?? nextId
        nextId = max(nextId, i + 1)
        let m = EncryptedMessage(id: i, serverTs: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)),
                                 ciphertext: ciphertext.base64EncodedString())
        messages.append(m)
        messages.sort { $0.id < $1.id }
        return m
    }

    func emit(_ e: ServerEvent) { cont?.yield(e) }
    func fail() { cont?.finish(throwing: FakeError()); cont = nil }
    func setPostError(_ e: Error?) { postError = e }

    func postMessage(_ ciphertext: Data) async throws -> PostMessageResult {
        if let postError { throw postError }
        postedCount += 1
        let m = store(ciphertext)
        cont?.yield(.message(m)) // Server-Echo
        return PostMessageResult(id: m.id, serverTs: m.serverTs)
    }

    func getMessages(after: Int64?, before: Int64?, limit: Int) async throws -> MessagesPage {
        if let before {
            let older = messages.filter { $0.id < before }
            let page = Array(older.suffix(limit))
            return MessagesPage(messages: page, hasMore: older.count > page.count)
        }
        let newer = messages.filter { $0.id > (after ?? 0) }
        let page = Array(newer.prefix(limit))
        return MessagesPage(messages: page, hasMore: newer.count > page.count)
    }

    func uploadBlob(_ data: Data, progress: (@Sendable (Double) -> Void)?) async throws -> BlobResult {
        let id = UUID().uuidString.lowercased()
        blobs[id] = data
        progress?(1.0)
        return BlobResult(blobId: id, size: Int64(data.count))
    }

    func putBlob(_ id: String, _ data: Data) { blobs[id] = data }

    func getBlob(_ id: String) async throws -> Data {
        guard let d = blobs[id] else { throw ApiError.http(status: 404, code: "not_found") }
        return d
    }

    func connectEvents() async throws -> AsyncThrowingStream<ServerEvent, Error> {
        connectCount += 1
        let (s, c) = AsyncThrowingStream<ServerEvent, Error>.makeStream()
        cont = c
        return s
    }
}

final class MemoryCache: BlobCaching, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    func read(room: String, blobId: String) -> Data? { lock.withLock { items[room + "/" + blobId] } }
    func write(room: String, blobId: String, data: Data) { lock.withLock { items[room + "/" + blobId] = data } }
    func remove(room: String, blobId: String) { _ = lock.withLock { items.removeValue(forKey: room + "/" + blobId) } }
}

/// PNG-Datei, die nur aus Signatur, IHDR und IEND besteht (für Pixel-Grenzen).
func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
    func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let tb = Array(type.utf8)
        return be(UInt32(body.count)) + tb + body + be(crc32(tb + body))
    }
    let ihdr = be(width) + be(height) + [8, 2, 0, 0, 0]
    return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IEND", []))
}
