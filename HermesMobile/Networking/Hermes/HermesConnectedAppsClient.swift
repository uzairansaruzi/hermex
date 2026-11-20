import Foundation

struct HermesConnectedApp: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notConnected
        case waiting
        case connected
        case needsReconnect
        case turnedOff
    }

    struct Account: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let alias: String?
        let status: String

        var title: String { alias ?? label }
        var isConnected: Bool { status == "active" }
        var isPending: Bool { status == "pending" }
    }

    let id: String
    let name: String
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

    var accountToRepair: Account? { accounts.first { !$0.isConnected && !$0.isPending } }

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

enum HermesConnectedAppsDeadEnd: Error, Equatable {
    case hostTooOld
    case unavailable
    case needsNousSignIn

    init?(_ error: Error) {
        switch error {
        case BotFailure.rejected(-32601), BotSettingFailure.rejected(-32601, _): self = .hostTooOld
        case BotFailure.rejected(4031), BotSettingFailure.rejected(4031, _): self = .unavailable
        case BotFailure.rejected(4032), BotSettingFailure.rejected(4032, _): self = .needsNousSignIn
        default: return nil
        }
    }
}

@MainActor final class HermesConnectedAppsClient {
    enum SignIn: Equatable {
        case link(URL, opID: String)
        case connected
    }

    nonisolated static let returnScheme = "hermes"

    private let http: HermesConnection

    convenience init(saved connection: BotConnection, server: URL) {
        self.init(http: HermesConnections.shared.connection(for: connection, server: server))
    }

    init(http: HermesConnection) { self.http = http }

    func profiles() async throws -> (names: [String], initial: String) {
        try await HermesEnvironmentClient(http: http).profiles()
    }

    func apps(profile: String) async throws -> [HermesConnectedApp] {
        try await gateway { client in
            async let catalog = client.call(.connectedAppsCatalog(profile: profile))
            async let list = client.call(.connectedAppsList(profile: profile))
            async let accounts = client.call(.connectedAppsAccounts(profile: profile))
            guard try await list["available"].flag != false else { throw HermesConnectedAppsDeadEnd.unavailable }
            return try await HermesConnectedApp.apps(catalog: catalog, list: list, accounts: accounts)
        }
    }

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

    func finished(profile: String, opID: String) async {
        _ = try? await gateway { try await $0.call(.connectedAppsWake(profile: profile, opID: opID)) }
    }

    func remove(_ account: HermesConnectedApp.Account, profile: String) async throws {
        _ = try await gateway { try await $0.call(.connectedAppsRemove(profile: profile, connectionID: account.id)) }
    }

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
