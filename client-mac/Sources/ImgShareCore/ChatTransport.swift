import Foundation

/// Ereignisse aus dem WebSocket des Servers.
public enum ServerEvent: Sendable, Equatable {
    case message(EncryptedMessage)
    case presence(online: Int)
}

/// Schnittstelle zwischen ChatSession und Server (ApiClient oder Test-Fake).
public protocol ChatTransport: Sendable {
    func postMessage(_ ciphertext: Data) async throws -> PostMessageResult
    func getMessages(after: Int64?, before: Int64?, limit: Int) async throws -> MessagesPage
    func uploadBlob(_ data: Data, progress: (@Sendable (Double) -> Void)?) async throws -> BlobResult
    func getBlob(_ id: String) async throws -> Data
    /// Öffnet den WebSocket. Der Stream endet mit Fehler, wenn die Verbindung abbricht.
    func connectEvents() async throws -> AsyncThrowingStream<ServerEvent, Error>
}
