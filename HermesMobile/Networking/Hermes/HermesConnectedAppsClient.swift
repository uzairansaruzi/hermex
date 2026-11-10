import Foundation

/// One app a Profile can connect through Nous Portal (#1629): the host's catalog row joined with
/// that Profile's accounts for it. `id` is the catalog slug, which every call names the app by.
struct HermesConnectedApp: Identifiable, Equatable, Sendable {
    /// What the app's row offers. One per app, however many accounts it has.
    enum State: Equatable, Sendable {
        case notConnected
        /// A sign-in was started and not finished; its account is pending.
        case waiting
        case connected
        /// An account exists but no longer works: failed, expired, revoked or inactive.
        case needsReconnect
        /// The Nous account's policy turns the app off. Only Nous Portal turns it back on.
        case turnedOff
    }

    /// One account of an app. A retired one, left behind by a reconnect, is never listed.
    struct Account: Identifiable, Equatable, Sendable {
        /// The host's `connection_id`.
        let id: String
        /// The host's own label for the account, shown when it has no `alias`.
        let label: String
        /// The name the user or the agent gave it, when it has one.
        let alias: String?
        let status: String

        var title: String { alias ?? label }
        var isConnected: Bool { status == "active" }
        var isPending: Bool { status == "pending" }
    }

    let id: String
    let name: String
    /// The catalog's description, nil when it is the catalog's filler ("Use Notion through Hermes").
    let summary: String?
    let category: String
    let isEnabled: Bool
    let accounts: [Account]

    var state: State {
        if !isEnabled { return .turnedOff }
        if accounts.contains(where: \.isConnected) { return .connected }
        if accounts.contains(where: \.isPending) { return .waiting }
        return accounts.isEmpty ? .notConnected : .needsReconnect
    }

    /// The account a Reconnect repairs: the first one that neither works nor is still signing in.
    var accountToRepair: Account? { accounts.first { !$0.isConnected && !$0.isPending } }

    /// Joins the host's three answers. An app the catalog lists without a state row is on and
    /// has no accounts; an account whose app left the catalog is dropped with it.
    static func apps(catalog: BotJSON, list: BotJSON, accounts: BotJSON) -> [HermesConnectedApp] {
        var turnedOff: Set<String> = []
        for row in list["connectors"].list ?? [] where row["enabled"].flag == false {
            if let slug = row["connector"].text { turnedOff.insert(slug) }
        }
        var accountsByApp: [String: [Account]] = [:]
        for row in accounts["accounts"].list ?? [] where row["disabled"].flag != true {
            guard let id = row["connection_id"].text, !id.isEmpty, let slug = row["connector"].text else { continue }
            let alias = row["alias"].text.flatMap { $0.isEmpty ? nil : $0 }
            accountsByApp[slug, default: []].append(Account(id: id, label: row["label"].text ?? slug, alias: alias,
                                                            status: row["status"].text ?? ""))
        }
        return (catalog["connectors"].list ?? []).compactMap { row in
            guard let slug = row["slug"].text, !slug.isEmpty else { return nil }
            let name = row["name"].text ?? slug
            let description = row["description"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return HermesConnectedApp(id: slug, name: name,
                                      summary: description.isEmpty || description == "Use \(name) through Hermes" ? nil : description,
                                      category: row["category"].text ?? "", isEnabled: !turnedOff.contains(slug),
                                      accounts: accountsByApp[slug] ?? [])
        }
    }
}

/// Why a host has no Connected Apps to show, each from its own refusal (#1629).
enum HermesConnectedAppsDeadEnd: Error, Equatable {
    /// -32601: the host has no `connectors.*` methods.
    case hostTooOld
    /// 4031 `CONNECTORS_UNAVAILABLE`: turned off in the host's config, or the Nous account lacks them.
    case unavailable
    /// 4032 `NEEDS_NOUS_AUTH`: the Profile has no usable Nous sign-in and may not create a guest one.
    case needsNousSignIn

    /// A read's refusal is a `BotFailure`; a connect's or a removal's keeps the host's message.
    init?(_ error: Error) {
        switch error {
        case BotFailure.rejected(-32601), BotSettingFailure.rejected(-32601, _): self = .hostTooOld
        case BotFailure.rejected(4031), BotSettingFailure.rejected(4031, _): self = .unavailable
        case BotFailure.rejected(4032), BotSettingFailure.rejected(4032, _): self = .needsNousSignIn
        default: return nil
        }
    }
}

/// The Connected Apps screen's client on a Hermes host (#1629): the `connectors.*` RPCs for one
/// Profile's own Nous account, over the sign-in and socket the server's Bot screens share. Every
/// call names the Profile and nothing is cached, so an app never shows under another server or
/// Profile. A refusal that means the host has nothing to show throws `HermesConnectedAppsDeadEnd`.
@MainActor final class HermesConnectedAppsClient {
    /// What starting a sign-in came to.
    enum SignIn: Equatable {
        /// Open `link` in the browser, then tell the host with `finished(profile:opID:)`.
        case link(URL, opID: String)
        /// The app was already connected; there is nothing to open.
        case connected
    }

    /// The scheme the portal's done page returns to, `hermes://connections/done`. The host asks
    /// for the desktop app's return on every account sign-in and a client cannot name its own. An
    /// `ASWebAuthenticationSession` catches a scheme Hermex has not registered, which closes the
    /// sheet without handing the user to the official Hermes app, which has (#1629's spike).
    nonisolated static let returnScheme = "hermes"

    private let http: HermesConnection

    /// `server`'s saved connection, on the sign-in and socket its Bot screens share.
    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    /// The host's Profiles and the one to start on, its default.
    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

    /// Every app `profile` can connect, in the host's catalog order, each with its accounts.
    func apps(profile: String) async throws -> [HermesConnectedApp] {
        try await gateway { client in
            async let catalog = client.call(.connectedAppsCatalog(profile: profile))
            async let list = client.call(.connectedAppsList(profile: profile))
            async let accounts = client.call(.connectedAppsAccounts(profile: profile))
            guard try await list["available"].flag != false else { throw HermesConnectedAppsDeadEnd.unavailable }
            return try await HermesConnectedApp.apps(catalog: catalog, list: list, accounts: accounts)
        }
    }

    /// Starts `app`'s sign-in, or `repairing`'s when that account is broken. The host hands back a
    /// sign-in that is still open rather than a new one, even after its pending account was
    /// removed, and that link is dead (the portal answers 404). So a link whose account the host
    /// no longer lists is closed and asked for once more, which mints a fresh one.
    func signIn(profile: String, app: String, repairing: HermesConnectedApp.Account? = nil) async throws -> SignIn {
        try await gateway { client in
            let start = HermesCall.connectedAppsConnect(profile: profile, app: app, repairing: repairing)
            var opened = try Self.opened(try await client.call(start))
            if let account = opened.accountID, let opID = opened.opID {
                let listed = try await client.call(.connectedAppsAccounts(profile: profile))["accounts"].list ?? []
                if !listed.contains(where: { $0["connection_id"].text == account }) {
                    _ = try await client.call(.connectedAppsSettle(profile: profile, opID: opID))
                    opened = try Self.opened(try await client.call(start))
                }
            }
            guard let link = opened.link, let opID = opened.opID else { return .connected }
            return .link(link, opID: opID)
        }
    }

    /// Tells the host the browser came back, so it reads the account now. A sign-in that already
    /// settled has no operation left to wake, and that refusal is not an error.
    func finished(profile: String, opID: String) async {
        _ = try? await gateway { try await $0.call(.connectedAppsWake(profile: profile, opID: opID)) }
    }

    /// Removes one account from `profile`: a connected one disconnects, a pending one cancels.
    func remove(_ account: HermesConnectedApp.Account, profile: String) async throws {
        _ = try await gateway { try await $0.call(.connectedAppsRemove(profile: profile, connectionID: account.id)) }
    }

    /// One `connectors.connect` answer: the link to open, and the operation and account behind it.
    /// A connected app has no link; a link that is not HTTPS never opens.
    private static func opened(_ reply: BotJSON) throws -> (link: URL?, opID: String?, accountID: String?) {
        let target = reply["targets"].list?.first ?? .null
        guard let text = target["connect_url"].text, !text.isEmpty else {
            guard target["state"].text == "connected" || reply["settled"].flag == true else { throw BotFailure.unsupported }
            return (nil, nil, nil)
        }
        guard let link = URL(string: text), link.scheme?.lowercased() == "https", let opID = reply["op_id"].text else {
            throw BotFailure.unsupported
        }
        return (link, opID, target["connection_id"].text)
    }

    private func gateway<Value>(_ work: (BotClient) async throws -> Value) async throws -> Value {
        let client = BotClient(http: http)
        defer { client.close() }
        do {
            try await client.connect()
            return try await work(client)
        } catch {
            throw HermesConnectedAppsDeadEnd(error) ?? error
        }
    }
}
