import Foundation

/// The keys the `hermex-push` plugin hands back from its pairing route, stored per
/// configured Hermex server. `installKey` is the relay capability that addresses this
/// host's devices; `previewKey` decrypts sealed previews in the Notification Service
/// Extension (#559). Both are credentials: Keychain only, never `UserDefaults`, and one
/// server's pairing is never read under another.
struct HermexPushPairing: Codable, Equatable {
    let relayURL: URL
    let installKey: String
    let previewKey: String
    /// The plugin's payload contract version. Stored as received so a host ahead of this
    /// build is recorded rather than rejected; nothing here parses a payload yet.
    let payloadVersion: Int
    /// The APNs token last registered at the relay, lowercase hex. Nil until the push
    /// entitlement and token registration land (#558); pairing still completes so the
    /// keys are in place for it.
    var deviceToken: String?

    /// The plugin's own vocabulary, fixed by `hermex-push`: the env var it reads, the
    /// installed plugin directory name, and the install identifier hermes-agent resolves
    /// to the `plugin/` subfolder of the repository.
    static let relayURLEnvironmentKey = "HERMEX_PUSH_RELAY_URL"
    static let pluginName = "hermex-push"
    static let pluginIdentifier = "https://github.com/uzairansaruzi/hermex-push.git/plugin"
    /// The relay Hermex runs for users who do not host their own (hermex#556). The field
    /// stays editable: the plugin accepts any https relay, and http only to loopback.
    static let defaultRelayURL = URL(string: "https://hermex-relay.hermex-relay.workers.dev")!

    /// Decodes `GET /api/plugins/hermex-push/pairing`. Fields the plugin may add later are
    /// ignored, but a key the relay could not use fails instead of pairing a phone that
    /// can never receive a push: the install key is 64 lowercase hex and the preview key
    /// is base64 of exactly 32 bytes (AES-256-GCM).
    init(_ body: BotJSON, deviceToken: String? = nil) throws {
        guard let install = body["install_key"].text, Self.isInstallKey(install),
              let preview = body["preview_key"].text, Data(base64Encoded: preview)?.count == 32,
              let address = body["relay_url"].text, let url = Self.relayURL(address)
        else { throw HermexPushFailure.unusablePairing }
        relayURL = url
        installKey = install
        previewKey = preview
        payloadVersion = body["payload_version"].integer ?? 1
        self.deviceToken = deviceToken
    }

    static func isInstallKey(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Accepts the relay addresses the plugin itself accepts: https anywhere, plain http
    /// only to loopback for a local capture. A typed address with credentials, a query or
    /// a fragment is rejected rather than sent to the host's environment.
    static func relayURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return nil }
        let scheme = parts.scheme?.lowercased()
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        // The relay refuses redirects, so a trailing slash must not become `//installs`.
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }
}

/// Failures that belong to push provisioning rather than to the Hermes gateway. Each one
/// is shown next to the step that produced it, so the user knows what to retry.
enum HermexPushFailure: Error, Equatable, LocalizedError {
    case invalidRelayURL, unusablePairing, pairingUnavailable, relayRejected(Int), noConnection
    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return String(localized: "Enter an HTTPS relay address without credentials or a query.")
        case .unusablePairing:
            return String(localized: "This Hermes host returned pairing keys Hermex cannot use. Update the hermex-push plugin.")
        case .pairingUnavailable:
            return String(localized: "The plugin did not answer after the restart. Check that Hermes came back up, then try again.")
        case .relayRejected(let status):
            return String(localized: "The relay refused this phone (\(status)). Check the relay address, then try again.")
        case .noConnection:
            return String(localized: "Connect to this Hermes host first.")
        }
    }
}

/// One pairing per configured Hermex server, in the same server-scoped Keychain the Bot
/// connection uses. Removing the server or its connection removes this with it.
@MainActor struct HermexPushPairingStore {
    var keychain: any KeychainStoring = KeychainStore()

    func load(server: URL) throws -> HermexPushPairing? {
        guard let value = try keychain.load(.hermexPushPairing, scope: server.absoluteString) else { return nil }
        return try? JSONDecoder().decode(HermexPushPairing.self, from: Data(value.utf8))
    }

    func save(_ pairing: HermexPushPairing, server: URL) throws {
        let value = String(decoding: try JSONEncoder().encode(pairing), as: UTF8.self)
        try keychain.save(value, forKey: .hermexPushPairing, scope: server.absoluteString)
    }

    func remove(server: URL) throws {
        try keychain.delete(.hermexPushPairing, scope: server.absoluteString)
    }

    /// Best-effort teardown when a connection or a whole server is removed: this phone
    /// comes off the relay so it stops receiving that host's pushes, then the keys go. An
    /// unreachable relay never blocks removal — the keys are deleted either way, so this
    /// phone can no longer decrypt a preview.
    func unpair(server: URL, relay: HermexPushRelayClient = HermexPushRelayClient()) async {
        if let pairing = try? load(server: server), let token = pairing.deviceToken {
            try? await relay.removeDevice(pairing, token: token)
        }
        try? remove(server: server)
    }
}
