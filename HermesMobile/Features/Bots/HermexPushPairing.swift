import Foundation

enum HermexPushPlugin {
    static let relayURLEnvironmentKey = "HERMEX_PUSH_RELAY_URL"
    static let name = "hermex-push"
    static let installIdentifier = "https://github.com/uzairansaruzi/hermex-push.git/plugin"
    static let defaultRelayURL = URL(string: "https://hermex-relay.hermex-relay.workers.dev")!
    static let minimumVersion = HermexPushPluginVersion("0.7.3")!
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

    static func hostListing(_ body: BotJSON) -> HermexPushHostListing? {
        guard let row = body["plugins"].list?.first(where: { ($0["key"].text ?? $0["name"].text) == name }) else { return nil }
        let target = row["update_available"].flag == true ? row["update_target"].text.flatMap { $0.isEmpty ? nil : $0 } : nil
        return HermexPushHostListing(installed: row["version"].text.flatMap(HermexPushPluginVersion.init), updateTarget: target)
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

struct HermexPushHostListing: Equatable, Sendable {
    let installed: HermexPushPluginVersion?
    let updateTarget: String?
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

struct HermexPushUpdateOffer: Equatable {
    enum Kind: Equatable {
        case required(loaded: HermexPushPluginVersion?)
        case newer(loaded: HermexPushPluginVersion)
        case restart
    }

    let kind: Kind
    let dismissal: String
}

@MainActor @Observable final class HermexPushUpdateOffers {
    static let shared = HermexPushUpdateOffers()
    static let recheckInterval: Duration = .seconds(60 * 60)
    #if DEBUG
    static let debugForcesCardKey = "hermexPush.debugForcesUpdateCard"
    static let debugOffer = HermexPushUpdateOffer(kind: .required(loaded: HermexPushPluginVersion("0.6.0")), dismissal: "debug")
    #endif

    private var offers: [URL: HermexPushUpdateOffer] = [:]
    private var dismissals: [URL: String] = [:]
    @ObservationIgnored private var checkedAt: [URL: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var revisions: [URL: Int] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func dismissalKey(for server: URL) -> String { "hermexPush.dismissedUpdate|\(server.absoluteString)" }

    static func forget(_ server: URL, in defaults: UserDefaults) {
        defaults.removeObject(forKey: dismissalKey(for: server))
        shared.clear(server)
    }

    func offer(for server: URL) -> HermexPushUpdateOffer? { offers[server] }

    func cardOffer(for server: URL) -> HermexPushUpdateOffer? {
        offers[server].flatMap { $0.dismissal == dismissals[server] ? nil : $0 }
    }

    func dismiss(_ offer: HermexPushUpdateOffer, for server: URL) {
        defaults.set(offer.dismissal, forKey: Self.dismissalKey(for: server))
        dismissals[server] = offer.dismissal
    }

    func revision(for server: URL) -> Int { revisions[server, default: 0] }

    func record(_ standing: HermexPushProvisioner.PluginUpdate, for server: URL, readSince revision: Int? = nil) {
        if let revision {
            guard revision == self.revision(for: server) else { return }
        } else {
            revisions[server, default: 0] += 1
        }
        switch standing {
        case .available(let loaded):
            offers[server] = HermexPushUpdateOffer(kind: .required(loaded: loaded),
                                                   dismissal: "minimum \(HermexPushPlugin.minimumVersion)")
        case .newer(let loaded, let target):
            offers[server] = HermexPushUpdateOffer(kind: .newer(loaded: loaded), dismissal: "update \(target)")
        case .restartNeeded(let loaded):
            offers[server] = HermexPushUpdateOffer(kind: .restart, dismissal: "restart \(loaded?.description ?? "")")
        case .upToDate:
            offers[server] = nil
        case .setupNeedsRestart, .restartTimedOut, .checkFailed:
            return
        }
        dismissals[server] = defaults.string(forKey: Self.dismissalKey(for: server))
    }

    func clear(_ server: URL) {
        revisions[server, default: 0] += 1
        offers[server] = nil
        dismissals[server] = nil
        checkedAt[server] = nil
    }

    func checkIfDue(server: URL, connection: BotConnection, now: ContinuousClock.Instant = .now) async {
        let provisioner = HermexPushProvisioner(server: server, connection: connection, offers: self)
        guard provisioner.pairing != nil else { return clear(server) }
        if let last = checkedAt[server], now - last < Self.recheckInterval { return }
        checkedAt[server] = now
        await provisioner.checkPlugin()
    }
}
