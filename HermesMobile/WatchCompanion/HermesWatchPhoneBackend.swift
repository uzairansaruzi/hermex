import Foundation
import WatchShared

/// How the watch phone backend chooses a Hermes host without touching webui.
enum WatchHermesRoute {
    /// A URL missing from the registry reads as webui, matching `AuthManager.kind(of:)`.
    static func kind(of urlString: String, accounts: [ServerAccount]) -> ServerKind {
        let needle = normalize(urlString)
        guard !needle.isEmpty else { return .webui }
        return accounts.first { normalize($0.id) == needle || normalize($0.urlString) == needle }?.kind ?? .webui
    }

    /// Webui's empty sidebar opens `show_cli_sessions`. A Hermes session list must not.
    static func revealsWebuiCLISessions(_ kind: ServerKind) -> Bool { kind == .webui }

    /// A Hermes Run Now answers only after the run finishes. The watch must return first.
    static func awaitsRunNowTrigger(_ features: CronFeatures) -> Bool { !features.runNowWaitsForRun }

    /// Skill toggles need `HermesSkillsClient`, which is not in this tree.
    static func togglesSkills(on kind: ServerKind) -> Bool { kind == .webui }

    /// A Hermes reply uses the phone's gateway turn. The watch only reads that server.
    static func writesUnsupported(_ kind: ServerKind) -> Bool { kind == .hermes }

    /// Hermes profile switches stay in `HermesProfilePreference`. `POST /api/profiles/active`
    /// would move the CLI and gateway default.
    static func remembersProfileLocally(_ kind: ServerKind) -> Bool { kind == .hermes }

    static func rememberedProfile(
        server: URL, listed: [String], current: String, defaults: UserDefaults = .standard
    ) -> String {
        HermesProfilePreference.resolve(for: server, listed: listed, current: current, in: defaults)
    }

    static func rememberProfile(
        _ name: String, server: URL, listed: [String], defaults: UserDefaults = .standard
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard listed.contains(trimmed) else { throw WatchCompanionError.backend(.invalidResponse) }
        HermesProfilePreference.save(trimmed, for: server, in: defaults)
    }

    static func runningJobIDs(_ list: CronJobList) -> Set<String> {
        Set(list.runningJobs.keys)
    }

    static func job(_ jobs: [CronJob], id jobID: String) -> CronJob? {
        jobs.first { job in
            guard let hostID = job.jobId?.trimmingCharacters(in: .whitespacesAndNewlines), !hostID.isEmpty else { return false }
            return hostID == jobID || APIClientWatchPhoneBackend.clip(hostID, maxUTF8: 256) == jobID
        }
    }

    /// A wrist create never picks a workspace. Omitting the kind lets a project
    /// Board keep its worktree; sending `"scratch"` would opt out of that project.
    static func createWorkspaceKind() -> String? { nil }

    /// Hermes can land a Ready request in To Do or Review. Success follows that rule.
    /// `from` is the Card's status before the write. A nil `from` cannot tell a
    /// no-op from a host that moved the Card, so a Ready landing in To Do still counts.
    static func kanbanMoveSucceeded(
        requested: String, landed: String?, from previous: String? = nil, backend: KanbanBackend
    ) -> Bool {
        let policy: WatchKanbanMovePolicy = backend == .hermes ? .hermes : .webui
        let status = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard WatchKanbanStatus.allowsDestination(status, policy: policy) else { return false }
        return backend.accepts(landed?.lowercased(), requested: status, from: previous?.lowercased())
    }

    static func sessionRows(
        from profiles: [BotProfile],
        live: [String: BotLiveStatus],
        selectedProfile: String,
        archived: Bool,
        query: String?,
        limit: Int
    ) -> [WatchPhoneSessionRow] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows: [(WatchPhoneSessionRow, Date)] = profiles.compactMap { profile in
            guard profile.hidden == archived,
                  let sessionID = APIClientWatchPhoneBackend.trimmed(profile.canonicalID) else { return nil }
            if let needle, !needle.isEmpty {
                let haystack = [profile.name, profile.id, profile.preview ?? ""].joined(separator: " ").lowercased()
                guard haystack.contains(needle) else { return nil }
            }
            let status = live[profile.id]
            let row = WatchPhoneSessionRow(
                sessionID: APIClientWatchPhoneBackend.clip(sessionID, maxUTF8: 256),
                title: APIClientWatchPhoneBackend.clip(profile.name, maxUTF8: 1024),
                profile: APIClientWatchPhoneBackend.clip(profile.id, maxUTF8: 256),
                workspaceLabel: nil,
                updatedAt: profile.lastActive,
                isPinned: profile.pinned,
                isArchived: profile.hidden,
                attention: status == .waiting,
                runState: status == .working ? .responding : (status == .waiting ? .attention : nil)
            )
            return (row, profile.lastActive ?? .distantPast)
        }
        return rows.sorted { lhs, rhs in
            let leftSelected = lhs.0.profile == selectedProfile
            let rightSelected = rhs.0.profile == selectedProfile
            if leftSelected != rightSelected { return leftSelected }
            if lhs.0.isPinned != rhs.0.isPinned { return lhs.0.isPinned }
            return lhs.1 > rhs.1
        }
        .prefix(max(limit, 0))
        .map(\.0)
    }

    static func transcriptPage(from data: Data, limit: Int) throws -> WatchPhoneTranscriptPage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(HermesWatchMessagePage.self, from: data)
        let messages = page.messages ?? []
        let window = Array(messages.suffix(max(limit, 1)))
        let blocks = window.enumerated().flatMap { offset, message in
            WatchTranscriptProjection.blocks(for: APIClientWatchPhoneBackend.hint(from: message, ordinal: offset))
        }
        return WatchPhoneTranscriptPage(
            blocks: blocks,
            nextBefore: nil,
            isTruncated: messages.count > window.count
        )
    }

    static func columns(
        in snapshot: KanbanBoardSnapshot,
        cards: [WatchPhoneKanbanCardGlance],
        includeArchived: Bool
    ) -> [String] {
        var ordered: [String] = []
        for column in snapshot.columns ?? [] {
            guard let name = APIClientWatchPhoneBackend.trimmed(column.name)?.lowercased(),
                  !ordered.contains(name) else { continue }
            ordered.append(name)
        }
        if ordered.isEmpty { ordered = hermesColumns }
        for card in cards where !ordered.contains(card.status) { ordered.append(card.status) }
        if includeArchived, !ordered.contains("archived") { ordered.append("archived") }
        if !includeArchived { ordered.removeAll { $0 == "archived" } }
        return ordered
    }

    static let hermesColumns = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]

    static func failure(_ error: Error) -> Error {
        if error is CancellationError || error is WatchCompanionError { return error }
        if case BotFailure.rejected(401) = error { return WatchCompanionError.backend(.authRequired) }
        if let api = error as? APIError {
            return WatchCompanionError.backend(APIClientWatchPhoneBackend.authCode(for: api))
        }
        return WatchCompanionError.backend(.unknown)
    }

    static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/"), trimmed.count > 1 { trimmed.removeLast() }
        return trimmed
    }
}

private struct HermesWatchMessagePage: Decodable {
    let messages: [ChatMessage]?
}

/// Holds a Hermes Run Now reply without cancelling the trigger when the watch
/// is answered first.
@MainActor
private final class RunNowOutcome {
    var result: Result<CronMutationResponse, Error>?
}

/// Watch reads and wrist actions on a saved Hermes connection. Webui custom headers
/// are never attached. Credentials stay in the phone's Keychain.
@MainActor
struct HermesWatchPhoneBackend {
    func listSessions(
        urlString: String, archived: Bool, query: String?, limit: Int
    ) async throws -> [WatchPhoneSessionRow] {
        try await attempt {
            let (url, http) = try self.connection(for: urlString)
            let (profiles, live) = try await self.roster(on: http)
            let selected = await self.selectedProfile(on: http, server: url, listed: profiles.map(\.id))
            return WatchHermesRoute.sessionRows(
                from: profiles, live: live, selectedProfile: selected,
                archived: archived, query: query, limit: limit
            )
        }
    }

    func listProfiles(urlString: String) async throws -> WatchPhoneProfilePage {
        try await attempt {
            let (url, http) = try self.connection(for: urlString)
            let client = HermesCronClient(http: http)
            let profiles = try await client.cronProfiles()
            let names = profiles.compactMap(\.normalizedName)
            let current = await self.dashboardProfile(on: http)
            let active = WatchHermesRoute.rememberedProfile(server: url, listed: names, current: current)
            let choices = profiles.compactMap { profile -> WatchPhoneProfileChoice? in
                guard let name = profile.normalizedName else { return nil }
                var label = profile.displayName
                if let model = APIClientWatchPhoneBackend.trimmed(profile.model) {
                    label += "\n" + model
                }
                return WatchPhoneProfileChoice(
                    name: APIClientWatchPhoneBackend.clip(name, maxUTF8: 256),
                    label: APIClientWatchPhoneBackend.clip(label, maxUTF8: 240)
                )
            }
            return WatchPhoneProfilePage(profiles: choices, activeName: active)
        }
    }

    func switchProfile(urlString: String, name: String) async throws {
        let page = try await listProfiles(urlString: urlString)
        guard let url = URL(string: urlString) else { throw WatchCompanionError.backend(.invalidResponse) }
        try WatchHermesRoute.rememberProfile(name, server: url, listed: page.profiles.map(\.name))
    }

    func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance] {
        try await attempt {
            let client = HermesCronClient(http: try self.connection(for: urlString).http)
            let list = try await client.cronJobs()
            let running = WatchHermesRoute.runningJobIDs(list)
            return list.jobs.prefix(limit).compactMap {
                APIClientWatchPhoneBackend.taskGlance(from: $0, runningJobIDs: running)
            }
        }
    }

    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
        try await attempt {
            let client = HermesCronClient(http: try self.connection(for: urlString).http)
            let list = try await client.cronJobs()
            guard let job = WatchHermesRoute.job(list.jobs, id: jobID), let hostID = job.jobId else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            let history = try await client.cronHistory(jobID: hostID, profile: job.profile, offset: 0, limit: limit)
            return history.runs.prefix(limit).map {
                WatchPhoneTaskRun(id: $0.filename, finishedAt: $0.modified, durationSeconds: $0.usage.durationSeconds)
            }
        }
    }

    func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String? {
        try await attempt {
            let client = HermesCronClient(http: try self.connection(for: urlString).http)
            let list = try await client.cronJobs()
            guard let job = WatchHermesRoute.job(list.jobs, id: jobID), let hostID = job.jobId else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            let detail = try await client.cronRunDetail(jobID: hostID, profile: job.profile, filename: runID)
            return APIClientWatchPhoneBackend.trimmed(detail.content) ?? APIClientWatchPhoneBackend.trimmed(detail.snippet)
        }
    }

    func controlTask(urlString: String, jobID: String, action: String) async throws {
        try await attempt {
            let client = HermesCronClient(http: try self.connection(for: urlString).http)
            let list = try await client.cronJobs()
            guard let job = WatchHermesRoute.job(list.jobs, id: jobID), let hostID = job.jobId else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            switch action {
            case TaskControl.run.rawValue:
                guard client.cronFeatures.offersRunNow(for: job), !client.cronFeatures.runNowResumes(job) else {
                    throw WatchCompanionError.backend(.invalidResponse)
                }
                let profile = job.profile
                if WatchHermesRoute.awaitsRunNowTrigger(client.cronFeatures) {
                    let response = try await client.runCron(jobID: hostID, profile: profile)
                    if response.ok == false { throw WatchCompanionError.backend(.invalidResponse) }
                    return
                }
                // The host answers only after the run. Keep the request alive, but
                // answer the watch once two seconds pass without a fast refusal.
                let outcome = RunNowOutcome()
                Task { @MainActor in
                    do { outcome.result = .success(try await client.runCron(jobID: hostID, profile: profile)) }
                    catch { outcome.result = .failure(error) }
                }
                try await Task.sleep(for: .seconds(2))
                if let result = outcome.result {
                    let response = try result.get()
                    if response.ok == false { throw WatchCompanionError.backend(.invalidResponse) }
                }
            case TaskControl.pause.rawValue:
                let response = try await client.pauseCron(jobID: hostID, profile: job.profile, reason: nil)
                if response.ok == false { throw WatchCompanionError.backend(.invalidResponse) }
            case TaskControl.resume.rawValue:
                let response = try await client.resumeCron(jobID: hostID, profile: job.profile)
                if response.ok == false { throw WatchCompanionError.backend(.invalidResponse) }
            default:
                throw WatchCompanionError.backend(.invalidResponse)
            }
        }
    }

    func listSkills(urlString: String, query: String?, limit: Int) async throws -> [WatchPhoneSkillGlance] {
        try await attempt {
            let (url, http) = try self.connection(for: urlString)
            let client = HermesCronClient(http: http)
            let names = try await client.cronProfiles().compactMap(\.normalizedName)
            let profile = WatchHermesRoute.rememberedProfile(
                server: url, listed: names, current: await self.dashboardProfile(on: http)
            )
            let skills = try await client.cronSkills(profile: profile)
            return APIClientWatchPhoneBackend.skillGlances(from: skills, query: query, limit: limit)
        }
    }

    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] {
        try await listKanbanBoard(
            urlString: urlString, slug: nil, includeArchived: false, onlyMine: false, limit: limit
        ).cards
    }

    func listKanbanBoard(
        urlString: String, slug: String?, includeArchived: Bool, onlyMine: Bool, limit: Int
    ) async throws -> WatchPhoneKanbanBoardGlance {
        try await attempt {
            let (url, http) = try self.connection(for: urlString)
            let client = HermesKanbanClient(http: http)
            let boards: KanbanBoardsResponse
            do {
                boards = try await client.kanbanBoards()
            } catch KanbanCapabilityError.kanbanUnavailable {
                return Self.emptyBoard()
            } catch BotFailure.rejected(404) {
                return Self.emptyBoard()
            }
            if let slug, !slug.isEmpty {
                KanbanBoardPreference.save(slug, for: url, in: .standard)
            }
            let preferred = (slug?.isEmpty == false ? slug : nil) ?? APIClientWatchPhoneBackend.savedBoardSlug(for: urlString)
            let chosen = APIClientWatchPhoneBackend.boardSlugsToTry(in: boards, preferred: preferred).first
            var cards: [WatchPhoneKanbanCardGlance] = []
            var columns = WatchHermesRoute.hermesColumns
            if let chosen {
                var request = KanbanBoardRequest(board: chosen, includeArchived: includeArchived)
                if onlyMine {
                    let names = try await HermesCronClient(http: http).cronProfiles().compactMap(\.normalizedName)
                    let current = await self.dashboardProfile(on: http)
                    request.assignee = WatchHermesRoute.rememberedProfile(
                        server: url, listed: names, current: current
                    )
                }
                let snapshot = try await client.kanbanBoard(request)
                cards = APIClientWatchPhoneBackend.kanbanCards(from: snapshot, limit: limit, includeArchived: includeArchived)
                columns = WatchHermesRoute.columns(in: snapshot, cards: cards, includeArchived: includeArchived)
            }
            let name = boards.boards?.first { APIClientWatchPhoneBackend.trimmed($0.slug) == chosen }
                .flatMap { APIClientWatchPhoneBackend.trimmed($0.name) ?? APIClientWatchPhoneBackend.trimmed($0.slug) }
                ?? "Kanban"
            let choices = (boards.boards ?? []).prefix(12).compactMap { board -> WatchKanbanBoardChrome.Choice? in
                guard let boardSlug = APIClientWatchPhoneBackend.trimmed(board.slug) else { return nil }
                return WatchKanbanBoardChrome.Choice(
                    slug: boardSlug,
                    name: APIClientWatchPhoneBackend.clip(
                        APIClientWatchPhoneBackend.trimmed(board.name) ?? boardSlug, maxUTF8: 80
                    )
                )
            }
            return WatchPhoneKanbanBoardGlance(
                name: APIClientWatchPhoneBackend.clip(name, maxUTF8: 80),
                slug: chosen ?? "",
                columns: columns,
                boards: choices,
                cards: cards,
                movePolicy: WatchKanbanMovePolicy.hermes.rawValue
            )
        }
    }

    func createKanbanCard(urlString: String, boardSlug: String, title: String, status: String) async throws {
        try await attempt {
            guard WatchKanbanStatus.createDestinations(policy: .hermes).contains(status.lowercased()),
                  !boardSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            let client = HermesKanbanClient(http: try self.connection(for: urlString).http)
            let response = try await client.createKanbanCard(KanbanCreateCardRequest(
                board: boardSlug, title: title, body: nil, status: status, priority: nil,
                assignee: nil, tenant: nil, workspaceKind: WatchHermesRoute.createWorkspaceKind(),
                workspacePath: nil, skills: nil, maxRuntimeSeconds: nil, prerequisiteID: nil,
                idempotencyKey: UUID().uuidString
            ))
            _ = try KanbanCardMutationValidator.validate(response, expectedCardID: nil)
        }
    }

    func dispatchKanban(urlString: String, boardSlug: String, dryRun: Bool) async throws -> String {
        try await attempt {
            let client = HermesKanbanClient(http: try self.connection(for: urlString).http)
            let result = try await client.dispatchKanban(KanbanDispatchRequest(board: boardSlug, dryRun: dryRun))
            return APIClientWatchPhoneBackend.dispatchSummary(result, dryRun: dryRun)
        }
    }

    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
        try await attempt {
            let requested = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard WatchKanbanStatus.allowsDestination(requested, policy: .hermes) else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            let slug = boardSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else { throw WatchCompanionError.backend(.invalidResponse) }
            let client = HermesKanbanClient(http: try self.connection(for: urlString).http)
            // Complete is legal only from Review. The watch hides the other
            // columns; this read is what the host has now, so a stale glance
            // cannot finish a Card the host has already moved.
            let detail = try await client.kanbanCardDetail(KanbanCardDetailRequest(cardID: cardID, board: slug))
            let previous = detail.card?.status?.rawValue
            if requested == "done", previous?.lowercased() != "review" {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            let response = try await client.setKanbanCardStatus(
                KanbanCardStatusRequest(cardID: cardID, board: slug, status: requested)
            )
            let card = try KanbanCardMutationValidator.validate(response, expectedCardID: cardID)
            guard WatchHermesRoute.kanbanMoveSucceeded(
                requested: requested, landed: card.status?.rawValue, from: previous, backend: .hermes
            ) else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
        }
    }

    func transcript(
        urlString: String, sessionID: String, before _: Int?, limit: Int
    ) async throws -> WatchPhoneTranscriptPage {
        try await attempt {
            let (url, http) = try self.connection(for: urlString)
            let (profiles, _) = try await self.roster(on: http)
            let matched = profiles.first {
                $0.canonicalID == sessionID || $0.canonicalTipID == sessionID
                    || APIClientWatchPhoneBackend.clip($0.canonicalID ?? "", maxUTF8: 256) == sessionID
            }?.id
            let owner = if let matched {
                matched
            } else {
                await self.selectedProfile(on: http, server: url, listed: profiles.map(\.id))
            }
            let data: Data
            do {
                data = try await http.data(.sessionMessages(key: sessionID, profile: owner))
            } catch BotFailure.rejected(404) {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            return try WatchHermesRoute.transcriptPage(from: data, limit: limit)
        }
    }

    // MARK: - Connection

    /// The phone's saved sign-in for this server. The active server reuses the
    /// shared connection. Any other server gets its own jar, so a watch read
    /// cannot retire the gateway the phone is using.
    private func connection(for urlString: String) throws -> (url: URL, http: HermesConnection) {
        guard let url = URL(string: urlString) else { throw WatchCompanionError.backend(.invalidResponse) }
        guard let saved = try BotConnectionStore().load(server: url) else {
            throw WatchCompanionError.backend(.authRequired)
        }
        let active = ServerRegistry.shared.activeServerID.map(WatchHermesRoute.normalize)
        if active == WatchHermesRoute.normalize(url.absoluteString) {
            return (url, HermesConnections.shared.connection(for: saved, server: url))
        }
        return (url, HermesConnection(connection: saved))
    }

    /// `GET /api/profiles/active`. Never the POST that moves the CLI default.
    private func dashboardProfile(on http: HermesConnection) async -> String {
        guard let data = try? await http.data(.profilesActive),
              let current = (try? JSONDecoder().decode(BotJSON.self, from: data))?["current"].text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else { return "default" }
        return current
    }

    private func selectedProfile(on http: HermesConnection, server: URL, listed: [String]) async -> String {
        WatchHermesRoute.rememberedProfile(
            server: server, listed: listed, current: await dashboardProfile(on: http)
        )
    }

    private func roster(on http: HermesConnection) async throws -> (profiles: [BotProfile], live: [String: BotLiveStatus]) {
        let client = BotClient(http: http)
        defer { client.close() }
        try await client.connect()
        let roster = try await client.call(.profilesList(includeSessions: true))
        let profiles = (roster["profiles"].list ?? []).compactMap(BotProfile.init)
        let live: [String: BotLiveStatus]
        if let active = try? await client.call(.sessionActiveList) {
            live = BotLiveStatus.statuses(active["sessions"].list ?? [], profiles: profiles)
        } else {
            live = [:]
        }
        return (profiles, live)
    }

    private func attempt<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch { throw WatchHermesRoute.failure(error) }
    }

    private static func emptyBoard() -> WatchPhoneKanbanBoardGlance {
        WatchPhoneKanbanBoardGlance(
            name: "Kanban", slug: "", columns: WatchHermesRoute.hermesColumns,
            boards: [], cards: [], movePolicy: WatchKanbanMovePolicy.hermes.rawValue
        )
    }
}
