import CryptoKit
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

/// What the relay said about Settings' test notification (#874). Any 200 is delivered:
/// Apple accepted every banner, or the relay had already sent this event.
enum PushRelayTestOutcome: Equatable {
    case delivered
    /// No answer at all: this iPhone is offline, or the relay's host is down.
    case unreachable
    /// This pairing's install or preview key is not one the relay or the extension
    /// could use, so nothing was sent.
    case unusablePairing
    /// Any other answer. `result` is the relay's own code (`apns_rejected`,
    /// `delivery_retry`, `event_limit`, …), nil when the body was not the relay's JSON,
    /// such as Cloudflare's own refusal page (#834).
    case rejected(statusCode: Int, result: String?)
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

    /// Posts one `reply` event down the plugin's own route, so the test crosses the
    /// real relay → APNs → notification service path to every iPhone paired with this
    /// install. One call is one request, with no retry: each tap costs relay quota.
    /// A fresh `event_id` keeps a second test from being deduplicated as the first; the
    /// fixed thread and collapse ids make it replace the first banner instead of stacking.
    func sendTestNotification(pairing: PushPairing) async -> PushRelayTestOutcome {
        let keys = PushPreviewKeys(installKey: pairing.installKey, previewKey: pairing.previewKey)
        let preview = PushPreview(title: String(localized: "Hermex test notification"),
                                  body: String(localized: "Push through this server’s relay reached this iPhone."))
        guard let url = try? Self.installURL(pairing: pairing).appending(path: "notify"),
              let sealed = PushPreview.seal(preview, keys: keys),
              let body = try? JSONEncoder().encode(TestNotification(sealed: sealed))
        else { return .unusablePairing }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Push relay test failed in transport")
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        guard http.statusCode != 200 else { return .delivered }
        Self.logger.error("Push relay test returned \(http.statusCode, privacy: .public)")
        return .rejected(statusCode: http.statusCode,
                         result: (try? JSONDecoder().decode(RelayAnswer.self, from: data))?.result)
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
        try installURL(pairing: pairing).appending(path: "devices")
    }

    private static func installURL(pairing: PushPairing) throws -> URL {
        guard pairing.hasWellFormedInstallKey else { throw PushRelayError.malformedInstallKey }
        return pairing.relayURL.appending(path: "installs/\(pairing.installKey)")
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

    /// Exactly the relay's strict notify schema (`relay/src/contract.ts`): an unknown or
    /// missing key is a 400. `source: other` makes a tap only open the app.
    private struct TestNotification: Encodable {
        /// "7e57", repeated: fixed, so a new test banner replaces the last one.
        private static let group = String(repeating: "7e57", count: 8)
        let v = 1
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let threadID = TestNotification.group
        let sessionID = "hermex-test"
        let source = "other"
        let isSubagent = false
        let sentAt = Int(Date().timeIntervalSince1970)
        let kind = "reply"
        let collapseID = TestNotification.group
        let sealed: String

        enum CodingKeys: String, CodingKey {
            case v, source, kind, sealed
            case eventID = "event_id", threadID = "thread_id", sessionID = "session_id"
            case isSubagent = "is_subagent", sentAt = "sent_at", collapseID = "collapse_id"
        }
    }

    /// Every relay answer is `{"result": …}`; anything else decodes to nothing.
    private struct RelayAnswer: Decodable { let result: String? }
}

extension PushPreview {
    /// The inverse of `open`, for the one preview the phone writes itself: Settings'
    /// test notification. It lives in the app target because the extension never seals.
    /// Nil only for a preview key that is not base64 of 32 bytes.
    static func seal(_ preview: PushPreview, keys: PushPreviewKeys) -> String? {
        guard let rawKey = Data(base64Encoded: keys.previewKey), rawKey.count == 32,
              let plaintext = try? JSONEncoder().encode(preview),
              // A nil nonce is a fresh random 12 bytes, so `combined` is nonce || ciphertext || tag.
              let combined = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: rawKey),
                                                authenticating: keys.previewAAD).combined
        else { return nil }
        return combined.base64EncodedString()
    }
}
