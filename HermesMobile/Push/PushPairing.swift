import Foundation
import KeychainAccess

/// One server's completed push pairing: where its relay lives, the capability
/// that addresses its install, and the key that unseals its previews.
///
/// The install key is a bearer capability — whoever holds it can manage that
/// install's devices — so it lives in the Keychain and never in a log, a URL we
/// print, or `UserDefaults`.
struct PushPairing: Codable, Equatable, Sendable {
    let relayURL: URL
    /// 64 lowercase hex characters, minted by the plugin on the user's host.
    let installKey: String
    /// The plugin's AES-256-GCM preview key, base64. Only the Notification
    /// Service Extension uses it; the app stores it so the extension can read it
    /// out of the shared access group.
    let previewKey: String
    /// The device token this pairing was last registered with, lowercase hex.
    /// Nil until the first successful registration. Keeping it lets a rotation
    /// delete the stale token at the relay instead of leaking a dead device.
    var registeredToken: String?

    init(relayURL: URL, installKey: String, previewKey: String, registeredToken: String? = nil) {
        self.relayURL = relayURL
        self.installKey = installKey
        self.previewKey = previewKey
        self.registeredToken = registeredToken
    }

    /// The relay rejects anything else with a 400, and a 400 at registration time
    /// reads to the user as "notifications just don't work", so callers check here.
    var hasWellFormedInstallKey: Bool {
        installKey.count == 64 && installKey.allSatisfy { Self.lowercaseHex.contains($0) }
    }

    private static let lowercaseHex = Set("0123456789abcdef")
}

/// Reads and writes pairings, one per configured server.
@MainActor protocol PushPairingStoring {
    func pairing(for server: URL) throws -> PushPairing?
    func save(_ pairing: PushPairing, for server: URL) throws
    func remove(for server: URL) throws
    /// Every configured server that has completed pairing. One device token has
    /// to be registered with each of them, and a pairing is per server, so the
    /// registrar always works from the whole set rather than the active server.
    func allPairings() throws -> [URL: PushPairing]
}

/// The pairing keys live in a Keychain *access group* shared with the
/// Notification Service Extension (`PushPreviewKeys.stored`), unlike the rest of the app's credentials,
/// which stay in the app's default group. The extension finds the right server's
/// preview key by hashing each stored install key and matching the payload's
/// `install_hash`, so it needs to enumerate this group — hence `allPairings`.
@MainActor struct KeychainPushPairingStore: PushPairingStoring {
    private let keychain: Keychain

    /// The access group comes from `HermesKeychainAccessGroup` (the Info.plist
    /// mirror of `KEYCHAIN_ACCESS_GROUP`). Without it there is nothing to share,
    /// so the initializer fails rather than quietly writing somewhere the
    /// extension can never read.
    init?(bundle: Bundle = .main) {
        guard let service = bundle.object(forInfoDictionaryKey: "HermesKeychainService") as? String,
              let accessGroup = bundle.object(forInfoDictionaryKey: "HermesKeychainAccessGroup") as? String,
              !service.isEmpty, !accessGroup.isEmpty else { return nil }
        self.keychain = Keychain(service: service, accessGroup: accessGroup)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    func pairing(for server: URL) throws -> PushPairing? {
        guard let value = try keychain.get(Self.key(for: server)) else { return nil }
        return try? JSONDecoder().decode(PushPairing.self, from: Data(value.utf8))
    }

    func save(_ pairing: PushPairing, for server: URL) throws {
        let value = String(decoding: try JSONEncoder().encode(pairing), as: UTF8.self)
        try keychain.set(value, key: Self.key(for: server))
    }

    func remove(for server: URL) throws {
        try keychain.remove(Self.key(for: server))
    }

    func allPairings() throws -> [URL: PushPairing] {
        var result: [URL: PushPairing] = [:]
        for key in keychain.allKeys() {
            guard let scope = Self.scope(fromKey: key), let server = URL(string: scope),
                  let value = try keychain.get(key),
                  let pairing = try? JSONDecoder().decode(PushPairing.self, from: Data(value.utf8))
            else { continue }
            result[server] = pairing
        }
        return result
    }

    static func key(for server: URL) -> String {
        KeychainStore.scopedKey(.pushPairing, scope: server.absoluteString)
    }

    /// The inverse of `key(for:)`. Other keys in the group (there are none today,
    /// but the extension shares it) are skipped rather than mis-parsed.
    static func scope(fromKey key: String) -> String? {
        let prefix = "\(KeychainStore.Key.pushPairing.rawValue)::"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}
