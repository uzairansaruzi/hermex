import Foundation

struct ChatStartResponse: Decodable, Equatable {
    let streamId: String?
    let sessionId: String?
    let pendingStartedAt: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case streamId
        case sessionId
        case pendingStartedAt
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamId = container.decodeLossyStringIfPresent(forKey: .streamId)
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
        pendingStartedAt = container.decodeLossyDoubleIfPresent(forKey: .pendingStartedAt)
        error = container.decodeLossyStringIfPresent(forKey: .error)
    }

    func runStartedAt(sentAt: Date) -> Date {
        guard let pendingStartedAt, pendingStartedAt > 0 else { return sentAt }
        return Date(timeIntervalSince1970: pendingStartedAt)
    }
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

struct RunJournalStatus: Decodable, Equatable {
    let terminal: Bool?
    let terminalState: String?
}

struct ChatSteerResponse: Decodable, Equatable {
    let accepted: Bool?
    let fallback: String?
    let streamId: String?
    let error: String?
}

enum ChatSteerOutcome {
    case delivered
    case serverQueued
    case runEnded
    case refused(transportError: Error?)
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
    let ttsVoice: String?
    let ttsEngine: String?

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
        case ttsVoice
        case ttsEngine
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
        ttsVoice = try? container.decode(String.self, forKey: .ttsVoice)
        ttsEngine = try? container.decode(String.self, forKey: .ttsEngine)
    }
}

struct DefaultModelResponse: Decodable, Equatable {
    let ok: Bool?
    let model: String?
}

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
    enum WebUIUpdateState: Equatable {
        case upToDate
        case updateAvailable(behind: Int)
        case unavailable
    }

    enum ForcedCheckOutcome: Equatable {
        case updateAvailable(behind: Int)
        case upToDate
        case disabled
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
    enum Outcome: Equatable {
        case applying
        case restartBlocked
        case failed
    }

    var outcome: Outcome {
        if restartBlocked == true {
            return .restartBlocked
        }

        if ok == true {
            return .applying
        }

        return .failed
    }

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
    let supportedEfforts: [String]?
    let supportsReasoningEffort: Bool?
    let error: String?

    var effectiveEffort: String? {
        reasoningEffort ?? effort
    }

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

enum ProfileNameRules {
    static func isValid(_ name: String) -> Bool {
        guard let first = name.first, name.count <= 64 else { return false }
        guard isLowercaseAlphanumeric(first) else { return false }
        return name.allSatisfy { isLowercaseAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isLowercaseAlphanumeric(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character)
    }

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
    let allModels: [ModelCatalogOption]

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
        var seen = Set<String>()
        self.allModels = (models + extraModels).filter { seen.insert($0.id).inserted }
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

struct ModelCatalogOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
    let providerID: String?
}

extension String {
    var bareModelID: String {
        guard hasPrefix("@"), let separator = lastIndex(of: ":") else { return self }
        return String(self[index(after: separator)...])
    }

    var modelIDProviderPrefix: String? {
        guard hasPrefix("@"), let separator = lastIndex(of: ":") else { return nil }
        let provider = self[index(after: startIndex)..<separator]
        return provider.isEmpty ? nil : String(provider)
    }
}

extension ModelCatalogOption {
    func matchesSelection(modelID: String?, providerID: String?) -> Bool {
        guard let modelID else { return false }

        let optionProvider = self.providerID ?? id.modelIDProviderPrefix
        let selectionProvider = providerID
            ?? optionProvider.flatMap { modelID.hasPrefix("@\($0):") ? $0 : nil }
            ?? modelID.modelIDProviderPrefix
        guard normalizedModelID(id, providerID: optionProvider)
                == normalizedModelID(modelID, providerID: selectionProvider)
        else { return false }

        guard let selectionProvider else {
            return id.modelIDProviderPrefix == nil
        }
        guard let optionProvider else { return false }
        return optionProvider == selectionProvider
    }

    private func normalizedModelID(_ modelID: String, providerID: String?) -> String {
        guard let providerID else { return modelID.bareModelID }
        let prefix = "@\(providerID):"
        guard modelID.hasPrefix(prefix) else { return modelID.bareModelID }
        return String(modelID.dropFirst(prefix.count))
    }
}

extension Collection where Element == ModelCatalogOption {
    func firstMatchingSelection(modelID: String?, providerID: String?) -> ModelCatalogOption? {
        guard let modelID, !modelID.isEmpty else { return nil }

        if let exact = first(where: { $0.id == modelID && (providerID == nil || $0.providerID == providerID) }) {
            return exact
        }

        return first { $0.matchesSelection(modelID: modelID, providerID: providerID) }
    }
}

extension ModelsResponse {
    var catalogGroups: [ModelCatalogGroup] {
        ModelCatalogParser.parseGroups(from: self)
    }

    func displayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        return catalogGroups
            .flatMap(\.allModels)
            .first(where: { $0.id == modelID })?
            .displayName
    }
}

struct ModelsLiveResponse: Decodable, Equatable {
    let provider: String?
    let models: [JSONValue]?
    let count: Int?
}

extension ModelsLiveResponse {
    var normalizedProvider: String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    var liveOptions: [ModelCatalogOption] {
        guard let models else { return [] }
        return ModelCatalogParser.parseModelOptions(
            from: .array(models),
            providerID: normalizedProvider
        )
    }
}

extension Array where Element == ModelCatalogGroup {
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
