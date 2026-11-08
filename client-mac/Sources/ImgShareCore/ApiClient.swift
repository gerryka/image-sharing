import Foundation

public enum ApiError: Error, Equatable, Sendable, UserFacingError {
    case http(status: Int, code: String?)
    case invalidServerURL
    case httpsRequired
    case frameTooLarge
    case responseTooLarge
    case invalidResponse

    public var message: String {
        switch self {
        case .http(401, _): return "Zugriff verweigert – passt der Schlüssel?"
        case .http(403, "invite_required"):
            return "Der Chat existiert auf dem Server noch nicht. Zum Anlegen braucht es den Server-Zugangscode."
        case .http(413, _): return "Datei ist zu groß für den Server."
        case .http(429, _): return "Zu viele Anfragen, bitte kurz warten."
        case .http(507, "quota_exceeded"): return "Der Speicher für diesen Chat am Server ist voll."
        case .http(507, "room_limit"): return "Auf dem Server können keine weiteren Chats angelegt werden."
        case .http(507, _): return "Der Server hat keinen freien Speicher mehr."
        case .http(let s, let c): return "Serverfehler \(s)" + (c.map { " (\($0))" } ?? "")
        case .invalidServerURL: return "Ungültige Server-Adresse."
        case .httpsRequired: return "Die Server-Adresse muss mit https:// beginnen."
        case .frameTooLarge: return "WebSocket-Nachricht zu groß."
        case .responseTooLarge: return "Antwort des Servers ist zu groß."
        case .invalidResponse: return "Ungültige Antwort vom Server."
        }
    }
}

public final class ApiClient: ChatTransport {
    public static let inviteHeader = "X-Invite-Code"
    static let maxResponseBytes = 32 * 1024 * 1024
    static let maxFrameBytes = 4 * 1024 * 1024
    static let pingInterval: Duration = .seconds(20)
    static let pongTimeout: Duration = .seconds(10)

    let base: URL
    let roomId: String
    let token: String
    let invite: String
    let session: URLSession

    public convenience init(serverURL: URL, keys: ChatKeys, invite: String?) {
        self.init(serverURL: serverURL, roomId: keys.roomId, tokenB64URL: keys.tokenBase64URL, invite: invite)
    }

    /// Nur für Tests: beliebiger Token zu einem Raum.
    convenience init(serverURL: URL, roomId: String, token: Data, invite: String?) {
        let t = token.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        self.init(serverURL: serverURL, roomId: roomId, tokenB64URL: t, invite: invite)
    }

    init(serverURL: URL, roomId: String, tokenB64URL: String, invite: String?) {
        var s = serverURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        base = URL(string: s + "/")!
        self.roomId = roomId
        token = tokenB64URL
        self.invite = invite?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    /// https ist Pflicht, http nur für Loopback (Tests).
    public static func validateServerURL(_ text: String) -> Result<URL, ApiError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(),
              let host = u.host(percentEncoded: false), !host.isEmpty else { return .failure(.invalidServerURL) }
        if scheme == "https" { return .success(u) }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return .success(u) }
        if scheme == "http" { return .failure(.httpsRequired) }
        return .failure(.invalidServerURL)
    }

    // MARK: Requests

    func url(_ rel: String, query: [URLQueryItem] = []) -> URL {
        var u = base.appending(path: "v1/rooms/\(roomId)/\(rel)")
        if !query.isEmpty { u.append(queryItems: query) }
        return u
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("ImgShare/1.0", forHTTPHeaderField: "User-Agent")
        // Nur beim allerersten Anlegen eines Chats nötig; der Server ignoriert ihn sonst.
        if !invite.isEmpty { r.setValue(invite, forHTTPHeaderField: Self.inviteHeader) }
        return r
    }

    func send(_ req: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ApiError.invalidResponse }
        if http.expectedContentLength > Self.maxResponseBytes { throw ApiError.responseTooLarge }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        for try await b in bytes {
            chunk.append(b)
            if chunk.count == 64 * 1024 {
                data.append(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                if data.count > Self.maxResponseBytes { throw ApiError.responseTooLarge }
            }
        }
        data.append(contentsOf: chunk)
        if data.count > Self.maxResponseBytes { throw ApiError.responseTooLarge }
        try Self.ensureOK(http, data)
        return data
    }

    static func ensureOK(_ http: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw ApiError.http(status: http.statusCode, code: code)
    }

    public func postMessage(_ ciphertext: Data) async throws -> PostMessageResult {
        var r = request(url("messages"), method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["ciphertext": ciphertext.base64EncodedString()])
        return try WireJSON.decoder().decode(PostMessageResult.self, from: try await send(r))
    }

    public func getMessages(after: Int64?, before: Int64?, limit: Int) async throws -> MessagesPage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let after { q.append(URLQueryItem(name: "after", value: String(after))) }
        if let before { q.append(URLQueryItem(name: "before", value: String(before))) }
        return try WireJSON.decoder().decode(MessagesPage.self, from: try await send(request(url("messages", query: q))))
    }

    public func uploadBlob(_ data: Data, progress: (@Sendable (Double) -> Void)?) async throws -> BlobResult {
        var r = request(url("blobs"), method: "POST")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await session.upload(for: r, from: data, delegate: UploadProgress(progress))
        guard let http = response as? HTTPURLResponse else { throw ApiError.invalidResponse }
        try Self.ensureOK(http, body)
        progress?(1.0)
        return try WireJSON.decoder().decode(BlobResult.self, from: body)
    }

    public func getBlob(_ id: String) async throws -> Data {
        try await send(request(url("blobs/\(id)")))
    }

    // MARK: WebSocket

    public func connectEvents() async throws -> AsyncThrowingStream<ServerEvent, Error> {
        var comps = URLComponents(url: url("ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        let task = session.webSocketTask(with: request(comps.url!))
        task.maximumMessageSize = Self.maxFrameBytes
        task.resume()
        // Erstes Frame abwarten, damit Verbindungsfehler (401, 403, …) hier geworfen werden.
        let first: URLSessionWebSocketTask.Message
        do {
            first = try await task.receive()
        } catch {
            task.cancel()
            if let http = task.response as? HTTPURLResponse, http.statusCode >= 400 {
                throw ApiError.http(status: http.statusCode, code: nil)
            }
            throw error
        }

        let (stream, cont) = AsyncThrowingStream<ServerEvent, Error>.makeStream()
        if let e = Self.decodeFrame(first) { cont.yield(e) }

        let reader = Task {
            do {
                while !Task.isCancelled {
                    if let e = Self.decodeFrame(try await task.receive()) { cont.yield(e) }
                }
            } catch {
                cont.finish(throwing: error)
            }
        }
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                if Task.isCancelled { return }
                do {
                    try await Self.ping(timeout: Self.pongTimeout) { handler in
                        task.sendPing(pongReceiveHandler: handler)
                    }
                } catch {
                    task.cancel(with: .goingAway, reason: nil)
                    cont.finish(throwing: URLError(.networkConnectionLost))
                    return
                }
            }
        }
        cont.onTermination = { _ in
            reader.cancel(); pinger.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        return stream
    }

    /// Ping mit Timeout: ein lautlos toter Socket (Ruhezustand) liefert nie ein Pong.
    /// Eine Continuation, die entweder der Pong-Handler oder der Timeout fortsetzt – wer zuerst kommt.
    static func ping(timeout: Duration,
                     send: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            send { err in
                guard once.claim() else { return }
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard once.claim() else { return }
                c.resume(throwing: URLError(.timedOut))
            }
        }
    }

    static func decodeFrame(_ m: URLSessionWebSocketTask.Message) -> ServerEvent? {
        let data: Data
        switch m {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return nil
        }
        struct Frame: Decodable {
            let type: String
            let online: Int?
            let id: Int64?
            let server_ts: String?
            let ciphertext: String?
        }
        guard let f = try? JSONDecoder().decode(Frame.self, from: data) else { return nil }
        switch f.type {
        case "presence":
            return f.online.map { .presence(online: $0) }
        case "message":
            guard let id = f.id, let ts = f.server_ts.flatMap(WireJSON.parseDate), let ct = f.ciphertext else { return nil }
            return .message(EncryptedMessage(id: id, serverTs: ts, ciphertext: ct))
        default:
            return nil
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: (@Sendable (Double) -> Void)?
    init(_ report: (@Sendable (Double) -> Void)?) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
