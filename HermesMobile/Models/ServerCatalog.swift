import Foundation

struct ChatStartResponse: Decodable, Equatable {
    let streamId: String?
    let sessionId: String?
    let error: String?
}

struct ChatCancelResponse: Decodable, Equatable {
    let ok: Bool?
    let cancelled: Bool?
    let streamId: String?
    let error: String?
}

struct ChatStreamStatusResponse: Decodable, Equatable {
    let active: Bool?
    let streamId: String?
    let replayAvailable: Bool?
    let journal: RunJournalStatus?
}

/// The server's run-journal summary, surfaced on `/api/chat/stream/status` so a
/// reconciled Live Activity can be finalized with the run's real outcome (#267).
/// Every field is optional: the `journal` block is absent when the server has no
/// summary for a stream, and `terminalState`'s vocabulary may grow upstream — so
/// we decode tolerantly and never crash on an unknown value.
struct RunJournalStatus: Decodable, Equatable {
    /// Whether the server logged a genuine terminal event for the run. Decoded to
    /// mirror the journal payload shape (#267 acceptance criterion named both
    /// fields); outcome mapping reads `terminalState` only. Kept because it is not
    /// redundant with `terminalState`: a run the server force-marks
    /// `"lost-worker-bookkeeping"` reports `terminal == false`, so this stays
    /// available for any future consumer that must tell a real terminal event from
    /// a bookkeeping one.
    let terminal: Bool?
    let terminalState: String?
}

struct ChatSteerResponse: Decodable, Equatable {
    let accepted: Bool?
    let fallback: String?
    let streamId: String?
    let error: String?
}

struct BtwStartResponse: Decodable, Equatable {
    let streamId: String?
    let sessionId: String?
    let parentSessionId: String?
    let error: String?
}

struct BackgroundStartResponse: Decodable, Equatable {
    let taskId: String?
    let streamId: String?
    let sessionId: String?
    let error: String?
}

struct BackgroundStatusResponse: Decodable, Equatable {
    let results: [BackgroundResult]?
}

struct BackgroundResult: Decodable, Equatable {
    let taskId: String?
    let prompt: String?
    let answer: String?
    let completedAt: Double?
}

struct ModelsResponse: Decodable, Equatable {
    let groups: [JSONValue]?
    let models: [JSONValue]?
    let defaultModel: String?
    let activeProvider: String?
}

struct CommandsResponse: Decodable, Equatable {
    let commands: [AgentCommand]?
}

struct AgentCommand: Decodable, Equatable, Identifiable, Sendable {
    var id: String { name ?? UUID().uuidString }

    let name: String?
    let description: String?
    let category: String?
    let aliases: [String]?
    let argsHint: String?
    let subcommands: [String]?
    let cliOnly: Bool?
    let gatewayOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case category
        case aliases
        case argsHint
        case subcommands
        case cliOnly
        case gatewayOnly
    }

    init(
        name: String?,
        description: String? = nil,
        category: String? = nil,
        aliases: [String]? = nil,
        argsHint: String? = nil,
        subcommands: [String]? = nil,
        cliOnly: Bool? = nil,
        gatewayOnly: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.aliases = aliases
        self.argsHint = argsHint
        self.subcommands = subcommands
        self.cliOnly = cliOnly
        self.gatewayOnly = gatewayOnly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        description = container.decodeLossyStringIfPresent(forKey: .description)
        category = container.decodeLossyStringIfPresent(forKey: .category)
        aliases = try? container.decodeIfPresent([String].self, forKey: .aliases)
        argsHint = container.decodeLossyStringIfPresent(forKey: .argsHint)
        subcommands = try? container.decodeIfPresent([String].self, forKey: .subcommands)
        cliOnly = container.decodeLossyBoolIfPresent(forKey: .cliOnly)
        gatewayOnly = container.decodeLossyBoolIfPresent(forKey: .gatewayOnly)
    }
}

/// `GET /api/providers` — read-only provider status (#26). Shape verified against
/// the live server (2026-07-02) and upstream `api/providers.py::get_providers()`
/// @ `312d3fab`: standard entries carry the full field set, while entries derived
/// from `custom_providers` in config.yaml (`is_custom == true`) omit `is_oauth`,
/// `auth_error`, `is_self_hosted`, `base_url`, and `is_plugin_provider` — so every
/// field stays optional and decoding never fails on a partial entry.
struct ProvidersResponse: Decodable, Equatable {
    let providers: [ProviderSummary]?
    let activeProvider: String?

    init(providers: [ProviderSummary]?, activeProvider: String?) {
        self.providers = providers
        self.activeProvider = activeProvider
    }

    enum CodingKeys: String, CodingKey {
        case providers
        case activeProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = try? container.decodeIfPresent([ProviderSummary].self, forKey: .providers)
        activeProvider = container.decodeLossyStringIfPresent(forKey: .activeProvider)
    }
}

/// One provider entry from `GET /api/providers`. `keySource` vocabulary upstream:
/// `env_file`, `env_var`, `config_yaml`, `oauth`, `none` — plus `env`, `config`,
/// and `token` from the live-auth fallback probe. Unknown values are kept verbatim.
struct ProviderSummary: Decodable, Equatable, Sendable {
    let id: String?
    let displayName: String?
    let hasKey: Bool?
    let configurable: Bool?
    let isSelfHosted: Bool?
    let baseUrl: String?
    let isPluginProvider: Bool?
    let isOauth: Bool?
    let isCustom: Bool?
    let keySource: String?
    let authError: String?
    let models: [ProviderModel]?
    /// Size of the provider's complete catalog. May exceed `models.count` when the
    /// server trims the list to a featured subset (e.g. large Nous Portal accounts).
    let modelsTotal: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case hasKey
        case configurable
        case isSelfHosted
        case baseUrl
        case isPluginProvider
        case isOauth
        case isCustom
        case keySource
        case authError
        case models
        case modelsTotal
    }

    init(
        id: String?,
        displayName: String? = nil,
        hasKey: Bool? = nil,
        configurable: Bool? = nil,
        isSelfHosted: Bool? = nil,
        baseUrl: String? = nil,
        isPluginProvider: Bool? = nil,
        isOauth: Bool? = nil,
        isCustom: Bool? = nil,
        keySource: String? = nil,
        authError: String? = nil,
        models: [ProviderModel]? = nil,
        modelsTotal: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hasKey = hasKey
        self.configurable = configurable
        self.isSelfHosted = isSelfHosted
        self.baseUrl = baseUrl
        self.isPluginProvider = isPluginProvider
        self.isOauth = isOauth
        self.isCustom = isCustom
        self.keySource = keySource
        self.authError = authError
        self.models = models
        self.modelsTotal = modelsTotal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        displayName = container.decodeLossyStringIfPresent(forKey: .displayName)
        hasKey = container.decodeLossyBoolIfPresent(forKey: .hasKey)
        configurable = container.decodeLossyBoolIfPresent(forKey: .configurable)
        isSelfHosted = container.decodeLossyBoolIfPresent(forKey: .isSelfHosted)
        baseUrl = container.decodeLossyStringIfPresent(forKey: .baseUrl)
        isPluginProvider = container.decodeLossyBoolIfPresent(forKey: .isPluginProvider)
        isOauth = container.decodeLossyBoolIfPresent(forKey: .isOauth)
        isCustom = container.decodeLossyBoolIfPresent(forKey: .isCustom)
        keySource = container.decodeLossyStringIfPresent(forKey: .keySource)
        authError = container.decodeLossyStringIfPresent(forKey: .authError)
        models = try? container.decodeIfPresent([ProviderModel].self, forKey: .models)
        modelsTotal = container.decodeLossyIntIfPresent(forKey: .modelsTotal)
    }
}

/// A model entry inside a provider's `models` list. Upstream normally emits
/// `{ "id": …, "label": … }` objects, but the docs historically described bare
/// model-ID strings — both shapes decode.
struct ProviderModel: Decodable, Equatable, Sendable {
    let id: String?
    let label: String?

    init(id: String?, label: String? = nil) {
        self.id = id
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let raw = try? single.decode(String.self) {
            id = raw
            label = raw
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        label = container.decodeLossyStringIfPresent(forKey: .label)
    }
}

/// `GET /api/settings` (the saved-settings body `POST /api/settings` echoes the
/// same shape back). The server returns ~75 keys; we decode only the ones with
/// a consumer or near-term use (#19). Every field is optional and lossy-decoded
/// — servers omit keys freely and we never crash on an unexpected shape.
struct SettingsResponse: Decodable, Equatable {
    let botName: String?
    let webuiVersion: String?
    let agentVersion: String?
    let theme: String?
    let checkForUpdates: Bool?
    let showCliSessions: Bool?
    let showClaudeCodeSessions: Bool?
    let maxTokens: Int?
    let maxTokensEffective: Int?
    let authEnabled: Bool?
    let passwordAuthEnabled: Bool?
    let passkeysEnabled: Bool?
    let passwordlessEnabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case botName
        case webuiVersion
        case agentVersion
        case theme
        case checkForUpdates
        case showCliSessions
        case showClaudeCodeSessions
        case maxTokens
        case maxTokensEffective
        case authEnabled
        case passwordAuthEnabled
        case passkeysEnabled
        case passwordlessEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        botName = container.decodeLossyStringIfPresent(forKey: .botName)
        webuiVersion = container.decodeLossyStringIfPresent(forKey: .webuiVersion)
        agentVersion = container.decodeLossyStringIfPresent(forKey: .agentVersion)
        theme = container.decodeLossyStringIfPresent(forKey: .theme)
        checkForUpdates = container.decodeLossyBoolIfPresent(forKey: .checkForUpdates)
        showCliSessions = container.decodeLossyBoolIfPresent(forKey: .showCliSessions)
        showClaudeCodeSessions = container.decodeLossyBoolIfPresent(forKey: .showClaudeCodeSessions)
        maxTokens = container.decodeLossyIntIfPresent(forKey: .maxTokens)
        maxTokensEffective = container.decodeLossyIntIfPresent(forKey: .maxTokensEffective)
        authEnabled = container.decodeLossyBoolIfPresent(forKey: .authEnabled)
        passwordAuthEnabled = container.decodeLossyBoolIfPresent(forKey: .passwordAuthEnabled)
        passkeysEnabled = container.decodeLossyBoolIfPresent(forKey: .passkeysEnabled)
        passwordlessEnabled = container.decodeLossyBoolIfPresent(forKey: .passwordlessEnabled)
    }
}

struct DefaultModelResponse: Decodable, Equatable {
    let ok: Bool?
    let model: String?
}

/// `GET /api/updates/check`. Every field is optional: older servers, the
/// `{ "disabled": true }` opt-out payload, and failed/`stale_check` responses
/// all omit different keys, and we never crash on a shape we don't expect.
struct UpdatesCheckResponse: Decodable, Equatable {
    let webui: UpdateTargetInfo?
    let agent: UpdateTargetInfo?
    let checkedAt: Double?
    let disabled: Bool?
}

struct UpdateTargetInfo: Decodable, Equatable {
    let name: String?
    let behind: Int?
    let currentSha: String?
    let latestSha: String?
    let branch: String?
    let repoUrl: String?
    let compareUrl: String?
    let error: String?
    let staleCheck: Bool?
}

extension UpdatesCheckResponse {
    /// What the Settings screen should show for the webui repo. `.unavailable`
    /// means "show the version only, no indicator" — the server turned the check
    /// off, errored, returned a stale result, or omitted the webui block.
    enum WebUIUpdateState: Equatable {
        case upToDate
        case updateAvailable(behind: Int)
        case unavailable
    }

    /// The fully-distinguished result of a *manual* (forced) update check (#308).
    /// Unlike `webuiUpdateState`, this keeps `disabled` and `error` apart so the
    /// "Check for updates" popup can word each case for the user — the passive
    /// inline note treats both as "no indicator" and collapses them together.
    enum ForcedCheckOutcome: Equatable {
        case updateAvailable(behind: Int)
        case upToDate
        /// Update checks are turned off on this server (`{ "disabled": true }`).
        case disabled
        /// The check failed, returned a stale result, or omitted the webui block.
        case error
    }

    var forcedCheckOutcome: ForcedCheckOutcome {
        if disabled == true {
            return .disabled
        }

        guard let webui else {
            return .error
        }

        if webui.error != nil || webui.staleCheck == true {
            return .error
        }

        if let behind = webui.behind, behind > 0 {
            return .updateAvailable(behind: behind)
        }

        return .upToDate
    }

    /// The passive inline indicator's coarser view of the same check. Derived from
    /// `forcedCheckOutcome` so the two never drift: both "off" and "errored"
    /// collapse to `.unavailable` (show the version only, with no indicator).
    var webuiUpdateState: WebUIUpdateState {
        switch forcedCheckOutcome {
        case let .updateAvailable(behind):
            return .updateAvailable(behind: behind)
        case .upToDate:
            return .upToDate
        case .disabled, .error:
            return .unavailable
        }
    }
}

/// `POST /api/updates/apply`. Tolerant: every field is optional because the
/// server returns a different mix of keys per outcome — success (`ok`,
/// `restart_scheduled`), restart-blocked (`restart_blocked` + active counts),
/// merge conflict (`conflict`), diverged history (`diverged`), or a generic
/// failure — and may add more over time. We never crash on an unexpected shape.
struct UpdatesApplyResponse: Decodable, Equatable {
    let ok: Bool?
    let message: String?
    let target: String?
    let conflict: Bool?
    let diverged: Bool?
    let restartBlocked: Bool?
    let restartScheduled: Bool?
    let stashConflict: Bool?
    let activeStreams: Int?
    let activeRuns: Int?
}

extension UpdatesApplyResponse {
    /// How the Settings screen should react to an apply attempt.
    enum Outcome: Equatable {
        /// Server accepted the update and is restarting; poll until it returns.
        case applying
        /// Active chat/agent work blocked the restart. Not a failure — surface
        /// the server's message and let the user retry once work finishes.
        case restartBlocked
        /// The update could not be applied (merge conflict, diverged history,
        /// unreachable remote, or a generic `ok: false`).
        case failed
    }

    var outcome: Outcome {
        // A restart-blocked response always carries `ok: false`, so check the
        // blocked flag first to avoid mislabelling it as a hard failure.
        if restartBlocked == true {
            return .restartBlocked
        }

        if ok == true {
            return .applying
        }

        return .failed
    }

    /// The server's human-readable message, or `fallback` when it omitted one.
    func displayMessage(default fallback: String) -> String {
        guard let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return fallback
        }

        return trimmed
    }
}

struct ReasoningStatusResponse: Decodable, Equatable {
    let ok: Bool?
    let showReasoning: Bool?
    let reasoningEffort: String?
    let effort: String?
    /// Model-aware effort vocabulary from `GET /api/reasoning` (`supported_efforts`).
    /// `nil` on older servers that don't send the field — callers must fall back
    /// to the static effort list (issue #18).
    let supportedEfforts: [String]?
    /// `supports_reasoning_effort` — `false` means the resolved model has no
    /// effort control at all (hide the picker). `nil` on older servers.
    let supportsReasoningEffort: Bool?
    let error: String?

    var effectiveEffort: String? {
        reasoningEffort ?? effort
    }

    /// `supported_efforts` trimmed, lowercased, de-duplicated, order preserved.
    /// Stays `nil` when the server omitted the field (legacy fallback signal).
    var normalizedSupportedEfforts: [String]? {
        guard let supportedEfforts else { return nil }
        var seen = Set<String>()
        return supportedEfforts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct PersonalitiesResponse: Decodable, Equatable {
    let personalities: [PersonalitySummary]?
}

extension PersonalitiesResponse {
    var slashAutocompleteNames: [String] {
        var seen = Set<String>()
        return (["none"] + (personalities ?? []).compactMap { personality in
            guard let name = personality.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return nil
            }

            return name
        })
        .filter { seen.insert($0).inserted }
    }
}

struct PersonalitySummary: Decodable, Equatable, Hashable, Identifiable {
    var id: String { name ?? UUID().uuidString }

    let name: String?
    let description: String?
}

struct PersonalitySetResponse: Decodable, Equatable {
    let ok: Bool?
    let personality: String?
    let prompt: String?
    let error: String?
}

struct ProfilesResponse: Decodable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let singleProfileMode: Bool?

    init(profiles: [ProfileSummary]?, active: String?, singleProfileMode: Bool? = nil) {
        self.profiles = profiles
        self.active = active
        self.singleProfileMode = singleProfileMode
    }
}

struct ProfileCreateResponse: Decodable, Equatable {
    let ok: Bool?
    let profile: ProfileSummary?
    let error: String?
}

/// Mirrors the upstream profile-name rule (`^[a-z0-9][a-z0-9_-]{0,63}$`) so the
/// create form can validate before hitting the server.
enum ProfileNameRules {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 64 else { return false }
        guard isLowercaseAlphanumeric(first) else { return false }
        return name.allSatisfy { isLowercaseAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isLowercaseAlphanumeric(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character)
    }

    /// Mirrors the upstream base-URL rule for profile creation: when provided,
    /// the value must start with `http://` or `https://` (server 400s otherwise).
    static func isValidBaseURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://")
    }
}

struct ProfileSwitchResponse: Decodable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let defaultModel: String?
    let defaultWorkspace: String?
    let error: String?
}

struct ProfileSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name ?? path ?? UUID().uuidString }

    let name: String?
    let path: String?
    let isDefault: Bool?
    let isActive: Bool?
    let gatewayRunning: Bool?
    let model: String?
    let provider: String?
    let hasEnv: Bool?
    let skillCount: Int?

    var displayName: String {
        guard let name, !name.isEmpty else { return String(localized: "Profile") }
        return name == "default" ? String(localized: "Default") : name
    }

    var normalizedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ProfilesResponse {
    var effectiveDefaultProfileName: String? {
        if let active = normalizedProfileName(active) {
            return active
        }

        if let activeProfile = profiles?.first(where: { $0.isActive == true })?.normalizedName {
            return activeProfile
        }

        if let defaultProfile = profiles?.first(where: { $0.isDefault == true })?.normalizedName {
            return defaultProfile
        }

        return profiles?.compactMap(\.normalizedName).first
    }

    func displayName(for profileName: String?) -> String? {
        guard let profileName = normalizedProfileName(profileName) else { return nil }

        return profile(matching: profileName)?.displayName
            ?? (profileName == "default" ? String(localized: "Default") : profileName)
    }

    func profile(matching profileName: String?) -> ProfileSummary? {
        guard let profileName = normalizedProfileName(profileName) else { return nil }
        return profiles?.first { $0.normalizedName == profileName }
    }

    private func normalizedProfileName(_ profileName: String?) -> String? {
        guard let profileName else { return nil }
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ModelCatalogGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let providerID: String?
    let models: [ModelCatalogOption]
    let extraModels: [ModelCatalogOption]

    init(
        id: String,
        name: String,
        providerID: String?,
        models: [ModelCatalogOption],
        extraModels: [ModelCatalogOption]
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.models = models
        self.extraModels = extraModels
    }

    init(
        id: String,
        name: String,
        providerID: String?,
        models: [ModelCatalogOption]
    ) {
        self.init(
            id: id,
            name: name,
            providerID: providerID,
            models: models,
            extraModels: []
        )
    }
}

extension ModelCatalogGroup {
    var slashAutocompleteModels: [ModelCatalogOption] {
        var seen = Set<String>()
        return (models + extraModels).filter { seen.insert($0.id).inserted }
    }
}

struct ModelCatalogOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let providerID: String?
}

extension ModelCatalogOption {
    func matchesSelection(modelID: String?, providerID: String?) -> Bool {
        guard id == modelID else { return false }
        guard let providerID else { return true }
        return self.providerID == providerID
    }
}

extension Collection where Element == ModelCatalogOption {
    func firstMatchingSelection(modelID: String?, providerID: String?) -> ModelCatalogOption? {
        guard let modelID, !modelID.isEmpty else { return nil }

        if let providerID {
            return first { $0.id == modelID && $0.providerID == providerID }
        }

        return first { $0.id == modelID }
    }
}

extension ModelsResponse {
    var catalogGroups: [ModelCatalogGroup] {
        ModelCatalogParser.parseGroups(from: self)
    }

    func displayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        return catalogGroups
            .flatMap(\.slashAutocompleteModels)
            .first(where: { $0.id == modelID })?
            .displayName
    }
}

/// Response of `GET /api/models/live`: the uncached model list for one provider.
/// Shape: `{"provider": "<id>", "models": [{"id", "label"}], "count": <int>}`;
/// the server echoes back the provider it resolved when none was requested.
struct ModelsLiveResponse: Decodable, Equatable {
    let provider: String?
    let models: [JSONValue]?
    let count: Int?
}

extension ModelsLiveResponse {
    /// Provider id with whitespace-only values normalized away.
    var normalizedProvider: String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Models parsed from the live payload, attributed to the echoed provider.
    var liveOptions: [ModelCatalogOption] {
        guard let models else { return [] }
        return ModelCatalogParser.parseModelOptions(
            from: .array(models),
            providerID: normalizedProvider
        )
    }
}

extension Array where Element == ModelCatalogGroup {
    /// Replaces the matching provider group's models with the live list (live is
    /// authoritative for that provider, covering both additions and removals).
    /// Returns `self` unchanged when the provider matches no group or the live
    /// list is empty, so an odd live response can never blank out the cached picker.
    func mergingLiveModels(from response: ModelsLiveResponse) -> [ModelCatalogGroup] {
        guard let provider = response.normalizedProvider else { return self }

        let liveModels = response.liveOptions
        guard !liveModels.isEmpty else { return self }

        return map { group in
            guard group.providerID == provider else { return group }
            return ModelCatalogGroup(
                id: group.id,
                name: group.name,
                providerID: group.providerID,
                models: liveModels,
                extraModels: group.extraModels
            )
        }
    }
}

private enum ModelCatalogParser {
    static func parseGroups(from response: ModelsResponse) -> [ModelCatalogGroup] {
        guard let groupValues = response.groups else { return [] }

        return groupValues.enumerated().compactMap { index, groupValue in
            guard case .object(let groupDict) = groupValue else { return nil }

            let providerID = stringValue(from: groupDict["provider_id"])
            let name = stringValue(from: groupDict["name"]) ?? providerID ?? String(localized: "Models")
            let models = parseModelOptions(from: groupDict["models"], providerID: providerID)
            let extraModels = parseModelOptions(from: groupDict["extra_models"], providerID: providerID)
            guard !models.isEmpty else { return nil }

            return ModelCatalogGroup(
                id: providerID ?? "\(name)-\(index)",
                name: name,
                providerID: providerID,
                models: models,
                extraModels: extraModels
            )
        }
    }

    static func parseModelOptions(from value: JSONValue?, providerID: String?) -> [ModelCatalogOption] {
        guard case .array(let items) = value else { return [] }

        return items.compactMap { item in
            guard case .object(let dict) = item else { return nil }

            let id = stringValue(from: dict["id"]) ?? ""
            guard !id.isEmpty else { return nil }

            let displayName = stringValue(from: dict["name"])
                ?? stringValue(from: dict["label"])
                ?? id
            let optionProviderID = stringValue(from: dict["provider_id"]) ?? providerID

            return ModelCatalogOption(
                id: id,
                displayName: displayName,
                providerID: optionProviderID
            )
        }
    }

    private static func stringValue(from value: JSONValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
