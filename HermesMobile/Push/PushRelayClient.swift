import Foundation
import OSLog

/// Registering and revoking this device at one install's relay.
@MainActor protocol PushRelayRegistering {
    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws
    func deleteDevice(token: String, pairing: PushPairing) async throws
}

@MainActor protocol PushActivityRelaying {
    func registerActivity(token: String, sessionID: String, deviceToken: String, pairing: PushPairing) async throws
    func deleteActivity(sessionID: String, deviceToken: String, pairing: PushPairing) async throws
}

enum PushRelayError: Error, Equatable {
    /// The relay answered, but not with success. 400 means the body or the
    /// environment was wrong, 409 that the install is at its 32-device limit,
    /// 503 that the relay could not reach storage or APNs and a retry may work.
    case http(statusCode: Int)
    /// The install key is not the 64 lowercase hex characters the relay expects.
    case malformedInstallKey
    case transport
}

/// The relay is a different host from the user's Hermes server and speaks a tiny
/// contract of its own, so it does not go through `Endpoint`/`APIClient`. Shapes
/// are from `relay/README.md` and `relay/src/contract.ts` in `uzairansaruzi/hermex-push`.
///
/// The install key is a bearer capability and it sits in the *path*, so no URL
/// built here is ever logged, attached to an error, or shown to the user.
@MainActor struct PushRelayClient: PushRelayRegistering, PushActivityRelaying {
    private static let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "push")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Registering the same token again replaces that device's preferences, so
    /// this is the launch-time refresh as well as the first pairing's call.
    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws {
        var request = URLRequest(url: try Self.devicesURL(pairing: pairing))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The relay replaces preferences on registration, including launch refresh
        // and token rotation, so always send this server's confirmed choices.
        request.httpBody = try JSONEncoder().encode(
            DeviceRegistration(deviceToken: token, bundleID: identity.bundleID, environment: identity.environment,
                               prefs: pairing.effectivePreferences)
        )
        try await send(request, describedAs: "register")
    }

    /// Idempotent: a token the relay has already revoked still answers 200.
    func deleteDevice(token: String, pairing: PushPairing) async throws {
        var request = URLRequest(url: try Self.devicesURL(pairing: pairing).appending(path: token))
        request.httpMethod = "DELETE"
        try await send(request, describedAs: "delete")
    }

    func registerActivity(token: String, sessionID: String, deviceToken: String, pairing: PushPairing) async throws {
        var request = URLRequest(url: try Self.activityURL(sessionID: sessionID, deviceToken: deviceToken, pairing: pairing))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["activity_token": token])
        try await send(request, describedAs: "register activity")
    }

    func deleteActivity(sessionID: String, deviceToken: String, pairing: PushPairing) async throws {
        var request = URLRequest(url: try Self.activityURL(sessionID: sessionID, deviceToken: deviceToken, pairing: pairing))
        request.httpMethod = "DELETE"
        try await send(request, describedAs: "delete activity")
    }

    static func activityURL(sessionID: String, deviceToken: String, pairing: PushPairing) throws -> URL {
        // A session is one opaque path segment, including any slash or percent sign.
        let base = try devicesURL(pairing: pairing).appending(path: deviceToken).appending(path: "activities")
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let segment = sessionID.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw PushRelayError.transport
        }
        parts.percentEncodedPath += "/" + segment
        guard let url = parts.url else { throw PushRelayError.transport }
        return url
    }

    private func send(_ request: URLRequest, describedAs action: String) async throws {
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Push relay \(action, privacy: .public) failed in transport")
            throw PushRelayError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw PushRelayError.transport }
        guard http.statusCode == 200 else {
            Self.logger.error("Push relay \(action, privacy: .public) returned \(http.statusCode, privacy: .public)")
            throw PushRelayError.http(statusCode: http.statusCode)
        }
    }

    static func devicesURL(pairing: PushPairing) throws -> URL {
        guard pairing.hasWellFormedInstallKey else { throw PushRelayError.malformedInstallKey }
        return pairing.relayURL.appending(path: "installs/\(pairing.installKey)/devices")
    }

    private struct DeviceRegistration: Encodable {
        let deviceToken: String
        let bundleID: String
        let environment: PushEnvironment
        let prefs: PushPreferences

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case bundleID = "bundle_id"
            case environment, prefs
        }
    }
}
