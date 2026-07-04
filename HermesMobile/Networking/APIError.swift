import Foundation

enum APIError: LocalizedError {
    case invalidServerURL
    case network(underlying: Error)
    case http(statusCode: Int, body: String?)
    case decoding(underlying: Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "Enter a valid server URL, for example https://hermes.yourdomain.com or http://<server-tailscale-ip>:8787.")
        case .network(let underlying):
            return Self.networkMessage(for: underlying)
        case .http(let statusCode, let body):
            if Self.isVanishedSession(statusCode: statusCode, body: body) {
                return String(localized: "That session no longer exists on the server. Reopen another session or create a new one.")
            }

            switch statusCode {
            case -1:
                return String(localized: "The server response could not be read. Check that the URL points to a Hermes Web UI server.")
            case 400:
                if let message = Self.serverErrorMessage(from: body) {
                    return String(localized: "The server rejected the request: \(message)")
                }
                return String(localized: "The server rejected the request.")
            case 403:
                return String(localized: "The server refused access. Check the server password and permissions.")
            case 404:
                return String(localized: "The server endpoint was not found. Check that the URL points to a Hermes Web UI server.")
            case 408:
                return String(localized: "The server took too long to respond. Check that the Mac is awake and the server is running.")
            case 429:
                return String(localized: "The server is receiving too many requests. Wait a moment, then try again.")
            case 500:
                return String(localized: "The Hermes server hit an internal error. Check the server logs, then try again.")
            case 502, 503, 504:
                return String(localized: "The server or Cloudflare tunnel is unavailable. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected.")
            default:
                if let message = Self.serverErrorMessage(from: body) {
                    return String(localized: "Server returned HTTP \(statusCode): \(message)")
                }
                return String(localized: "Server returned HTTP \(statusCode).")
            }
        case .decoding:
            return String(localized: "The server response could not be read.")
        case .unauthorized:
            return String(localized: "The password was rejected. Check the server password and try again.")
        }
    }

    var privacySafeLogCategory: String {
        switch self {
        case .invalidServerURL:
            return "invalidServerURL"
        case .network(let underlying):
            if let urlError = underlying as? URLError {
                return "network.url.\(urlError.code.rawValue)"
            }
            return "network.other"
        case .http(let statusCode, _):
            return "http.\(statusCode)"
        case .decoding:
            return "decoding"
        case .unauthorized:
            return "unauthorized"
        }
    }

    var serverCode: String? {
        guard case .http(_, let body) = self else { return nil }
        return Self.serverErrorPayload(from: body)?.code
    }

    var serverMessage: String? {
        guard case .http(_, let body) = self else { return nil }
        return Self.serverErrorMessage(from: body)
    }

    /// True for the documented "prompt already expired" respond rejection:
    /// HTTP 409 with `{"stale": true, …}` in the body (issue #25). Used to show
    /// a friendly expired state instead of a generic failure.
    var indicatesExpiredPendingPrompt: Bool {
        guard case .http(let statusCode, let body) = self, statusCode == 409 else { return false }
        return Self.serverErrorPayload(from: body)?.stale == true
    }

    static func privacySafeLogCategory(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.privacySafeLogCategory
        }

        if let urlError = error as? URLError {
            return "network.url.\(urlError.code.rawValue)"
        }

        if error is CancellationError {
            return "cancelled"
        }

        return "other"
    }
}

private extension APIError {
    struct ErrorPayload: Decodable {
        let error: String?
        let message: String?
        let detail: String?
        let code: String?
        let stale: Bool?
    }

    static func networkMessage(for error: Error) -> String {
        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else {
            return String(localized: "Could not reach the server. Check the URL and network connection.")
        }

        switch urlError.code {
        case .timedOut:
            return String(localized: "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected.")
        case .cannotFindHost, .dnsLookupFailed:
            return String(localized: "Could not find that server. Check the URL and Cloudflare DNS hostname.")
        case .cannotConnectToHost, .networkConnectionLost:
            return String(localized: "Could not connect to the server. Check that hermes-webui is running and the tunnel is connected.")
        case .notConnectedToInternet, .dataNotAllowed:
            return String(localized: "This device is offline. Connect to the internet, then try again.")
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return String(localized: "The HTTPS connection failed. Check the server URL and certificate.")
        case .appTransportSecurityRequiresSecureConnection:
            return String(localized: "iOS blocked this insecure HTTP connection. Use HTTPS, or use a Tailscale IP in the 100.64.0.0/10 range.")
        case .cancelled:
            return String(localized: "The request was cancelled.")
        default:
            return String(localized: "Could not reach the server. Check the URL, network connection, and tunnel status.")
        }
    }

    static func isVanishedSession(statusCode: Int, body: String?) -> Bool {
        guard statusCode == 404 else { return false }
        return serverErrorMessage(from: body)?.localizedCaseInsensitiveContains("Session not found") == true
    }

    static func serverErrorMessage(from body: String?) -> String? {
        guard let payload = serverErrorPayload(from: body) else { return nil }
        let message = payload.error ?? payload.message ?? payload.detail
        return message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func serverErrorPayload(from body: String?) -> ErrorPayload? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ErrorPayload.self, from: data)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
