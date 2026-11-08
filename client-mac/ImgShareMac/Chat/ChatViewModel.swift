import Foundation
import ImgShareCore
import Observation

/// Zustand eines Chat-Fensters: Entwurf, ausgewähltes Bild, Warteschlange.
@MainActor @Observable
final class ChatViewModel {
    var session: ChatSession
    var draft = ""
    var pendingImage: PasteboardImage.Picked?
    var sendError: String?
    var isSendingText = false
    let outgoing = OutgoingQueue()

    init(session: ChatSession) { self.session = session }

    /// Text senden; der Entwurf bleibt bei Fehlern erhalten.
    func sendText() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingText else { return }
        isSendingText = true
        defer { isSendingText = false }
        do {
            try await session.sendText(text)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            sendError = nil
        } catch {
            sendError = ErrorText.describe(error)
        }
    }

    func pick(_ result: Result<PasteboardImage.Picked, Error>) {
        switch result {
        case .success(let p):
            if Int64(p.data.count) > ImageFormat.maxImageBytes {
                sendError = ImageError.tooLarge.message
            } else {
                pendingImage = p; sendError = nil
            }
        case .failure(let e): sendError = ErrorText.describe(e)
        }
    }

    func sendPendingImage() {
        guard let p = pendingImage else { return }
        pendingImage = nil
        outgoing.enqueue(.image(p.data, fileName: p.fileName))
        Task { await processQueue() }
    }

    func retry(_ id: UUID) {
        outgoing.retry(id)
        Task { await processQueue() }
    }

    private func processQueue() async {
        let session = self.session
        await outgoing.process { item, report in
            switch item.kind {
            case .image(let data, let name): try await session.sendImage(data, fileName: name, progress: report)
            case .text(let t): try await session.sendText(t)
            }
        }
    }
}
