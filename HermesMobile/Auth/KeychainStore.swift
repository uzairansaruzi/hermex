import Foundation
import KeychainAccess

protocol KeychainStoring {
    func save(_ value: String, forKey key: KeychainStore.Key) throws
    func load(_ key: KeychainStore.Key) throws -> String?
    func delete(_ key: KeychainStore.Key) throws

    // Per-server-scoped variants (#16): the same logical key namespaced by a
    // stable server identifier (the normalized server URL), so secrets like the
    // custom request headers are stored separately per configured server and one
    // server's credentials are never read or cleared for another.
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws
    func load(_ key: KeychainStore.Key, scope: String) throws -> String?
    func delete(_ key: KeychainStore.Key, scope: String) throws
}

struct KeychainStore: KeychainStoring {
    enum Key: String {
        case serverURL = "server_url"
        // JSON-encoded [{name, value}] of user-supplied request headers (#255).
        // Values may be secrets, so the list lives in the Keychain, not defaults.
        case customHeaders = "custom_headers"
        // JSON-encoded multi-server registry (server list + active id). The server
        // URL is treated as a credential, so the registry
        // lives in the Keychain, not UserDefaults (#15).
        case servers = "servers"
        case botConnection = "bot_connection"
        // Per-server push pairing (relay URL, install key, preview key). Unlike
        // every other key here it lives in a shared Keychain access group so the
        // Notification Service Extension can read it; see `PushPairing.swift`.
        case pushPairing = "push_pairing"
    }

    private let keychain: Keychain

    init(service: String? = nil) {
        let service = service
            ?? Bundle.main.object(forInfoDictionaryKey: "HermesKeychainService") as? String
            ?? Bundle.main.bundleIdentifier
            ?? "com.uzairansar.hermesmobile"
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    func save(_ value: String, forKey key: Key) throws {
        try keychain.set(value, key: key.rawValue)
    }

    func load(_ key: Key) throws -> String? {
        try keychain.get(key.rawValue)
    }

    func delete(_ key: Key) throws {
        try keychain.remove(key.rawValue)
    }

    func save(_ value: String, forKey key: Key, scope: String) throws {
        try keychain.set(value, key: Self.scopedKey(key, scope: scope))
    }

    func load(_ key: Key, scope: String) throws -> String? {
        try keychain.get(Self.scopedKey(key, scope: scope))
    }

    func delete(_ key: Key, scope: String) throws {
        try keychain.remove(Self.scopedKey(key, scope: scope))
    }

    /// Namespaces a logical key by a server scope. `::` can't appear in a key's
    /// raw value (they're lowercase identifiers), so it's an unambiguous separator
    /// and the legacy unscoped account (`custom_headers`) never collides with a
    /// scoped one (`custom_headers::https://host`).
    static func scopedKey(_ key: Key, scope: String) -> String {
        "\(key.rawValue)::\(scope)"
    }


    // MARK: - Diagnostic load

    /// Outcome of a diagnostic Keychain read, distinguishing a missing entry from
    /// a Keychain API failure. `restoreSavedServer` uses this to log the right
    /// reason when the server URL cannot be restored.
    enum LoadResult {
        case value(String)
        case missing
        case error(Error)
    }

    /// Reads `key` with full error detail. The regular `load(_:)` swallows errors
    /// (it returns `nil` for both "not found" and "Keychain locked"), which makes
    /// the `.unconfigured` fallback indistinguishable from a transient Keychain
    /// failure. This variant distinguishes the two so diagnostic logging can tell
    /// the user — or a future crash report — exactly what happened.
    func loadWithDiagnostics(_ key: Key) -> LoadResult {
        do {
            if let value = try keychain.get(key.rawValue) {
                return .value(value)
            }
            return .missing
        } catch {
            return .error(error)
        }
    }
}
