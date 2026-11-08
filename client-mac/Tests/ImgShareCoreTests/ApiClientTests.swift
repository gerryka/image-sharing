import Foundation
import Testing
@testable import ImgShareCore

struct ApiClientTests {
    @Test func validateServerURL() {
        #expect((try? ApiClient.validateServerURL("https://x.at:47000").get())?.absoluteString == "https://x.at:47000")
        #expect((try? ApiClient.validateServerURL(" http://127.0.0.1:1 ").get()) != nil)
        #expect((try? ApiClient.validateServerURL("http://localhost:1").get()) != nil)
        #expect((try? ApiClient.validateServerURL("http://[::1]:1").get()) != nil)
        #expect(throws: ApiError.httpsRequired) { try ApiClient.validateServerURL("http://example.com").get() }
        #expect(throws: ApiError.invalidServerURL) { try ApiClient.validateServerURL("kein url").get() }
        #expect(throws: ApiError.invalidServerURL) { try ApiClient.validateServerURL("https://").get() }
    }

    func client(invite: String? = TestServer.invite) throws -> (ApiClient, ChatKeys) {
        let keys = try ChatKeys.derive(rootKey: ChatKeys.generateRootKey())
        return (ApiClient(serverURL: TestServer.url!, keys: keys, invite: invite), keys)
    }

    @Test(.enabled(if: TestServer.url != nil))
    func createsRoomWithInviteAndPostsMessage() async throws {
        let keys = try ChatKeys.derive(rootKey: ChatKeys.generateRootKey())
        let noInvite = ApiClient(serverURL: TestServer.url!, keys: keys, invite: nil)
        await #expect(throws: ApiError.http(status: 403, code: "invite_required")) {
            _ = try await noInvite.getMessages(after: nil, before: nil, limit: 1)
        }
        let api = ApiClient(serverURL: TestServer.url!, keys: keys, invite: TestServer.invite)
        let ct = try keys.encrypt(Data("hallo".utf8))
        let res = try await api.postMessage(ct)
        #expect(res.id > 0)
        let page = try await api.getMessages(after: 0, before: nil, limit: 10)
        #expect(page.messages.count == 1)
        #expect(Data(base64Encoded: page.messages[0].ciphertext) == ct)
    }

    @Test(.enabled(if: TestServer.url != nil))
    func wrongTokenIs401() async throws {
        let (api, keys) = try client()
        _ = try await api.postMessage(try keys.encrypt(Data("x".utf8)))
        let wrong = ApiClient(serverURL: TestServer.url!, roomId: keys.roomId,
                              token: ChatKeys.generateRootKey(), invite: nil)
        await #expect(throws: ApiError.http(status: 401, code: "unauthorized")) {
            _ = try await wrong.getMessages(after: 0, before: nil, limit: 1)
        }
    }

    @Test(.enabled(if: TestServer.url != nil))
    func blobRoundTrip() async throws {
        let (api, _) = try client()
        let data = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
        let last = LockedBox(0.0)
        let up = try await api.uploadBlob(data) { p in last.set(p) }
        #expect(up.size == Int64(data.count))
        #expect(last.get() == 1.0)
        #expect(try await api.getBlob(up.blobId) == data)
    }

    @Test(.enabled(if: TestServer.url != nil))
    func websocketDeliversMessageAndPresence() async throws {
        let (a, keys) = try client()
        _ = try await a.getMessages(after: 0, before: nil, limit: 1) // Raum anlegen
        let b = ApiClient(serverURL: TestServer.url!, keys: keys, invite: nil)
        var ita = try await a.connectEvents().makeAsyncIterator()
        var itb = try await b.connectEvents().makeAsyncIterator()

        func waitPresence(_ it: inout AsyncThrowingStream<ServerEvent, Error>.Iterator, _ n: Int) async throws {
            while let e = try await it.next() { if case .presence(let o) = e, o == n { return } }
            Issue.record("Stream endete vor presence \(n)")
        }
        try await waitPresence(&ita, 2)
        try await waitPresence(&itb, 2)

        let res = try await a.postMessage(try keys.encrypt(Data("ws".utf8)))
        while let e = try await itb.next() {
            if case .message(let m) = e { #expect(m.id == res.id); break }
        }
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.withLock { value = v } }
    func get() -> T { lock.withLock { value } }
}
