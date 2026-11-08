import Foundation
import Testing
@testable import ImgShareCore

@MainActor
struct ChatSessionTests {
    let root = ChatKeys.generateRootKey()
    var keys: ChatKeys { try! ChatKeys.derive(rootKey: root) }
    let fake = FakeTransport()
    let cache = MemoryCache()
    let me = "me-device"
    let fast = Backoff(initial: .milliseconds(1), max: .milliseconds(4))

    func payload(_ kind: String, sender: String = "other", text: String? = nil,
                 image: ImageInfo? = nil, readUpTo: Int64? = nil) -> Data {
        let p = Payload(kind: kind, sender: sender, senderName: "Gegenüber", sentAt: Date(),
                        text: text, image: image, readUpTo: readUpTo)
        return try! keys.encrypt(try! WireJSON.encoder().encode(p))
    }

    func session(lastRead: Int64 = 0, onLastRead: @escaping (Int64) -> Void = { _ in }) throws -> ChatSession {
        let info = ChatEntryInfo(id: "c1", serverURL: URL(string: "https://x.invalid")!, myName: "Ich",
                                 chatName: "Test", deviceId: me, lastReadId: lastRead)
        return try ChatSession(entry: info, rootKey: root, invite: nil, transport: fake, cache: cache,
                               backoff: fast, onLastReadChanged: onLastRead)
    }

    func started(_ s: ChatSession) async -> ChatSession {
        s.start()
        _ = await eventually { s.state == .online }
        return s
    }

    @Test func initialLoadDecryptsAndSorts() async throws {
        await fake.store(payload("text", text: "drei"), id: 3)
        await fake.store(payload("text", text: "eins"), id: 1)
        await fake.store(payload("text", text: "zwei"), id: 2)
        let s = await started(try session())
        defer { s.stop() }
        #expect(s.isLoaded)
        #expect(s.messages.map(\.id) == [1, 2, 3])
        #expect(s.messages.map(\.text) == ["eins", "zwei", "drei"])
    }

    @Test func dedupsPostEcho() async throws {
        let s = await started(try session())
        defer { s.stop() }
        let id = try await s.sendText("hi")
        _ = await eventually(timeout: .milliseconds(50)) { false } // Echo-Verarbeitung abwarten
        #expect(s.messages.count == 1)
        #expect(s.messages[0].id == id)
        #expect(s.messages[0].isMine)
    }

    @Test func ignoresGarbage() async throws {
        let s = await started(try session())
        defer { s.stop() }
        let bad = ImageInfo(blobId: "../x", mime: "image/png", filename: "a.png", size: 1, width: 1, height: 1)
        let junk: [Data] = [
            Data((0..<64).map { _ in UInt8.random(in: 0...255) }),
            payload("reaction", text: "x"),
            payload("text", text: ""),
            payload("image", image: bad),
            Data(count: 27),
        ]
        for j in junk { await fake.emit(.message(await fake.store(j))) }
        await fake.emit(.message(await fake.store(payload("text", text: "ok"))))
        #expect(await eventually { s.messages.count == 1 })
        #expect(s.messages[0].text == "ok")
        #expect(s.state == .online)
    }

    @Test func readReceipts() async throws {
        let s = await started(try session())
        defer { s.stop() }
        await fake.emit(.message(await fake.store(payload("read", readUpTo: 7))))
        #expect(await eventually { s.otherReadUpTo == 7 })
        await fake.emit(.message(await fake.store(payload("read", readUpTo: 5))))
        await fake.emit(.message(await fake.store(payload("read", sender: me, readUpTo: 99))))
        _ = await eventually(timeout: .milliseconds(100)) { false }
        #expect(s.otherReadUpTo == 7)
        #expect(s.messages.isEmpty)
    }

    @Test func unreadAndMarkRead() async throws {
        let lastRead = LockedBox<Int64>(0)
        await fake.store(payload("text", text: "a"))
        await fake.store(payload("text", text: "b"))
        let s = await started(try session(onLastRead: { lastRead.set($0) }))
        defer { s.stop() }
        #expect(s.unreadCount == 2)
        let posted = await fake.postedCount
        await s.markRead()
        #expect(s.unreadCount == 0)
        #expect(lastRead.get() == 2)
        #expect(await fake.postedCount == posted + 1)
        await s.markRead()
        #expect(await fake.postedCount == posted + 1)
    }

    @Test func presenceThreshold() async throws {
        let s = await started(try session())
        defer { s.stop() }
        await fake.emit(.presence(online: 1))
        _ = await eventually(timeout: .milliseconds(50)) { false }
        #expect(!s.otherOnline)
        await fake.emit(.presence(online: 2))
        #expect(await eventually { s.otherOnline })
    }

    @Test func reconnectsWithBackoffAndCatchesUp() async throws {
        let s = await started(try session())
        defer { s.stop() }
        await fake.fail()
        await fake.store(payload("text", text: "zehn"), id: 10)
        #expect(await eventually { s.messages.contains { $0.id == 10 } })
        #expect(await eventually { s.state == .online })
        #expect(await fake.connectCount >= 2)
        // Nach erneutem Echo keine Duplikate
        await fake.emit(.message(EncryptedMessage(id: 10, serverTs: Date(),
                                                  ciphertext: payload("text", text: "zehn").base64EncodedString())))
        _ = await eventually(timeout: .milliseconds(50)) { false }
        #expect(s.messages.filter { $0.id == 10 }.count == 1)
    }

    @Test func offlineStateAfterFailure() async throws {
        let slow = Backoff(initial: .seconds(5), max: .seconds(5))
        let info = ChatEntryInfo(id: "c1", serverURL: URL(string: "https://x.invalid")!, myName: "Ich",
                                 chatName: "Test", deviceId: me, lastReadId: 0)
        let s = try ChatSession(entry: info, rootKey: root, invite: nil, transport: fake, cache: cache,
                                backoff: slow, onLastReadChanged: { _ in })
        _ = await started(s)
        defer { s.stop() }
        await fake.fail()
        #expect(await eventually { s.state == .offline })
        #expect(s.lastError != nil)
    }

    @Test func loadOlderPrepends() async throws {
        for i in 1...250 { await fake.store(payload("text", text: "n\(i)"), id: Int64(i)) }
        let s = await started(try session())
        defer { s.stop() }
        #expect(s.messages.first?.id == 51)
        #expect(s.hasOlder)
        try await s.loadOlder()
        #expect(s.messages.first?.id == 1)
        try await s.loadOlder()
        #expect(!s.hasOlder)
        #expect(s.messages.count == 250)
    }

    @Test func sendImageRejectsNonImage() async throws {
        let s = try session()
        await #expect(throws: ImageError.unsupportedFormat) {
            _ = try await s.sendImage(Data("GIF89a......".utf8), fileName: "a.gif", progress: nil)
        }
        #expect(ErrorText.describe(ImageError.unsupportedFormat) == "Nur PNG und JPG werden unterstützt.")
    }

    @Test func sendImageRejectsTooLarge() async throws {
        let s = try session()
        var big = pngHeaderOnly(width: 1, height: 1)
        big.append(Data(count: Int(ImageFormat.maxImageBytes) + 1 - big.count))
        await #expect(throws: ImageError.tooLarge) {
            _ = try await s.sendImage(big, fileName: "a.png", progress: nil)
        }
        #expect(ErrorText.describe(ImageError.tooLarge) == "Bild ist größer als 24 MB.")
    }

    @Test func sendImageRoundTrip() async throws {
        let s = await started(try session())
        defer { s.stop() }
        _ = try await s.sendImage(tinyPNG, fileName: "x.png", progress: nil)
        let msg = try #require(s.messages.last)
        #expect(msg.image?.width == 1 && msg.image?.mime == "image/png")
        #expect(try await s.imageData(for: msg.image!) == tinyPNG)
    }

    @Test func imageDataUsesCacheAndDropsCorrupt() async throws {
        let s = try session()
        let enc = try keys.encrypt(tinyPNG)
        await fake.putBlob("blob-1", enc)
        cache.write(room: keys.roomId, blobId: "blob-1", data: Data("kaputt".utf8))
        let info = ImageInfo(blobId: "blob-1", mime: "image/png", filename: "a.png", size: 1, width: 1, height: 1)
        #expect(try await s.imageData(for: info) == tinyPNG)
        #expect(cache.read(room: keys.roomId, blobId: "blob-1") == enc)
    }

    @Test func imageDataRejectsPixelBomb() async throws {
        let s = try session()
        await fake.putBlob("bomb", try keys.encrypt(pngHeaderOnly(width: 20000, height: 20000)))
        let info = ImageInfo(blobId: "bomb", mime: "image/png", filename: "a.png", size: 1, width: 1, height: 1)
        await #expect(throws: ImageError.tooManyPixels) { _ = try await s.imageData(for: info) }
        #expect(cache.read(room: keys.roomId, blobId: "bomb") == nil)
    }

    @Test func newMessageHookOnlyForLiveForeign() async throws {
        await fake.store(payload("text", text: "alt"))
        let s = try session()
        let seen = LockedBox<[String]>([])
        s.onNewMessage = { m, live in if live { seen.set(seen.get() + [m.text ?? ""]) } }
        _ = await started(s)
        defer { s.stop() }
        _ = try await s.sendText("eigen")
        await fake.emit(.message(await fake.store(payload("text", text: "neu"))))
        #expect(await eventually { seen.get() == ["neu"] })
    }
}

@MainActor
struct ChatSessionOverflowTests {
    @Test func imageDataRejectsOverflowingIHDR() async throws {
        let root = ChatKeys.generateRootKey()
        let keys = try ChatKeys.derive(rootKey: root)
        let fake = FakeTransport()
        let info = ChatEntryInfo(id: "c", serverURL: URL(string: "https://x.invalid")!, myName: "a", chatName: "b",
                                 deviceId: "d", lastReadId: 0)
        let s = try ChatSession(entry: info, rootKey: root, invite: nil, transport: fake, cache: MemoryCache(),
                                onLastReadChanged: { _ in })
        await fake.putBlob("huge", try keys.encrypt(pngHeaderOnly(width: 0xFFFF_FFFF, height: 0xFFFF_FFFF)))
        let img = ImageInfo(blobId: "huge", mime: "image/png", filename: "a.png", size: 1, width: 1, height: 1)
        await #expect(throws: ImageError.self) { _ = try await s.imageData(for: img) }
    }
}
