import CryptoKit
import Foundation
import UserNotifications

struct ScreenLease: Equatable {
    enum Holder: Equatable { case agent, human }

    let holder: Holder
    let viewerHash: String?

    init(_ json: BotJSON) {
        holder = json["holder"].text == "human" ? .human : .agent
        viewerHash = json["viewer_hash"].text
    }

    func isHeld(by viewerID: String) -> Bool {
        holder == .human && viewerHash == Self.hash(viewerID)
    }

    static func hash(_ viewerID: String) -> String {
        String(SHA256.hash(data: Data(viewerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }
}

struct ScreenHold: Codable, Equatable {
    var viewerIDs: [String]
    var isConfirmed: Bool
    var lastInput: Date
    var source: ScreenSource

    func holder(of lease: ScreenLease) -> String? {
        viewerIDs.first { lease.isHeld(by: $0) }
    }
}

@MainActor @Observable final class ScreenHoldStore {
    static let shared = ScreenHoldStore(keychain: KeychainStore())

    private(set) var revision = 0
    @ObservationIgnored let idleNotification: ScreenIdleNotification
    @ObservationIgnored private let keychain: any KeychainStoring

    init(keychain: any KeychainStoring, idleNotification: ScreenIdleNotification = .system) {
        self.keychain = keychain
        self.idleNotification = idleNotification
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

    func forget(viewerIDs: [String], server: URL, profile: String) {
        guard hold(server: server, profile: profile)?.viewerIDs == viewerIDs else { return }
        save(nil, server: server, profile: profile)
    }

    func removeAll(server: URL) {
        try? keychain.delete(.screenHolds, scope: server.absoluteString)
        revision += 1
    }
}

enum ScreenIdlePolicy {
    static let prompt: Duration = .seconds(14 * 60)
    static let limit: Duration = .seconds(15 * 60)

    static func deadline(after lastInput: Date) -> Date {
        lastInput.addingTimeInterval(TimeInterval(limit.components.seconds))
    }
}

@MainActor enum ScreenHolds {
    private static let deadline: Duration = .seconds(4)

    static func handBackAll(server: URL, store: ScreenHoldStore = .shared) async {
        let holds = store.holds(server: server)
        guard !holds.isEmpty, let connection = try? BotConnectionStore().load(server: server) else { return }
        await withOwnClient(connection, server: server) { client in
            for (profile, hold) in holds {
                await handBack(hold, profile: profile, server: server, client: client, store: store)
            }
        }
    }

    static func handBack(profile: String, server: URL, connection: BotConnection, store: ScreenHoldStore = .shared) async {
        guard let hold = store.hold(server: server, profile: profile) else { return }
        await withOwnClient(connection, server: server) { client in
            await handBack(hold, profile: profile, server: server, client: client, store: store)
        }
    }

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
        store.idleNotification.cancel(server: server, profile: profile)
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

enum ScreenIdleNotification {
    case system
    case off

    func schedule(server: URL, profile: String, title: String, at deadline: Date) {
        guard self == .system else { return }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "You still hold \(title)'s screen")
        content.body = String(localized: "The bot is paused. Open Hermex to hand control back.")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier(server: server, profile: profile), content: content, trigger: trigger))
    }

    func cancel(server: URL, profile: String) {
        guard self == .system else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(server: server, profile: profile)])
    }

    private func identifier(server: URL, profile: String) -> String {
        "screen-idle|\(server.absoluteString)|\(profile)"
    }
}
