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
/// `docs/agents/kanban.md` § Hermes has their shapes. The skills routes (#1069) are read at the
/// same pin and checked against `scripts/local-hermes`: the list is a bare array with `enabled`,
/// the toggle is PUT, not webui's POST, and a refusal or a missing skill is `{detail}`. The file
/// routes a skill's linked files use (#1070) are read at the same pin and checked against
/// `scripts/local-hermes`: a listing answers `{entries: [{name, path, isDirectory}]}`, or 200
/// `{entries: [], error}` for a folder it can't read, and each entry's `path` is resolved
/// (`/private/var/…` for `/var/…` on a Mac), so it never matches the path that was asked for.
/// The file, config and soul routes the Memory screen uses (#1073) are read at the same pin and
/// checked against `scripts/local-hermes`: a missing file reads 404 `{detail: "File not found"}`,
/// a write to a missing folder is 400 "Parent directory does not exist", and `files/mkdir`
/// answers the folder's entry.
/// The update routes (#1075) are read at the same pin and checked against `scripts/local-hermes`;
/// `docs/agents/bots.md` § Updating Hermes has their shapes. `POST /api/audio/speak` (#1072) is
/// read at the same pin and checked against `scripts/local-hermes`: `{text}` only, spoken by the
/// Profile's `tts.provider`, answered `{ok, data_url, mime_type, provider}`, or `{detail}`.
/// The analytics routes (#1074) are read at the same pin, recorded from `scripts/local-hermes`
/// (`Fixtures/HermesAgent/analytics.json`) and checked read-only against a live host: `days`
/// outside 1-365 is a 422, an unknown Profile a 404 `{detail}`, a store the host can't read a
/// 503 whose `detail` is `{error: "state_db_…", message, path}`, and a sum over an empty window
/// is null.
/// Dictation's `POST /api/audio/transcribe` (#1071) is read at the same pin and checked against
/// `scripts/local-hermes`: JSON, not multipart; `{ok, transcript, provider}`, with silence an
/// empty transcript; and `{detail}` for a refusal or a provider failure (400), an unknown
/// Profile (404) or an unexpected failure (500).
/// The Sessions list's page and read mark (#1046) are read at the same pin, checked against
/// `scripts/local-hermes` and the shape of a read-only `GET /api/sessions` on a 0.21.5 host;
/// `docs/agents/bots.md` § Sessions list on Hermes has the recipe.
/// A session's transcript pages (#1047) are read at the same pin, checked against a compacted
/// session on `scripts/local-hermes` and the shape of a read-only page from a 0.21.5 host:
/// `{session_id, profile, messages, pagination: {limit, offset, order, returned}}`, each page
/// oldest first, with no total, so a short page is the start.
/// The row actions (#1048) are read at the same pin and checked against `scripts/local-hermes`: a
/// PATCH answers `{ok, title, <flag>}`, a refused title (in use, over 100 characters, the canonical
/// Bot Chat) is 400 `{detail}`, an archived list back-fills non-archived pinned rows, and the
/// export is the session row with its `messages`, without a `Content-Disposition`.
/// The search (#1053) is read at the same pin and checked against `scripts/local-hermes`:
/// `{results: [...]}`, an empty `q` answers none, and a Profile the host lacks is 404 `{detail}`;
/// `HermesSessionSearch` has the result's fields.
/// A session's own row and the session import (#1051) are read at the same pin and checked against
/// `scripts/local-hermes`: the row is the stored one, flags as 0/1, `model_config` a JSON string
/// (`{"_branched_from": <parent>}` on a branch), and system prompt and tool names included, about
/// 60 KB; an import answers `{ok, imported, skipped, detached, imported_ids, skipped_ids, errors}`,
/// skips an id the Profile has, refuses a payload with 400 `{detail: {errors}}` before writing
/// anything, and answers 413 past 25 MB.
enum HermesREST: Equatable, Sendable {
    /// The most rows `GET /api/sessions` lists in one page.
    static let sessionPageSize = 100
    /// The most display rows one transcript page (`sessionMessages` with an offset) carries.
    static let transcriptPageSize = 100
    /// The most sessions one search answers; the host allows up to 100 and defaults to 20.
    static let sessionSearchLimit = 50

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
    /// One recording for `profile`'s speech-to-text: `dataURL` is base64 of up to 25 MiB of
    /// audio, and `mimeType` an `audio/*` type.
    case transcribe(profile: String, dataURL: String, mimeType: String)
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
    /// A stored session's rows under `profile`. Without an offset, its latest 500: a background
    /// task's `bg_<id>` side session, whose last reply is its durable result (#1013). With one,
    /// a transcript page (#1047): `transcriptPageSize` display rows counted back from the newest,
    /// compacted ones included, in chronological order.
    case sessionMessages(key: String, profile: String, offset: Int? = nil)
    /// One page of `profile`'s sessions for the Sessions list (#1046): latest activity first,
    /// without archived, empty or machine-run rows, `sessionPageSize` at a time from `offset`.
    /// Each page also brings every pinned row it missed, archived ones included. `archived`
    /// reads the Archived screen's page instead (#1048): only archived rows, hidden Bot Chats
    /// included, plus the same pinned back-fill.
    case sessionList(profile: String, offset: Int, archived: Bool = false)
    /// One change to a session, with `profile` in the body (#1046, #1048).
    case updateSession(key: String, profile: String, change: HermesSessionChange)
    /// That exact session's row and every message, unredacted, as one JSON object (#1048).
    case sessionExport(key: String, profile: String)
    /// That exact session's stored row (#1051), or 404 `{detail}` when `profile` has none.
    case sessionRow(key: String, profile: String)
    /// Imports sessions as an export holds them (#1051), each under the id it carries. `body` is
    /// the JSON `{sessions, profile}`, encoded by the caller off the main actor: it carries every
    /// message.
    case importSessions(body: Data)
    /// `profile`'s sessions matching `query` (#1053): id matches, then message-content matches,
    /// at most `sessionSearchLimit`, archived and hidden ones included, without machine-run rows.
    case sessionSearch(query: String, profile: String)
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
    /// One Profile's skills, disabled ones included: a bare array of `{name, description,
    /// category, enabled, …}`.
    case skills(profile: String?)
    /// Turns one skill on or off for `profile`, which goes in the body, where the host reads
    /// it before the query; `{ok, name, enabled}`.
    case setSkill(name: String, enabled: Bool, profile: String?)
    /// A skill's SKILL.md: `{name, content, path}`, where `path` is a host path, or 404 `{detail}`.
    case skillContent(name: String, profile: String?)
    /// `{entries: [{name, path, isDirectory}]}` for one folder at a host path, not recursive, with
    /// build, VCS and credential entries hidden; 200 `{entries: [], error}` when it can't be read.
    case fsList(path: String)
    /// `{text, binary, truncated, byteSize, …}` for the file at a host path, its first 512 KiB
    /// (`truncated` past that); 404 `{detail}` when there is none.
    case fsReadText(path: String)
    /// `{root}`: the repository folder holding a host path, or null outside one (#1114).
    case gitRoot(path: String)
    /// `null` outside a repository, else `{branch, detached, ahead, behind, staged, unstaged,
    /// untracked, conflicted, changed, added, removed, files: [{path, staged, unstaged, untracked,
    /// conflicted}]}`, with `files` capped at 200 and `changed` the full count. `repository` is
    /// the root, since every path is relative to it.
    case gitStatus(repository: String)
    /// `{files: [{path, added, removed, status, staged}], base}`: every uncommitted change, sorted.
    case gitChanges(repository: String)
    /// `{diff}`: one file's staged or worktree diff, an all-add one for an untracked file.
    case gitDiff(repository: String, file: String, staged: Bool)
    /// `{diff}`: one file's whole change against HEAD, staged and worktree edits together.
    case gitFileDiff(repository: String, file: String)
    // Repository writes (#1115): each answers `{ok}`, or 400 `{detail}` with git's stderr. The
    // host hands `file` to git as a pathspec, where `*` matches other files and `.` or no file the
    // whole tree, so a file goes out literal (`:(literal)file`) and one that isn't a single
    // repository-relative path (`isGitFile`) is refused here.
    /// `git add -- file`. Without a file the host runs `git add -A`, so one is always named.
    case gitStage(repository: String, file: String)
    /// `git reset -q HEAD [-- file]`; nil unstages everything, which leaves the worktree alone.
    case gitUnstage(repository: String, file: String?)
    /// `git checkout HEAD -- file` then `git clean -fd -- file`: back to HEAD, deleting it when
    /// untracked. Without a file the host does that to the whole tree, so one is always named.
    case gitRevert(repository: String, file: String)
    /// `git commit -m message`, never pushing. With nothing staged the host runs `git add -A`
    /// first, so `HermesGitClient` checks the staged count before sending it.
    case gitCommit(repository: String, message: String)
    /// Pushes to the upstream, or `-u origin <branch>` without one; does nothing on a detached HEAD.
    case gitPush(repository: String)
    /// `{sha}`: HEAD's full sha, or null before the first commit.
    case gitHead(repository: String)
    /// `{diff, recent}`: what a commit would take (the staged diff, else everything against HEAD,
    /// with untracked names appended) and the last ten subjects, for a commit message.
    case gitCommitContext(repository: String)
    /// `{branches: [{name, checkedOut, isDefault, isRemote, worktreePath}]}` (#1116): local heads
    /// first, then remote-tracking refs (`origin/name`) with no local head; empty before the first
    /// commit.
    case gitBranches(repository: String)
    /// `git switch branch`; `{branch}`, or 400 `{detail}`. The host rewrites the name first
    /// (`isBranchName`), so one it would change, which could name another branch, is refused
    /// here. A remote ref (`origin/name`) would fail, so a remote row goes out by its short name,
    /// which git turns into a tracking branch.
    case gitSwitchBranch(repository: String, branch: String)
    /// Replaces or creates the file at a host path, atomically; `{ok, path, byteSize}`. It never
    /// creates folders: a missing parent is 400 "Parent directory does not exist".
    case fsWriteText(path: String, content: String)
    /// Creates the folder at a host path, with its parents; 409 when a file is in the way.
    case filesMkdir(path: String)
    /// A Profile's whole config, unredacted, credentials included: decode only what is needed.
    case config(profile: String)
    /// `{content, exists}`: the Profile's SOUL.md, empty when it has none.
    case profileSoul(name: String)
    /// Replaces the Profile's SOUL.md, atomically; `{ok: true}`.
    case setProfileSoul(name: String, content: String)
    /// Speaks `text` in `profile`'s voice: the audio as a base64 data URL (`BotClient.speech`).
    case speak(text: String, profile: String)
    /// One Profile's usage over the last `days` (1-365): `{daily, totals, by_model, period_days, …}`,
    /// `daily` holding only days with sessions, by UTC date.
    case analyticsUsage(days: Int, profile: String)
    /// The same window by model and billing provider: `{models, totals, period_days}`.
    case analyticsModels(days: Int, profile: String)
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
    /// Whether the host's install is behind. The host caches the answer for 24 hours; `force`
    /// asks it to look again.
    case updateCheck(force: Bool)
    /// Starts `hermes update` on the host, without a body. It answers once the update has
    /// started, before it restarts the dashboard.
    case updateApply
    /// The update action: whether it runs, its exit code, the tail of its log and the
    /// summary of the host's latest update receipt.
    case updateStatus
    /// The host's latest update receipt, or 404 when no update has run.
    case updateReceipt
    /// Public process liveness with the running release, read while the dashboard restarts.
    case health

    func request(base: URL) throws -> URLRequest {
        switch self {
        case .status: return Self.get(base.appendingPathComponent("api/status"))
        case .health: return Self.get(base.appendingPathComponent("api/health"))
        case .updateCheck(let force):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/hermes/update/check"),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            if force { parts.queryItems = [URLQueryItem(name: "force", value: "true")] }
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .updateApply: return Self.bare("POST", base.appendingPathComponent("api/hermes/update"))
        case .updateStatus:
            // The log tail is only read for the summary of a run that stopped, so 40 lines will do.
            guard var parts = URLComponents(url: base.appendingPathComponent("api/actions/hermes-update/status"),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "lines", value: "40")]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .updateReceipt: return Self.get(base.appendingPathComponent("api/hermes/update/receipt"))
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
        case .transcribe(let profile, let dataURL, let mimeType):
            return try Self.send("POST", try Self.url(base, "api/audio/transcribe", profile: profile),
                                 ["data_url": .string(dataURL), "mime_type": .string(mimeType)])
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
        case .sessionMessages(let key, let profile, let offset):
            guard Self.isSegment(key), !profile.isEmpty, (offset ?? 0) >= 0,
                  var parts = URLComponents(url: try Self.url(base, "api/sessions/\(key)/messages", profile: profile),
                                            resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            // Both `order` and `limit`: a limit alone pages from the oldest row. Without
            // `include_compacted` the transcript would end at the last compaction.
            if let offset {
                parts.queryItems = (parts.queryItems ?? []) + [
                    URLQueryItem(name: "order", value: "latest"),
                    URLQueryItem(name: "limit", value: String(Self.transcriptPageSize)),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "include_compacted", value: "true")
                ]
            }
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .sessionList(let profile, let offset, let archived):
            guard !profile.isEmpty, offset >= 0,
                  var parts = URLComponents(url: base.appendingPathComponent("api/sessions"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            // Every value is sent: the host's defaults order by creation, list empty sessions
            // and keep cron, Kanban, one-shot, subagent and tool runs.
            parts.queryItems = [
                URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "order", value: "recent"),
                URLQueryItem(name: "archived", value: archived ? "only" : "exclude"),
                URLQueryItem(name: "limit", value: String(Self.sessionPageSize)), URLQueryItem(name: "offset", value: String(offset))
            ] + (archived ? [] : [URLQueryItem(name: "min_messages", value: "1")]) + [
                URLQueryItem(name: "exclude_sources", value: "cron,kanban,oneshot,subagent,tool")
            ]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .updateSession(let key, let profile, let change):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return try Self.send("PATCH", base.appendingPathComponent("api/sessions").appendingPathComponent(key),
                                 [change.field: change.value, "profile": .string(profile)])
        case .sessionExport(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)/export", profile: profile))
        case .sessionRow(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)", profile: profile))
        case .importSessions(let body):
            var request = Self.bare("POST", base.appendingPathComponent("api/sessions/import"))
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        case .sessionSearch(let query, let profile):
            guard !query.isEmpty, !profile.isEmpty,
                  var parts = URLComponents(url: base.appendingPathComponent("api/sessions/search"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            // The same sources the list leaves out, so a search never finds a row it never shows.
            parts.queryItems = [
                URLQueryItem(name: "q", value: query), URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: String(Self.sessionSearchLimit)),
                URLQueryItem(name: "exclude_sources", value: "cron,kanban,oneshot,subagent,tool")
            ]
            // The host reads a bare `+` as a space, so a typed one ("c++") is escaped.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
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
        case .setSkill(let name, let enabled, let profile):
            var body: [String: BotJSON] = ["name": .string(name), "enabled": .bool(enabled)]
            if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
            return try Self.send("PUT", base.appendingPathComponent("api/skills/toggle"), body)
        case .skillContent(let name, let profile):
            guard var parts = URLComponents(url: try Self.url(base, "api/skills/content", profile: profile),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "name", value: name)] + (parts.queryItems ?? [])
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .fsList(let path):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/fs/list"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "path", value: path)]
            // The host reads a query's `+` as a space; a path keeps its own.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .fsReadText(let path):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/fs/read-text"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "path", value: path)]
            // The host reads a query's `+` as a space; a path keeps its own.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .gitRoot(let path):
            return try Self.pathQuery(base, "api/fs/git-root", [URLQueryItem(name: "path", value: path)])
        case .gitStatus(let repository):
            return try Self.pathQuery(base, "api/git/status", [URLQueryItem(name: "path", value: repository)])
        case .gitChanges(let repository):
            return try Self.pathQuery(base, "api/git/review/list", [URLQueryItem(name: "path", value: repository),
                                                                    URLQueryItem(name: "scope", value: "uncommitted")])
        case .gitDiff(let repository, let file, let staged):
            return try Self.pathQuery(base, "api/git/review/diff", [
                URLQueryItem(name: "path", value: repository), URLQueryItem(name: "file", value: file),
                URLQueryItem(name: "scope", value: "uncommitted"), URLQueryItem(name: "staged", value: staged ? "true" : "false")
            ])
        case .gitFileDiff(let repository, let file):
            return try Self.pathQuery(base, "api/git/file-diff", [URLQueryItem(name: "path", value: repository),
                                                                  URLQueryItem(name: "file", value: file)])
        case .gitStage(let repository, let file):
            return try Self.gitWrite(base, "api/git/review/stage", repository: repository, file: file)
        case .gitUnstage(let repository, let file):
            return try Self.gitWrite(base, "api/git/review/unstage", repository: repository, file: file)
        case .gitRevert(let repository, let file):
            return try Self.gitWrite(base, "api/git/review/revert", repository: repository, file: file)
        case .gitCommit(let repository, let message):
            return try Self.send("POST", base.appendingPathComponent("api/git/review/commit"),
                                 ["path": .string(repository), "message": .string(message), "push": .bool(false)])
        case .gitPush(let repository):
            return try Self.send("POST", base.appendingPathComponent("api/git/review/push"), ["path": .string(repository)])
        case .gitHead(let repository):
            return try Self.pathQuery(base, "api/git/review/rev-parse", [URLQueryItem(name: "path", value: repository)])
        case .gitCommitContext(let repository):
            return try Self.pathQuery(base, "api/git/review/commit-context", [URLQueryItem(name: "path", value: repository)])
        case .gitBranches(let repository):
            return try Self.pathQuery(base, "api/git/branches", [URLQueryItem(name: "path", value: repository)])
        case .gitSwitchBranch(let repository, let branch):
            guard !repository.isEmpty, Self.isBranchName(branch) else { throw BotFailure.invalidAddress }
            return try Self.send("POST", base.appendingPathComponent("api/git/branch/switch"),
                                 ["path": .string(repository), "branch": .string(branch)])
        case .fsWriteText(let path, let content):
            return try Self.send("POST", base.appendingPathComponent("api/fs/write-text"),
                                 ["path": .string(path), "content": .string(content)])
        case .filesMkdir(let path):
            return try Self.send("POST", base.appendingPathComponent("api/files/mkdir"), ["path": .string(path)])
        case .config(let profile):
            guard !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/config", profile: profile))
        case .profileSoul(let name):
            guard Self.isSegment(name) else { throw BotFailure.invalidAddress }
            return Self.get(base.appendingPathComponent("api/profiles/\(name)/soul"))
        case .setProfileSoul(let name, let content):
            guard Self.isSegment(name) else { throw BotFailure.invalidAddress }
            return try Self.send("PUT", base.appendingPathComponent("api/profiles/\(name)/soul"), ["content": .string(content)])
        case .speak(let text, let profile):
            guard !profile.isEmpty else { throw BotFailure.invalidAddress }
            return try Self.send("POST", try Self.url(base, "api/audio/speak", profile: profile), ["text": .string(text)])
        case .analyticsUsage(let days, let profile): return try Self.analytics(base, "usage", days: days, profile: profile)
        case .analyticsModels(let days, let profile): return try Self.analytics(base, "models", days: days, profile: profile)
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

    /// One analytics read for `profile` over the last `days`, a window the host accepts.
    private static func analytics(_ base: URL, _ route: String, days: Int, profile: String) throws -> URLRequest {
        guard (1...365).contains(days), !profile.isEmpty,
              var parts = URLComponents(url: base.appendingPathComponent("api/analytics").appendingPathComponent(route),
                                        resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
        parts.queryItems = [URLQueryItem(name: "days", value: String(days)), URLQueryItem(name: "profile", value: profile)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return get(url)
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

    /// A GET of `route` whose query names host paths, each `+` kept as itself: the host reads a
    /// query's `+` as a space.
    private static func pathQuery(_ base: URL, _ route: String, _ items: [URLQueryItem]) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent(route), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return get(url)
    }

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
    /// Whether `file` names one path inside a repository, as a Git write's `file` must: not blank,
    /// not absolute, no `.` or `..` part, and no empty part but a folder's trailing slash
    /// (`Sources/`, as an untracked folder's row names it).
    static func isGitFile(_ file: String) -> Bool {
        guard !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var parts = file.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Whether the host's branch sanitizer leaves `name` as it is (`_sanitize_branch` at the pin):
    /// Python word characters (letters, numerals, `_`), `.`, `/` and `-` only, no run of `-`, `/`
    /// or `.`, and none of those three at either end. Checked per scalar, not per Character: the
    /// host strips a combining mark, so "cafe" + U+0301 would switch to "cafe".
    static func isBranchName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              !"-./".unicodeScalars.contains(first), !"-./".unicodeScalars.contains(last) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
            default: scalar.properties.numericType != nil || "_./-".unicodeScalars.contains(scalar)
            }
        } && !["--", "//", ".."].contains { name.contains($0) }
    }

    /// A Git review write at `repository`, its `file` literal (`isGitFile`); nil only unstages.
    private static func gitWrite(_ base: URL, _ route: String, repository: String, file: String?) throws -> URLRequest {
        guard !repository.isEmpty, file.map(isGitFile) != false else { throw BotFailure.invalidAddress }
        var body: [String: BotJSON] = ["path": .string(repository)]
        if let file { body["file"] = .string(":(literal)" + file) }
        return try send("POST", base.appendingPathComponent(route), body)
    }

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

/// One change `HermesREST.updateSession` writes (#1046, #1048). `pinned` and `archived` apply
/// across the session's compression lineage, and `pinned: true` also unhides it; `title` names
/// that exact session, cleaned by the host, and the host refuses one already in use.
enum HermesSessionChange: Equatable, Sendable {
    /// `false` reads the session up to now for every client; `true` marks it unread.
    case unread(Bool)
    case pinned(Bool)
    case archived(Bool)
    case title(String)

    fileprivate var field: String {
        switch self {
        case .unread: return "unread"
        case .pinned: return "pinned"
        case .archived: return "archived"
        case .title: return "title"
        }
    }

    fileprivate var value: BotJSON {
        switch self {
        case .unread(let flag), .pinned(let flag), .archived(let flag): return .bool(flag)
        case .title(let title): return .string(title)
        }
    }
}
