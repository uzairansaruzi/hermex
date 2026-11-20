import Foundation
import WidgetKit

@MainActor final class ProviderLimitsPublisher {
    static let shared = ProviderLimitsPublisher(file: ProviderLimitsSnapshotFile.shared)

    struct Scope: Equatable {
        let server: URL
        let connectionID: UUID
        let profile: String
    }

    struct Ticket {
        let scope: Scope
        fileprivate let generation: Int
    }

    private let file: ProviderLimitsSnapshotFile?
    private let reloadWidget: () -> Void
    private var generation = 0
    private var ticketScope: Scope?

    init(file: ProviderLimitsSnapshotFile?,
         reloadWidget: @escaping () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: ProviderLimitsSnapshot.widgetKind)
         }) {
        self.file = file
        self.reloadWidget = reloadWidget
    }

    func ticket(for scope: Scope) -> Ticket {
        generation += 1
        ticketScope = scope
        return Ticket(scope: scope, generation: generation)
    }

    func publish(_ cards: [ProviderLimitCard], stale: Set<String>, with ticket: Ticket, now: Date = Date()) {
        guard ticket.generation == generation, let file else { return }
        let providers = cards.prefix(ProviderLimitsSnapshot.maxProviders).compactMap { card in
            let windows = card.rows.compactMap { row in
                row.remainingPercent.map {
                    ProviderLimitsSnapshot.Window(label: row.label, remainingPercent: $0, resetAt: row.resetAt)
                }
            }
            return windows.isEmpty ? nil : ProviderLimitsSnapshot.Provider(
                id: card.id, title: card.title, updatedAt: card.updatedAt, isStale: stale.contains(card.id),
                windows: Array(windows.prefix(ProviderLimitsSnapshot.maxWindows)))
        }
        let snapshot = ProviderLimitsSnapshot(
            serverKey: BotHistoryCache.Scope.key(ticket.scope.server), connectionID: ticket.scope.connectionID,
            profile: ticket.scope.profile, publishedAt: now, providers: providers)
        if let current = file.read(), current.published(at: now) == snapshot { return }
        guard (try? file.write(snapshot)) != nil else { return }
        reloadWidget()
    }

    func invalidate() {
        generation += 1
        ticketScope = nil
        if file?.remove() == true { reloadWidget() }
    }

    func invalidate(server: URL, unlessConnection connectionID: UUID? = nil) {
        let key = BotHistoryCache.Scope.key(server)
        let written = file?.read().map { [($0.serverKey, $0.connectionID)] } ?? []
        let loading = ticketScope.map { [(BotHistoryCache.Scope.key($0.server), $0.connectionID)] } ?? []
        guard (written + loading).contains(where: { $0.0 == key && $0.1 != connectionID }) else { return }
        invalidate()
    }
}

extension HermesUsageDestination {
    @MainActor func opens(state: AuthManager.State, servers: [ServerAccount],
                          savedConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID) -> Bool {
        guard case .loggedIn(let server) = state,
              servers.first(where: { $0.id == server.absoluteString })?.kind == .hermes,
              BotHistoryCache.Scope.key(server) == serverKey else { return false }
        return savedConnectionID(server) == connectionID
    }
}
