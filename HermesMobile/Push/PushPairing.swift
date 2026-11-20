import Foundation
import KeychainAccess

struct PushPairing: Codable, Equatable, Sendable {
    let relayURL: URL
    let installKey: String
    let previewKey: String
    var registeredToken: String?
    var preferences: PushPreferences?
    var preferencesNeedSync: Bool?
    var effectivePreferences: PushPreferences { preferences ?? PushPreferences() }

    init(relayURL: URL, installKey: String, previewKey: String, registeredToken: String? = nil) {
        self.relayURL = relayURL
        self.installKey = installKey
        self.previewKey = previewKey
        self.registeredToken = registeredToken
    }

    var hasWellFormedInstallKey: Bool {
        installKey.count == 64 && installKey.allSatisfy { Self.lowercaseHex.contains($0) }
    }

    func hasSameRegistration(as other: PushPairing) -> Bool {
        relayURL == other.relayURL && installKey == other.installKey
            && previewKey == other.previewKey && registeredToken == other.registeredToken
    }

    private static let lowercaseHex = Set("0123456789abcdef")
}

struct PushPreferences: Codable, Equatable, Sendable {
    var replies = true
    var muteSubagents = true
    var previews = true
    var presenceSuppression = true

    init(replies: Bool = true, muteSubagents: Bool = true, previews: Bool = true, presenceSuppression: Bool = true) {
        self.replies = replies
        self.muteSubagents = muteSubagents
        self.previews = previews
        self.presenceSuppression = presenceSuppression
    }

    enum CodingKeys: String, CodingKey {
        case replies, previews
        case muteSubagents = "mute_subagents"
        case presenceSuppression = "presence_suppression"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        replies = try values.decodeIfPresent(Bool.self, forKey: .replies) ?? true
        muteSubagents = try values.decodeIfPresent(Bool.self, forKey: .muteSubagents) ?? true
        previews = try values.decodeIfPresent(Bool.self, forKey: .previews) ?? true
        presenceSuppression = try values.decodeIfPresent(Bool.self, forKey: .presenceSuppression) ?? true
    }
}

@MainActor protocol PushPairingStoring {
    func pairing(for server: URL) throws -> PushPairing?
    func save(_ pairing: PushPairing, for server: URL) throws
    func remove(for server: URL) throws
    func allPairings() throws -> [URL: PushPairing]
}

@MainActor struct KeychainPushPairingStore: PushPairingStoring {
    private let keychain: Keychain

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

    static func scope(fromKey key: String) -> String? {
        let prefix = "\(KeychainStore.Key.pushPairing.rawValue)::"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}

enum MovePushPairingOutcome: Equatable, Sendable {
    case sourceUnpaired
    case destinationAlreadyPaired
    case copied
    case differentInstall
    case unchecked
}

@MainActor protocol PushPairingCopying {
    func pairing(for server: URL) -> PushPairing?
    func copyPairing(from source: URL, to destination: URL, matching install: PushPairing,
                     isConfigured: @escaping @MainActor (URL) -> Bool) async throws -> MovePushPairingOutcome
}

@MainActor enum MovePushPairing {
    static func carry(from source: URL, to destination: URL, registrar: any PushPairingCopying,
                      isConfigured: @escaping @MainActor (URL) -> Bool,
                      readDestination: () async throws -> PushPairing) async -> MovePushPairingOutcome {
        guard registrar.pairing(for: source) != nil else { return .sourceUnpaired }
        guard registrar.pairing(for: destination) == nil else { return .destinationAlreadyPaired }
        guard let install = try? await readDestination() else { return .unchecked }
        return (try? await registrar.copyPairing(from: source, to: destination, matching: install,
                                                 isConfigured: isConfigured)) ?? .unchecked
    }
}
