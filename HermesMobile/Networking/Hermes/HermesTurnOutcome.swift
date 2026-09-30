import Foundation

/// How a Hermes turn ended, read tolerantly from what the host already sends about it:
/// the failure `session.resume` retains in `inflight`, or a live `message.complete`.
/// A pure value with every field optional, so an older or newer host decodes to
/// whatever it sent. Bot Chat's outcome row reads it; Sessions on Hermes can too.
struct HermesTurnOutcome: Equatable, Sendable {
    /// The host's advisory `error_surface`: which layer failed, why, and whether
    /// retrying unchanged can help. Unknown keys are ignored.
    struct Surface: Equatable, Sendable {
        /// `provider`, `endpoint`, `streaming`, `auth`, `billing`, `gateway`, `disk` or `runtime`.
        var layer: String?
        /// The failure reason, such as `rate_limit` or `context_overflow`.
        var code: String?
        var retryable: Bool?
        var provider: String?
        /// When a rate limit lifts, if the provider said.
        var resetsAt: Date?
        /// The host's own sentence for the failure (sent for `free_tier_*` codes).
        var message: String?
    }

    /// The host's raw error text; nil on a turn that did not fail.
    var error: String?
    var surface: Surface?
    /// True on every failure the host retains; the retry verdict for a host without a surface.
    var recoverable: Bool?
    /// The provider's billing page, only as an `https` URL (`message.complete` only).
    var billingURL: URL?
    /// The classified reason sent with a billing wall (`message.complete` only).
    var failureReason: String?
    /// A free-form host warning, such as a reply that was shown but not saved
    /// (`message.complete` only). It can arrive on a successful turn.
    var warning: String?

    /// The failure `session.resume` retains until the next turn starts or the session
    /// closes. Nil when `inflight` carries no error, as after a success or a Stop.
    init?(inflight: BotJSON) {
        guard inflight["error"] != .null else { return nil }
        self.init(failure: inflight)
    }

    /// A `message.complete` payload. Nil when it carries nothing beyond the reply,
    /// which is every ordinary turn.
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

    /// Whether retrying unchanged can help: the host's own verdict, or, from a host
    /// that sends no surface, whether it kept the failure as recoverable.
    var offersRetry: Bool { surface?.retryable ?? (recoverable == true) }

    private static func nonEmpty(_ value: BotJSON) -> String? {
        guard let text = value.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
