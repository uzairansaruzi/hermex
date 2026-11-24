import Foundation

enum HermexPushPlugin {
    static let relayURLEnvironmentKey = "HERMEX_PUSH_RELAY_URL"
    static let name = "hermex-push"
    static let installIdentifier = "https://github.com/uzairansaruzi/hermex-push.git/plugin"
    static let defaultRelayURL = URL(string: "https://hermex-relay.hermex-relay.workers.dev")!
    static let newestVersion = HermexPushPluginVersion("0.7.2")!
    static let restartVersion = HermexPushPluginVersion("0.4.0")!

    static func canRestart(_ loaded: HermexPushPluginVersion?) -> Bool {
        loaded.map { $0 >= restartVersion } ?? false
    }

    static func loadedVersion(_ body: BotJSON) -> HermexPushPluginVersion? {
        body["plugin_version"].text.flatMap(HermexPushPluginVersion.init)
    }

    static func isOnDisk(hub body: BotJSON) -> Bool? {
        body["plugins"].list?.contains { $0["name"].text == name }
    }

    static func installedVersion(hub body: BotJSON) -> HermexPushPluginVersion? {
        body["plugins"].list?.first { $0["name"].text == name }?["version"].text.flatMap(HermexPushPluginVersion.init)
    }

    static func missingRoute(_ body: BotJSON) -> HermexPushRouteMissing? {
        if body["detail"].text == "Plugin not found" { return .pluginOff }
        if body["detail"].text?.hasPrefix("No such API endpoint") == true
            || body["error"].text?.hasPrefix("Headless backend") == true { return .notMounted }
        return nil
    }

    static func pairing(_ body: BotJSON) throws -> PushPairing {
        guard let install = body["install_key"].text,
              let preview = body["preview_key"].text, Data(base64Encoded: preview)?.count == 32,
              let address = body["relay_url"].text, let url = relayURL(address)
        else { throw HermexPushFailure.unusablePairing }
        let pairing = PushPairing(relayURL: url, installKey: install, previewKey: preview)
        guard pairing.hasWellFormedInstallKey else { throw HermexPushFailure.unusablePairing }
        return pairing
    }

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
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }
}

enum HermexPushFailure: Error, Equatable, LocalizedError {
    case unusablePairing, pairingUnavailable, noConnection
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

struct HermexCompanionRoutes: Equatable, Sendable {
    static let closed = HermexCompanionRoutes(pluginVersion: nil, routes: [])

    let pluginVersion: HermexPushPluginVersion?
    let routes: Set<String>

    init(_ body: BotJSON) {
        self.init(pluginVersion: HermexPushPlugin.loadedVersion(body),
                  routes: Set(body["routes"].list?.compactMap(\.text) ?? []))
    }

    init(pluginVersion: HermexPushPluginVersion?, routes: Set<String>) {
        self.pluginVersion = pluginVersion
        self.routes = routes
    }

    func supports(_ route: String) -> Bool { routes.contains(route) }
}

enum HermexPushRouteMissing: Error, Equatable { case pluginOff, notMounted }

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
