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

struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    /// Loads the composer's server config for a chat. Profiles (and a switch to
    /// the session's profile) go first because `/api/models` and
    /// `/api/workspaces` are profile-scoped upstream. After that, models,
    /// workspaces, and commands load concurrently; only reasoning waits, for the
    /// model it is scoped to. Errors keep the serial order's precedence
    /// (profiles, models, reasoning, workspaces), and commands load even when the
    /// rest fails.
    func loadConfiguration(from initialState: ChatComposerConfigState) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?

        do {
            try await resolveProfile(into: &state)
        } catch {
            configurationError = error
        }

        async let agentCommands = loadAgentCommands()
        if configurationError == nil {
            async let workspaceResponse = client.workspaces()
            do {
                try await loadModelAndReasoning(into: &state)
                applyWorkspaces(try await workspaceResponse, to: &state)
            } catch {
                configurationError = error
            }
        }
        state.agentCommands = await agentCommands

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError
        )
    }

    private func resolveProfile(into state: inout ChatComposerConfigState) async throws {
        let profilesResponse = try await client.profiles()
        state.profileOptions = profilesResponse.profiles ?? []
        state.isSingleProfileMode = profilesResponse.singleProfileMode ?? false
        state.selectedProfileName = Self.nonEmpty(state.currentProfile)
            ?? Self.nonEmpty(profilesResponse.active)
            ?? profilesResponse.effectiveDefaultProfileName

        guard let sessionProfile = Self.nonEmpty(state.currentProfile),
              Self.nonEmpty(profilesResponse.active) != sessionProfile
        else { return }

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

    private func loadModelAndReasoning(into state: inout ChatComposerConfigState) async throws {
        let selectedProfile = Self.profileSummary(
            matching: state.selectedProfileName,
            in: state.profileOptions
        )
        if state.currentModel == nil {
            state.currentModel = Self.nonEmpty(selectedProfile?.model)
        }

        let modelsResponse = try await client.models()
        state.modelCatalogGroups = modelsResponse.catalogGroups
        if state.currentModel == nil {
            state.currentModel = modelsResponse.defaultModel
        }
        if Self.nonEmpty(state.currentModelProvider) == nil {
            state.currentModelProvider = Self.nonEmpty(selectedProfile?.provider)
                ?? Self.uniqueProvider(for: state.currentModel, in: state.modelCatalogGroups)
        }

        // Scope the query to the session's resolved model/provider so the
        // gating fields are model-accurate (issue #18); the seeded effort is
        // the server's already-coerced value for that model.
        let reasoningResponse = try await client.reasoning(
            model: Self.nonEmpty(state.currentModel),
            provider: Self.nonEmpty(state.currentModelProvider)
        )
        state.selectedReasoningEffort = reasoningResponse.effectiveEffort
        state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
        state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort
    }

    private func applyWorkspaces(
        _ workspaceResponse: WorkspacesResponse,
        to state: inout ChatComposerConfigState
    ) {
        state.workspaceRoots = workspaceResponse.workspaces ?? []
        if state.currentWorkspace == nil {
            state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
        }
        state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
    }

    private func loadAgentCommands() async -> [AgentCommand] {
        (try? await client.commands())?.commands ?? []
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
