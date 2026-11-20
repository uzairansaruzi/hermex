import Foundation

struct HermesTurnOutcome: Equatable, Sendable {
    struct Surface: Equatable, Sendable {
        var layer: String?
        var code: String?
        var retryable: Bool?
        var provider: String?
        var resetsAt: Date?
        var message: String?
    }

    var error: String?
    var surface: Surface?
    var recoverable: Bool?
    var billingURL: URL?
    var failureReason: String?
    var warning: String?

    init?(inflight: BotJSON) {
        guard inflight["error"] != .null else { return nil }
        self.init(failure: inflight)
    }

    init?(complete payload: BotJSON) {
        self.init(failure: payload)
        if let url = payload["billing"]["billing_url"].text.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https" {
            billingURL = url
        }
        failureReason = Self.nonEmpty(payload["failure_reason"])
        warning = Self.nonEmpty(payload["warning"])
        guard payload["error"] != .null || payload["billing"] != .null || warning != nil else { return nil }
    }

    private init(failure fields: BotJSON) {
        error = Self.nonEmpty(fields["error"])
        recoverable = fields["recoverable"].flag
        let surface = fields["error_surface"]
        if surface.fields != nil {
            self.surface = Surface(
                layer: Self.nonEmpty(surface["layer"]), code: Self.nonEmpty(surface["code"]),
                retryable: surface["retryable"].flag, provider: Self.nonEmpty(surface["provider"]),
                resetsAt: surface["resets_at"].number.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil },
                message: Self.nonEmpty(surface["message"]))
        }
    }

    var offersRetry: Bool { surface?.retryable ?? (recoverable == true) }

    private static func nonEmpty(_ value: BotJSON) -> String? {
        guard let text = value.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
