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

/// Loads everything the composer needs (profile, model, provider, reasoning
/// effort, workspaces, commands) for one chat.
///
/// ## Ordering contract — why this is not a flat fan-out
///
/// Two of these endpoints are **profile-scoped on the server**: `/api/models`
/// resolves against the active profile inside `get_available_models()`
/// (upstream issue #3957) and `/api/workspaces` reads a per-profile workspace
/// file via `get_active_profile_name()`. Issuing either one concurrently with
/// `/api/profile/switch` is a race that yields the *previous* profile's model
/// catalog or workspace list, so profile resolution is a hard barrier.
///
/// What can overlap:
/// - `/api/commands` is a static `hermes_cli` registry with no profile scoping,
///   so it runs concurrently with the entire chain.
/// - After the profile is settled, `/api/models` and `/api/workspaces` overlap.
/// - `/api/reasoning` is scoped to the resolved model+provider *and* reads the
///   active profile's config, so it also sits behind the barrier. When the
///   session already pins model and provider (the common case for an existing
///   chat) the catalog cannot change them, so it overlaps the catalog fetch.
///   Otherwise it waits for `/api/models` to supply `default_model`.
///
/// Each endpoint owns its own error handling: a failing `/api/models` no
/// longer abandons workspaces and commands (which previously left the composer
/// with no workspace list until a full reload).
struct ChatComposerConfigLoader {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func loadConfiguration(from initialState: ChatComposerConfigState) async -> ChatComposerConfigLoadResult {
        var state = initialState
        var configurationError: Error?
        // Surface the first failure, matching the previous single-`catch`
        // behavior where the earliest throw won.
        func record(_ error: Error) {
            if configurationError == nil { configurationError = error }
        }

        // Profile-independent: overlaps the whole profile-resolution chain.
        async let commandsResult: CommandsResponse? = try? await client.commands()

        // A session that pins no profile can never trigger `/api/profile/switch`,
        // so the server's active profile is already settled and the profile-scoped
        // reads do not have to queue behind `/api/profiles`. This is the common
        // case (default profile), and it removes a full round trip from it.
        let sessionPinsProfile = Self.nonEmpty(state.currentProfile) != nil
        async let earlyModelsResult: Result<ModelsResponse, Error>? = sessionPinsProfile
            ? nil
            : await Self.capture { try await client.models(freshness: .sessionVisit) }
        async let earlyWorkspacesResult: Result<WorkspacesResponse, Error>? = sessionPinsProfile
            ? nil
            : await Self.capture { try await client.workspaces() }

        // ── Phase 1: profile resolution (barrier for profile-scoped reads) ──
        var canReadProfileScopedEndpoints = true
        do {
            let profilesResponse = try await client.profiles()
            state.profileOptions = profilesResponse.profiles ?? []
            state.isSingleProfileMode = profilesResponse.singleProfileMode ?? false
            state.selectedProfileName = Self.nonEmpty(state.currentProfile)
                ?? Self.nonEmpty(profilesResponse.active)
                ?? profilesResponse.effectiveDefaultProfileName

            if let sessionProfile = Self.nonEmpty(state.currentProfile),
               Self.nonEmpty(profilesResponse.active) != sessionProfile {
                // `/api/profile/switch` mutates the server's ACTIVE profile —
                // global state every other client sees. The config load now
                // starts as soon as the chat appears, so without this check a
                // chat the user opens and immediately abandons would still
                // thrash the server's active profile as a side effect.
                try Task.checkCancellation()
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
        } catch {
            record(error)
            // Fail closed: if the profile never settled we cannot tell which
            // profile `/api/models` and `/api/workspaces` would answer for, and
            // showing another profile's models is worse than showing none.
            canReadProfileScopedEndpoints = false
        }

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

        guard canReadProfileScopedEndpoints else {
            state.agentCommands = (await commandsResult)?.commands ?? []
            // Always await the speculative children so nothing is left dangling.
            _ = await earlyModelsResult
            _ = await earlyWorkspacesResult
            return ChatComposerConfigLoadResult(state: state, configurationError: configurationError)
        }

        // ── Phase 2: profile-scoped reads, now safe to overlap ──
        //
        // The catalog can only change the model when it is still unresolved,
        // and only change the provider when that is still unresolved. When both
        // are already pinned the reasoning query is identical either way, so it
        // does not need to wait for the catalog.
        let reasoningScopeIsSettled =
            Self.nonEmpty(state.currentModel) != nil && Self.nonEmpty(state.currentModelProvider) != nil
        // Snapshot the pinned scope as immutable lets: capturing the mutable
        // `state` inside a concurrent child task is a data race (and a hard
        // error under the Swift 6 language mode).
        let pinnedModel = Self.nonEmpty(state.currentModel)
        let pinnedProvider = Self.nonEmpty(state.currentModelProvider)

        // Reuse the speculative results when the session pinned no profile;
        // otherwise issue them now that the barrier has cleared.
        async let lateModelsResult: Result<ModelsResponse, Error>? = sessionPinsProfile
            ? await Self.capture { try await client.models(freshness: .sessionVisit) }
            : nil
        async let lateWorkspacesResult: Result<WorkspacesResponse, Error>? = sessionPinsProfile
            ? await Self.capture { try await client.workspaces() }
            : nil
        async let settledReasoningResult: Result<ReasoningStatusResponse, Error>? = reasoningScopeIsSettled
            ? await Self.capture {
                try await client.reasoning(model: pinnedModel, provider: pinnedProvider)
            }
            : nil

        // `??` takes an autoclosure, which cannot capture an `async let`, so
        // each child is awaited into a local first.
        let lateModels = await lateModelsResult
        let earlyModels = await earlyModelsResult
        let lateWorkspaces = await lateWorkspacesResult
        let earlyWorkspaces = await earlyWorkspacesResult
        let modelsResult = lateModels ?? earlyModels
        let workspacesResult = lateWorkspaces ?? earlyWorkspaces

        switch modelsResult {
        case .success(let modelsResponse):
            state.modelCatalogGroups = modelsResponse.catalogGroups
            if state.currentModel == nil {
                state.currentModel = modelsResponse.defaultModel
            }
            if Self.nonEmpty(state.currentModelProvider) == nil {
                state.currentModelProvider = Self.uniqueProvider(
                    for: state.currentModel,
                    in: state.modelCatalogGroups
                )
            }
        case .failure(let error):
            record(error)
        case nil:
            break
        }

        // Scope the query to the session's resolved model/provider so the
        // gating fields are model-accurate (issue #18); the seeded effort is
        // the server's already-coerced value for that model.
        let reasoningResult: Result<ReasoningStatusResponse, Error>
        if let settled = await settledReasoningResult {
            reasoningResult = settled
        } else {
            reasoningResult = await Self.capture {
                try await client.reasoning(
                    model: Self.nonEmpty(state.currentModel),
                    provider: Self.nonEmpty(state.currentModelProvider)
                )
            }
        }
        switch reasoningResult {
        case .success(let reasoningResponse):
            state.selectedReasoningEffort = reasoningResponse.effectiveEffort
            state.supportedReasoningEfforts = reasoningResponse.normalizedSupportedEfforts
            state.supportsReasoningEffort = reasoningResponse.supportsReasoningEffort
        case .failure(let error):
            record(error)
        }

        switch workspacesResult {
        case .success(let workspaceResponse):
            state.workspaceRoots = workspaceResponse.workspaces ?? []
            if state.currentWorkspace == nil {
                state.currentWorkspace = workspaceResponse.last ?? state.workspaceRoots.compactMap(\.path).first
            }
            state.workspaceSuggestions = state.workspaceRoots.compactMap(\.path)
        case .failure(let error):
            record(error)
        case nil:
            break
        }

        state.agentCommands = (await commandsResult)?.commands ?? []

        return ChatComposerConfigLoadResult(
            state: state,
            configurationError: configurationError
        )
    }

    /// `async let` cannot bind a `throws` expression without forcing the error
    /// to the awaiting site, which would re-serialize the very calls we are
    /// overlapping. Capturing into a `Result` keeps each endpoint's failure
    /// isolated to its own branch.
    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
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
                .flatMap(\.slashAutocompleteModels)
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
