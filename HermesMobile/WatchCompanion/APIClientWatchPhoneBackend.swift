import Foundation
import UIKit
import WatchShared

enum WatchChatCancelAcceptance {
    /// A missing `ok` still counts. Only an explicit `false` is a refusal.
    static func isAccepted(_ response: ChatCancelResponse) -> Bool {
        response.ok != false
    }
}

/// Phone execution port: scoped `APIClient` calls, never a watch-invented endpoint.
struct APIClientWatchPhoneBackend: WatchPhoneBackend {
    /// The iPhone's active server is listed first; `WatchRootModel` follows that
    /// first entry when the watch has no explicit selection of its own.
    func servers() async -> [WatchPhoneServerAccount] {
        let registry = ServerRegistry.shared
        let active = registry.activeServerID
        return registry.servers
            .sorted { lhs, rhs in
                (lhs.id == active ? 0 : 1) < (rhs.id == active ? 0 : 1)
            }
            .map {
                WatchPhoneServerAccount(
                    urlString: $0.urlString,
                    displayName: $0.displayName,
                    writesUnsupported: WatchHermesRoute.writesUnsupported($0.kind)
                )
            }
    }

    func listSessions(
        urlString: String,
        archived: Bool,
        query: String?,
        limit: Int
    ) async throws -> [WatchPhoneSessionRow] {
        // A Hermes roster is `profiles.list`. `sidebarSessions` would open webui's
        // `show_cli_sessions` gate on a host that does not have that setting.
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listSessions(
                urlString: urlString, archived: archived, query: query, limit: limit
            )
        }
        let client = try client(for: urlString)
        let summaries: [SessionSummary]
        do {
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summaries = try await client.searchSessions(query: query).sessions ?? []
            } else {
                let revealAgentSessions = URL(string: urlString)
                    .map { SessionRowDisplaySettings.showsCliSessions(for: $0) } ?? true
                summaries = try await client.sidebarSessions(
                    includeArchived: archived,
                    revealAgentSessions: revealAgentSessions
                ).sessions ?? []
            }
        } catch let error as APIError {
            // Surface auth failure distinctly so the watch can say "sign in on
            // iPhone" instead of showing an empty ready surface. Reuses the
            // same 401 mapping APIClient uses everywhere else.
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
        return summaries
            .filter { archived ? ($0.archived == true) : ($0.archived != true) }
            .prefix(limit)
            .map(Self.row(from:))
    }

    func listProfiles(urlString: String) async throws -> WatchPhoneProfilePage {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listProfiles(urlString: urlString)
        }
        let response = try await call(urlString) { try await $0.profiles() }
        let profiles = (response.profiles ?? []).compactMap { profile -> WatchPhoneProfileChoice? in
            guard let name = profile.normalizedName else { return nil }
            var label = profile.displayName
            if let model = Self.trimmed(profile.model) {
                label += "\n" + model
            }
            return WatchPhoneProfileChoice(name: Self.clip(name, maxUTF8: 256), label: Self.clip(label, maxUTF8: 240))
        }
        return WatchPhoneProfilePage(
            profiles: profiles,
            activeName: response.effectiveDefaultProfileName
        )
    }

    func switchProfile(urlString: String, name: String) async throws {
        if isHermes(urlString) {
            try await HermesWatchPhoneBackend().switchProfile(urlString: urlString, name: name)
            return
        }
        let response = try await call(urlString) { try await $0.switchProfile(name: name) }
        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    /// Running state comes from `cronStatus`, like the iPhone Tasks screen; a
    /// job's own `state` never says "running". A failed status read leaves
    /// every task not-running rather than failing the glance.
    func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance] {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listTasks(urlString: urlString, limit: limit)
        }
        let client = try client(for: urlString)
        // The phone has about 30 seconds to answer the watch. The default
        // request timeout is longer than that, so a quiet cron endpoint used
        // to expire the reply and leave Tasks spinning.
        let response: CronJobsResponse
        do {
            let data = try await client.sendData(endpoint: .crons, method: "GET", encodedBody: nil, timeout: 20)
            response = try await client.decode(CronJobsResponse.self, from: data)
        } catch let error as APIError {
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
        let running = await runningJobIDs(on: client)
        return (response.jobs ?? []).prefix(limit).compactMap { Self.taskGlance(from: $0, runningJobIDs: running) }
    }

    /// Gives the status endpoint a few seconds, then shows every task as not
    /// running. Waiting out URLSession's default timeout kept the watch spinning.
    private func runningJobIDs(on client: APIClient) async -> Set<String> {
        await withTaskGroup(of: Set<String>?.self) { group in
            group.addTask {
                guard let status = try? await client.cronStatus() else { return [] }
                return Set(status.runningJobs?.keys.map { $0 } ?? [])
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    static func taskGlance(from job: CronJob, runningJobIDs: Set<String>) -> WatchPhoneTaskGlance? {
        let id = job.jobId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = job.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jobID = (id?.isEmpty == false ? id : nil) ?? (fallback?.isEmpty == false ? fallback : nil) else {
            return nil
        }
        let schedule = job.scheduleDescription?.sentence ?? Self.trimmed(job.scheduleText) ?? "Scheduled"
        let isPaused = job.status == .paused || job.status == .off
        return WatchPhoneTaskGlance(
            id: Self.clip(jobID, maxUTF8: 256),
            name: Self.clip(job.displayName, maxUTF8: 1024),
            schedule: Self.clip(schedule, maxUTF8: 1024),
            enabled: !isPaused,
            running: runningJobIDs.contains(jobID),
            lastResult: Self.trimmed(job.lastStatus),
            lastRunAt: job.lastRunAt?.date,
            nextRunAt: isPaused ? nil : job.nextRunAt?.date,
            failureSummary: job.failureSummary.map { Self.clip($0, maxUTF8: 480) }
        )
    }

    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listTaskRuns(urlString: urlString, jobID: jobID, limit: limit)
        }
        let response = try await call(urlString) {
            try await $0.cronHistory(jobID: jobID, offset: 0, limit: min(max(limit, 1), 20))
        }
        return response.runs.prefix(limit).map {
            WatchPhoneTaskRun(id: $0.filename, finishedAt: $0.modified, durationSeconds: $0.usage.durationSeconds)
        }
    }

    func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String? {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().taskRunOutput(urlString: urlString, jobID: jobID, runID: runID)
        }
        let response = try await call(urlString) { try await $0.cronRunDetail(jobID: jobID, filename: runID) }
        return Self.trimmed(response.content) ?? Self.trimmed(response.snippet)
    }

    func listSkills(urlString: String, query: String?, limit: Int) async throws -> [WatchPhoneSkillGlance] {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listSkills(urlString: urlString, query: query, limit: limit)
        }
        let response = try await call(urlString) { try await $0.skills() }
        return Self.skillGlances(from: response.skills ?? [], query: query, limit: limit)
    }

    static func skillGlances(from skills: [SkillSummary], query: String?, limit: Int) -> [WatchPhoneSkillGlance] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return skills.compactMap { skill -> WatchPhoneSkillGlance? in
            guard let name = trimmed(skill.name) else { return nil }
            if let needle, !needle.isEmpty {
                let haystack = [name, skill.description, skill.category]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                guard haystack.contains(needle) else { return nil }
            }
            let summary = trimmed(skill.description)
                .flatMap { WatchTranscriptProjection.clippedMarkdown(WatchTranscriptProjection.wristMarkdown($0), max: 600) }
                ?? trimmed(skill.category) ?? ""
            let enabled: Bool? = skill.disabled.map { !$0 }
            return WatchPhoneSkillGlance(
                name: clip(name, maxUTF8: 256),
                summary: clip(summary, maxUTF8: 4096),
                enabled: enabled
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    func memoryGlance(urlString: String) async throws -> [WatchPhoneMemoryGlance] {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.memoryDocument) }
        let response = try await call(urlString) { try await $0.memory() }
        return Self.memoryGlances(from: response)
    }

    /// Agent notes and About you, split into `§` entries and shaped for the
    /// wrist. Persona fills in only when both are empty: the watch contract
    /// carries two sections.
    static func memoryGlances(from response: MemoryResponse) -> [WatchPhoneMemoryGlance] {
        func glance(_ section: String, _ raw: String?) -> WatchPhoneMemoryGlance? {
            guard let raw = Self.trimmed(raw) else { return nil }
            let shaped = WatchMemoryProjection.wristEntries(from: raw)
            guard !shaped.entries.isEmpty else { return nil }
            return WatchPhoneMemoryGlance(
                section: section,
                text: WatchMemoryProjection.wireContent(shaped.entries),
                isTruncated: shaped.isTruncated
            )
        }
        var sections = [glance("memory", response.memory), glance("user", response.user)].compactMap { $0 }
        if sections.isEmpty, let soul = glance("soul", response.soul) {
            sections.append(soul)
        }
        return Array(sections.prefix(2))
    }

    func usageGlance(urlString: String, days: Int) async throws -> WatchPhoneUsageGlance {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.insightsAggregate) }
        let window = min(365, max(1, days))
        let response = try await call(urlString) { try await $0.insights(days: window) }
        return Self.usageGlance(from: response, window: window)
    }

    static func usageGlance(from response: InsightsResponse, window: Int) -> WatchPhoneUsageGlance {
        let breakdown = response.models ?? []
        let models = breakdown.compactMap { Self.trimmed($0.model) }
        let modelUsage = breakdown
            .compactMap { model -> WatchPhoneModelUsage? in
                guard let name = Self.trimmed(model.model) else { return nil }
                let tokens = model.totalTokens ?? ((model.inputTokens ?? 0) + (model.outputTokens ?? 0))
                return WatchPhoneModelUsage(
                    name: Self.clip(name, maxUTF8: 240),
                    totalTokens: max(tokens, 0),
                    cost: model.cost ?? 0,
                    sessions: model.sessions ?? 0
                )
            }
            .sorted { ($0.cost, $0.totalTokens) > ($1.cost, $1.totalTokens) }
        // ISO dates sort chronologically as strings; undated rows cannot be
        // placed on the chart.
        let daily = (response.dailyTokens ?? [])
            .compactMap { day -> (String, Int)? in
                guard let date = Self.trimmed(day.date) else { return nil }
                return (date, (day.inputTokens ?? 0) + (day.outputTokens ?? 0))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        return WatchPhoneUsageGlance(
            days: response.periodDays ?? window,
            totalSessions: response.totalSessions ?? 0,
            totalMessages: response.totalMessages ?? 0,
            totalInputTokens: response.totalInputTokens ?? 0,
            totalOutputTokens: response.totalOutputTokens ?? 0,
            totalTokens: response.totalTokens ?? 0,
            totalCost: response.totalCost ?? 0,
            models: models,
            modelUsage: modelUsage,
            dailyTokens: daily
        )
    }

    func listProjects(urlString: String, limit: Int) async throws -> [WatchPhoneProjectGlance] {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.workspace) }
        let response = try await call(urlString) { try await $0.projects() }
        return (response.projects ?? []).prefix(limit).compactMap { project in
            guard let name = Self.trimmed(project.name) else { return nil }
            let id = Self.trimmed(project.projectId) ?? name
            return WatchPhoneProjectGlance(id: Self.clip(id, maxUTF8: 256), name: Self.clip(name, maxUTF8: 240))
        }
    }

    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listKanbanCards(urlString: urlString, limit: limit)
        }
        let client = try client(for: urlString)
        let boards: KanbanBoardsResponse
        do {
            let boardList = try await client.sendData(
                endpoint: .kanbanBoards,
                method: "GET",
                encodedBody: nil,
                timeout: 12
            )
            boards = try await client.decode(KanbanBoardsResponse.self, from: boardList)
        } catch let error as APIError {
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
        let preferred = Self.savedBoardSlug(for: urlString)
        let slugs = Self.boardSlugsToTry(in: boards, preferred: preferred)
        guard !slugs.isEmpty else { return [] }
        // Keep going past an empty board. The iPhone's saved board, and the
        // server's active board, are often the empty default while the cards
        // live on another board. Stop before the watch's reply window closes.
        let deadline = Date().addingTimeInterval(16)
        var sawBoard = false
        var lastError: Error?
        for slug in slugs.prefix(4) {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < 1 { break }
            do {
                let data = try await client.sendData(
                    endpoint: .kanbanBoard(KanbanBoardRequest(board: slug)),
                    method: "GET",
                    encodedBody: nil,
                    timeout: min(8, remaining)
                )
                sawBoard = true
                let cards = Self.kanbanCards(fromBoardData: data, limit: limit)
                if !cards.isEmpty { return cards }
            } catch {
                lastError = error
            }
        }
        if !sawBoard, let lastError {
            if let error = lastError as? APIError {
                throw WatchCompanionError.backend(Self.authCode(for: error))
            }
            throw lastError
        }
        return []
    }

    /// The board the iPhone is browsing, including a board with no cards. The
    /// watch shows that board's statuses at zero instead of skipping to another
    /// board that happens to have cards.
    func listKanbanBoard(
        urlString: String,
        slug: String?,
        includeArchived: Bool,
        onlyMine: Bool,
        limit: Int
    ) async throws -> WatchPhoneKanbanBoardGlance {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().listKanbanBoard(
                urlString: urlString,
                slug: slug,
                includeArchived: includeArchived,
                onlyMine: onlyMine,
                limit: limit
            )
        }
        let client = try client(for: urlString)
        let boards = try await Self.kanbanBoards(on: client)
        if let slug, !slug.isEmpty {
            KanbanBoardPreference.save(slug, for: client.baseURL, in: .standard)
        }
        let preferred = (slug?.isEmpty == false ? slug : nil) ?? Self.savedBoardSlug(for: urlString)
        let chosen = Self.boardSlugsToTry(in: boards, preferred: preferred).first
        var columns = await Self.kanbanColumnOrder(on: client)
        var cards: [WatchPhoneKanbanCardGlance] = []
        if let chosen {
            let data = try await client.sendData(
                endpoint: .kanbanBoard(KanbanBoardRequest(
                    board: chosen,
                    includeArchived: includeArchived,
                    onlyMine: onlyMine
                )),
                method: "GET",
                encodedBody: nil,
                timeout: 12
            )
            cards = Self.kanbanCards(fromBoardData: data, limit: limit, includeArchived: includeArchived)
            columns = Self.columnOrder(base: columns, boardData: data, cards: cards, includeArchived: includeArchived)
        }
        let name = Self.boardName(in: boards, slug: chosen) ?? "Kanban"
        let choices = (boards.boards ?? []).prefix(12).compactMap { board -> WatchKanbanBoardChrome.Choice? in
            guard let boardSlug = Self.trimmed(board.slug) else { return nil }
            return WatchKanbanBoardChrome.Choice(
                slug: boardSlug,
                name: Self.clip(Self.trimmed(board.name) ?? boardSlug, maxUTF8: 80)
            )
        }
        return WatchPhoneKanbanBoardGlance(
            name: Self.clip(name, maxUTF8: 80),
            slug: chosen ?? "",
            columns: columns,
            boards: choices,
            cards: cards,
            movePolicy: WatchKanbanMovePolicy.webui.rawValue
        )
    }

    private static func kanbanBoards(on client: APIClient) async throws -> KanbanBoardsResponse {
        do {
            let data = try await client.sendData(endpoint: .kanbanBoards, method: "GET", encodedBody: nil, timeout: 12)
            return try await client.decode(KanbanBoardsResponse.self, from: data)
        } catch let error as APIError {
            throw WatchCompanionError.backend(authCode(for: error))
        }
    }

    /// The six statuses the iPhone always shows, plus any column this server added.
    private static func kanbanColumnOrder(on client: APIClient) async -> [String] {
        var ordered = WatchKanbanStatus.boardOrder
        guard let data = try? await client.sendData(endpoint: .kanbanConfig, method: "GET", encodedBody: nil, timeout: 8),
              let config = try? await client.decode(KanbanConfiguration.self, from: data)
        else { return ordered }
        for name in config.columns ?? [] {
            guard let status = trimmed(name)?.lowercased(), !ordered.contains(status) else { continue }
            ordered.append(status)
        }
        return ordered
    }

    private static func columnOrder(
        base: [String],
        boardData: Data,
        cards: [WatchPhoneKanbanCardGlance],
        includeArchived: Bool
    ) -> [String] {
        var ordered = base
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try? decoder.decode(KanbanBoardSnapshot.self, from: boardData)
        for name in snapshot?.columns ?? [] {
            guard let status = trimmed(name.name)?.lowercased(), !ordered.contains(status) else { continue }
            ordered.append(status)
        }
        for card in cards where !ordered.contains(card.status) {
            ordered.append(card.status)
        }
        if includeArchived, !ordered.contains("archived") {
            ordered.append("archived")
        }
        return ordered
    }

    private static func boardName(in boards: KanbanBoardsResponse, slug: String?) -> String? {
        guard let slug else { return nil }
        return boards.boards?.first { trimmed($0.slug) == slug }.flatMap { trimmed($0.name) ?? trimmed($0.slug) }
    }

    /// Decoded columns first. If that yields nothing, walk the JSON for task
    /// objects so a shape the model does not know still reaches the watch.
    static func kanbanCards(fromBoardData data: Data, limit: Int, includeArchived: Bool = false) -> [WatchPhoneKanbanCardGlance] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let snapshot = try? decoder.decode(KanbanBoardSnapshot.self, from: data) {
            let decoded = kanbanCards(from: snapshot, limit: limit, includeArchived: includeArchived)
            if !decoded.isEmpty { return decoded }
        }
        return harvestedCards(from: data, limit: limit, includeArchived: includeArchived)
    }

    static func harvestedCards(from data: Data, limit: Int, includeArchived: Bool = false) -> [WatchPhoneKanbanCardGlance] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var cards: [WatchPhoneKanbanCardGlance] = []
        var seen = Set<String>()
        func add(_ dict: [String: Any], column: String?) {
            guard cards.count < limit else { return }
            let id = jsonString(dict["id"]) ?? jsonString(dict["task_id"]) ?? jsonString(dict["taskId"])
            let title = jsonString(dict["title"])
            let status = (jsonString(dict["status"]) ?? column)?.lowercased()
            guard let id, let title, let status, includeArchived || status != "archived", seen.insert(id).inserted else { return }
            cards.append(WatchPhoneKanbanCardGlance(
                id: String(id.prefix(256)),
                title: clip(title, maxUTF8: 1024),
                status: status,
                assignee: jsonString(dict["assignee"]).map { clip($0, maxUTF8: 240) },
                priority: jsonInt(dict["priority"]),
                body: jsonString(dict["body"]).map { clip($0, maxUTF8: 2048) },
                tenant: jsonString(dict["tenant"]).map { clip($0, maxUTF8: 240) },
                commentCount: jsonInt(dict["comment_count"] ?? dict["commentCount"]),
                linkCount: Self.linkCount(in: dict),
                ageSeconds: jsonDouble(dict["age_seconds"] ?? dict["ageSeconds"]),
                skills: jsonStrings(dict["skills"])
            ))
        }
        func walk(_ value: Any, column: String?) {
            if cards.count >= limit { return }
            if let dict = value as? [String: Any] {
                let next = jsonString(dict["name"]) ?? column
                add(dict, column: next)
                for child in dict.values { walk(child, column: next) }
            } else if let array = value as? [Any] {
                for child in array { walk(child, column: column) }
            }
        }
        walk(root, column: nil)
        return cards
    }

    private static func jsonString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.stringValue
        default:
            return nil
        }
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func jsonStrings(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let strings = values.compactMap { jsonString($0) }
        return strings.isEmpty ? nil : strings
    }

    private static func linkCount(in dict: [String: Any]) -> Int? {
        let raw = dict["link_counts"] ?? dict["linkCounts"]
        guard let links = raw as? [String: Any] else { return nil }
        let total = (jsonInt(links["parents"]) ?? 0) + (jsonInt(links["children"]) ?? 0)
        return total > 0 ? total : nil
    }

    /// The iPhone stores the browsed board under the server URL's absolute
    /// string, with or without a trailing slash.
    static func savedBoardSlug(for urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternates = trimmed.hasSuffix("/")
            ? [trimmed, String(trimmed.dropLast())]
            : [trimmed, trimmed + "/"]
        for candidate in alternates {
            guard let url = URL(string: candidate),
                  let saved = KanbanBoardPreference.savedSlug(for: url, in: .standard)
            else { continue }
            let slug = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !slug.isEmpty { return slug }
        }
        return nil
    }

    /// Order: the board the iPhone is browsing, then the server's active board,
    /// then any other board that reports cards. Duplicates are skipped.
    static func boardSlugsToTry(in boards: KanbanBoardsResponse, preferred: String?) -> [String] {
        let listed = boards.boards ?? []
        func known(_ slug: String) -> Bool {
            listed.isEmpty || listed.contains { trimmed($0.slug) == slug }
        }
        var ordered: [String] = []
        func append(_ slug: String?) {
            guard let slug = trimmed(slug), known(slug), !ordered.contains(slug) else { return }
            ordered.append(slug)
        }
        append(preferred)
        append(boards.current)
        append(listed.first { $0.isCurrent == true }?.slug)
        let rest = listed
            .filter { trimmed($0.slug).map { !ordered.contains($0) } ?? false }
            .sorted { cardCount($0) > cardCount($1) }
        for board in rest where cardCount(board) > 0 {
            append(board.slug)
        }
        if ordered.isEmpty {
            append(listed.compactMap { trimmed($0.slug) }.first)
        }
        return ordered
    }

    private static func cardCount(_ board: KanbanBoard) -> Int {
        if let total = board.total { return total }
        return board.counts?.values.reduce(0, +) ?? 0
    }

    /// Cards in board order. A Card without an id cannot be moved, so it is
    /// dropped rather than given an invented one; archived Cards stay on iPhone.
    static func kanbanCards(from snapshot: KanbanBoardSnapshot, limit: Int, includeArchived: Bool = false) -> [WatchPhoneKanbanCardGlance] {
        var cards: [WatchPhoneKanbanCardGlance] = []
        for column in snapshot.columns ?? [] {
            let columnStatus = Self.trimmed(column.name)?.lowercased()
            guard includeArchived || columnStatus != "archived" else { continue }
            for card in column.cards ?? [] {
                guard cards.count < limit else { return cards }
                guard let id = Self.trimmed(card.cardID), id.utf8.count <= 256,
                      let status = Self.trimmed(card.status?.rawValue)?.lowercased() ?? columnStatus
                else { continue }
                let links = (card.linkCounts?.parents ?? 0) + (card.linkCounts?.children ?? 0)
                cards.append(WatchPhoneKanbanCardGlance(
                    id: id,
                    title: Self.clip(Self.trimmed(card.title) ?? "Card", maxUTF8: 1024),
                    status: status,
                    assignee: Self.trimmed(card.assignee),
                    priority: card.priority,
                    body: Self.trimmed(card.body).map { Self.clip($0, maxUTF8: 2048) },
                    tenant: Self.trimmed(card.tenant),
                    commentCount: card.commentCount,
                    linkCount: links > 0 ? links : nil,
                    ageSeconds: card.ageSeconds,
                    skills: card.skills?.compactMap { Self.trimmed($0) }
                ))
            }
        }
        return cards
    }

    func controlTask(urlString: String, jobID: String, action: String) async throws {
        if isHermes(urlString) {
            try await HermesWatchPhoneBackend().controlTask(urlString: urlString, jobID: jobID, action: action)
            return
        }
        let client = try client(for: urlString)
        let response: CronMutationResponse
        switch action {
        case TaskControl.run.rawValue:
            response = try await client.runCron(jobID: jobID)
        case TaskControl.pause.rawValue:
            response = try await client.pauseCron(jobID: jobID)
        case TaskControl.resume.rawValue:
            response = try await client.resumeCron(jobID: jobID)
        default:
            throw WatchCompanionError.backend(.invalidResponse)
        }
        if response.ok == false {
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.skills) }
        let response = try await client(for: urlString).toggleSkill(name: name, enabled: enabled)
        if response.ok == false {
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    func createKanbanCard(urlString: String, boardSlug: String, title: String, status: String) async throws {
        if isHermes(urlString) {
            try await HermesWatchPhoneBackend().createKanbanCard(
                urlString: urlString, boardSlug: boardSlug, title: title, status: status
            )
            return
        }
        let client = try client(for: urlString)
        do {
            let response = try await client.createKanbanCard(KanbanCreateCardRequest(
                board: boardSlug,
                title: title,
                body: nil,
                status: status,
                priority: nil,
                assignee: nil,
                tenant: nil,
                workspaceKind: "scratch",
                workspacePath: nil,
                skills: nil,
                maxRuntimeSeconds: nil,
                prerequisiteID: nil,
                idempotencyKey: UUID().uuidString
            ))
            _ = try KanbanCardMutationValidator.validate(response, expectedCardID: nil)
        } catch let error as APIError {
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
    }

    func dispatchKanban(urlString: String, boardSlug: String, dryRun: Bool) async throws -> String {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().dispatchKanban(
                urlString: urlString, boardSlug: boardSlug, dryRun: dryRun
            )
        }
        let client = try client(for: urlString)
        let result: KanbanDispatchResult
        do {
            result = try await client.dispatchKanban(KanbanDispatchRequest(board: boardSlug, dryRun: dryRun))
        } catch let error as APIError {
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
        return Self.dispatchSummary(result, dryRun: dryRun)
    }

    static func dispatchSummary(_ result: KanbanDispatchResult, dryRun: Bool) -> String {
        let rows: [(String, Int?)] = [
            ("Spawned", result.spawned),
            ("Promoted", result.promoted),
            ("Reclaimed", result.reclaimed),
            ("Skipped unassigned", result.skippedUnassigned),
            ("Skipped", result.skippedNonspawnable),
            ("Auto blocked", result.autoBlocked),
            ("Timed out", result.timedOut),
            ("Crashed", result.crashed),
        ]
        let summary = rows.compactMap { name, count in count.map { "\(name) \($0)" } }.joined(separator: "\n")
        return summary.isEmpty ? (dryRun ? "Preview ready." : "Dispatcher finished.") : summary
    }

    /// Only the wrist's destinations (the iPhone's ordinary moves plus Done);
    /// success means the server's returned Card carries the new status, the
    /// same settlement rule the iPhone Kanban screen uses.
    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
        if isHermes(urlString) {
            try await HermesWatchPhoneBackend().moveKanbanCard(
                urlString: urlString, cardID: cardID, status: status, boardSlug: boardSlug
            )
            return
        }
        guard WatchKanbanStatus.allowsDestination(status.lowercased(), policy: .webui) else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        let slug = boardSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        let client = try client(for: urlString)
        let response = try await call(urlString) { _ in
            try await client.setKanbanCardStatus(
                KanbanCardStatusRequest(cardID: cardID, board: slug, status: status)
            )
        }
        let card = try KanbanCardMutationValidator.validate(response, expectedCardID: cardID)
        guard card.status?.rawValue.lowercased() == status.lowercased() else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    private func call<T>(_ urlString: String, _ work: (APIClient) async throws -> T) async throws -> T {
        let client = try client(for: urlString)
        do {
            return try await work(client)
        } catch let error as APIError {
            throw WatchCompanionError.backend(Self.authCode(for: error))
        }
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func clip(_ value: String, maxUTF8: Int) -> String {
        if value.utf8.count <= maxUTF8 { return value }
        var kept = ""
        var used = 0
        for character in value {
            let next = used + character.utf8.count
            if next > maxUTF8 { break }
            kept.append(character)
            used = next
        }
        return kept
    }

    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.createSession) }
        let created = try await client(for: urlString).createSession(
            workspace: workspace,
            model: nil,
            modelProvider: nil,
            profile: profileID
        )
        guard let sessionID = created.session?.sessionId, !sessionID.isEmpty else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        return sessionID
    }

    func startChat(urlString: String, sessionID: String, message: String) async throws -> String {
        try await startChat(urlString: urlString, sessionID: sessionID, message: message, attachments: nil)
    }

    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.send) }
        let payloads = attachments?.map(\.jsonValue)
        let response = try await client(for: urlString).startChat(
            sessionID: sessionID,
            message: message,
            workspace: nil,
            model: nil,
            attachments: payloads
        )
        if let error = response.error, !error.isEmpty {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        guard let streamID = response.streamId, !streamID.isEmpty else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        let noticeURL = urlString
        let noticeSession = sessionID
        let noticeStream = streamID
        Task {
            await self.deliverReplyWhenSettled(
                urlString: noticeURL,
                sessionID: noticeSession,
                streamID: noticeStream
            )
        }
        return streamID
    }

    /// A watch-started run returns as soon as the stream id exists. This waits
    /// for that stream to finish, then hands the reply to the watch as a
    /// notification. A long run that outlives the phone's background time still
    /// shows on Now the next time the wrist opens it.
    private func deliverReplyWhenSettled(urlString: String, sessionID: String, streamID: String) async {
        let token = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "hermex.watch.reply") {}
        }
        defer {
            let ending = token
            if ending != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(ending) }
            }
        }
        var finished = false
        for attempt in 0..<12 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            if Task.isCancelled { return }
            if await streamIsConfirmedFinished(urlString: urlString, streamID: streamID) {
                finished = true
                break
            }
        }
        // A run that is still going, or whose status never confirmed, must not
        // notify. The latest transcript can still be the previous answer.
        guard finished else { return }
        guard let page = try? await transcript(urlString: urlString, sessionID: sessionID, before: nil, limit: 8),
              let body = WatchReplyNotice.assistantText(in: page.blocks)
        else { return }
        await MainActor.run {
            PhoneWatchConnectivityHost.shared.deliverReply(body: body, sessionID: sessionID)
        }
    }

    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.send) }
        let response = try await client(for: urlString).uploadFile(
            sessionID: sessionID,
            data: data,
            filename: filename
        )
        if let error = response.error, !error.isEmpty {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        guard let path = response.path, !path.isEmpty else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        let name = response.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchChatAttachment(
            name: (name?.isEmpty == false) ? name! : filename,
            path: path,
            mime: response.mime ?? "application/octet-stream",
            size: response.size,
            isImage: response.isImage ?? false
        )
    }

    func cancelChat(urlString: String, streamID: String) async throws {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.stop) }
        let response = try await client(for: urlString).cancelChat(streamID: streamID)
        // `ok: false` is a refused cancel. Treating it as success hid Stop
        // while the server kept running. A missing `ok` is still acceptance,
        // matching the phone's `cancelActiveStream`.
        guard WatchChatCancelAcceptance.isAccepted(response) else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    func transcript(
        urlString: String,
        sessionID: String,
        before: Int?,
        limit: Int
    ) async throws -> WatchPhoneTranscriptPage {
        if isHermes(urlString) {
            return try await HermesWatchPhoneBackend().transcript(
                urlString: urlString, sessionID: sessionID, before: before, limit: limit
            )
        }
        let detail = try await client(for: urlString).session(
            id: sessionID,
            includeMessages: true,
            messageLimit: limit,
            messageBefore: before
        ).session
        let messages = detail?.messages ?? []
        let window = Array(messages.suffix(limit))
        let blocks = window.enumerated().flatMap { offset, message in
            WatchTranscriptProjection.blocks(for: Self.hint(from: message, ordinal: offset))
        }
        return WatchPhoneTranscriptPage(
            blocks: Array(blocks),
            nextBefore: detail?.messagesOffset,
            isTruncated: detail?.messagesTruncated == true || messages.count > window.count
        )
    }

    func mediaData(urlString: String, sessionID: String, path: String) async throws -> Data {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.media) }
        return try await client(for: urlString).mediaData(sessionID: sessionID, path: path)
    }

    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String {
        let raw = UserDefaults.standard.string(forKey: ComposerSTTProviderPreference.storageKey) ?? ""
        if isHermes(urlString) {
            // HermesTranscription is not in this tree. The server closure fails
            // before any request, so the composer's on-device provider can still run.
            let speechAuthorized = await WatchVoiceNoteTranscription.speechAlreadyAuthorized()
            let preference = ComposerSTTProviderPreference.storedValue(raw)
            return try await WatchVoiceNoteTranscription.transcript(
                preference: preference,
                speechAuthorized: speechAuthorized,
                onDeviceSupported: speechAuthorized,
                server: { throw WatchCompanionError.backend(.invalidResponse) },
                onDevice: { try await WatchVoiceNoteTranscription.recognizeOnDevice(data: data) }
            )
        }
        let preference = ComposerSTTProviderPreference.storedValue(raw)
        // Status only. Requesting authorization would prompt a locked phone.
        let speechAuthorized = await WatchVoiceNoteTranscription.speechAlreadyAuthorized()
        return try await WatchVoiceNoteTranscription.transcript(
            preference: preference,
            speechAuthorized: speechAuthorized,
            onDeviceSupported: speechAuthorized,
            server: { try await self.serverTranscript(urlString: urlString, data: data, filename: filename) },
            onDevice: { try await WatchVoiceNoteTranscription.recognizeOnDevice(data: data) }
        )
    }

    private func serverTranscript(urlString: String, data: Data, filename: String) async throws -> String {
        let response = try await client(for: urlString).transcribeAudio(data: data, filename: filename)
        guard let text = WatchVoiceNoteTranscription.serverTranscriptText(
            transcript: response.transcript,
            error: response.error
        ) else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        return text
    }

    /// `true` only when this stream's own status says it has finished.
    /// A missing status, or a session that is merely not streaming yet, is not
    /// enough: that race used to notify the watch with the previous answer.
    private func streamIsConfirmedFinished(urlString: String, streamID: String) async -> Bool {
        guard let status = try? await client(for: urlString).chatStreamStatus(streamID: streamID) else {
            return false
        }
        if status.journal?.terminal == true { return true }
        return status.active == false
    }

    func runPhase(
        urlString: String,
        sessionID: String,
        streamID: String
    ) async throws -> (phase: WatchRunPhase, isTerminal: Bool) {
        if isHermes(urlString) { throw WatchCompanionError.unsupported(.runState) }
        let client = try client(for: urlString)
        if let status = try? await client.chatStreamStatus(streamID: streamID) {
            let terminal = status.journal?.terminal == true || status.active == false
            let phase: WatchRunPhase = terminal ? .completed : .responding
            return (phase, terminal)
        }
        let status = try await client.sessionStatus(id: sessionID)
        let streaming = status.isStreaming == true || status.activeStreamId == streamID
        return (streaming ? .responding : .completed, !streaming)
    }

    private func isHermes(_ urlString: String) -> Bool {
        WatchHermesRoute.kind(of: urlString, accounts: ServerRegistry.shared.servers) == .hermes
    }

    private func client(for urlString: String) throws -> APIClient {
        guard let url = URL(string: urlString) else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        let headers = headers(for: urlString)
        return APIClient(baseURL: url, customHeaderProvider: { headers })
    }

    /// Headers resolve by URL because that is what the watch scope maps to; the
    /// active server's live edits come from the store, the rest from their
    /// per-server Keychain scope, so server A's proxy token never reaches server B.
    private func headers(for urlString: String) -> [CustomHeader] {
        if urlString == ServerRegistry.shared.activeServer?.urlString {
            return CustomHeaderStore.shared.snapshot()
        }
        if let stored = try? KeychainStore().load(.customHeaders, scope: urlString) {
            return [CustomHeader].decodeFromStorage(stored)
        }
        return []
    }

    private static func row(from summary: SessionSummary) -> WatchPhoneSessionRow {        WatchPhoneSessionRow(
            sessionID: summary.id,
            title: summary.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled",
            profile: summary.profile,
            workspaceLabel: summary.workspace,
            updatedAt: summary.updatedAt.map { Date(timeIntervalSince1970: $0) }
                ?? summary.lastMessageAt.map { Date(timeIntervalSince1970: $0) },
            isPinned: summary.pinned == true,
            isArchived: summary.archived == true,
            attention: summary.signalsAttention,
            runState: summary.isStreaming == true ? .responding : nil
        )
    }

    /// Desktop transcripts often omit `message_id`. `ChatMessage.id` then folds
    /// the whole body into the identity, which is longer than the watch wire
    /// allows, so one long reply rejected the entire conversation.
    static func hint(from message: ChatMessage, ordinal: Int) -> WatchPhoneMessageHint {
        let rawRole = message.role?.lowercased()
        let isToolResult = rawRole == "tool"
        let attachments = (message.attachments ?? []).map { attachment in
            WatchPhoneAttachmentHint(
                name: attachment.name ?? URL(fileURLWithPath: attachment.path ?? "file").lastPathComponent,
                path: attachment.path,
                mime: attachment.mime,
                isImage: attachment.isImage == true || Self.isImagePath(attachment.path ?? attachment.name)
            )
        }
        let tools: [WatchPhoneToolHint]
        if isToolResult {
            tools = [
                WatchPhoneToolHint(
                    title: message.name ?? "Tool",
                    state: "done",
                    summary: message.content
                ),
            ]
        } else {
            tools = Self.toolHints(from: message.toolCalls)
        }
        return WatchPhoneMessageHint(
            id: watchMessageID(message, ordinal: ordinal),
            role: role(from: message.role),
            text: message.content ?? "",
            attachments: attachments,
            tools: tools,
            isToolResult: isToolResult
        )
    }

    static func watchMessageID(_ message: ChatMessage, ordinal: Int) -> String {
        if let messageID = message.messageId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !messageID.isEmpty {
            return String(messageID.prefix(64))
        }
        let stamp = message.timestamp.map { String(Int($0)) } ?? "0"
        return "m\(ordinal)-\(message.role ?? "msg")-\(stamp)"
    }

    static func toolHints(from calls: [JSONValue]?) -> [WatchPhoneToolHint] {
        (calls ?? []).compactMap { call in
            guard case .object(let object) = call else { return nil }
            let function = object["function"].flatMap { value -> [String: JSONValue]? in
                if case .object(let nested) = value { return nested }
                return nil
            }
            let title = object["name"]?.lossyString
                ?? function?["name"]?.lossyString
                ?? "Tool"
            let state = object["status"]?.lossyString
                ?? object["state"]?.lossyString
                ?? "called"
            let summary = object["summary"]?.lossyString
                ?? function?["arguments"]?.lossyString
            return WatchPhoneToolHint(title: title, state: state, summary: summary)
        }
    }

    static func isImagePath(_ value: String?) -> Bool {
        guard let value else { return false }
        let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext)
    }

    static func role(from raw: String?) -> WatchMessageRole {
        switch raw?.lowercased() {
        case "assistant": return .assistant
        case "system": return .system
        default: return .user
        }
    }

    /// Maps an `APIError` to the sanitized diagnostic code the watch should see.
    /// A 401 (or `.unauthorized`) means the iPhone's session for this server is
    /// gone; the watch must tell the user to sign in on iPhone rather than
    /// present an empty ready surface. Everything else stays a generic failure.
    static func authCode(for error: APIError) -> SanitizedDiagnosticCode {
        switch error {
        case .unauthorized:
            return .authRequired
        case .http(let status, _) where status == 401:
            return .authRequired
        default:
            return .unknown
        }
    }
}

private extension JSONValue {
    var lossyString: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }
}

private extension WatchChatAttachment {
    /// Same object the iOS composer sends as `PendingAttachment.toJSONValue`.
    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "path": .string(path),
            "mime": .string(mime),
            "is_image": .bool(isImage),
        ]
        if let size {
            object["size"] = .number(Double(size))
        }
        return .object(object)
    }
}

private extension String {
    var nilIfEmpty: String? {
        allSatisfy(\.isWhitespace) ? nil : self
    }
}
