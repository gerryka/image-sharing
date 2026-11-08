import Foundation
import Observation

public struct OutgoingItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case text(String)
        case image(Data, fileName: String)
    }

    public let id: UUID
    public let kind: Kind
    public var progress: Double = 0
    public var error: String?
}

/// Warteschlange für ausgehende Nachrichten: zeigt Fortschritt, behält Fehlgeschlagenes zum erneuten Senden.
@MainActor @Observable
public final class OutgoingQueue {
    public private(set) var items: [OutgoingItem] = []
    @ObservationIgnored private var running = false

    public init() {}

    public func enqueue(_ kind: OutgoingItem.Kind) {
        items.append(OutgoingItem(id: UUID(), kind: kind))
    }

    /// Sendet alle offenen Einträge der Reihe nach. Fehlgeschlagene bleiben mit Fehlertext stehen.
    public func process(using send: (OutgoingItem, @escaping @Sendable (Double) -> Void) async throws -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        var attempted = Set<UUID>()
        while let item = items.first(where: { $0.error == nil && !attempted.contains($0.id) }) {
            attempted.insert(item.id)
            let id = item.id
            let report: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in self?.update(id) { $0.progress = p } }
            }
            do {
                try await send(item, report)
                items.removeAll { $0.id == id }
            } catch {
                update(id) { $0.error = ErrorText.describe(error); $0.progress = 0 }
            }
        }
    }

    public func retry(_ id: UUID) { update(id) { $0.error = nil } }

    public func discard(_ id: UUID) { items.removeAll { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout OutgoingItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }
}
