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
            if let stale = Self.agentRuntimeStale(statusCode: statusCode, body: body) {
                return stale.message
            }
            if Self.isVanishedSession(statusCode: statusCode, body: body) {
                return String(localized: "That session no longer exists on the server. Reopen another session or create a new one.")
            }

            switch statusCode {
            case -1:
                return String(localized: "The server response could not be read. Check that the URL points to a Hermes Web UI server.")
            case 400:
                if let message = Self.displayableServerMessage(from: body) {
                    return String(localized: "The server rejected the request: \(message)")
                }
                return String(localized: "The server rejected the request.")
            case 403:
                // A 403 is a per-request refusal (read-only imported session, missing
                // permission), not a bad password: 401 owns the password copy.
                if let message = Self.displayableServerMessage(from: body) {
                    return String(localized: "The server refused the request: \(message)")
                }
                return String(localized: "The server refused the request. Check the server permissions and try again.")
            case 404:
                return String(localized: "The server endpoint was not found. Check that the URL points to a Hermes Web UI server.")
            case 408:
                return String(localized: "The server did not respond in time. Check that the server is running and the connection is available.")
            case 429:
                return String(localized: "The server is receiving too many requests. Wait a moment, then try again.")
            case 500:
                return String(localized: "The Hermes server hit an internal error. Check the server logs, then try again.")
            case 502, 503, 504:
                return String(localized: "Could not connect to the server. Check that hermes-webui is running and the tunnel is connected.")
            default:
                if let message = Self.displayableServerMessage(from: body) {
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

    var activeStreamID: String? {
        guard case .http(let statusCode, let body) = self, statusCode == 409 else { return nil }
        return Self.serverErrorPayload(from: body)?.activeStreamId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var indicatesMissingStream: Bool {
        guard case .http(let statusCode, let body) = self, statusCode == 404 else { return false }
        return Self.serverErrorMessage(from: body)?.localizedCaseInsensitiveContains("stream not found") == true
    }

    /// Set for hermes-webui's stale-runtime 409 (#955); `errorDescription`
    /// already shows its copy, and chat uses it to offer Copy fix prompt.
    var agentRuntimeStale: AgentRuntimeStale? {
        guard case .http(let statusCode, let body) = self else { return nil }
        return Self.agentRuntimeStale(statusCode: statusCode, body: body)
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
        let activeStreamId: String?

        enum CodingKeys: String, CodingKey {
            case error, message, detail, code, stale
            case activeStreamId = "active_stream_id"
        }
    }

    /// Decoded apart from `ErrorPayload`, so a `type` of another shape in some
    /// other error can't hide that error's message or `active_stream_id`.
    struct AgentRuntimeStalePayload: Decodable {
        let type: String?
        let agentUpdateState: String?

        enum CodingKeys: String, CodingKey {
            case type
            case agentUpdateState = "agent_update_state"
        }
    }

    static func agentRuntimeStale(statusCode: Int, body: String?) -> AgentRuntimeStale? {
        guard statusCode == 409,
              let data = body?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AgentRuntimeStalePayload.self, from: data),
              payload.type == "agent_runtime_stale" else { return nil }
        return AgentRuntimeStale(agentUpdateState: payload.agentUpdateState)
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
            return String(localized: "The server did not respond in time. Check that the server is running and the connection is available.")
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
            return String(localized: "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP.")
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

    /// Longest server-provided message we interpolate into user-facing copy.
    static let displayedServerMessageLimit = 200

    /// The structured server message, bounded for display. Shared by every HTTP
    /// branch that shows server text so an oversized body never floods an alert.
    static func displayableServerMessage(from body: String?) -> String? {
        guard let message = serverErrorMessage(from: body) else { return nil }
        guard message.count > displayedServerMessageLimit else { return message }
        return String(message.prefix(displayedServerMessageLimit)) + "…"
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

/// hermes-webui's `agent_runtime_stale` 409 (`api/agent_runtime.py`,
/// `agent_runtime_stale_payload`): Hermes Agent was updated under the running
/// WebUI, which refuses every local Agent action until someone restarts it on
/// the server. The app cannot restart it, so the copy says what to do there.
enum AgentRuntimeStale: Equatable {
    /// The update finished, or the server can't tell (`stale`, `unverified`,
    /// `unknown`, absent, or a state added later).
    case updated
    /// `agent_update_state: "active"`: the update is still running.
    case updating
    /// `agent_update_state: "incomplete"`: the update stopped partway.
    case incomplete

    init(agentUpdateState: String?) {
        switch agentUpdateState {
        case "active": self = .updating
        case "incomplete": self = .incomplete
        default: self = .updated
        }
    }

    var message: String {
        switch self {
        case .updated:
            return String(localized: "Hermes was updated on your server. Restart Hermes WebUI there, then try again.")
        case .updating:
            return String(localized: "Hermes is still updating on your server. Wait for it to finish, restart Hermes WebUI, then try again.")
        case .incomplete:
            return String(localized: "A Hermes update on your server didn't finish. Check it, restart Hermes WebUI, then try again.")
        }
    }

    /// What the chat composer's Copy fix prompt puts on the pasteboard, for the
    /// user to send their agent over a messaging gateway (which `hermes update`
    /// restarts, so it still works). Nil while the update is running: the fix
    /// then is to wait, not restart.
    var fixPrompt: String? {
        guard self != .updating else { return nil }
        return String(localized: """
        My Hermes WebUI is refusing chats with "Hermes Agent was updated while Hermes WebUI was running." Please do only this:
        1. Check that no Hermes update is still running and the last one finished without errors. If it didn't, stop and tell me.
        2. Restart the Hermes WebUI server the same way it was started (systemd, launchd, ctl.sh, Docker, or whatever runs it). Don't update, reinstall, or reconfigure anything.
        3. Confirm it's back: its `/health` endpoint should return 200.

        If it doesn't come back up, show me the last lines of its error log and suggest a fix, but don't change config, environment variables, or Hermes source until I say so.
        """)
    }
}

#if DEBUG
extension APIError {
    /// `--stale-runtime-send` (`DEVELOPMENT.md`): the first chat send of this
    /// launch fails with the stale-runtime 409 instead of reaching the server,
    /// so its banner and Copy fix prompt can be checked without updating Hermes.
    @MainActor static func takeLaunchArgumentStaleRuntimeFailure() -> APIError? {
        guard !didTakeLaunchArgumentStaleRuntimeFailure,
              ProcessInfo.processInfo.arguments.contains("--stale-runtime-send") else { return nil }
        didTakeLaunchArgumentStaleRuntimeFailure = true
        return .http(
            statusCode: 409,
            body: #"{"error": "Hermes Agent was updated while Hermes WebUI was running. Restart Hermes WebUI manually before retrying this action.", "type": "agent_runtime_stale", "retryable": true, "restart_scheduled": false}"#
        )
    }

    @MainActor private static var didTakeLaunchArgumentStaleRuntimeFailure = false
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
