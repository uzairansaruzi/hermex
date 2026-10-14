import Foundation
import os

/// What a configured server is (#899). A webui server is a `hermes-webui` instance, signed in
/// through `AuthManager` with its own cookie; a Hermes server is a Hermes dashboard Hermex reaches
/// directly, whose sign-in is the `BotConnection` saved under its own URL and whose home is the
/// Bots inbox. A missing or unknown value reads as `webui`, the only kind before #899.
enum ServerKind: String, Codable, Sendable {
    case webui
    case hermes
}

/// Non-secret-shaped metadata for one configured server.
///
/// This is the persisted account model introduced by I-039a (#15) — the
/// foundation the rest of the multi-server epic (#16/#17/#18) builds on. The
/// server URL is treated as a credential, so the whole
/// registry is persisted in the Keychain (see `ServerRegistry`), alongside the
/// existing `server_url` and `custom_headers` entries. The auth cookie still
/// lives in `HTTPCookieStorage`. This model is an additive shadow of the
/// single-server state; nothing in this slice reads it for routing yet.
///
/// Decoding is tolerant (CLAUDE.md rule 3): missing fields fall back to sensible
/// defaults so a blob written by a different slice in the epic still loads.
struct ServerAccount: Codable, Identifiable, Equatable, Sendable {
    /// Stable per-server identity. We reuse the normalized base-URL string so it
    /// matches the offline cache's `serverURLString` key (`CachedSession` /
    /// `CachedMessage`) — no separate id↔URL mapping to keep in sync. A Hermes
    /// server's is its address as `BotConnection.address(_:)` normalizes it, never
    /// `AuthManager.normalizedServerURL`, whose rules differ.
    let id: String
    /// Normalized base URL (scheme + host [+ port]); equal to `id` in this slice.
    var urlString: String
    /// User-facing label. Seeded from the global identity on migration; editable
    /// per server in #17.
    var displayName: String
    /// Avatar initials. Seeded/derived on migration; editable per server in #17.
    var initials: String
    /// Per-server Header Logo Color (hex). Seeded from the global color on
    /// migration; editable per server in #17.
    var headerLogoColorHex: String
    var createdAt: Date
    var updatedAt: Date
    /// Set when the server is added and never changed: a webui server and a Hermes
    /// server can't share a URL (`AuthManager.addHermesServer`).
    var kind: ServerKind
    /// A Hermes server's release, as `/api/status` reported it at the last saved
    /// sign-in. Nil for webui servers, whose version Settings reads live.
    var serverVersion: String?
    /// The webui servers whose chats moved here (Move to Hermes, #707). Kept on the
    /// destination so it outlives removing the webui entry and goes with this one, and
    /// written only by `AuthManager.commitMove` and `updateMoveRecord`: `ServerRegistry.update`
    /// keeps the stored list, so an identity edit from an older copy can't drop it.
    var movedWebuiServers: [MovedWebuiServer]

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
        movedWebuiServers: [MovedWebuiServer] = []
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
        self.movedWebuiServers = movedWebuiServers
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
        case movedWebuiServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An entry needs at least an identifier; tolerate either key being the
        // one present so older/newer blobs across the epic still decode.
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
        // Read as text so a kind from a newer build, or a value of the wrong type,
        // falls back to webui instead of failing the entry.
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap(ServerKind.init(rawValue:)) ?? .webui
        serverVersion = try? container.decodeIfPresent(String.self, forKey: .serverVersion)
        // One unreadable record is dropped on its own; the entry still loads.
        movedWebuiServers = ((try? container.decodeIfPresent([Lossy<MovedWebuiServer>].self, forKey: .movedWebuiServers)) ?? [])
            .compactMap(\.value)
    }
}

/// A webui server whose chats moved to the Hermes server holding this record (#707). The
/// legacy routes of #1217 read it to send the webui server's old links, pushes and Shortcuts
/// to the destination, including after the webui entry is removed. One webui server has at
/// most one record across the whole registry.
struct MovedWebuiServer: Codable, Equatable, Sendable {
    /// The webui server's id: its URL as `AuthManager.normalizedServerURL` normalizes it.
    let sourceServerID: String
    /// Where each webui Profile's imports and new chats go, chosen explicitly at Review.
    /// Existing chats route by where they actually are, never by this mapping. A Profile
    /// missing here is unmapped, and its legacy entry points refuse rather than guess.
    var profiles: [MovedWebuiProfile]
    /// When the move finished its work and saved its report. Nil while it is unfinished.
    var completedAt: Date?
    /// The last counts the move recorded, which removal copy reads. Nil when none was saved.
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

    /// Where `profile`'s imports and new chats go, or nil when it is unmapped.
    func destination(ofProfile profile: String) -> MovedWebuiProfile.Destination? {
        profiles.first { $0.source == profile }?.destination
    }
}

/// One webui Profile's explicit choice at Review.
struct MovedWebuiProfile: Codable, Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        /// The Hermes Profile, by name, that the webui Profile's chats go to.
        case hermes(profile: String)
        /// The webui Profile stays where it is, usable on the webui entry.
        case keepOnWebui
    }

    /// The webui Profile's name, as the webui server lists it.
    let source: String
    let destination: Destination

    init(source: String, destination: Destination) {
        self.source = source
        self.destination = destination
    }

    enum CodingKeys: String, CodingKey {
        case source, hermesProfile, keepOnWebui
    }

    /// A mapping that names neither destination, or both, fails, so the Profile reads as
    /// unmapped rather than guessed.
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

/// The last counts a move recorded for the chats it left on webui. Each is nil when the
/// move couldn't establish it, which removal copy must show as unknown, never as zero.
struct MovedWebuiReport: Codable, Equatable, Sendable {
    /// Chats still only on webui: not copied, failed, or in a Profile kept on webui.
    var remaining: Int?
    /// Chats whose presence on Hermes couldn't be checked.
    var unchecked: Int?
    /// Chats over the import limits, reported and never trimmed.
    var oversized: Int?
    /// Of `remaining`, the chats in webui Profiles kept there or left unmapped (#1218).
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

/// Decodes one element of a list, or nil when that element can't be read, so one bad
/// element never fails the whole list.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Process-wide, thread-safe registry of configured servers plus which one is
/// active, persisted as a JSON blob in the Keychain (the server URL is a
/// credential, #15).
///
/// Mirrors `CustomHeaderStore`: the blob is loaded from the Keychain **once** at
/// init into a lock-guarded in-memory snapshot, reads come from that snapshot
/// (no synchronous `securityd` IPC on every property access), and mutations
/// update the snapshot and write through to the Keychain under the same lock.
/// `AuthManager` owns all writes: it calls `activate(url:)` when it configures or
/// restores a server, and `forgetActiveServer()` on full sign-out. Per-server
/// identity is seeded from the global identity defaults on first insert only, so
/// later per-server edits (#17) survive relaunch.
final class ServerRegistry: @unchecked Sendable {
    static let shared = ServerRegistry()

    private let keychain: any KeychainStoring
    /// Source of the global identity values used to seed a new server entry
    /// (`sessionIdentity.*` / `headerLogoColorHex` — non-secret `@AppStorage`
    /// settings that stay in UserDefaults).
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

    /// Single persisted blob so the list and the active selection stay atomic.
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
            // One unreadable entry is dropped on its own, never the whole list.
            servers = ((try? container.decodeIfPresent([Lossy<ServerAccount>].self, forKey: .servers)) ?? [])
                .compactMap(\.value)
            activeServerID = try? container.decodeIfPresent(String.self, forKey: .activeServerID)
        }
    }

    // MARK: - Reads (in-memory snapshot, no Keychain IPC)

    var servers: [ServerAccount] { storage.withLock { $0.servers } }

    var activeServerID: String? { storage.withLock { $0.activeServerID } }

    var activeServer: ServerAccount? {
        storage.withLock { snapshot in
            guard let id = snapshot.activeServerID else { return nil }
            return snapshot.servers.first { $0.id == id }
        }
    }

    // MARK: - Mutations (update snapshot + write through to the Keychain)

    /// Ensures `url` is registered and marked active, returning the active entry.
    ///
    /// Dedupes by id (the normalized URL string): a URL already present is just
    /// re-activated, never duplicated, and its identity and kind are left untouched
    /// so any per-server edits from #17 survive. A new URL is inserted as `kind`, with
    /// `serverVersion` and its identity seeded from the current global identity
    /// defaults. Callers pass an already-normalized URL
    /// (`AuthManager.normalizedServerURL`, or `BotConnection.address(_:)` for a Hermes server).
    @discardableResult
    func activate(url: URL, kind: ServerKind = .webui, serverVersion: String? = nil) -> ServerAccount {
        let id = url.absoluteString
        // When re-activating an already-registered server we mirror its (possibly
        // per-server-edited, #17) identity into the global identity defaults so the
        // existing @AppStorage-backed consumers follow the switch. We never mirror
        // on first insert: a new entry is *seeded from* those defaults, so writing
        // back would change first-run identity for single-server users.
        var identityToMirror: ServerAccount?
        let result: ServerAccount = storage.withLock { snapshot in
            if let existing = snapshot.servers.first(where: { $0.id == id }) {
                // Already registered: only flip the active selection + write
                // through when it actually changes, so the launch path
                // (restoreSavedServer → activate for the already-active server)
                // doesn't do a redundant synchronous Keychain write every start.
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

    /// Marks an already-registered server active (the Settings switcher, #17).
    /// No-op — returning nil — when `id` isn't registered or is already active.
    /// Mirrors the newly active server's identity into the global identity
    /// defaults so the avatar / header tint follow the switch.
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

    /// Removes the server `id`. When it was the active server, auto-selects the
    /// next remaining server as active and mirrors its identity; returns the
    /// server that is active *after* removal (nil when none remain, i.e. the
    /// caller should return to onboarding). Removing a non-active server leaves
    /// the active selection untouched. No-op for an unregistered id. (#17)
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

    /// Replaces the stored entry for `account.id` (per-server identity edits,
    /// #17), bumping `updatedAt`, and keeps the stored `movedWebuiServers`, which only
    /// `commit` writes. No-op for an unregistered id. Mirrors to the
    /// global identity defaults when the updated server is the active one, so the
    /// active server's edits show up live without each consumer reading the
    /// registry directly.
    func update(_ account: ServerAccount) {
        var activeUpdate: ServerAccount?
        storage.withLock { snapshot in
            guard let index = snapshot.servers.firstIndex(where: { $0.id == account.id }) else {
                return
            }
            var updated = account
            updated.updatedAt = now()
            updated.movedWebuiServers = snapshot.servers[index].movedWebuiServers
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

    /// Forgets the active server entirely, mirroring a full sign-out
    /// (`AuthManager.clearLocalAuth`) so a single-server install returns to
    /// "no servers configured."
    func forgetActiveServer() {
        storage.withLock { snapshot in
            guard let id = snapshot.activeServerID else { return }
            snapshot.servers.removeAll { $0.id == id }
            snapshot.activeServerID = nil
            persist(snapshot)
        }
    }

    /// Applies `change` to the server list and keeps the result only once the Keychain has
    /// saved it (Move to Hermes, #1215). `change` gets the registry's clock for `updatedAt`.
    /// When `change` or the save throws, the registry stays as it was, in memory and on disk.
    /// Never changes the active server or the global identity defaults.
    func commit<Result>(_ change: (_ servers: inout [ServerAccount], _ now: Date) throws -> Result) throws -> Result {
        try storage.withLockUnchecked { snapshot in
            var next = snapshot
            let result = try change(&next.servers, now())
            try save(next)
            snapshot = next
            return result
        }
    }

    // MARK: - Seeding

    /// Builds a fresh entry, seeding per-server identity from the global identity
    /// defaults and falling back to a host-derived label/initials when those are
    /// empty (intake: "derive from the normalized host by default").
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

    /// Writes `account`'s per-server identity into the global identity defaults
    /// (`sessionIdentity.*` / `headerLogoColorHex`). The active server's stored
    /// identity stays the source of truth; this keeps the global `@AppStorage`
    /// mirror — which the avatar, header logo color, and New Chat/Send tint read —
    /// in step whenever the active server changes or its identity is edited (#17).
    /// Called outside the storage lock (UserDefaults has its own synchronization).
    private func mirrorIdentityToDefaults(_ account: ServerAccount) {
        identityDefaults.set(account.displayName, forKey: SessionIdentitySettings.displayNameKey)
        identityDefaults.set(account.initials, forKey: SessionIdentitySettings.initialsKey)
        identityDefaults.set(account.headerLogoColorHex, forKey: HeaderLogoColor.storageKey)
    }

    // MARK: - Persistence

    /// Writes the snapshot through to the Keychain, ignoring a failure. Called under the
    /// storage lock.
    private func persist(_ snapshot: Snapshot) {
        try? save(snapshot)
    }

    /// Writes the snapshot through to the Keychain, throwing when it isn't saved.
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
