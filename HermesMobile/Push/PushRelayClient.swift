import CryptoKit
import Foundation
import OSLog

@MainActor protocol PushRelayRegistering {
    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws
    func deleteDevice(token: String, pairing: PushPairing) async throws
}

@MainActor protocol PushActivityRelaying {
    func registerActivity(token: String, sessionID: String, deviceToken: String, pairing: PushPairing) async throws
    func deleteActivity(sessionID: String, deviceToken: String, pairing: PushPairing) async throws
}

enum PushRelayError: Error, Equatable {
    case http(statusCode: Int)
    case malformedInstallKey
    case transport
}

enum PushRelayTestOutcome: Equatable {
    case delivered
    case unreachable
    case unusablePairing
    case rejected(statusCode: Int, result: String?)
}

@MainActor struct PushRelayClient: PushRelayRegistering, PushActivityRelaying {
    private static let logger = Logger(subsystem: "com.uzairansar.hermesmobile", category: "push")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws {
        var request = URLRequest(url: try Self.devicesURL(pairing: pairing))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeviceRegistration(deviceToken: token, bundleID: identity.bundleID, environment: identity.environment,
                               prefs: pairing.effectivePreferences)
        )
        try await send(request, describedAs: "register")
    }

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

    private struct TestNotification: Encodable {
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

    private struct RelayAnswer: Decodable { let result: String? }
}

extension PushPreview {
    static func seal(_ preview: PushPreview, keys: PushPreviewKeys) -> String? {
        guard let rawKey = Data(base64Encoded: keys.previewKey), rawKey.count == 32,
              let plaintext = try? JSONEncoder().encode(preview),
              let combined = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: rawKey),
                                                authenticating: keys.previewAAD).combined
        else { return nil }
        return combined.base64EncodedString()
    }
}
