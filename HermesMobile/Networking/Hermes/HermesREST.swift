import Foundation

enum HermesREST: Equatable, Sendable {
    static let platformNote = """
        You are chatting with the user through Hermex, a native iPhone app for Hermes. Markdown renders. \
        To send the user a file from this machine, write MEDIA:/absolute/path/to/file in your reply: \
        images show inline, audio plays in the chat, video opens from a tile, and any other file arrives \
        as a file the user can save or share. Send the file rather than asking the user to open a path. \
        Hermex has no tours, tips, panes or layouts: don't call gui_tour or show_tip; set_theme changes \
        only light, dark and the accent.
        """

    static let sessionPageSize = 100
    static let transcriptPageSize = 100
    static let sessionSearchLimit = 50
    static let sessionSearchMaximum = 100

    case status
    case dashboardPage
    case login(username: String, password: String)
    case nativeRefresh(refreshToken: String, provider: String)
    case nativeToken(code: String, verifier: String)
    case identity
    case profilesActive
    case ticket
    case profileTicket(profile: String)
    case deleteProfile(name: String)
    case uploadImage(profile: String, filename: String, dataURL: String)
    case transcribe(profile: String, dataURL: String, mimeType: String)
    case downloadArtifact(path: String, profile: String, sessionID: String?)
    case environment(profile: String)
    case setEnvironment(key: String, value: String, profile: String?)
    case removeEnvironment(key: String, profile: String)
    case installPlugin(identifier: String, ref: String? = nil)
    case removePlugin(name: String)
    case screenCapabilities
    case screenStatus
    case screenObserve
    case screenAcquire(viewerID: String)
    case screenRelease(viewerID: String?)
    case setPlugin(name: String, enabled: Bool)
    case restartGateway(profile: String? = nil)
    case messagingPlatforms(profile: String)
    case memoryStatus(profile: String)
    case pluginCatalog
    case pushPairing
    case pluginCapabilities
    case companionProviderQuota(provider: String, profile: String, refresh: Bool)
    case restartDashboard
    case pluginsHub
    case sessionMessages(key: String, profile: String, offset: Int? = nil)
    case sessionList(profile: String, offset: Int, archived: Bool = false, scheduled: Bool = false, limit: Int? = nil)
    case sessionScan(profile: String, offset: Int)
    case updateSession(key: String, profile: String, change: HermesSessionChange, identity: HermesSessionWriteIdentity?)
    case sessionMutationSnapshot(key: String, profile: String)
    case sessionExport(key: String, profile: String)
    case sessionRow(key: String, profile: String)
    case importSessions(body: Data, identity: HermesSessionWriteIdentity)
    case sessionSearch(query: String, profile: String, limit: Int = sessionSearchLimit, scheduled: Bool = false)
    case cronJobs
    case cronCreate(profile: String?, fields: [String: BotJSON])
    case cronUpdate(id: String, profile: String?, updates: [String: BotJSON])
    case cronPause(id: String, profile: String?)
    case cronResume(id: String, profile: String?)
    case cronDelete(id: String, profile: String?)
    case cronTrigger(id: String, profile: String?)
    case cronRuns(id: String, profile: String?, limit: Int)
    case cronDeliveryTargets(profile: String?)
    case skills(profile: String?)
    case setSkill(name: String, enabled: Bool, profile: String?)
    case skillContent(name: String, profile: String?)
    case fsList(path: String)
    case fsReadText(path: String)
    case gitRoot(path: String)
    case gitStatus(repository: String)
    case gitChanges(repository: String)
    case gitDiff(repository: String, file: String, staged: Bool)
    case gitFileDiff(repository: String, file: String)
    case gitBranchChanges(repository: String)
    case gitBranchDiff(repository: String, file: String)
    case gitTurnChanges(repository: String, base: String)
    case gitTurnDiff(repository: String, file: String, base: String)
    case gitStage(repository: String, file: String)
    case gitUnstage(repository: String, file: String?)
    case gitRevert(repository: String, file: String)
    case gitCommit(repository: String, message: String)
    case gitPush(repository: String)
    case gitHead(repository: String)
    case gitCommitContext(repository: String)
    case gitBranches(repository: String)
    case gitSwitchBranch(repository: String, branch: String)
    case gitFetch(repository: String)
    case gitPull(repository: String)
    case gitCreateBranch(repository: String, name: String)
    case gitShipInfo(repository: String)
    case filesRead(path: String)
    case filesUpload(path: String, text: String)
    case config(profile: String)
    case setPlatformNote(profile: String)
    case profileSoul(name: String)
    case setProfileSoul(name: String, content: String)
    case speak(text: String, profile: String)
    case analyticsUsage(days: Int, profile: String)
    case analyticsModels(days: Int, profile: String)
    case kanbanConfig
    case kanbanBoards
    case kanbanBoard(board: String, tenant: String?, includeArchived: Bool)
    case kanbanStats(board: String)
    case kanbanAssignees(board: String)
    case kanbanTask(id: String, board: String)
    case kanbanTaskLog(id: String, board: String, tailBytes: Int)
    case kanbanCreateTask(board: String, body: [String: BotJSON])
    case kanbanUpdateTask(id: String, board: String, body: [String: BotJSON])
    case kanbanComment(id: String, board: String, body: String)
    case kanbanLink(board: String, parent: String, child: String)
    case kanbanUnlink(board: String, parent: String, child: String)
    case kanbanBulk(board: String, body: [String: BotJSON])
    case kanbanDispatch(board: String, dryRun: Bool)
    case kanbanCreateBoard(body: [String: BotJSON])
    case kanbanEditBoard(slug: String, body: [String: BotJSON])
    case kanbanArchiveBoard(slug: String)
    case kanbanSwitchBoard(slug: String)
    case updateCheck(force: Bool)
    case updateApply
    case updateStatus
    case updateReceipt
    case health
    case migrationPlan
    case migrateGateway

    func request(base: URL) throws -> URLRequest {
        switch self {
        case .status: return Self.get(base.appendingPathComponent("api/status"))
        case .dashboardPage: return Self.get(base.appendingPathComponent(""))
        case .health: return Self.get(base.appendingPathComponent("api/health"))
        case .migrationPlan: return Self.get(base.appendingPathComponent("api/gateway/migrate/plan"))
        case .migrateGateway: return Self.bare("POST", base.appendingPathComponent("api/gateway/migrate"))
        case .updateCheck(let force):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/hermes/update/check"),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            if force { parts.queryItems = [URLQueryItem(name: "force", value: "true")] }
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .updateApply: return Self.bare("POST", base.appendingPathComponent("api/hermes/update"))
        case .updateStatus:
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
        case .nativeRefresh(let refreshToken, let provider):
            return try Self.send("POST", base.appendingPathComponent("auth/native/refresh"), [
                "refresh_token": .string(refreshToken), "provider": .string(provider)
            ])
        case .nativeToken(let code, let verifier):
            return try Self.send("POST", base.appendingPathComponent("auth/native/token"), [
                "code": .string(code), "code_verifier": .string(verifier)
            ])
        case .identity: return Self.get(base.appendingPathComponent("api/auth/me"))
        case .profilesActive: return Self.get(base.appendingPathComponent("api/profiles/active"))
        case .ticket: return try Self.send("POST", base.appendingPathComponent("api/auth/ws-ticket"), [:])
        case .profileTicket(let profile):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/webapp/socket-ticket"),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "socket", value: "gateway"), URLQueryItem(name: "profile", value: profile)]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return try Self.send("POST", url, [:])
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
            guard !profile.isEmpty, sessionID?.isEmpty != true else { throw BotArtifactFailure.invalidReference }
            let path = try BotArtifactReference.path(path, address: base)
            guard var parts = URLComponents(url: base.appendingPathComponent("api/fs/download"), resolvingAgainstBaseURL: false)
            else { throw BotArtifactFailure.invalidReference }
            parts.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: profile)]
                + (sessionID.map { [URLQueryItem(name: "session_id", value: $0)] } ?? [])
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw BotArtifactFailure.invalidReference }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return request
        case .environment(let profile): return Self.get(try Self.url(base, "api/env", profile: profile))
        case .setEnvironment(let key, let value, let profile):
            var body: [String: BotJSON] = ["key": .string(key), "value": .string(value)]
            if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
            return try Self.send("PUT", base.appendingPathComponent("api/env"), body)
        case .removeEnvironment(let key, let profile):
            return try Self.send("DELETE", base.appendingPathComponent("api/env"), ["key": .string(key), "profile": .string(profile)])
        case .installPlugin(let identifier, let ref):
            var body: [String: BotJSON] = ["identifier": .string(identifier), "enable": .bool(true), "force": .bool(true)]
            if let ref { body["ref"] = .string(ref) }
            return try Self.send("POST", base.appendingPathComponent("api/dashboard/agent-plugins/install"), body)
        case .removePlugin(let name):
            var request = URLRequest(url: base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name))
            request.httpMethod = "DELETE"
            return request
        case .screenCapabilities: return Self.get(Self.screenRoute(base, "capabilities"))
        case .screenStatus: return Self.get(Self.screenRoute(base, "status"))
        case .screenObserve: return try Self.send("POST", Self.screenRoute(base, "observe"), [:])
        case .screenAcquire(let viewerID):
            return try Self.send("POST", Self.screenRoute(base, "lease/acquire"), ["viewer_id": .string(viewerID)])
        case .screenRelease(let viewerID):
            var body: [String: BotJSON] = ["force": .bool(true)]
            if let viewerID { body["viewer_id"] = .string(viewerID) }
            return try Self.send("POST", Self.screenRoute(base, "lease/release"), body)
        case .setPlugin(let name, let enabled):
            let url = base.appendingPathComponent("api/dashboard/agent-plugins").appendingPathComponent(name)
                .appendingPathComponent(enabled ? "enable" : "disable")
            return try Self.send("POST", url, [:])
        case .restartGateway(let profile): return try Self.send("POST", try Self.url(base, "api/gateway/restart", profile: profile), [:])
        case .messagingPlatforms(let profile): return Self.get(try Self.url(base, "api/messaging/platforms", profile: profile))
        case .memoryStatus(let profile): return Self.get(try Self.url(base, "api/memory", profile: profile))
        case .pluginCatalog: return Self.get(base.appendingPathComponent("api/dashboard/plugins/catalog"))
        case .pushPairing: return Self.get(base.appendingPathComponent("api/plugins/hermex-push/pairing"))
        case .pluginCapabilities: return Self.get(base.appendingPathComponent("api/plugins/hermex-push/capabilities"))
        case .companionProviderQuota(let provider, let profile, let refresh):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/plugins/hermex-push/provider-quota"),
                                            resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "profile", value: profile)]
                + (refresh ? [URLQueryItem(name: "refresh", value: "1")] : [])
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .restartDashboard: return try Self.send("POST", base.appendingPathComponent("api/plugins/hermex-push/restart"), [:])
        case .pluginsHub: return Self.get(base.appendingPathComponent("api/dashboard/plugins/hub"))
        case .sessionMessages(let key, let profile, let offset):
            guard Self.isSegment(key), !profile.isEmpty, (offset ?? 0) >= 0,
                  var parts = URLComponents(url: try Self.url(base, "api/sessions/\(key)/messages", profile: profile),
                                            resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
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
        case .sessionList(let profile, let offset, let archived, let scheduled, let limit):
            guard !profile.isEmpty, offset >= 0,
                  var parts = URLComponents(url: base.appendingPathComponent("api/sessions"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [
                URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "order", value: "recent"),
                URLQueryItem(name: "archived", value: archived ? "only" : "exclude"),
                URLQueryItem(name: "limit", value: String(limit ?? Self.sessionPageSize)),
                URLQueryItem(name: "offset", value: String(offset))
            ] + (archived ? [] : [URLQueryItem(name: "min_messages", value: "1")]) + (scheduled ? [
                URLQueryItem(name: "sources", value: "cron"),
                URLQueryItem(name: "exclude_sources", value: "kanban,oneshot,subagent,tool")
            ] : [URLQueryItem(name: "exclude_sources", value: archived ? "kanban,oneshot,subagent,tool" : "cron,kanban,oneshot,subagent,tool")])
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .sessionScan(let profile, let offset):
            guard !profile.isEmpty, offset >= 0,
                  var parts = URLComponents(url: base.appendingPathComponent("api/sessions"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [
                URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "order", value: "created"),
                URLQueryItem(name: "archived", value: "include"),
                URLQueryItem(name: "limit", value: String(Self.sessionPageSize)), URLQueryItem(name: "offset", value: String(offset))
            ]
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .updateSession(let key, let profile, let change, let identity):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return try Self.send("PATCH", base.appendingPathComponent("api/sessions").appendingPathComponent(key),
                                 [change.field: change.value, "profile": .string(profile)].merging(identity?.fields ?? [:]) { $1 })
        case .sessionMutationSnapshot(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)/mutation-snapshot", profile: profile))
        case .sessionExport(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)/export", profile: profile))
        case .sessionRow(let key, let profile):
            guard Self.isSegment(key), !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/sessions/\(key)", profile: profile))
        case .importSessions(let body, let identity):
            guard body.first == UInt8(ascii: "{") else { throw BotFailure.unsupported }
            var request = Self.bare("POST", base.appendingPathComponent("api/sessions/import"))
            request.httpBody = Data("{".utf8) + identity.leadingMembers + body.dropFirst()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        case .sessionSearch(let query, let profile, let limit, let scheduled):
            guard !query.isEmpty, !profile.isEmpty,
                  var parts = URLComponents(url: base.appendingPathComponent("api/sessions/search"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [
                URLQueryItem(name: "q", value: query), URLQueryItem(name: "profile", value: profile),
                URLQueryItem(name: "limit", value: String(limit))
            ] + (scheduled ? [URLQueryItem(name: "sources", value: "cron"),
                              URLQueryItem(name: "exclude_sources", value: "kanban,oneshot,subagent,tool")]
                 : [URLQueryItem(name: "exclude_sources", value: "cron,kanban,oneshot,subagent,tool")])
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
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = parts.url else { throw BotFailure.invalidAddress }
            return Self.get(url)
        case .fsReadText(let path):
            guard var parts = URLComponents(url: base.appendingPathComponent("api/fs/read-text"), resolvingAgainstBaseURL: false)
            else { throw BotFailure.invalidAddress }
            parts.queryItems = [URLQueryItem(name: "path", value: path)]
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
        case .gitBranchChanges(let repository):
            return try Self.pathQuery(base, "api/git/review/list", [URLQueryItem(name: "path", value: repository),
                                                                    URLQueryItem(name: "scope", value: "branch")])
        case .gitBranchDiff(let repository, let file):
            return try Self.pathQuery(base, "api/git/review/diff", [URLQueryItem(name: "path", value: repository),
                                                                    URLQueryItem(name: "file", value: file),
                                                                    URLQueryItem(name: "scope", value: "branch")])
        case .gitTurnChanges(let repository, let sha):
            return try Self.pathQuery(base, "api/git/review/list", [URLQueryItem(name: "path", value: repository),
                                                                    URLQueryItem(name: "scope", value: "lastTurn"),
                                                                    URLQueryItem(name: "base", value: sha)])
        case .gitTurnDiff(let repository, let file, let sha):
            return try Self.pathQuery(base, "api/git/review/diff", [URLQueryItem(name: "path", value: repository),
                                                                    URLQueryItem(name: "file", value: file),
                                                                    URLQueryItem(name: "scope", value: "lastTurn"),
                                                                    URLQueryItem(name: "base", value: sha)])
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
        case .gitFetch(let repository):
            return try Self.pluginGit(base, "fetch", repository: repository, [:])
        case .gitPull(let repository):
            return try Self.pluginGit(base, "pull", repository: repository, [:])
        case .gitCreateBranch(let repository, let name):
            guard Self.isBranchName(name) else { throw BotFailure.invalidAddress }
            return try Self.pluginGit(base, "branch", repository: repository, ["name": .string(name)])
        case .gitShipInfo(let repository):
            return try Self.pathQuery(base, "api/git/review/ship-info", [URLQueryItem(name: "path", value: repository)])
        case .filesRead(let path):
            return try Self.pathQuery(base, "api/files/read", [URLQueryItem(name: "path", value: path)])
        case .filesUpload(let path, let text):
            return try Self.send("POST", base.appendingPathComponent("api/files/upload"), [
                "path": .string(path), "overwrite": .bool(true),
                "data_url": .string("data:text/plain;base64," + Data(text.utf8).base64EncodedString())
            ])
        case .config(let profile):
            guard !profile.isEmpty else { throw BotFailure.invalidAddress }
            return Self.get(try Self.url(base, "api/config", profile: profile))
        case .setPlatformNote(let profile):
            guard !profile.isEmpty else { throw BotFailure.invalidAddress }
            let note: BotJSON = .object([HermesCall.source: .object(["append": .string(Self.platformNote)])])
            return try Self.send("PUT", try Self.url(base, "api/config", profile: profile),
                                 ["config": .object(["platform_hints": note])])
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

    private static func analytics(_ base: URL, _ route: String, days: Int, profile: String) throws -> URLRequest {
        guard (1...365).contains(days), !profile.isEmpty,
              var parts = URLComponents(url: base.appendingPathComponent("api/analytics").appendingPathComponent(route),
                                        resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
        parts.queryItems = [URLQueryItem(name: "days", value: String(days)), URLQueryItem(name: "profile", value: profile)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return get(url)
    }

    private static func kanban(_ base: URL, _ path: [String], _ query: [URLQueryItem] = [],
                               _ method: String = "GET", _ body: [String: BotJSON]? = nil) throws -> URLRequest {
        let url = path.reduce(base.appendingPathComponent("api/plugins/kanban")) { $0.appendingPathComponent($1) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        guard let body else { return get(url) }
        return try send(method, url, body)
    }

    enum UpgradePass: Equatable, Sendable {
        case ticket(String)
        case pageToken(String)
    }

    static func gatewayUpgrade(base: URL, pass: UpgradePass) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/ws"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.unsupported }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        if case .pageToken(let token) = pass { parts.queryItems = [URLQueryItem(name: "token", value: token)] }
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        var request = URLRequest(url: url)
        if case .ticket(let ticket) = pass {
            request.setValue("hermes-gateway-v1, hermes-gateway-ticket." + ticket, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        return request
    }

    static func kanbanEventsUpgrade(base: URL, board: String, since: Int, pass: UpgradePass) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/plugins/kanban/events"),
                                        resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        let credential = switch pass {
        case .ticket(let ticket): URLQueryItem(name: "ticket", value: ticket)
        case .pageToken(let token): URLQueryItem(name: "token", value: token)
        }
        parts.queryItems = [URLQueryItem(name: "board", value: board), URLQueryItem(name: "since", value: String(max(0, since))),
                            credential]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return URLRequest(url: url)
    }

    static func screenUpgrade(base: URL, ticket: String) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent("api/display/ws"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return URLRequest(url: url)
    }

    static func screenPluginUpgrade(base: URL, streamTicket: String, pass: UpgradePass) throws -> URLRequest {
        guard var parts = URLComponents(url: screenRoute(base, "stream"), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        let credential = switch pass {
        case .ticket(let ticket): URLQueryItem(name: "ticket", value: ticket)
        case .pageToken(let token): URLQueryItem(name: "token", value: token)
        }
        parts.queryItems = [credential, URLQueryItem(name: "stream_ticket", value: streamTicket)]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return URLRequest(url: url)
    }

    private static func screenRoute(_ base: URL, _ path: String) -> URL {
        base.appendingPathComponent("api/plugins/\(HermexScreenPlugin.name)/\(path)")
    }

    static func pageToken(in page: Data) -> String? {
        guard let html = String(data: page, encoding: .utf8),
              let match = html.firstMatch(of: /__HERMES_SESSION_TOKEN__\s*=\s*"([^"\\]+)"/) else { return nil }
        return String(match.1)
    }

    static func withholdsPageToken(_ page: Data) -> Bool {
        guard pageToken(in: page) == nil, let html = String(data: page, encoding: .utf8) else { return false }
        return html.contains(/__HERMES_AUTH_REQUIRED__\s*=\s*false/)
    }

    private static func get(_ url: URL) -> URLRequest { bare("GET", url) }

    private static func pluginGit(_ base: URL, _ route: String, repository: String,
                                  _ fields: [String: BotJSON]) throws -> URLRequest {
        guard !repository.isEmpty else { throw BotFailure.invalidAddress }
        return try send("POST", base.appendingPathComponent("api/plugins/hermex-push/git").appendingPathComponent(route),
                        fields.merging(["path": .string(repository)]) { $1 })
    }

    private static func pathQuery(_ base: URL, _ route: String, _ items: [URLQueryItem]) throws -> URLRequest {
        guard var parts = URLComponents(url: base.appendingPathComponent(route), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.queryItems = items
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return get(url)
    }

    private static func bare(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private static func url(_ base: URL, _ path: String, profile: String?) throws -> URL {
        guard var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        if let profile, !profile.isEmpty { parts.queryItems = [URLQueryItem(name: "profile", value: profile)] }
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }

    private static func cronJob(_ base: URL, _ id: String, _ action: String? = nil, profile: String?) throws -> URL {
        guard isSegment(id) else { throw BotFailure.invalidAddress }
        return try url(base, "api/cron/jobs/\(id)" + (action.map { "/" + $0 } ?? ""), profile: profile)
    }

    static func isGitFile(_ file: String) -> Bool {
        guard !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var parts = file.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

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

struct HermesSessionWriteIdentity: Equatable, Sendable {
    var requestID = UUID()
    let expectedRevision: Int

    fileprivate var fields: [String: BotJSON] {
        ["request_id": .string(requestID.uuidString), "expected_revision": .number(Double(expectedRevision))]
    }

    var leadingMembers: Data {
        Data(#""request_id":"\#(requestID.uuidString)","expected_revision":\#(expectedRevision),"#.utf8)
    }
}

enum HermesSessionChange: Equatable, Sendable {
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
