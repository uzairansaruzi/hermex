import Foundation

/// The relay's device routes (hermex-push `relay/README.md`). The install key is the
/// capability that addresses one Hermes host's phones, so it only ever travels inside the
/// path of an https request and is never logged.
struct HermexPushRelayClient {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    /// The APNs environment this build's tokens belong to. Debug builds pair against the
    /// sandbox; everything installed from TestFlight or the App Store is production.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.uzairansar.hermesmobile" }

    /// Registers this phone under the host's install key. Registering again replaces the
    /// stored record, which is how a changed environment or preference set is applied.
    func register(_ pairing: HermexPushPairing, token: String, bundleID: String = HermexPushRelayClient.bundleID,
                  environment: String = HermexPushRelayClient.environment) async throws {
        guard Self.isDeviceToken(token) else { throw HermexPushFailure.relayRejected(400) }
        var request = URLRequest(url: devicesURL(pairing))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(BotJSON.object([
            "device_token": .string(token), "bundle_id": .string(bundleID), "environment": .string(environment)
        ]))
        try await send(request)
    }

    /// Removes this phone from the host's install. Idempotent: a device the relay has
    /// already dropped is not an error, so Disable never stalls on a stale token.
    func removeDevice(_ pairing: HermexPushPairing, token: String) async throws {
        var request = URLRequest(url: devicesURL(pairing).appendingPathComponent(token))
        request.httpMethod = "DELETE"
        do { try await send(request) } catch HermexPushFailure.relayRejected(404) {}
    }

    static func isDeviceToken(_ value: String) -> Bool {
        (32...512).contains(value.count) && value.count.isMultiple(of: 2)
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func devicesURL(_ pairing: HermexPushPairing) -> URL {
        pairing.relayURL.appendingPathComponent("installs")
            .appendingPathComponent(pairing.installKey).appendingPathComponent("devices")
    }

    private func send(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BotFailure.transport }
        guard (200..<300).contains(response.statusCode) else { throw HermexPushFailure.relayRejected(response.statusCode) }
    }
}
