import Foundation

extension APIClient {
    func models() async throws -> ModelsResponse {
        try await send(endpoint: .models, method: "GET")
    }

    /// Live (uncached) model list for the active provider. The server resolves
    /// the provider itself when no `provider` param is sent and echoes it back,
    /// so callers can match the result against the cached catalog's groups.
    func modelsLive() async throws -> ModelsLiveResponse {
        try await send(endpoint: .modelsLive, method: "GET")
    }

    func commands() async throws -> CommandsResponse {
        try await send(endpoint: .commands, method: "GET")
    }

    func saveDefaultModel(model: String) async throws -> DefaultModelResponse {
        try await send(
            endpoint: .defaultModel,
            method: "POST",
            body: DefaultModelRequest(model: model)
        )
    }

    /// Reasoning status for a specific model/provider (`GET /api/reasoning`).
    /// Passing the session's current model + provider makes `supported_efforts`
    /// model-accurate (mirrors the upstream WebUI composer chip, issue #18);
    /// with no params the server resolves the config default model instead.
    func reasoning(model: String? = nil, provider: String? = nil) async throws -> ReasoningStatusResponse {
        try await send(endpoint: .reasoning(model: model, provider: provider), method: "GET")
    }

    func saveReasoningEffort(_ effort: String) async throws -> ReasoningStatusResponse {
        try await send(
            endpoint: .reasoning(),
            method: "POST",
            body: ReasoningEffortRequest(effort: effort)
        )
    }

    func saveReasoningDisplay(_ display: String) async throws -> ReasoningStatusResponse {
        try await send(
            endpoint: .reasoning(),
            method: "POST",
            body: ReasoningDisplayRequest(display: display)
        )
    }

    func personalities() async throws -> PersonalitiesResponse {
        try await send(endpoint: .personalities, method: "GET")
    }

    func setPersonality(sessionID: String, name: String) async throws -> PersonalitySetResponse {
        try await send(
            endpoint: .setPersonality,
            method: "POST",
            body: PersonalitySetRequest(sessionId: sessionID, name: name)
        )
    }

    func profiles() async throws -> ProfilesResponse {
        try await send(endpoint: .profiles, method: "GET")
    }

    func switchProfile(name: String) async throws -> ProfileSwitchResponse {
        try await send(
            endpoint: .switchProfile,
            method: "POST",
            body: ProfileSwitchRequest(name: name)
        )
    }

    /// Creates a new profile (`POST /api/profile/create`), mirroring the webui's
    /// create form payload: `clone_config` is always sent, everything else only
    /// when provided (`clone_from` is intentionally omitted — the server clones
    /// from the active profile). Rejected with 403 in single-profile mode.
    func createProfile(
        name: String,
        cloneConfig: Bool = false,
        defaultModel: String? = nil,
        modelProvider: String? = nil,
        baseUrl: String? = nil,
        apiKey: String? = nil
    ) async throws -> ProfileCreateResponse {
        try await send(
            endpoint: .createProfile,
            method: "POST",
            body: ProfileCreateRequest(
                name: name,
                cloneConfig: cloneConfig,
                defaultModel: defaultModel,
                modelProvider: modelProvider,
                baseUrl: baseUrl,
                apiKey: apiKey
            )
        )
    }

    func providers() async throws -> ProvidersResponse {
        try await send(endpoint: .providers, method: "GET")
    }

    func settings() async throws -> SettingsResponse {
        try await send(endpoint: .settings, method: "GET")
    }

    /// Writes the single server-synced session-visibility key (#19):
    /// `POST /api/settings {"show_cli_sessions": <bool>}`. Upstream
    /// `save_settings(body)` merges exactly the keys sent — nothing else is
    /// touched — and responds with the full saved settings dict, so the
    /// response reuses `SettingsResponse`. A general settings editor stays
    /// out of scope.
    func updateSettings(showCliSessions: Bool) async throws -> SettingsResponse {
        try await send(
            endpoint: .settings,
            method: "POST",
            body: ShowCliSessionsUpdateRequest(showCliSessions: showCliSessions)
        )
    }

    /// Writes only the server-synced Claude Code session visibility key.
    func updateSettings(showClaudeCodeSessions: Bool) async throws -> SettingsResponse {
        try await send(
            endpoint: .settings,
            method: "POST",
            body: ShowClaudeCodeSessionsUpdateRequest(
                showClaudeCodeSessions: showClaudeCodeSessions
            )
        )
    }

    func updatesCheck() async throws -> UpdatesCheckResponse {
        try await send(endpoint: .updatesCheck, method: "GET")
    }

    /// Forces a *live* update check: `POST /api/updates/check` with `{ "force": true }`.
    /// Upstream runs a real `git fetch` for this path (`check_for_updates(force=True)`),
    /// whereas the plain GET only returns the cached status. Same response shape, so
    /// `UpdatesCheckResponse` is reused. Used by the manual "Check for updates" button (#308).
    func updatesCheckForced() async throws -> UpdatesCheckResponse {
        try await send(
            endpoint: .updatesCheck,
            method: "POST",
            body: UpdatesCheckForceRequest(force: true)
        )
    }

    /// Applies a pending repo update. The server pulls `--ff-only` and then
    /// restarts itself, so the caller must tolerate a brief connection outage
    /// and re-poll afterwards. Defaults to the `webui` target (issue #180 scope;
    /// no `agent` target, `/force`, or `/summary`).
    func applyUpdate(target: String = "webui") async throws -> UpdatesApplyResponse {
        try await send(
            endpoint: .updatesApply,
            method: "POST",
            body: UpdatesApplyRequest(target: target)
        )
    }

    func insights(days: Int) async throws -> InsightsResponse {
        try await send(endpoint: .insights(days: days), method: "GET")
    }
}

private struct DefaultModelRequest: Encodable {
    let model: String
}

private struct ReasoningEffortRequest: Encodable {
    let effort: String
}

private struct ReasoningDisplayRequest: Encodable {
    let display: String
}

private struct PersonalitySetRequest: Encodable {
    let sessionId: String
    let name: String
}

private struct ProfileSwitchRequest: Encodable {
    let name: String
}

private struct ProfileCreateRequest: Encodable {
    let name: String
    let cloneConfig: Bool
    let defaultModel: String?
    let modelProvider: String?
    let baseUrl: String?
    let apiKey: String?
}

private struct UpdatesApplyRequest: Encodable {
    let target: String
}

private struct UpdatesCheckForceRequest: Encodable {
    let force: Bool
}

private struct ShowCliSessionsUpdateRequest: Encodable {
    // Encoded as `show_cli_sessions` via the client's convertToSnakeCase strategy.
    let showCliSessions: Bool
}

private struct ShowClaudeCodeSessionsUpdateRequest: Encodable {
    // Encoded as `show_claude_code_sessions` by convertToSnakeCase.
    let showClaudeCodeSessions: Bool
}
