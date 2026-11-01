import Foundation
import WidgetKit

/// Writes the Limits widget's snapshot (#1409) from what a Hermes server's Usage screen loaded, and
/// clears it when its server or connection stops being the one in use. Usage is the only refresh:
/// nothing here polls or reads the host.
///
/// A load takes a `Ticket` before it awaits the host and hands it back with the cards. Only the
/// newest ticket writes, so a closed Usage screen's late load can't replace the Profile opened
/// after it. Every invalidation (a server switch, sign-out, the server's removal, its connection
/// replaced) also ends the newest ticket before clearing the file, so a load that started earlier
/// can never write its old result back. Main-actor, so publications and invalidations are serialized.
@MainActor final class ProviderLimitsPublisher {
    static let shared = ProviderLimitsPublisher(file: ProviderLimitsSnapshotFile.shared)

    /// The Usage screen whose cards a load publishes.
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
    /// The newest ticket's scope, while a load may still write it.
    private var ticketScope: Scope?

    init(file: ProviderLimitsSnapshotFile?,
         reloadWidget: @escaping () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: ProviderLimitsSnapshot.widgetKind)
         }) {
        self.file = file
        self.reloadWidget = reloadWidget
    }

    /// Taken by a Usage load before it reads the host; it supersedes every earlier ticket.
    func ticket(for scope: Scope) -> Ticket {
        generation += 1
        ticketScope = scope
        return Ticket(scope: scope, generation: generation)
    }

    /// Writes `cards` (the ones in `stale` kept from before a failed refresh) for `ticket`'s
    /// scope, unless something invalidated it since. Only percentage windows go in, and each
    /// provider keeps its own measurement time. An unchanged snapshot is not written again.
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

    /// Ends every load in flight, then empties the widget.
    func invalidate() {
        generation += 1
        ticketScope = nil
        if file?.remove() == true { reloadWidget() }
    }

    /// `invalidate()` when the snapshot, or a load still in flight, is `server`'s and, given a
    /// `connectionID`, reads through another connection. Removing or signing in to an unrelated
    /// server leaves the widget as it is.
    func invalidate(server: URL, unlessConnection connectionID: UUID? = nil) {
        let key = BotHistoryCache.Scope.key(server)
        let written = file?.read().map { [($0.serverKey, $0.connectionID)] } ?? []
        let loading = ticketScope.map { [(BotHistoryCache.Scope.key($0.server), $0.connectionID)] } ?? []
        guard (written + loading).contains(where: { $0.0 == key && $0.1 != connectionID }) else { return }
        invalidate()
    }
}

extension HermesUsageDestination {
    /// Whether a widget's Usage link opens now: only on the signed-in active Hermes server it
    /// names, through the same saved connection. Anything else opens the app as it is, and never
    /// switches servers; the Sessions list then checks the host still has the Profile.
    @MainActor func opens(state: AuthManager.State, servers: [ServerAccount],
                          savedConnectionID: @MainActor (URL) -> UUID? = BotDeepLinkRouter.savedConnectionID) -> Bool {
        guard case .loggedIn(let server) = state,
              servers.first(where: { $0.id == server.absoluteString })?.kind == .hermes,
              BotHistoryCache.Scope.key(server) == serverKey else { return false }
        return savedConnectionID(server) == connectionID
    }
}
