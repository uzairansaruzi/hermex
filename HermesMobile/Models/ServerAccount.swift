import Foundation
import os

enum ServerKind: String, Codable, Sendable {
    case webui
    case hermes
}

enum HermesGatewayKind: String, Codable, Sendable {
    case dashboard
    case webapp
}

struct ServerAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var urlString: String
    var displayName: String
    var initials: String
    var headerLogoColorHex: String
    var createdAt: Date
    var updatedAt: Date
    var kind: ServerKind
    var serverVersion: String?
    var hermesGateway: HermesGatewayKind?
    var movedWebuiServers: [MovedWebuiServer]
    var moveToHermesPrompt: MoveToHermesPrompt?

    init(
        id: String,
        urlString: String,
        displayName: String,
        initials: String,
        headerLogoColorHex: String,
        createdAt: Date,
        updatedAt: Date,
        kind: ServerKind = .webui,
        serverVersion: String? = nil,
        hermesGateway: HermesGatewayKind? = nil,
        movedWebuiServers: [MovedWebuiServer] = [],
        moveToHermesPrompt: MoveToHermesPrompt? = nil
    ) {
        self.id = id
        self.urlString = urlString
        self.displayName = displayName
        self.initials = initials
        self.headerLogoColorHex = headerLogoColorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
        self.serverVersion = serverVersion
        self.hermesGateway = hermesGateway
        self.movedWebuiServers = movedWebuiServers
        self.moveToHermesPrompt = moveToHermesPrompt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case urlString
        case displayName
        case initials
        case headerLogoColorHex
        case createdAt
        case updatedAt
        case kind
        case serverVersion
        case hermesGateway
        case movedWebuiServers
        case moveToHermesPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedURL = try container.decodeIfPresent(String.self, forKey: .urlString)
        guard let resolved = decodedID ?? decodedURL else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "ServerAccount requires an id or urlString"
            )
        }
        id = decodedID ?? resolved
        urlString = decodedURL ?? resolved
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        initials = try container.decodeIfPresent(String.self, forKey: .initials) ?? ""
        headerLogoColorHex = try container.decodeIfPresent(String.self, forKey: .headerLogoColorHex)
            ?? HeaderLogoColor.defaultHex
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap(ServerKind.init(rawValue:)) ?? .webui
        serverVersion = try? container.decodeIfPresent(String.self, forKey: .serverVersion)
        hermesGateway = (try? container.decodeIfPresent(String.self, forKey: .hermesGateway))
            .flatMap(HermesGatewayKind.init(rawValue:))
        movedWebuiServers = ((try? container.decodeIfPresent([Lossy<MovedWebuiServer>].self, forKey: .movedWebuiServers)) ?? [])
            .compactMap(\.value)
        moveToHermesPrompt = (try? container.decodeIfPresent(String.self, forKey: .moveToHermesPrompt))
            .flatMap(MoveToHermesPrompt.init(rawValue:))
    }
}

enum MoveToHermesPrompt: String, Codable, Sendable {
    case asked
    case dismissed
}

struct MovedWebuiServer: Codable, Equatable, Sendable {
    let sourceServerID: String
    var profiles: [MovedWebuiProfile]
    var completedAt: Date?
    var report: MovedWebuiReport?

    init(sourceServerID: String, profiles: [MovedWebuiProfile], completedAt: Date? = nil,
         report: MovedWebuiReport? = nil) {
        self.sourceServerID = sourceServerID
        self.profiles = profiles
        self.completedAt = completedAt
        self.report = report
    }

    enum CodingKeys: String, CodingKey {
        case sourceServerID, profiles, completedAt, report
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceServerID = try container.decode(String.self, forKey: .sourceServerID)
        profiles = ((try? container.decodeIfPresent([Lossy<MovedWebuiProfile>].self, forKey: .profiles)) ?? [])
            .compactMap(\.value)
        completedAt = try? container.decodeIfPresent(Date.self, forKey: .completedAt)
        report = try? container.decodeIfPresent(MovedWebuiReport.self, forKey: .report)
    }

    func destination(ofProfile profile: String) -> MovedWebuiProfile.Destination? {
        profiles.first { $0.source == profile }?.destination
    }
}

struct MovedWebuiProfile: Codable, Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case hermes(profile: String)
        case keepOnWebui
    }

    let source: String
    let destination: Destination

    init(source: String, destination: Destination) {
        self.source = source
        self.destination = destination
    }

    enum CodingKeys: String, CodingKey {
        case source, hermesProfile, keepOnWebui
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        let profile = (try? container.decodeIfPresent(String.self, forKey: .hermesProfile)).flatMap { $0 }
        let keeps = (try? container.decodeIfPresent(Bool.self, forKey: .keepOnWebui)) == true
        switch (profile.flatMap { $0.isEmpty ? nil : $0 }, keeps) {
        case (let profile?, false): destination = .hermes(profile: profile)
        case (nil, true): destination = .keepOnWebui
        default:
            throw DecodingError.dataCorruptedError(forKey: .source, in: container,
                                                   debugDescription: "A moved Profile names no single destination")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        switch destination {
        case .hermes(let profile): try container.encode(profile, forKey: .hermesProfile)
        case .keepOnWebui: try container.encode(true, forKey: .keepOnWebui)
        }
    }
}

struct MovedWebuiReport: Codable, Equatable, Sendable {
    var remaining: Int?
    var unchecked: Int?
    var oversized: Int?
    var kept: Int?
    var recordedAt: Date

    init(remaining: Int?, unchecked: Int?, oversized: Int?, kept: Int? = nil, recordedAt: Date) {
        self.remaining = remaining
        self.unchecked = unchecked
        self.oversized = oversized
        self.kept = kept
        self.recordedAt = recordedAt
    }

    enum CodingKeys: String, CodingKey {
        case remaining, unchecked, oversized, kept, recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remaining = try? container.decodeIfPresent(Int.self, forKey: .remaining)
        unchecked = try? container.decodeIfPresent(Int.self, forKey: .unchecked)
        oversized = try? container.decodeIfPresent(Int.self, forKey: .oversized)
        kept = try? container.decodeIfPresent(Int.self, forKey: .kept)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

final class ServerRegistry: @unchecked Sendable {
    static let shared = ServerRegistry()

    private let keychain: any KeychainStoring
    private let identityDefaults: UserDefaults
    private let now: () -> Date
    private let storage: OSAllocatedUnfairLock<Snapshot>

    init(
        keychain: any KeychainStoring = KeychainStore(),
        identityDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.identityDefaults = identityDefaults
        self.now = now
        self.storage = OSAllocatedUnfairLock(initialState: Self.loadSnapshot(from: keychain))
    }

    private struct Snapshot: Codable {
        var servers: [ServerAccount]
        var activeServerID: String?

        init(servers: [ServerAccount] = [], activeServerID: String? = nil) {
            self.servers = servers
            self.activeServerID = activeServerID
        }

        var activeServer: ServerAccount? {
            guard let activeServerID else { return nil }
            return servers.first { $0.id == activeServerID }
        }

        enum CodingKeys: String, CodingKey {
            case servers
            case activeServerID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            servers = ((try? container.decodeIfPresent([Lossy<ServerAccount>].self, forKey: .servers)) ?? [])
                .compactMap(\.value)
            activeServerID = try? container.decodeIfPresent(String.self, forKey: .activeServerID)
        }
    }

    var servers: [ServerAccount] { storage.withLock { $0.servers } }

    var activeServerID: String? { storage.withLock { $0.activeServerID } }

    var activeServer: ServerAccount? {
        storage.withLock { snapshot in
            guard let id = snapshot.activeServerID else { return nil }
            return snapshot.servers.first { $0.id == id }
        }
    }

    @discardableResult
    func activate(url: URL, kind: ServerKind = .webui, serverVersion: String? = nil) -> ServerAccount {
        let id = url.absoluteString
        var identityToMirror: ServerAccount?
        let result: ServerAccount = storage.withLock { snapshot in
            if let existing = snapshot.servers.first(where: { $0.id == id }) {
                if snapshot.activeServerID != id {
                    snapshot.activeServerID = id
                    persist(snapshot)
                    identityToMirror = existing
                }
                return existing
            }

            var account = makeSeededAccount(id: id, url: url)
            account.kind = kind
            account.serverVersion = serverVersion
            snapshot.servers.append(account)
            snapshot.activeServerID = id
            persist(snapshot)
            return account
        }
        if let identityToMirror {
            mirrorIdentityToDefaults(identityToMirror)
        }
        return result
    }

    @discardableResult
    func add(url: URL, kind: ServerKind, serverVersion: String?) -> ServerAccount {
        let id = url.absoluteString
        return storage.withLock { snapshot in
            if let existing = snapshot.servers.first(where: { $0.id == id }) { return existing }
            var account = makeSeededAccount(id: id, url: url)
            account.kind = kind
            account.serverVersion = serverVersion
            snapshot.servers.append(account)
            persist(snapshot)
            return account
        }
    }

    @discardableResult
    func setActive(id: String) -> ServerAccount? {
        var newActive: ServerAccount?
        storage.withLock { snapshot in
            guard snapshot.activeServerID != id,
                  let account = snapshot.servers.first(where: { $0.id == id }) else {
                return
            }
            snapshot.activeServerID = id
            persist(snapshot)
            newActive = account
        }
        if let newActive {
            mirrorIdentityToDefaults(newActive)
        }
        return newActive
    }

    @discardableResult
    func remove(id: String) -> ServerAccount? {
        var activeChangedTo: ServerAccount?
        var didChangeActive = false
        let activeAfter: ServerAccount? = storage.withLock { snapshot in
            guard snapshot.servers.contains(where: { $0.id == id }) else {
                return snapshot.activeServer
            }
            let wasActive = snapshot.activeServerID == id
            snapshot.servers.removeAll { $0.id == id }
            if wasActive {
                let next = snapshot.servers.first
                snapshot.activeServerID = next?.id
                didChangeActive = true
                activeChangedTo = next
            }
            persist(snapshot)
            return snapshot.activeServer
        }
        if didChangeActive, let activeChangedTo {
            mirrorIdentityToDefaults(activeChangedTo)
        }
        return activeAfter
    }

    func update(_ account: ServerAccount) {
        var activeUpdate: ServerAccount?
        storage.withLock { snapshot in
            guard let index = snapshot.servers.firstIndex(where: { $0.id == account.id }) else {
                return
            }
            var updated = account
            updated.updatedAt = now()
            updated.movedWebuiServers = snapshot.servers[index].movedWebuiServers
            updated.moveToHermesPrompt = snapshot.servers[index].moveToHermesPrompt
            snapshot.servers[index] = updated
            persist(snapshot)
            if snapshot.activeServerID == account.id {
                activeUpdate = updated
            }
        }
        if let activeUpdate {
            mirrorIdentityToDefaults(activeUpdate)
        }
    }

    func forgetActiveServer() {
        storage.withLock { snapshot in
            guard let id = snapshot.activeServerID else { return }
            snapshot.servers.removeAll { $0.id == id }
            snapshot.activeServerID = nil
            persist(snapshot)
        }
    }

    func commit<Result>(_ change: (_ servers: inout [ServerAccount], _ now: Date) throws -> Result) throws -> Result {
        try storage.withLockUnchecked { snapshot in
            var next = snapshot
            let result = try change(&next.servers, now())
            try save(next)
            snapshot = next
            return result
        }
    }

    private func makeSeededAccount(id: String, url: URL) -> ServerAccount {
        let hostFallback = url.host ?? url.absoluteString
        let storedName = (identityDefaults.string(forKey: SessionIdentitySettings.displayNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedInitials = identityDefaults.string(forKey: SessionIdentitySettings.initialsKey) ?? ""
        let storedColor = identityDefaults.string(forKey: HeaderLogoColor.storageKey) ?? ""

        let displayName = storedName.isEmpty ? hostFallback : storedName
        let initials = SessionIdentitySettings.displayInitials(
            displayName: displayName,
            storedInitials: storedInitials,
            fallbackFullName: hostFallback
        )
        let colorHex = HeaderLogoColor.normalizedHex(storedColor) ?? HeaderLogoColor.defaultHex

        let timestamp = now()
        return ServerAccount(
            id: id,
            urlString: id,
            displayName: displayName,
            initials: initials,
            headerLogoColorHex: colorHex,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func mirrorIdentityToDefaults(_ account: ServerAccount) {
        identityDefaults.set(account.displayName, forKey: SessionIdentitySettings.displayNameKey)
        identityDefaults.set(account.initials, forKey: SessionIdentitySettings.initialsKey)
        identityDefaults.set(account.headerLogoColorHex, forKey: HeaderLogoColor.storageKey)
    }

    private func persist(_ snapshot: Snapshot) {
        try? save(snapshot)
    }

    private func save(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try keychain.save(String(decoding: data, as: UTF8.self), forKey: .servers)
    }

    private static func loadSnapshot(from keychain: any KeychainStoring) -> Snapshot {
        guard
            let json = try? keychain.load(.servers),
            let data = json.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return Snapshot()
        }
        return snapshot
    }
}
