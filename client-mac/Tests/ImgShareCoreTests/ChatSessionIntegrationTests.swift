import Foundation
import Testing
@testable import ImgShareCore

@MainActor
struct ChatSessionIntegrationTests {
    func pair(server: URL, backoff: Backoff = Backoff(initial: .milliseconds(100), max: .milliseconds(400)))
        throws -> (ChatSession, ChatSession) {
        let root = ChatKeys.generateRootKey()
        func make(_ dev: String) throws -> ChatSession {
            let info = ChatEntryInfo(id: dev, serverURL: server, myName: dev, chatName: "T", deviceId: dev, lastReadId: 0)
            return try ChatSession(entry: info, rootKey: root, invite: TestServer.invite, cache: MemoryCache(),
                                   backoff: backoff, onLastReadChanged: { _ in })
        }
        return (try make("A"), try make("B"))
    }

    @Test(.enabled(if: TestServer.url != nil))
    func twoSessionsChat() async throws {
        let (a, b) = try pair(server: TestServer.url!)
        a.start(); b.start()
        defer { a.stop(); b.stop() }
        #expect(await eventually { a.state == .online && b.state == .online })
        #expect(await eventually { a.otherOnline && b.otherOnline })

        let id = try await a.sendText("Grüße 👋")
        #expect(await eventually { b.messages.contains { $0.id == id && $0.text == "Grüße 👋" && !$0.isMine } })

        await b.markRead()
        #expect(await eventually { a.otherReadUpTo == id })

        try await a.sendImage(tinyPNG, fileName: "x.png", progress: nil)
        #expect(await eventually { b.messages.last?.image != nil })
        let info = try #require(b.messages.last?.image)
        #expect(try await b.imageData(for: info) == tinyPNG)
    }

    @Test(.enabled(if: TestServer.flakyURL != nil))
    func recoversAfterConnectionDrop() async throws {
        let (a, b) = try pair(server: TestServer.flakyURL!)
        a.start()
        defer { a.stop(); b.stop() }
        #expect(await eventually { a.state == .online })
        // Server schließt die Verbindung nach 2 s hart.
        #expect(await eventually { a.state != .online })
        let id = try await b.sendText("während getrennt")
        #expect(await eventually(timeout: .seconds(10)) { a.state == .online })
        #expect(await eventually { a.messages.filter { $0.id == id }.count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.messages.filter { $0.id == id }.count == 1)
    }

    @Test(.enabled(if: TestServer.url != nil))
    func tooLongTextIs413WithGermanMessage() async throws {
        let (a, _) = try pair(server: TestServer.url!)
        let text = String(repeating: "x", count: 100_000) // > MAX_MESSAGE_BYTES (64 KiB)
        await #expect(throws: ApiError.http(status: 413, code: "too_large")) { try await a.sendText(text) }
        #expect(ApiError.http(status: 413, code: "too_large").message == "Datei ist zu groß für den Server.")
    }
}
