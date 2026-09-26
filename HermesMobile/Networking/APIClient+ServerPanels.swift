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

    /// Saves the default model. Pass `provider` whenever the row names its
    /// provider (`provider_id` from the catalog group): Core persists
    /// `{model, provider}` atomically and resolves slash-qualified ids like
    /// `anthropic/...` through the named provider's route. Without it such an
    /// id can be persisted through the wrong provider.
    func saveDefaultModel(model: String, provider: String? = nil) async throws -> DefaultModelResponse {
        try await send(
            endpoint: .defaultModel,
            method: "POST",
            body: DefaultModelRequest(model: model, provider: provider)
        )
    }

    /// Reasoning status for a specific model/provider (`GET /api/reasoning`).
    /// Passing the session's current model + provider makes `supported_efforts`
    /// model-accurate (mirrors the upstream WebUI composer chip, issue #18);
    /// with no params the server resolves the config default model instead.
    func reasoning(model: String? = nil, provider: String? = nil) async throws -> ReasoningStatusResponse {
        try await send(endpoint: .reasoning(model: model, provider: provider), method: "GET")
    }

    func saveReasoningEffort(
        _ effort: String,
        sessionID: String
    ) async throws -> ReasoningStatusResponse {
        try await send(
            endpoint: .reasoning(),
            method: "POST",
            body: ReasoningEffortRequest(effort: effort, sessionId: sessionID)
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

    func switchProfile(name: String, ownership: UUID = UUID()) async throws -> ProfileSwitchResponse {
        let response = try await ProfileCookieOwnership.shared.mutate(server: baseURL, ownership: ownership, restoring: false) {
            try await self.send(endpoint: .switchProfile, method: "POST", body: ProfileSwitchRequest(name: name))
        }
        return response! // An unconditional switch always runs or throws.
    }

    /// A failed/abandoned operation may recover only while it still owns the
    /// cookie. The check AND the response's cookie write share the same permit
    /// as switches from every other APIClient (list, settings, other chats).
    func restoreProfile(name: String, ownership: UUID) async throws -> ProfileSwitchResponse? {
        try await ProfileCookieOwnership.shared.mutate(server: baseURL, ownership: ownership, restoring: true) {
            try await self.send(endpoint: .switchProfile, method: "POST", body: ProfileSwitchRequest(name: name))
        }
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
    /// The catalog row's provider, so the server persists `{model, provider}`
    /// atomically and resolves slash-qualified ids through the right route.
    /// Surface split, verified in source: the compatibility pin
    /// (`f1d399b4`, `routes.py:4475`) reads only `body.get("model")` and
    /// silently ignores the extra key; `set_hermes_default_model` accepts
    /// `provider` from upstream HEAD `a00b02f` (`api/config.py:4780`).
    /// Optional so a providerless custom-model save still sends the bare
    /// `{model}` body; synthesized Encodable omits nil keys.
    let provider: String?
}

private struct ReasoningEffortRequest: Encodable {
    let effort: String
    let sessionId: String
}

private struct ReasoningDisplayRequest: Encodable {
    let display: String
}

private struct PersonalitySetRequest: Encodable {
    let sessionId: String
    let name: String
}

/// Process-wide because independent screens create independent APIClients.
/// Keep the permit across the network await: actor isolation alone is reentrant
/// and cannot protect URLSession's automatic Set-Cookie application.
private actor ProfileCookieOwnership {
    static let shared = ProfileCookieOwnership()
    private var owners: [String: UUID] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func mutate(
        server: URL,
        ownership: UUID,
        restoring: Bool,
        operation: @Sendable () async throws -> ProfileSwitchResponse
    ) async throws -> ProfileSwitchResponse? {
        // Cookies ignore ports. Conservatively share ownership for same-host
        // servers too, matching the existing shared cookie jar's scope.
        let key = server.host?.lowercased() ?? server.absoluteString
        if waiters[key] != nil {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        } else {
            waiters[key] = []
        }
        defer {
            if var queue = waiters[key], !queue.isEmpty {
                let next = queue.removeFirst()
                waiters[key] = queue
                next.resume()
            } else {
                waiters[key] = nil
            }
        }
        if restoring {
            guard owners[key] == ownership else { return nil }
        } else {
            try Task.checkCancellation()
            // Even failure may have changed a cookie. Retain the token so its
            // recovery can retry, unless a subsequent explicit switch takes it.
            owners[key] = ownership
        }
        return try await operation()
    }
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
