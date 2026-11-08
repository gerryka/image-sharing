import Foundation
import Testing
@testable import ImgShareCore

struct StorageTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "imgshare-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func configRoundTrip() throws {
        let dir = tempDir()
        var cfg = AppConfig()
        var e = ChatEntry(serverURL: "https://x.at:47000", myName: "Ich", chatName: "Chat")
        e.lastReadId = 42
        cfg.chats = [e]
        cfg.notificationsPaused = true
        try cfg.save(to: dir)
        let loaded = AppConfig.load(from: dir)
        #expect(loaded == cfg)
        #expect(e.id.count == 32 && e.deviceId.count == 32 && e.id != e.deviceId)
    }

    @Test func configIsAtomic() throws {
        let dir = tempDir()
        try AppConfig().save(to: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["config.json"])
    }

    @Test func corruptConfigIsBackedUp() throws {
        let dir = tempDir()
        try Data("{kaputt".utf8).write(to: dir.appending(path: "config.json"))
        let cfg = AppConfig.load(from: dir)
        #expect(cfg.chats.isEmpty)
        #expect(try String(contentsOf: dir.appending(path: "config.json.bak"), encoding: .utf8) == "{kaputt")
    }

    @Test func missingConfigIsEmpty() {
        #expect(AppConfig.load(from: tempDir()) == AppConfig())
    }

    @Test func entryInfo() {
        let e = ChatEntry(serverURL: "https://x.at", myName: "a", chatName: "b")
        #expect(e.info?.serverURL.absoluteString == "https://x.at")
        #expect(ChatEntry(serverURL: "kein url", myName: "a", chatName: "b").info == nil)
    }

    @Test func keychainRoundTrip() throws {
        let kc = KeychainStore(service: "at.mediatesystems.imgshare.tests.\(UUID().uuidString)")
        let key = ChatKeys.generateRootKey()
        try kc.setRootKey(key, chatId: "c1")
        #expect(try kc.rootKey(chatId: "c1") == key)
        try kc.setRootKey(ChatKeys.generateRootKey(), chatId: "c1") // überschreiben
        try kc.setInvite("  geheim  ", chatId: "c1")
        #expect(kc.invite(chatId: "c1") == "geheim")
        try kc.setInvite("", chatId: "c1")
        #expect(kc.invite(chatId: "c1") == nil)
        kc.removeAll(chatId: "c1")
        #expect(try kc.get(account: "c1.key") == nil)
        #expect(throws: StorageError.keyMissing) { try kc.rootKey(chatId: "c1") }
        #expect(ErrorText.describe(StorageError.keyMissing) == "Schlüssel nicht gefunden – bitte Chat neu einrichten.")
    }

    @Test func blobCacheRoundTripAndRemove() {
        let c = BlobCache(root: tempDir())
        let room = String(repeating: "a", count: 32)
        c.write(room: room, blobId: "b-1", data: Data([1, 2, 3]))
        #expect(c.read(room: room, blobId: "b-1") == Data([1, 2, 3]))
        c.remove(room: room, blobId: "b-1")
        #expect(c.read(room: room, blobId: "b-1") == nil)
    }

    @Test func blobCacheRejectsUnsafeIds() throws {
        let root = tempDir().appending(path: "cache")
        let c = BlobCache(root: root)
        c.write(room: String(repeating: "a", count: 32), blobId: "../x", data: Data([1]))
        c.write(room: "../..", blobId: "x", data: Data([1]))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(c.read(room: "../..", blobId: "x") == nil)
    }
}
