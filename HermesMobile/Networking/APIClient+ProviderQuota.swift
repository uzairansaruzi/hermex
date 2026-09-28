import Foundation

/// `GET /api/provider/quota?provider=<id>` — one provider's subscription limits
/// or prepaid credits (#415). Shape verified against the live server on
/// 2026-09-05 and upstream `api/providers.py` (`get_provider_quota`,
/// `_serialize_account_usage_snapshot`, `_sanitize_openrouter_quota`).
///
/// The handler answers with one of two payload families and never fails the
/// request: OAuth-backed providers carry `account_limits` (Codex, Anthropic),
/// OpenRouter carries `quota`, and everything else answers with a non-`available`
/// `status` and both null. `status` values seen live: `available`, `unsupported`,
/// `unavailable`, `no_key`, `invalid_key`. Every field is optional so a partial
/// or future payload decodes instead of throwing, and `pool` — the per-credential
/// breakdown Hermex deliberately does not show — is ignored.
struct ProviderQuotaResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let provider: String?
    let displayName: String?
    let supported: Bool?
    let status: String?
    let label: String?
    let message: String?
    let quota: ProviderQuotaCredits?
    let accountLimits: ProviderAccountLimits?

    enum CodingKeys: String, CodingKey {
        case ok
        case provider
        case displayName
        case supported
        case status
        case label
        case message
        case quota
        case accountLimits
    }

    init(
        ok: Bool? = nil,
        provider: String? = nil,
        displayName: String? = nil,
        supported: Bool? = nil,
        status: String? = nil,
        label: String? = nil,
        message: String? = nil,
        quota: ProviderQuotaCredits? = nil,
        accountLimits: ProviderAccountLimits? = nil
    ) {
        self.ok = ok
        self.provider = provider
        self.displayName = displayName
        self.supported = supported
        self.status = status
        self.label = label
        self.message = message
        self.quota = quota
        self.accountLimits = accountLimits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        provider = container.decodeLossyStringIfPresent(forKey: .provider)
        displayName = container.decodeLossyStringIfPresent(forKey: .displayName)
        supported = container.decodeLossyBoolIfPresent(forKey: .supported)
        status = container.decodeLossyStringIfPresent(forKey: .status)
        label = container.decodeLossyStringIfPresent(forKey: .label)
        message = container.decodeLossyStringIfPresent(forKey: .message)
        quota = (try? container.decodeIfPresent(ProviderQuotaCredits.self, forKey: .quota)) ?? nil
        accountLimits = (try? container.decodeIfPresent(ProviderAccountLimits.self, forKey: .accountLimits)) ?? nil
    }
}

/// The OpenRouter credits family. All three numbers are null when the key has no
/// spending cap, so a card renders from whichever ones arrived.
struct ProviderQuotaCredits: Decodable, Equatable, Sendable {
    let limitRemaining: Double?
    let usage: Double?
    let limit: Double?

    enum CodingKeys: String, CodingKey {
        case limitRemaining
        case usage
        case limit
    }

    init(limitRemaining: Double? = nil, usage: Double? = nil, limit: Double? = nil) {
        self.limitRemaining = limitRemaining
        self.usage = usage
        self.limit = limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitRemaining = container.decodeLossyDoubleIfPresent(forKey: .limitRemaining)
        usage = container.decodeLossyDoubleIfPresent(forKey: .usage)
        limit = container.decodeLossyDoubleIfPresent(forKey: .limit)
    }
}

/// The account-limits family (`openai-codex`, `anthropic`). `available` is false
/// whenever upstream attached an `unavailable_reason`, and `windows` is empty
/// when the probe found nothing to report — both hide the card.
struct ProviderAccountLimits: Decodable, Equatable, Sendable {
    let plan: String?
    let title: String?
    let available: Bool?
    let unavailableReason: String?
    let fetchedAt: String?
    let windows: [ProviderQuotaWindow]?
    let details: [String]?

    enum CodingKeys: String, CodingKey {
        case plan
        case title
        case available
        case unavailableReason
        case fetchedAt
        case windows
        case details
    }

    init(
        plan: String? = nil,
        title: String? = nil,
        available: Bool? = nil,
        unavailableReason: String? = nil,
        fetchedAt: String? = nil,
        windows: [ProviderQuotaWindow]? = nil,
        details: [String]? = nil
    ) {
        self.plan = plan
        self.title = title
        self.available = available
        self.unavailableReason = unavailableReason
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.details = details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = container.decodeLossyStringIfPresent(forKey: .plan)
        title = container.decodeLossyStringIfPresent(forKey: .title)
        available = container.decodeLossyBoolIfPresent(forKey: .available)
        unavailableReason = container.decodeLossyStringIfPresent(forKey: .unavailableReason)
        fetchedAt = container.decodeLossyStringIfPresent(forKey: .fetchedAt)
        windows = (try? container.decodeIfPresent([ProviderQuotaWindow].self, forKey: .windows)) ?? nil
        details = (try? container.decodeIfPresent([String].self, forKey: .details)) ?? nil
    }
}

/// One rate-limit window. `remaining_percent` is null whenever upstream could not
/// read `used_percent`, which is why the bar is optional and the row still shows
/// its label and reset time.
struct ProviderQuotaWindow: Decodable, Equatable, Sendable {
    let label: String?
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetAt: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case label
        case usedPercent
        case remainingPercent
        case resetAt
        case detail
    }

    init(
        label: String? = nil,
        usedPercent: Double? = nil,
        remainingPercent: Double? = nil,
        resetAt: String? = nil,
        detail: String? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.decodeLossyStringIfPresent(forKey: .label)
        usedPercent = container.decodeLossyDoubleIfPresent(forKey: .usedPercent)
        remainingPercent = container.decodeLossyDoubleIfPresent(forKey: .remainingPercent)
        resetAt = container.decodeLossyStringIfPresent(forKey: .resetAt)
        detail = container.decodeLossyStringIfPresent(forKey: .detail)
    }
}

extension APIClient {
    /// Reads one provider's quota. Pass `refresh: true` only from an explicit
    /// user gesture — it bypasses the server's 45 s cache and re-probes the
    /// upstream account, which can take several seconds.
    func providerQuota(provider: String, refresh: Bool = false) async throws -> ProviderQuotaResponse {
        try await send(endpoint: .providerQuota(provider: provider, refresh: refresh), method: "GET")
    }
}
