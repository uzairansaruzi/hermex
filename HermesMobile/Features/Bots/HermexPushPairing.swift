import Foundation

/// What the `hermex-push` plugin is called on a Hermes host, and how the pairing route
/// it mounts answers. The keys themselves are a `PushPairing`, stored once by
/// `PushRegistrar` in the Keychain access group the Notification Service Extension
/// reads; provisioning keeps no copy of its own.
enum HermexPushPlugin {
    /// The plugin's own vocabulary: the env var it reads, its installed directory name,
    /// and the identifier hermes-agent resolves to the `plugin/` subfolder of the repo.
    static let relayURLEnvironmentKey = "HERMEX_PUSH_RELAY_URL"
    static let name = "hermex-push"
    static let installIdentifier = "https://github.com/uzairansaruzi/hermex-push.git/plugin"
    /// The relay Hermex runs (hermex#556), used for a host that has never been set up.
    /// It is not offered as a choice: a host that already names its own relay keeps it,
    /// and self-hosting stays a server-side setting rather than a field on the phone.
    static let defaultRelayURL = URL(string: "https://hermex-relay.hermex-relay.workers.dev")!
    /// The newest plugin this build knows (#851). A host that has anything older loaded is
    /// offered an update in Settings → Notifications. Bump it in the app release that
    /// follows a plugin release (TESTFLIGHT.md's release gates).
    static let newestVersion = HermexPushPluginVersion("0.3.0")!

    /// `plugin_version` from the pairing route: the code the dashboard process has loaded,
    /// which lags the files on disk until that process restarts. Nil for a plugin older than
    /// 0.2.0, which leaves it out, and for anything unparseable; both count as older than
    /// every known version. Tolerant, unlike the keys beside it.
    static func loadedVersion(_ body: BotJSON) -> HermexPushPluginVersion? {
        body["plugin_version"].text.flatMap(HermexPushPluginVersion.init)
    }

    /// The version on the host's disk: `plugin.yaml`'s, as `GET /api/dashboard/plugins/hub`
    /// lists it per plugin. Nil when the plugin is not listed or its version doesn't parse.
    static func installedVersion(hub body: BotJSON) -> HermexPushPluginVersion? {
        body["plugins"].list?.first { $0["name"].text == name }?["version"].text.flatMap(HermexPushPluginVersion.init)
    }

    /// Decodes `GET /api/plugins/hermex-push/pairing`. Fields the plugin may add later
    /// are ignored, but a key the relay could not use fails instead of pairing a phone
    /// that can never receive a push: the install key is 64 lowercase hex characters and
    /// the preview key is base64 of exactly 32 bytes (AES-256-GCM).
    static func pairing(_ body: BotJSON) throws -> PushPairing {
        guard let install = body["install_key"].text,
              let preview = body["preview_key"].text, Data(base64Encoded: preview)?.count == 32,
              let address = body["relay_url"].text, let url = relayURL(address)
        else { throw HermexPushFailure.unusablePairing }
        let pairing = PushPairing(relayURL: url, installKey: install, previewKey: preview)
        guard pairing.hasWellFormedInstallKey else { throw HermexPushFailure.unusablePairing }
        return pairing
    }

    /// Accepts the relay addresses the plugin itself accepts: https anywhere, plain http
    /// only to loopback for a local capture. A host that answers with anything else is
    /// refused rather than pairing a phone the relay could never reach.
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

/// Failures that belong to setting a Hermes host up for push rather than to the Hermes
/// gateway. Each one is shown next to the step that produced it, so the user knows what
/// to retry.
enum HermexPushFailure: Error, Equatable, LocalizedError {
    case unusablePairing, pairingUnavailable, noConnection
    /// A plugin update turned hermex-push off and could not turn it back on.
    case pluginLeftOff
    var errorDescription: String? {
        switch self {
        case .pluginLeftOff:
            return String(localized: "Hermes still has the plugin turned off, so notifications stop when Hermes restarts. Try again to turn it back on.")
        case .unusablePairing:
            return String(localized: "This Hermes host returned pairing keys Hermex cannot use. Update the hermex-push plugin.")
        case .pairingUnavailable:
            return String(localized: "The plugin did not answer after the restart. Check that Hermes came back up, then try again.")
        case .noConnection:
            return String(localized: "Connect to this Hermes host first.")
        }
    }
}

/// A hermex-push version, compared number by number so 0.10.0 is newer than 0.9.0, and
/// 0.3 equals 0.3.0. Only dot-separated whole numbers parse.
struct HermexPushPluginVersion: Comparable, Sendable, CustomStringConvertible {
    let description: String
    private let numbers: [Int]

    init?(_ text: String) {
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false)
            .map { part in part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil }
        guard !numbers.contains(nil) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        description = text
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.padded(to: rhs) == rhs.padded(to: lhs) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.padded(to: rhs).lexicographicallyPrecedes(rhs.padded(to: lhs)) }

    private func padded(to other: Self) -> [Int] {
        numbers + Array(repeating: 0, count: max(0, other.numbers.count - numbers.count))
    }
}
