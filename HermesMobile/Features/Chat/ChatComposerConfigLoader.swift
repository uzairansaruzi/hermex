import Foundation

struct ChatComposerConfigState: Equatable, Sendable {
    var currentWorkspace: String?
    var currentModel: String?
    var currentModelProvider: String?
    var currentProfile: String?
    var selectedProfileName: String?
    var selectedReasoningEffort: String?
    /// Model-aware effort vocabulary (`supported_efforts`); `nil` on older
    /// servers → composer falls back to the full static list (issue #18).
    var supportedReasoningEfforts: [String]?
    /// `supports_reasoning_effort`; `false` hides the effort control, `nil`
    /// (older servers) keeps it visible.
    var supportsReasoningEffort: Bool?
    var modelCatalogGroups: [ModelCatalogGroup]
    var agentCommands: [AgentCommand]
    var workspaceRoots: [WorkspaceRoot]
    var workspaceSuggestions: [String]
    var profileOptions: [ProfileSummary]
    var isSingleProfileMode: Bool

    init(
        currentWorkspace: String? = nil,
        currentModel: String? = nil,
        currentModelProvider: String? = nil,
        currentProfile: String? = nil,
        selectedProfileName: String? = nil,
        selectedReasoningEffort: String? = nil,
        supportedReasoningEfforts: [String]? = nil,
        supportsReasoningEffort: Bool? = nil,
        modelCatalogGroups: [ModelCatalogGroup] = [],
        agentCommands: [AgentCommand] = [],
        workspaceRoots: [WorkspaceRoot] = [],
        workspaceSuggestions: [String] = [],
        profileOptions: [ProfileSummary] = [],
        isSingleProfileMode: Bool = false
    ) {
        self.currentWorkspace = currentWorkspace
        self.currentModel = currentModel
        self.currentModelProvider = currentModelProvider
        self.currentProfile = currentProfile
        self.selectedProfileName = selectedProfileName
        self.selectedReasoningEffort = selectedReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsReasoningEffort = supportsReasoningEffort
        self.modelCatalogGroups = modelCatalogGroups
        self.agentCommands = agentCommands
        self.workspaceRoots = workspaceRoots
        self.workspaceSuggestions = workspaceSuggestions
        self.profileOptions = profileOptions
        self.isSingleProfileMode = isSingleProfileMode
    }
}

struct ChatComposerConfigLoadResult: Sendable {
    let state: ChatComposerConfigState
    let configurationError: Error?
}

/// Seeds the loader with a just-completed profile switch so the client skips
/// the redundant `/api/profiles` (+ possible re-switch) round trip.
struct ChatComposerProfileSeed: Sendable, Equatable {
    let profiles: [ProfileSummary]?
    let active: String?
    let defaultModel: String?
    let defaultWorkspace: String?
    /// Carried forward because switch responses omit `single_profile_mode`.
    let isSingleProfileMode: Bool

    init(
        profiles: [ProfileSummary]?,
        active: String?,
        defaultModel: String? = nil,
        defaultWorkspace: String? = nil,
        isSingleProfileMode: Bool = false
    ) {
        self.profiles = profiles
        self.active = active
        self.defaultModel = defaultModel
        self.defaultWorkspace = defaultWorkspace
        self.isSingleProfileMode = isSingleProfileMode
    }

    init(
        switchResponse: ProfileSwitchResponse,
        isSingleProfileMode: Bool,
        fallbackProfiles: [ProfileSummary] = []
    ) {
        self.profiles = switchResponse.profiles ?? fallbackProfiles
        self.active = switchResponse.active
        self.defaultModel = switchResponse.defaultModel
        self.defaultWorkspace = switchResponse.defaultWorkspace
        self.isSingleProfileMode = isSingleProfileMode
    }
}

/// One-shot handoff so a replacement ChatView created after an empty-chat
/// profile switch can skip `/api/profiles` the same way the in-place path does.
/// Keyed by the full server URL (scheme + host + port + path) AND the
/// replacement session id, 5s TTL, consumed exactly once. Another chat on
/// the same server cannot take this seed; foreign lookups never wipe it.
enum RecentProfileSwitchSeed {
    private static let lock = NSLock()
    private static var entries: [String: (seed: ChatComposerProfileSeed, expires: Date)] = [:]

    /// Match multi-server identity: scheme/host/port matter; trailing slash does not.
    private static func serverKey(for server: URL) -> String {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.fragment = nil
        components.query = nil
        let path = components.path
        if path.count > 1, path.hasSuffix("/") {
            components.path = String(path.dropLast())
        }
        let normalized = components.url?.absoluteString ?? server.absoluteString
        return normalized.lowercased()
    }

    private static func entryKey(for server: URL, sessionID: String) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return serverKey(for: server) + "\u{1e}" + trimmed
    }

    static func store(_ seed: ChatComposerProfileSeed, for server: URL, sessionID: String) {
        lock.withLock {
            guard let key = entryKey(for: server, sessionID: sessionID) else { return }
            entries[key] = (seed, Date().addingTimeInterval(5))
        }
    }

    static func take(for server: URL, sessionID: String?) -> ChatComposerProfileSeed? {
        lock.withLock {
            guard let sessionID, let key = entryKey(for: server, sessionID: sessionID) else {
                return nil
            }
            guard let current = entries[key] else { return nil }
            entries[key] = nil
            guard current.expires > Date() else { return nil }
            return current.seed
        }
    }

    static func discard(for server: URL, sessionID: String?) {
        lock.withLock {
            guard let sessionID, let key = entryKey(for: server, sessionID: sessionID) else {
                return
            }
            entries[key] = nil
        }
    }

    /// Test hook: drop every pending seed without consuming one as a load.
    static func resetForTests() {
        lock.withLock { entries.removeAll() }
    }
}

struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func loadConfiguration(
        from initialState: ChatComposerConfigState,
        profileSeed: ChatComposerProfileSeed? = nil
    ) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?

        do {
            try await resolveProfiles(into: &state, profileSeed: profileSeed)

            let selectedProfile = Self.profileSummary(
                matching: state.selectedProfileName,
                in: state.profileOptions
            )
            if state.currentModel == nil {
                state.currentModel = Self.nonEmpty(selectedProfile?.model)
            }
            if Self.nonEmpty(state.currentModelProvider) == nil {
                state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
            }

            // Profile resolution is the only serial dependency. Models,
            // workspaces, commands, and reasoning (when the model is already
            // known from the profile/seed) run as one concurrent wave so a
            // profile switch pays roughly one network RTT instead of four.
            let seededModel = Self.nonEmpty(state.currentModel)
            let seededProvider = Self.nonEmpty(state.currentModelProvider)

            async let modelsOutcome = fetchModels()
            async let workspacesOutcome = fetchWorkspaces()
            async let commandsOutcome = fetchCommands()
            async let earlyReasoningOutcome = fetchReasoningIfModelKnown(
                model: seededModel,
                provider: seededProvider
            )

            let models = await modelsOutcome
            let workspaces = await workspacesOutcome
            let commands = await commandsOutcome
            let earlyReasoning = await earlyReasoningOutcome

            switch models {
            case .success(let modelsResponse):
                state.modelCatalogGroups = modelsResponse.catalogGroups
                if state.currentModel == nil {
                    state.currentModel = modelsResponse.defaultModel
                }
                if Self.nonEmpty(state.currentModelProvider) == nil {
                    state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
                        ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
                }
            case .failure(let error):
                configurationError = Self.preferredConfigurationError(
                    existing: configurationError,
                    incoming: error
                )
            }

            switch workspaces {
            case .success(let workspaceResponse):
                state.workspaceRoots = workspaceResponse.workspaces ?? []
                if state.currentWorkspace == nil {
                    state.currentWorkspace = workspaceResponse.last
                        ?? state.workspaceRoots.compactMap(\.path).first
                }
                state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
            case .failure(let error):
                configurationError = Self.preferredConfigurationError(
                    existing: configurationError,
                    incoming: error
                )
            }

            switch commands {
            case .success(let commandsResponse):
                state.agentCommands = commandsResponse.commands ?? []
            case .failure:
                // Commands stay best-effort, matching the previous loader.
                state.agentCommands = []
            }

            // Scope the query to the session's resolved model/provider so the
            // gating fields are model-accurate (issue #18); the seeded effort is
            // the server's already-coerced value for that model.
            let resolvedModel = Self.nonEmpty(state.currentModel)
            let resolvedProvider = Self.nonEmpty(state.currentModelProvider)
            let reasoning: Result<ReasoningStatusResponse, Error>?
            if let earlyReasoning,
               seededModel == resolvedModel,
               seededProvider == resolvedProvider {
                reasoning = earlyReasoning
            } else if resolvedModel != nil || resolvedProvider != nil {
                // Model only became known after `/api/models`, or the catalog
                // changed the provider pairing — fetch with the final pair.
                reasoning = await fetchReasoning(model: resolvedModel, provider: resolvedProvider)
                // Keep an early-wave 401 only when that replacement also fails,
                // so AuthManager still sees expiry. Speculative non-auth errors
                // (unscoped request → 4xx/5xx) must not remain after success.
                if case .failure(_) = reasoning,
                   case .failure(let earlyError)? = earlyReasoning,
                   case .unauthorized = earlyError as? APIError {
                    configurationError = Self.preferredConfigurationError(
                        existing: configurationError,
                        incoming: earlyError
                    )
                }
            } else {
                reasoning = earlyReasoning
            }

            if let reasoning {
                switch reasoning {
                case .success(let reasoningResponse):
                    state.selectedReasoningEffort = reasoningResponse.effectiveEffort
                    state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
                    state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort
                case .failure(let error):
                    configurationError = Self.preferredConfigurationError(
                        existing: configurationError,
                        incoming: error
                    )
                }
            }
        } catch {
            configurationError = error
            // Still try commands on the profiles-only failure path so slash
            // metadata can land even when profile resolution fails mid-flight.
            if state.agentCommands.isEmpty {
                if case .success(let commandsResponse) = await fetchCommands() {
                    state.agentCommands = commandsResponse.commands ?? []
                } else {
                    state.agentCommands = []
                }
            }
        }

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError
        )
    }

    private func resolveProfiles(
        into state: inout ChatComposerConfigState,
        profileSeed: ChatComposerProfileSeed?
    ) async throws {
        if let profileSeed {
            state.profileOptions = profileSeed.profiles ?? state.profileOptions
            state.isSingleProfileMode = profileSeed.isSingleProfileMode
            state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                ?? Self.nonEmpty(profileSeed.active)
                ?? state.selectedProfileName
                ?? state.profileOptions.first?.normalizedName
            state.currentProfile = state.selectedProfileName

            if state.currentWorkspace == nil {
                state.currentWorkspace = Self.nonEmpty(profileSeed.defaultWorkspace)
            }
            if state.currentModel == nil {
                state.currentModel = Self.nonEmpty(profileSeed.defaultModel)
            }
            return
        }

        let profilesResponse = try await client.profiles()
        state.profileOptions = profilesResponse.profiles ?? []
        state.isSingleProfileMode = profilesResponse.singleProfileMode ?? false
        state.selectedProfileName = Self.nonEmpty(state.currentProfile)
            ?? Self.nonEmpty(profilesResponse.active)
            ?? profilesResponse.effectiveDefaultProfileName

        if let sessionProfile = Self.nonEmpty(state.currentProfile),
           Self.nonEmpty(profilesResponse.active) != sessionProfile {
            let switchResponse = try await client.switchProfile(name: sessionProfile)
            state.profileOptions = switchResponse.profiles ?? state.profileOptions
            state.selectedProfileName = Self.nonEmpty(switchResponse.active) ?? sessionProfile
            state.currentProfile = state.selectedProfileName

            if state.currentWorkspace == nil {
                state.currentWorkspace = Self.nonEmpty(switchResponse.defaultWorkspace)
            }

            if state.currentModel == nil {
                state.currentModel = Self.nonEmpty(switchResponse.defaultModel)
            }
        }
    }

    private func fetchModels() async -> Result<ModelsResponse, Error> {
        do {
            return .success(try await client.models())
        } catch {
            return .failure(error)
        }
    }

    private func fetchWorkspaces() async -> Result<WorkspacesResponse, Error> {
        do {
            return .success(try await client.workspaces())
        } catch {
            return .failure(error)
        }
    }

    private func fetchCommands() async -> Result<CommandsResponse, Error> {
        do {
            return .success(try await client.commands())
        } catch {
            return .failure(error)
        }
    }

    private func fetchReasoning(
        model: String?,
        provider: String?
    ) async -> Result<ReasoningStatusResponse, Error> {
        do {
            return .success(try await client.reasoning(model: model, provider: provider))
        } catch {
            return .failure(error)
        }
    }

    private func fetchReasoningIfModelKnown(
        model: String?,
        provider: String?
    ) async -> Result<ReasoningStatusResponse, Error>? {
        guard model != nil || provider != nil else { return nil }
        return await fetchReasoning(model: model, provider: provider)
    }

    private static func preferredConfigurationError(existing: Error?, incoming: Error) -> Error {
        // Parallel wave can return several failures. Auth expiry must win so
        // AuthManager.handleAPIError still signs the user out.
        if let existing, case .unauthorized = existing as? APIError {
            return existing
        }
        if case .unauthorized = incoming as? APIError {
            return incoming
        }
        return existing ?? incoming
    }

    private static func profileSummary(
        matching profileName: String?,
        in profileOptions: [ProfileSummary]
    ) -> ProfileSummary? {
        guard let profileName = nonEmpty(profileName) else { return nil }
        return profileOptions.first { $0.normalizedName == profileName }
    }

    private static func uniqueProvider(
        for modelID: String?,
        in groups: [ModelCatalogGroup]
    ) -> String? {
        guard let modelID = nonEmpty(modelID) else { return nil }
        let providers = Set(
            groups
                .flatMap(\.allModels)
                .filter { $0.id == modelID }
                .compactMap { nonEmpty($0.providerID) }
        )
        return providers.count == 1 ? providers.first : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
