import CryptoKit
import Foundation
import UserNotifications

/// Who holds a screen, as `display.status`, `.lease.*` and the `display.lease` event report it.
/// The holder's id never leaves the host, only a hash its holder can match against its own.
struct ScreenLease: Equatable {
    /// Which side controls the screen. An unknown holder reads as the agent's.
    enum Holder: Equatable { case agent, human }

    let holder: Holder
    let viewerHash: String?

    init(_ json: BotJSON) {
        holder = json["holder"].text == "human" ? .human : .agent
        viewerHash = json["viewer_hash"].text
    }

    /// Whether `viewerID` is the one holding it: the first 12 hex characters of its SHA-256.
    func isHeld(by viewerID: String) -> Bool {
        holder == .human && viewerHash == Self.hash(viewerID)
    }

    static func hash(_ viewerID: String) -> String {
        String(SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

/// A takeover this iPhone made and hasn't handed back. Saved before the acquire goes out, because
/// a phone that suspends before the reply could otherwise hold a lease with no record of its id.
/// So `viewerIDs` names every id that may hold it: one once things settle, two while a return moves
/// it to a new socket's id. Each is a capability on the host, so this lives in the Keychain.
/// `lastInput` is saved when the app leaves the foreground and at takeover, so a killed app's
/// deadline errs early.
struct ScreenHold: Codable, Equatable {
    var viewerIDs: [String]
    /// The host has answered for it. An unconfirmed hold the host doesn't show never landed, so
    /// it goes quietly rather than reporting that someone else took over.
    var isConfirmed: Bool
    var lastInput: Date
    /// Which kind of screen it's on, so a hand-back from Bots home goes the right way.
    var source: ScreenSource

    func holder(of lease: ScreenLease) -> String? {
        viewerIDs.first { lease.isHeld(by: $0) }
    }
}

/// The holds on each configured server, by Profile, in one Keychain item per server, so a hold
/// never shows under another server and server removal drops them together. `revision` lets the
/// Bots home follow a hand-back that finishes after its Screen has closed.
@MainActor @Observable final class ScreenHoldStore {
    static let shared = ScreenHoldStore(keychain: KeychainStore())

    private(set) var revision = 0
    @ObservationIgnored private let keychain: any KeychainStoring

    init(keychain: any KeychainStoring) {
        self.keychain = keychain
    }

    func holds(server: URL) -> [String: ScreenHold] {
        guard let value = try? keychain.load(.screenHolds, scope: server.absoluteString) else { return [:] }
        return (try? JSONDecoder().decode([String: ScreenHold].self, from: Data(value.utf8))) ?? [:]
    }

    func hold(server: URL, profile: String) -> ScreenHold? {
        holds(server: server)[profile]
    }

    func save(_ hold: ScreenHold?, server: URL, profile: String) {
        var all = holds(server: server)
        all[profile] = hold
        if all.isEmpty {
            try? keychain.delete(.screenHolds, scope: server.absoluteString)
        } else if let data = try? JSONEncoder().encode(all) {
            try? keychain.save(String(decoding: data, as: UTF8.self), forKey: .screenHolds, scope: server.absoluteString)
        }
        revision += 1
    }

    /// Forgets the hold only if it still names `viewerIDs`. A reply about an old hold must not
    /// erase one retaken since, by a quick switch away and back.
    func forget(viewerIDs: [String], server: URL, profile: String) {
        guard hold(server: server, profile: profile)?.viewerIDs == viewerIDs else { return }
        save(nil, server: server, profile: profile)
    }

    func removeAll(server: URL) {
        try? keychain.delete(.screenHolds, scope: server.absoluteString)
        revision += 1
    }
}

/// How long a takeover lasts with no phone input. The plugin enforces this on the host for Mac and
/// Windows; a stock host's leases never expire, so on Linux the app does it when it next runs.
enum ScreenIdlePolicy {
    static let prompt: Duration = .seconds(14 * 60)
    static let limit: Duration = .seconds(15 * 60)

    static func deadline(after lastInput: Date) -> Date {
        lastInput.addingTimeInterval(TimeInterval(limit.components.seconds))
    }
}

/// Hands back holds from outside a Screen view: Bots home's banner, the Bot Screen switch, a server
/// switch or sign-out, and a takeover that expired while the app was away. Each runs on a
/// connection of its own, so replacing the server's shared connection can't cut it off.
@MainActor enum ScreenHolds {
    /// The most any of these waits for a host, so a sign-out never hangs on one that's gone.
    private static let deadline: Duration = .seconds(4)

    /// Releases every hold on `server`, and forgets each the host answers for. One it can't reach
    /// stays saved, so the banner offers it again and `reconcile` sees it next time.
    static func handBackAll(server: URL, store: ScreenHoldStore = .shared) async {
        let holds = store.holds(server: server)
        guard !holds.isEmpty, let connection = try? BotConnectionStore().load(server: server) else { return }
        await withOwnClient(connection, server: server) { client in
            for (profile, hold) in holds {
                await handBack(hold, profile: profile, server: server, client: client, store: store)
            }
        }
    }

    /// Releases one hold from Bots home's banner.
    static func handBack(profile: String, server: URL, connection: BotConnection, store: ScreenHoldStore = .shared) async {
        guard let hold = store.hold(server: server, profile: profile) else { return }
        await withOwnClient(connection, server: server) { client in
            await handBack(hold, profile: profile, server: server, client: client, store: store)
        }
    }

    /// Checks each saved hold against the host when Bots home opens: a hold the host no longer
    /// shows is forgotten, and one past its deadline hands back, which covers an app killed while
    /// holding. A host it can't reach changes nothing.
    static func reconcile(server: URL, connection: BotConnection, store: ScreenHoldStore = .shared, now: Date = Date()) async {
        guard !store.holds(server: server).isEmpty else { return }
        await withOwnClient(connection, server: server) { client in
            await reconcile(server: server, client: client, store: store, now: now)
        }
    }

    static func reconcile(server: URL, client: BotClient, store: ScreenHoldStore, now: Date) async {
        for (profile, hold) in store.holds(server: server) {
            guard let status = try? await hold.source.status(profile: profile, client: client) else { continue }
            if hold.holder(of: status.lease) == nil {
                store.forget(viewerIDs: hold.viewerIDs, server: server, profile: profile)
            } else if now >= ScreenIdlePolicy.deadline(after: hold.lastInput) {
                await handBack(hold, profile: profile, server: server, client: client, store: store)
            }
        }
    }

    private static func handBack(_ hold: ScreenHold, profile: String, server: URL, client: BotClient, store: ScreenHoldStore) async {
        guard (try? await hold.source.release(hold, profile: profile, client: client)) != nil else { return }
        store.forget(viewerIDs: hold.viewerIDs, server: server, profile: profile)
        ScreenIdleNotification.cancel(server: server, profile: profile)
    }

    private static func withOwnClient(_ connection: BotConnection, server: URL,
                                      _ body: @escaping @MainActor (BotClient) async -> Void) async {
        let http = HermesConnections.shared.ownConnection(for: connection, server: server)
        defer { HermesConnections.shared.retire(own: http, server: server) }
        let client = BotClient(http: http)
        defer { client.close() }
        try? await bounded {
            try await client.connect()
            await body(client)
        }
    }

    private static func bounded(_ work: @escaping @MainActor () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw BotFailure.transport
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

/// The local notice that a takeover ran out while the app was in the background. It says so and
/// asks nothing: control goes back when the app next runs. Sent only if notifications are already
/// allowed, so a Screen never raises the permission prompt.
enum ScreenIdleNotification {
    static func schedule(server: URL, profile: String, title: String, at deadline: Date) {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "You still hold \(title)'s screen")
        content.body = String(localized: "The bot is paused. Open Hermex to hand control back.")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier(server: server, profile: profile), content: content, trigger: trigger))
    }

    static func cancel(server: URL, profile: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(server: server, profile: profile)])
    }

    private static func identifier(server: URL, profile: String) -> String {
        "screen-idle|\(server.absoluteString)|\(profile)"
    }
}
