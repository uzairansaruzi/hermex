import Foundation

/// Every HTTP request Hermex sends to a direct Hermes host. A case builds its
/// method, path, query and JSON body against the connection's address.
/// `HermesConnection` sends them with its headers and cookie jar; only the connection
/// screen's status probe sends `.status` bare. Each operation reads its own reply status.
///
/// The push provisioning routes (#557) were verified against a 0.21.3 host on
/// 2026-09-19: install takes `{identifier, enable, force, ref}` and has no profile
/// parameter, enable and disable are path-only, and `PUT /api/env` and the gateway
/// restart take an optional `profile` Hermex leaves unset so every Profile inherits.
/// The plugins hub (#851) is read at the pin ca678285: `{plugins: [{name, version, …}]}`,
/// cached for 5 s and cleared by an install, so an update needs no rescan first.
/// The restart route (#934) is hermex-push's own, checked at the same pin with plugin 0.4.0:
/// 202 `{ok: true}`, 401 without a sign-in, then the dashboard back on its PID about 2 s later
/// with a new per-process session key, so the next signed-in read signs in again.
/// `GET /api/profiles/active` (#1010) is read at the same pin: `{active, current}`, each
/// falling back to `default`. `GET /api/sessions/{id}/messages` (#1013) too, against
/// `scripts/local-hermes`: `{session_id, profile, messages: [{role, content, tool_calls}]}`, the
/// latest 500 rows oldest first, or 404 `{detail}` for a session the Profile does not have.
/// The cron routes (#1040) are read at the same pin and checked against `scripts/local-hermes`:
/// the list is a bare array across every Profile, a mutation answers the job (delete `{ok}`),
/// `?profile=` is a hint the host checks, and a refusal is `{detail}`. The trigger (#1041) runs
/// the job before it answers it, and the run outlives a dropped request: `scripts/local-hermes`
/// finished and recorded a 20 s run whose request was dropped after 5 s. A job's runs (#1042) are
/// read at the same pin and checked against `scripts/local-hermes`: `{runs, limit}`, the job's run
/// sessions newest first, each `cron_<job>_<YYYYmmdd_HHMMSS>` with the session's `system_prompt`;
/// `limit` is clamped to 1-100, there is no offset, and a job without runs answers `{runs: []}`.
/// The Kanban plugin's reads (#1043), its event socket (#1045) and its writes (#1044) are under
/// `/api/plugins/kanban` at the same pin, checked against `scripts/local-hermes`;
/// `docs/agents/kanban.md` § Hermes has their shapes.
enum HermesREST: Equatable, Sendable {
    /// Public, so it reads the host before any credential is sent.
    case status
    case login(username: String, password: String)
    case identity
    /// `{active, current}`: `current` is the Profile this dashboard is scoped to, which a new
    /// session runs under (#1010); `active` is only the CLI's sticky default.
    case profilesActive
    /// Mints the single-use ticket one gateway socket presents.
    case ticket
    /// `DELETE /api/profiles/{name}`, the only Profile removal the host exposes; the
    /// gateway has no `profiles.delete` RPC. `name` is a validated Profile slug.
    case deleteProfile(name: String)
    /// Stores image bytes under the Profile. The returned path travels in one prompt.
    case uploadImage(profile: String, filename: String, dataURL: String)
    /// One session-scoped file download. `path` is checked against the address.
    case downloadArtifact(path: String, profile: String, sessionID: String)
    /// Writes one managed environment value at the host root.
    case setEnvironment(key: String, value: String)
    /// Installs an agent plugin, reinstalling over an existing copy.
    case installPlugin(identifier: String)
    case setPlugin(name: String, enabled: Bool)
    case restartGateway
    case pushPairing
    /// hermex-push 0.4.0's restart: 202, then the dashboard re-execs itself.
    case restartDashboard
    /// Every agent plugin with its on-disk version.
    case pluginsHub
    /// A stored session's latest rows under `profile`: a background task's `bg_<id>` side
    /// session, whose last reply is its durable result (#1013).
    case sessionMessages(key: String, profile: String)
    /// Every Profile's scheduled Tasks, paused and completed included: a bare array.
    case cronJobs
    /// Creates a Task in `profile`, or in the host's default Profile when nil.
    case cronCreate(profile: String?, fields: [String: BotJSON])
    /// `{updates}` never names the job or its Profile: the host can't move a job, so
    /// `profile` only routes the request.
    case cronUpdate(id: String, profile: String?, updates: [String: BotJSON])
    case cronPause(id: String, profile: String?)
    case cronResume(id: String, profile: String?)
    /// Also deletes the job's output folder on the host.
    case cronDelete(id: String, profile: String?)
    /// Runs the job now, without a body, and answers it once the run has finished. A paused
    /// job is resumed as it runs; one already running, or completed, is refused with 409.
    case cronTrigger(id: String, profile: String?)
    /// The job's newest `limit` runs (at most 100), newest first: each the session it ran in.
    case cronRuns(id: String, profile: String?, limit: Int)
    /// `{targets: [{id, name, …}]}`, `local` first, for one Profile's gateway platforms.
    case cronDeliveryTargets(profile: String?)
    /// One Profile's skills: a bare array of `{name, description, category, enabled, …}`.
    case skills(profile: String?)
    /// `{default_tenant, …}`, or 404 when the Kanban plugin is disabled or absent.
    case kanbanConfig
    /// Every Board with its counts, and `current`.
    case kanbanBoards
    /// One Board's Columns and Cards. `tenant` and archived Cards are the host's only filters.
    case kanbanBoard(board: String, tenant: String?, includeArchived: Bool)
    case kanbanStats(board: String)
    case kanbanAssignees(board: String)
    /// One Card with its comments, events, links and runs. `id` is the host's `t_…` id.
    case kanbanTask(id: String, board: String)
    /// The last `tailBytes` of a Card's worker log; `exists: false` when it never ran.
    case kanbanTaskLog(id: String, board: String, tailBytes: Int)
    /// Creates a Card from `body`; `{task, warning?}`.
    case kanbanCreateTask(board: String, body: [String: BotJSON])
    /// Edits a Card or changes its Status, which is how the host blocks and unblocks; `{task}`.
    case kanbanUpdateTask(id: String, board: String, body: [String: BotJSON])
    /// `{ok: true}`, without the comment.
    case kanbanComment(id: String, board: String, body: String)
    /// `parent` becomes a prerequisite of `child`; `{ok, gated}`, with neither id.
    case kanbanLink(board: String, parent: String, child: String)
    /// `{ok}`, 200 even when there was no such link.
    case kanbanUnlink(board: String, parent: String, child: String)
    /// One change for every id in `body`; `{results: [{id, ok, error?}]}`, 200 with failures.
    case kanbanBulk(board: String, body: [String: BotJSON])
    /// One dispatcher pass, at most eight workers; a dry run starts none.
    case kanbanDispatch(board: String, dryRun: Bool)
    /// `body` names the Board, never its directory or project; `{board, current}`.
    case kanbanCreateBoard(body: [String: BotJSON])
    case kanbanEditBoard(slug: String, body: [String: BotJSON])
    /// Archives the Board, never deletes it; `{result, current}`.
    case kanbanArchiveBoard(slug: String)
    /// Makes the Board the host's active one, for every client; `{current}`.
    case kanbanSwitchBoard(slug: String)

    func request(base: URL) throws -> URLRequest {
        switch self {
        case .status: return Self.get(base.appendingPathComponent("api/status"))
        case .login(let username, let password):
            return try Self.send("POST", base.appendingPathComponent("auth/password-login"), [
                "provider": .string("basic"), "username": .string(username), "password": .string(password)
            ])
        case .identity: return Self.get(base.appendingPathComponent("api/auth/me"))
        case .profilesActive: return Self.get(base.appendingPathComponent("api/profiles/active"))
        case .ticket: return try Self.send("POST", base.appendingPathComponent("api/auth/ws-ticket"), [:])
        case .deleteProfile(let name):
            var request = URLRequest(url: base.appendingPathComponent("api/profiles").appendingPathComponent(name))
            request.httpMethod = "DELETE"
            return request
        case .uploadImage(let profile, let filename, let dataURL):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/chat/image-upload"), resolvingAgainstBaseURL: false),
                  !profile.isEmpty else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "profile", value: profile)]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return try Self.send("POST", url, ["filename": .string(filename), "data_url": .string(dataURL)])
        case .downloadArtifact(let path, let profile, let sessionID):
            guard !profile.isEmpty, !sessionID.isEmpty else { throw BotArtifactFailure.invalidReference }
            let path = try BotArtifactReference.path(path, address: base)
            var parts = URLComponents(url: base.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)
            parts?.queryItems = [URLQueryItem(name: "path", value: path),
                                 URLQueryItem(name: "profile", value: profile),
                                 URLQueryItem(name: "session_id", value: sessionID)]
            guard let url = parts?.url else { throw BotArtifactFailure.invalidReference }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        case .setEnvironment(let key, let value):
            return try Self.send("PUT", base.appendingPathComponent("api/env"), ["key": .string(key), "value": .string(value)])
        case .installPlugin(let identifier):
            return try Self.send("POST", base.appendingPathComponent("api/dashboard/agent-plugins/install"), [
                "identifier": .string(identifier), "enable": .bool(true), "force": .bool(true)
            ])
        case .setPlugin(let name, let enabled):
            let url = base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name)
                .appendingPathComponent(enabled ? "enable" : "disable")
            return try Self.send("POST", url, [:])
        case .restartGateway: return try Self.send("POST", base.appendingPathComponent("api/gateway/restart"), [:])
        case .pushPairing: return Self.get(base.appendingPathComponent("api/plugins/hermex-push/pairing"))
        case .restartDashboard: return try Self.send("POST", base.appendingPathComponent("api/plugins/hermex-push/restart"), [:])
        case .pluginsHub: return Self.get(base.appendingPathComponent("api/dashboard/plugins/hub"))
        case .sessionMessages(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)/messages", profile: profile))
        case .cronJobs: return Self.get(base.appendingPathComponent("api/cron/jobs"))
        case .cronCreate(let profile, let fields):
            return try Self.send("POST", try Self.url(base, "api/cron/jobs", profile: profile), fields)
        case .cronUpdate(let id, let profile, let updates):
            return try Self.send("PUT", try Self.cronJob(base, id, profile: profile), ["updates": .object(updates)])
        case .cronPause(let id, let profile):
            return Self.bare("POST", try Self.cronJob(base, id, "pause", profile: profile))
        case .cronResume(let id, let profile):
            return Self.bare("POST", try Self.cronJob(base, id, "resume", profile: profile))
        case .cronDelete(let id, let profile): return Self.bare("DELETE", try Self.cronJob(base, id, profile: profile))
        case .cronTrigger(let id, let profile):
            return Self.bare("POST", try Self.cronJob(base, id, "trigger", profile: profile))
        case .cronRuns(let id, let profile, let limit):
            guard var parts = URLComponents(url: try Self.cronJob(base, id, "runs", profile: profile),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "limit", value: String(limit))]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .cronDeliveryTargets(let profile):
            return Self.get(try Self.url(base, "api/cron/delivery-targets", profile: profile))
        case .skills(let profile): return Self.get(try Self.url(base, "api/skills", profile: profile))
        case .kanbanConfig: return try Self.kanban(base, ["config"])
        case .kanbanBoards: return try Self.kanban(base, ["boards"])
        case .kanbanBoard(let board, let tenant, let includeArchived):
            var query = [URLQueryItem(name: "board", value: board)]
            if let tenant, !tenant.isEmpty { query.append(URLQueryItem(name: "tenant", value: tenant)) }
            if includeArchived { query.append(URLQueryItem(name: "include_archived", value: "true")) }
            return try Self.kanban(base, ["board"], query)
        case .kanbanStats(let board): return try Self.kanban(base, ["stats"], [URLQueryItem(name: "board", value: board)])
        case .kanbanAssignees(let board):
            return try Self.kanban(base, ["assignees"], [URLQueryItem(name: "board", value: board)])
        case .kanbanTask(let id, let board):
            guard Self.isSegment(id) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["tasks", id], [URLQueryItem(name: "board", value: board)])
        case .kanbanTaskLog(let id, let board, let tailBytes):
            guard Self.isSegment(id) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["tasks", id, "log"], [URLQueryItem(name: "board", value: board),
                                                                 URLQueryItem(name: "tail", value: String(tailBytes))])
        case .kanbanCreateTask(let board, let body):
            return try Self.kanban(base, ["tasks"], [URLQueryItem(name: "board", value: board)], "POST", body)
        case .kanbanUpdateTask(let id, let board, let body):
            guard Self.isSegment(id) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["tasks", id], [URLQueryItem(name: "board", value: board)], "PATCH", body)
        case .kanbanComment(let id, let board, let body):
            guard Self.isSegment(id) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["tasks", id, "comments"], [URLQueryItem(name: "board", value: board)], "POST",
                                   ["body": .string(body)])
        case .kanbanLink(let board, let parent, let child):
            return try Self.kanban(base, ["links"], [URLQueryItem(name: "board", value: board)], "POST",
                                   ["parent_id": .string(parent), "child_id": .string(child)])
        case .kanbanUnlink(let board, let parent, let child):
            var request = try Self.kanban(base, ["links"], [URLQueryItem(name: "board", value: board),
                                                            URLQueryItem(name: "parent_id", value: parent),
                                                            URLQueryItem(name: "child_id", value: child)])
            request.httpMethod = "DELETE"
            return request
        case .kanbanBulk(let board, let body):
            return try Self.kanban(base, ["tasks", "bulk"], [URLQueryItem(name: "board", value: board)], "POST", body)
        case .kanbanDispatch(let board, let dryRun):
            return try Self.kanban(base, ["dispatch"], [URLQueryItem(name: "board", value: board),
                                                        URLQueryItem(name: "dry_run", value: dryRun ? "true" : "false"),
                                                        URLQueryItem(name: "max", value: String(KanbanDispatchRequest.maximum))],
                                   "POST", [:])
        case .kanbanCreateBoard(let body):
            return try Self.kanban(base, ["boards"], [], "POST", body)
        case .kanbanEditBoard(let slug, let body):
            guard Self.isSegment(slug) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["boards", slug], [], "PATCH", body)
        case .kanbanArchiveBoard(let slug):
            guard Self.isSegment(slug) else { throw BotFailure.invalidAddress }
            var request = try Self.kanban(base, ["boards", slug], [URLQueryItem(name: "delete", value: "false")])
            request.httpMethod = "DELETE"
            return request
        case .kanbanSwitchBoard(let slug):
            guard Self.isSegment(slug) else { throw BotFailure.invalidAddress }
            return try Self.kanban(base, ["boards", slug, "switch"], [], "POST", [:])
        }
    }

    /// A request under the Kanban plugin's mount: a GET, or `method` with the JSON `body`.
    private static func kanban(_ base: URL, _ path: [String], _ query: [URLQueryItem] = [],
                               _ method: String = "GET", _ body: [String: BotJSON]? = nil) throws -> URLRequest {
        let url = path.reduce(base.appendingPathComponent("api/plugins/kanban")) { $0.appendingPathComponent($1) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        guard let body else { return get(url) }
        return try send(method, url, body)
    }

    /// The gateway socket's upgrade: the `ws`/`wss` URL matching the address's scheme,
    /// offering `hermes-gateway-v1` and the single-use ticket as subprotocols. A request's
    /// `Sec-WebSocket-Protocol` header is where `URLSessionWebSocketTask` takes them from.
    static func gatewayUpgrade(base: URL, ticket: String) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.unsupported }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        var request = URLRequest(url: url)
        request.setValue("hermes-gateway-v1, hermes-gateway-ticket." + ticket, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    /// A Board's Kanban event socket (#1045): `/api/plugins/kanban/events` on the `ws`/`wss`
    /// URL matching the address's scheme, presenting the single-use ticket as `?ticket=`. It
    /// offers no subprotocol, because the host accepts without echoing one. The host pins the
    /// socket to `board` and sends only events after `since`.
    static func kanbanEventsUpgrade(base: URL, board: String, since: Int, ticket: String) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/plugins/kanban/events"),
                                        resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "board", value: board), URLQueryItem(name: "since", value: String(max(0, since))),
                            URLQueryItem(name: "ticket", value: ticket)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return URLRequest(url: url)
    }

    private static func get(_ url: URL) -> URLRequest { bare("GET", url) }

    /// A request without a body.
    private static func bare(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    /// `path` under `base`, with `?profile=` when a Profile is named.
    private static func url(_ base: URL, _ path: String, profile: String?) throws -> URL {
        guard var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        if let profile, !profile.isEmpty { parts.queryItems = [URLQueryItem(name: "profile", value: profile)] }
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }

    /// One job's route, or one of its actions.
    private static func cronJob(_ base: URL, _ id: String, _ action: String? = nil, profile: String?) throws -> URL {
        guard isSegment(id) else { throw BotFailure.invalidAddress }
        return try url(base, "api/cron/jobs/\(id)" + (action.map { "/" + $0 } ?? ""), profile: profile)
    }

    /// One path segment of the host's own id characters, so an id never names another route.
    private static func isSegment(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
    }

    private static func send(_ method: String, _ url: URL, _ body: [String: BotJSON]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(BotJSON.object(body))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}
