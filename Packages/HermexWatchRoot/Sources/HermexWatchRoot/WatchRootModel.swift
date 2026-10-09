import CryptoKit
import Foundation
import Observation
import WatchShared

public protocol WatchCompanionLinking: Sendable {
    var isCompanionAvailable: Bool { get }
    var isReachable: Bool { get }
    /// Apple blocks WatchConnectivity until the iPhone is unlocked once after
    /// a reboot. A phone that is merely locked does not set this.
    var phoneNeedsUnlockAfterReboot: Bool { get }
    func makeService() -> any WatchCompanionServicing
    func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey>
    func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey>
}

public extension WatchCompanionLinking {
    var phoneNeedsUnlockAfterReboot: Bool { false }
}

/// One Kanban read: the board chrome (name, columns, other boards) and its cards.
public struct WatchKanbanBoardLoad: Sendable {
    public var chrome: WatchKanbanBoardChrome
    public var cards: [WatchKanbanCard]

    public init(chrome: WatchKanbanBoardChrome, cards: [WatchKanbanCard]) {
        self.chrome = chrome
        self.cards = cards
    }
}

@MainActor
@Observable
public final class WatchRootModel {
    public private(set) var state: WatchLaunchState
    public private(set) var servers: [RegistryEntry]
    public private(set) var selectedScope: ServerScope?
    public private(set) var sessions: [WatchSessionSummary]
    /// False until the first session read for this server settles. An empty
    /// list before that is "still loading", not "No sessions yet".
    public private(set) var hasLoadedSessions = false
    public private(set) var registryRevision: Revision
    public private(set) var lastErrorCode: String?
    public private(set) var nowPreview: String?
    /// The Now session's latest assistant turn as speakable words, for Read
    /// aloud. Separate from `nowPreview`, which is clipped to a glance line.
    public private(set) var nowSpokenReply: String?
    /// Set when a complication opens the app. Now consumes it once and starts
    /// a voice note; Cancel is still on screen before the note is sent.
    public private(set) var complicationRecordID: UUID?
    /// False while the watch app is not the frontmost scene, so a finished
    /// reply can be posted as a notification instead of only updating Now.
    public private(set) var isWatchForeground = false
    /// The board the watch is showing. A card move sends this slug instead of
    /// asking the phone to pick a board again.
    private(set) var kanbanBoardSlug = ""
    /// Scope the board on screen was loaded for. A phone server switch must
    /// not move a card that was read from the previous server.
    private var kanbanLoadedScope: ServerScope?
    /// Set while the phone cannot answer right now. The last ready screen stays
    /// up; this is the reason, not a reason to wipe it.
    public private(set) var phoneStatusNote: String?
    public private(set) var focusedSessionKey: SessionKey?

    private var link: (any WatchCompanionLinking)?
    private var activeRunBySession: [SessionKey: RunKey] = [:]
    private var fixtureTranscriptBySessionID: [String: [WatchTranscriptBlock]] = [:]
    private var fixtureGlances: FixtureGlances?

    /// Screenshot-fixture data for the glances, so their layout can be checked
    /// on a simulator with no paired phone.
    private struct FixtureGlances {
        var tasks: [WatchTaskSummary]
        var kanban: [WatchSkillSummary]
        var skills: [WatchSkillSummary]
        var usage: WatchInsightsAggregate?
        var memory: WatchMemoryDocument?
        var composer: WatchComposerOptions?
        var taskRuns: [String: [WatchTaskRun]] = [:]
        var taskOutputs: [String: String] = [:]
    }
    private var mediaCache: [String: Data] = [:]
    /// The watch has no server picker, so it follows whichever server the iPhone
    /// reports first (its active one). An explicit `select(_:)` pins the watch to
    /// that scope and stops the follow.
    private var followsPhoneActiveServer = true

    public init() {
        state = .setupRequired
        servers = []
        selectedScope = nil
        sessions = []
        hasLoadedSessions = false
        registryRevision = Revision(0)
        lastErrorCode = nil
        nowPreview = nil
        nowSpokenReply = nil
        focusedSessionKey = nil
    }

    public var nowSession: WatchSessionSummary? {
        let scoped = scopedSessions
        if let focusedSessionKey, let match = scoped.first(where: { $0.key == focusedSessionKey }) {
            return match
        }
        return WatchNowSession.preferred(from: scoped)
    }

    public var canStopNow: Bool {
        guard let session = nowSession else { return false }
        return activeRun(for: session) != nil
    }

    public func armComplicationRecording() {
        complicationRecordID = UUID()
        discardUnusableComplicationRecording()
    }

    /// A tap that already knows Now has no session must not start the
    /// microphone when a session appears later. A tap during the first load
    /// waits until that load says whether a session exists. A server that
    /// cannot take a watch reply never starts the microphone.
    public func discardUnusableComplicationRecording() {
        if !offersReplyControls {
            complicationRecordID = nil
            return
        }
        guard hasLoadedSessions, nowSession == nil else { return }
        complicationRecordID = nil
    }

    /// `true` the first time a complication tap is claimed, so the microphone
    /// starts once even if Now appears and the id changes in the same turn.
    public func consumeComplicationRecording() -> Bool {
        guard complicationRecordID != nil else { return false }
        complicationRecordID = nil
        return true
    }

    public func setWatchForeground(_ foreground: Bool) {
        isWatchForeground = foreground
    }

    public func attach(link: any WatchCompanionLinking) {
        self.link = link
        refreshConnection()
    }

    public func beginConnecting() {
        state = .connecting
    }

    public func markUnavailable() {
        state = .unavailable
        sessions = []
        hasLoadedSessions = false
        clearNowReply()
        focusedSessionKey = nil
        activeRunBySession = [:]
    }

    public func refreshConnection() {
        guard let link else {
            state = .setupRequired
            return
        }
        guard link.isCompanionAvailable else {
            // Companion not installed: first-run copy stays truthful.
            state = .setupRequired
            servers = []
            sessions = []
            clearNowReply()
            focusedSessionKey = nil
            activeRunBySession = [:]
            return
        }
        if link.phoneNeedsUnlockAfterReboot {
            // Apple will not deliver WatchConnectivity until the phone has
            // been unlocked once since it restarted. A locked phone after
            // that unlock is a normal wake, handled below.
            notePhoneQuiet(link)
            if state != .ready && state != .signedOut {
                state = .unavailable
            }
            return
        }
        // isReachable is false while Hermex is suspended, including when the
        // phone is locked. sendMessage still launches it in the background.
        phoneStatusNote = nil
        if state != .ready && state != .signedOut {
            beginConnecting()
        }
        let service = link.makeService()
        Task { await loadRegistry(using: service) }
    }

    /// Called by the app when WCSession reports the phone became reachable.
    /// Re-attaches and reloads the registry so a reconnect after backgrounding
    /// (or a quiet phone waking up) refreshes the wrist instead of staying stale.
    public func handleCompanionReachable() {
        refreshConnection()
    }

    /// Called by the app when WCSession reports the phone became unreachable.
    /// A locked phone is still woken by sendMessage. Only a reboot that has
    /// not been unlocked yet, or a watch with no iPhone app, leaves that screen.
    public func handleCompanionUnreachable() {
        guard let link, link.isCompanionAvailable else {
            if state != .setupRequired { state = .setupRequired }
            return
        }
        guard link.phoneNeedsUnlockAfterReboot else {
            // Reachability drops whenever Hermex is not in the foreground.
            // The in-flight sendMessage is what wakes a locked phone, so
            // this callback must not replace Connecting with "Set up on iPhone".
            phoneStatusNote = nil
            return
        }
        notePhoneQuiet(link)
        if state != .ready && state != .signedOut {
            state = .unavailable
        }
    }

    /// Apple's rule, not ours: after a reboot the iPhone must be unlocked
    /// once. After that, a locked phone should not blank the watch.
    private func notePhoneQuiet(_ link: any WatchCompanionLinking) {
        _ = link
        phoneStatusNote = "Unlock iPhone once after it restarts. It can stay locked after that."
    }

    /// Pull-to-refresh from the Sessions list (and foreground): reload the
    /// registry first so an iPhone active-server switch is followed without a
    /// relaunch, then reload sessions for the adopted scope. An explicit
    /// `select(_:)` pin still wins — `loadRegistry` only re-adopts when the
    /// watch is following the phone or the pinned scope vanished.
    public func refreshFromList() async {
        guard let link else { return }
        await loadRegistry(using: link.makeService())
    }

    public func select(_ scope: ServerScope) async {
        followsPhoneActiveServer = false
        adopt(scope)
        await loadSessions()
    }

    public func focus(_ session: WatchSessionSummary) {
        focusedSessionKey = session.key
    }

    public func loadSessions() async {
        guard let link, let scope = selectedScope else { return }
        do {
            let snapshot = try await link.makeService().refreshSessions(
                scope: scope,
                collection: .current,
                query: nil,
                localLimit: 100
            )
            // A refresh started for a server the wrist has already left must
            // not replace the new rows or clear Stop runs that belong to them.
            guard selectedScope == scope else { return }
            sessions = snapshot.value.items.filter { $0.key.scope == scope }
            dropRunsTheServerNoLongerReports()
            lastErrorCode = nil
            // A successful session load means we are genuinely ready: clear any
            // signed-out state a prior failed load may have set.
            if state == .signedOut { state = .ready }
            await refreshNowPreview()
        } catch WatchCompanionError.backend(.authRequired) {
            guard selectedScope == scope else { return }
            // The iPhone's session for this server is gone. The watch cannot
            // sign in, so present the truthful state instead of an empty ready
            // surface and disable mutations.
            state = .signedOut
            sessions = []
            clearNowReply()
            focusedSessionKey = nil
            activeRunBySession = [:]
            lastErrorCode = "authRequired"
        } catch {
            guard selectedScope == scope else { return }
            lastErrorCode = "sessionsUnavailable"
        }
        guard selectedScope == scope else { return }
        hasLoadedSessions = true
        discardUnusableComplicationRecording()
    }

    public func loadComposerOptions() async -> WatchComposerOptions? {
        if let fixtureGlances { return fixtureGlances.composer }
        return await loadGlance { service, scope in
            try await service.composerOptions(scope: scope).value
        }
    }

    // MARK: Screenshot-fixture writes

    /// The screenshot fixture has no phone to write through, so each wrist
    /// action mutates the fixture in place. A silent `true` would have made the
    /// fixture useless for checking that an action reaches the screen, so these
    /// return the same success/failure the real path does and the list reloads
    /// onto changed data.
    private func applyFixtureTaskControl(jobID: String, action: TaskControl) -> Bool {
        guard var fixture = fixtureGlances else { return false }
        guard let index = fixture.tasks.firstIndex(where: { $0.key.jobID == jobID }) else { return true }
        let task = fixture.tasks[index]
        let running = action == .run
        let enabled = action == .pause ? false : true
        if let updated = try? WatchTaskSummary(
            key: task.key,
            name: task.name,
            schedule: task.schedule,
            enabled: enabled,
            running: running,
            lastResult: running ? nil : task.lastResult,
            lastRunAt: task.lastRunAt,
            nextRunAt: enabled ? task.nextRunAt : nil,
            failureSummary: running ? nil : task.failureSummary
        ) {
            fixture.tasks[index] = updated
            fixtureGlances = fixture
        }
        lastErrorCode = nil
        return true
    }

    private func applyFixtureSkillToggle(name: String, enabled: Bool) -> Bool {
        guard var fixture = fixtureGlances else { return false }
        guard let index = fixture.skills.firstIndex(where: { $0.key.name == name }) else { return true }
        let skill = fixture.skills[index]
        if let updated = try? WatchSkillSummary(key: skill.key, summary: skill.summary, enabled: enabled) {
            fixture.skills[index] = updated
            fixtureGlances = fixture
        }
        lastErrorCode = nil
        return true
    }

    private func applyFixtureKanbanMove(cardID: String, status: String) -> Bool {
        guard var fixture = fixtureGlances else { return false }
        guard let index = fixture.kanban.firstIndex(where: { $0.key.name == cardID }) else { return true }
        let summary = fixture.kanban[index]
        let card = WatchKanbanCard(id: cardID, wireSummary: summary.summary)
        let moved = card.withStatus(status)
        if let updated = try? WatchSkillSummary(
            key: summary.key,
            summary: moved.wireSummary,
            enabled: summary.enabled
        ) {
            fixture.kanban[index] = updated
            fixtureGlances = fixture
        }
        lastErrorCode = nil
        return true
    }

    private func applyFixtureKanbanCreate(boardSlug: String, title: String, status: String) -> Bool {
        guard var fixture = fixtureGlances else { return false }
        _ = boardSlug
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let scope = fixture.kanban.first?.key.scope ?? selectedScope else { return true }
        let id = "c\(fixture.kanban.count + 1)"
        let created = WatchKanbanCard(id: id, title: trimmed, status: status, assignee: nil, priority: nil, body: nil)
        guard let key = try? SkillKey(scope: scope, name: id),
              let summary = try? WatchSkillSummary(key: key, summary: created.wireSummary, enabled: nil)
        else { return true }
        fixture.kanban.append(summary)
        fixtureGlances = fixture
        lastErrorCode = nil
        return true
    }

    private func applyFixtureProfileSwitch(name: String) -> Bool {
        guard var fixture = fixtureGlances, let composer = fixture.composer else { return false }
        if let active = try? ProfileID(name),
           let updated = try? WatchComposerOptions(
            scope: composer.scope,
            profiles: composer.profiles,
            workspaces: composer.workspaces,
            defaultProfileID: active,
            defaultWorkspaceHandle: composer.defaultWorkspaceHandle
           ) {
            fixture.composer = updated
            fixtureGlances = fixture
        }
        lastErrorCode = nil
        return true
    }

    /// Every write the iPhone accepts is fenced on the registry revision it
    /// issued (`PhoneCompanionBroker.matchesRevision`), while reads are fenced
    /// only on the scope. A revision the watch cached at connect time therefore
    /// goes stale on its own — the iPhone bumps it whenever its server list,
    /// order (an active-server switch), or display name changes, and a relaunched
    /// iPhone starts a fresh broker — and from then on every wrist action is
    /// rejected while every list still loads. Re-reading the revision from the
    /// phone immediately before a write closes that window. `registry()` is a
    /// local lookup on the iPhone, so this costs one cheap round trip.
    ///
    /// A transport failure answers with an empty registry; that must not clobber
    /// a good revision, so only a non-empty snapshot is adopted.
    @discardableResult
    private func refreshRevision(using service: any WatchCompanionServicing) async -> Revision {
        let snapshot = await service.registry()
        guard !snapshot.entries.isEmpty else { return registryRevision }
        servers = snapshot.entries
        registryRevision = snapshot.revision
        return snapshot.revision
    }

    public func switchActiveProfile(name: String) async -> Bool {
        if applyFixtureProfileSwitch(name: name) { return true }
        guard canMutate, let link, let scope = selectedScope else { return false }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        do {
            _ = try await service.switchActiveProfile(
                scope: scope,
                name: name,
                expectedRevision: revision
            )
            lastErrorCode = nil
            await loadSessions()
            return true
        } catch {
            lastErrorCode = "profileSwitchFailed"
            return false
        }
    }

    public func controlTask(jobID: String, action: TaskControl, scope: ServerScope? = nil) async -> Bool {
        if applyFixtureTaskControl(jobID: jobID, action: action) { return true }
        guard canMutate, let link, let selectedScope else { return false }
        let actionScope = scope ?? selectedScope
        guard actionScope == selectedScope else {
            lastErrorCode = "taskControlFailed"
            return false
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        let created = Date()
        do {
            let key = try TaskKey(scope: actionScope, jobID: jobID)
            let context = try CommandContext(
                stableCommandID: CommandID(rawValue: UUID()),
                scope: actionScope,
                expectedRevision: revision,
                createdAt: created,
                expiresAt: created.addingTimeInterval(60)
            )
            let receipt = await service.controlTask(key: key, action: action, context: context)
            guard receipt.receipt.phase == .acknowledged else {
                lastErrorCode = "taskControlFailed"
                return false
            }
            lastErrorCode = nil
            return true
        } catch {
            lastErrorCode = "taskControlFailed"
            return false
        }
    }

    public func setSkillEnabled(name: String, enabled: Bool, scope: ServerScope? = nil) async -> Bool {
        if applyFixtureSkillToggle(name: name, enabled: enabled) { return true }
        guard canMutate, let link, let selectedScope else { return false }
        let actionScope = scope ?? selectedScope
        guard actionScope == selectedScope else {
            lastErrorCode = "skillToggleFailed"
            return false
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        do {
            try await service.setSkillEnabled(
                scope: actionScope,
                name: name,
                enabled: enabled,
                expectedRevision: revision
            )
            lastErrorCode = nil
            return true
        } catch {
            lastErrorCode = "skillToggleFailed"
            return false
        }
    }

    public func moveKanbanCard(cardID: String, status: String) async -> Bool {
        if applyFixtureKanbanMove(cardID: cardID, status: status) { return true }
        guard canMutate, let link else { return false }
        guard let scope = readyKanbanScope() else {
            lastErrorCode = "kanbanMoveFailed"
            return false
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        do {
            let board = kanbanBoardSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !board.isEmpty else {
                lastErrorCode = "kanbanMoveFailed"
                return false
            }
            try await service.moveKanbanCard(
                scope: scope,
                cardID: cardID,
                status: status,
                boardSlug: board,
                expectedRevision: revision
            )
            lastErrorCode = nil
            return true
        } catch {
            lastErrorCode = "kanbanMoveFailed"
            return false
        }
    }

    public func createKanbanCard(boardSlug: String, title: String, status: String) async -> Bool {
        if applyFixtureKanbanCreate(boardSlug: boardSlug, title: title, status: status) { return true }
        guard canMutate, let link else { return false }
        guard let scope = readyKanbanScope() else {
            lastErrorCode = "kanbanCreateFailed"
            return false
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        do {
            try await service.createKanbanCard(
                scope: scope,
                boardSlug: boardSlug,
                title: title,
                status: status,
                expectedRevision: revision
            )
            lastErrorCode = nil
            return true
        } catch {
            lastErrorCode = "kanbanCreateFailed"
            return false
        }
    }

    /// A short count summary from the dispatcher. `nil` means it did not run.
    public func dispatchKanban(boardSlug: String, dryRun: Bool) async -> String? {
        if fixtureGlances != nil {
            lastErrorCode = nil
            return dryRun ? "Preview ready." : "Spawned 0\nPromoted 0"
        }
        guard canMutate, let link else { return nil }
        guard let scope = readyKanbanScope() else {
            lastErrorCode = "kanbanDispatchFailed"
            return nil
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        do {
            let summary = try await service.dispatchKanban(
                scope: scope,
                boardSlug: boardSlug,
                dryRun: dryRun,
                expectedRevision: revision
            )
            lastErrorCode = nil
            return summary
        } catch {
            lastErrorCode = "kanbanDispatchFailed"
            return nil
        }
    }

    public func loadTasks() async -> [WatchTaskSummary] {
        if let fixtureGlances { return fixtureGlances.tasks }
        return await loadGlance { service, scope in
            try await service.tasks(scope: scope, localLimit: 32).value.items
        } ?? []
    }

    public func loadSkills() async -> [WatchSkillSummary] {
        if let fixtureGlances { return fixtureGlances.skills }
        return await loadGlance { service, scope in
            try await service.skills(scope: scope, query: nil, localLimit: 64).value.items
        } ?? []
    }

    public func loadKanbanCards() async -> [WatchKanbanCard] {
        let summaries: [WatchSkillSummary]
        if let fixtureGlances {
            summaries = fixtureGlances.kanban
        } else {
            summaries = await loadGlance { service, scope in
                try await service.skills(scope: scope, query: WatchGlanceQuery.kanban, localLimit: 64).value.items
            } ?? []
        }
        return summaries.compactMap { summary in
            guard summary.key.name != WatchKanbanBoardChrome.cardID else { return nil }
            return WatchKanbanCard(id: summary.key.name, wireSummary: summary.summary)
        }
    }

    /// The board the iPhone is browsing, including a board whose columns are all
    /// empty. `nil` means the read failed; an empty card list is a real board.
    public func loadKanbanBoard(slug: String?, includeArchived: Bool, onlyMine: Bool) async -> WatchKanbanBoardLoad? {
        let loadedScope = selectedScope
        let summaries: [WatchSkillSummary]
        if let fixtureGlances {
            summaries = fixtureGlances.kanban
        } else {
            let query = WatchGlanceQuery.kanban(slug: slug, includeArchived: includeArchived, onlyMine: onlyMine)
            guard let loaded = await loadGlance({ service, scope in
                try await service.skills(scope: scope, query: query, localLimit: 64).value.items
            }) else { return nil }
            summaries = loaded
        }
        let board = Self.kanbanBoard(from: summaries, includeArchived: includeArchived)
        kanbanBoardSlug = board.chrome.slug
        kanbanLoadedScope = loadedScope
        return board
    }

    func useKanbanBoardForTesting(_ slug: String) {
        kanbanBoardSlug = slug
        kanbanLoadedScope = selectedScope
    }

    /// The board on screen and the phone's current server. A mismatch means
    /// the rows were loaded before a server switch.
    private func readyKanbanScope() -> ServerScope? {
        guard let selectedScope, kanbanLoadedScope == selectedScope else { return nil }
        return selectedScope
    }

    private static func kanbanBoard(from summaries: [WatchSkillSummary], includeArchived: Bool) -> WatchKanbanBoardLoad {
        var chrome: WatchKanbanBoardChrome?
        var cards: [WatchKanbanCard] = []
        for summary in summaries {
            if summary.key.name == WatchKanbanBoardChrome.cardID,
               let parsed = WatchKanbanBoardChrome(wireSummary: summary.summary) {
                chrome = parsed
                continue
            }
            cards.append(WatchKanbanCard(id: summary.key.name, wireSummary: summary.summary))
        }
        var resolved = chrome ?? WatchKanbanBoardChrome(
            name: "Kanban",
            slug: "default",
            columns: WatchKanbanStatus.boardOrder,
            boards: [WatchKanbanBoardChrome.Choice(slug: "default", name: "Kanban")]
        )
        for card in cards where !resolved.columns.contains(card.status) {
            resolved.columns.append(card.status)
        }
        if includeArchived, !resolved.columns.contains("archived") {
            resolved.columns.append("archived")
        }
        if !includeArchived {
            resolved.columns.removeAll { $0 == "archived" }
            cards.removeAll { $0.status == "archived" }
        }
        return WatchKanbanBoardLoad(chrome: resolved, cards: cards)
    }

    /// Recent runs, newest first. `nil` means the load failed, so the detail
    /// screen can show its own Try again instead of an empty history.
    public func loadTaskRuns(jobID: String, limit: Int = 5) async -> [WatchTaskRun]? {
        if let fixtureGlances { return fixtureGlances.taskRuns[jobID] ?? [] }
        guard let link, let scope = selectedScope else { return nil }
        do {
            let key = try TaskKey(scope: scope, jobID: jobID)
            let page = try PageRequest(continuation: nil, limit: min(max(limit, 1), 20))
            return try await link.makeService().taskRuns(key: key, page: page).value.items
        } catch {
            return nil
        }
    }

    /// One run's wrist-sized output. Outer `nil` is a failed load; an inner
    /// `nil` is a run that produced no output.
    public func loadTaskRunOutput(jobID: String, runID: String) async -> WatchTaskRunDetail? {
        if let fixtureGlances {
            guard let run = fixtureGlances.taskRuns[jobID]?.first(where: { $0.runID == runID }) else { return nil }
            return try? WatchTaskRunDetail(run: run, output: fixtureGlances.taskOutputs[runID], outputTruncated: false)
        }
        guard let link, let scope = selectedScope else { return nil }
        do {
            let key = try TaskKey(scope: scope, jobID: jobID)
            return try await link.makeService().taskRunDetail(key: key, runID: runID).value
        } catch {
            return nil
        }
    }

    public func loadMemory() async -> WatchMemoryDocument? {
        if let fixtureGlances { return fixtureGlances.memory }
        return await loadGlance { service, scope in
            try await service.memoryDocument(scope: scope).value
        }
    }

    public func loadUsage(days: Int = 30) async -> WatchInsightsAggregate? {
        if let fixtureGlances, let usage = fixtureGlances.usage {
            let scale = Double(days) / Double(usage.days.value)
            func scaled(_ value: Int) -> Int { Int((Double(value) * scale).rounded()) }
            return try? WatchInsightsAggregate(
                days: InsightsDays(days),
                totalSessions: scaled(usage.totalSessions),
                totalMessages: scaled(usage.totalMessages),
                totalInputTokens: scaled(usage.totalInputTokens),
                totalOutputTokens: scaled(usage.totalOutputTokens),
                totalTokens: scaled(usage.totalTokens),
                totalCost: usage.totalCost * Decimal(scale),
                models: usage.models,
                dailyTokens: BoundedCollection(items: Array(usage.dailyTokens.items.suffix(days)), isTruncated: false),
                activityByDay: usage.activityByDay,
                activityByHour: usage.activityByHour,
                modelUsage: usage.modelUsage
            )
        }
        if fixtureGlances != nil { return nil }
        return await loadGlance { service, scope in
            let window = try InsightsDays(min(max(days, 1), 365))
            return try await service.insightsAggregate(scope: scope, days: window).value
        }
    }

    private func loadGlance<T: Sendable>(_ work: (any WatchCompanionServicing, ServerScope) async throws -> T) async -> T? {
        guard let link, let scope = selectedScope else { return nil }
        do {
            let value = try await work(link.makeService(), scope)
            lastErrorCode = nil
            return value
        } catch is CancellationError {
            return nil
        } catch WatchCompanionError.backend(.authRequired) {
            state = .signedOut
            lastErrorCode = "authRequired"
            return nil
        } catch {
            lastErrorCode = "glanceUnavailable"
            return nil
        }
    }

    public func transcript(for session: WatchSessionSummary) async -> [WatchTranscriptBlock] {
        if let fixture = fixtureTranscriptBySessionID[session.key.sessionID] {
            return fixture
        }
        guard let link else { return [] }
        do {
            let snapshot = try await link.makeService().transcript(
                key: session.key,
                before: nil,
                limit: 20
            )
            if lastErrorCode == "transcriptUnavailable" {
                lastErrorCode = nil
            }
            return snapshot.value.blocks
        } catch {
            lastErrorCode = "transcriptUnavailable"
            return []
        }
    }

    public func send(text: String, to session: WatchSessionSummary) async -> RunKey? {
        await send(text: text, to: session.key)
    }

    public func sendVoiceNote(audio: Data, filename: String, to session: WatchSessionSummary) async -> RunKey? {
        await sendVoiceNote(audio: audio, filename: filename, to: session.key)
    }

    public func sendPhoto(image: Data, filename: String, caption: String, to session: WatchSessionSummary) async -> RunKey? {
        await sendPhoto(image: image, filename: filename, caption: caption, to: session.key)
    }

    public func sendPhoto(image: Data, filename: String, caption: String, to key: SessionKey) async -> RunKey? {
        guard offersReplyControls else { return nil }
        guard canMutate, let link, let scope = selectedScope else { return nil }
        let revision = await refreshRevision(using: link.makeService())
        do {
            let request = try WatchPhotoSendRequest(
                scope: scope,
                expectedRevision: revision,
                session: key,
                filename: filename,
                image: image,
                caption: caption
            )
            let receipt = try await link.sendPhoto(request)
            if let run = receipt.value {
                lastErrorCode = nil
                await loadSessions()
                activeRunBySession[key] = run
                markLocalRun(on: key)
                return run
            }
            lastErrorCode = "sendRejected"
            return nil
        } catch WatchPhotoValidationError.imageTooLarge {
            lastErrorCode = "tooLarge"
            return nil
        } catch {
            lastErrorCode = "sendFailed"
            return nil
        }
    }

    public func mediaBytes(for descriptor: WatchMediaDescriptor) async -> Data? {
        let cacheKey = WatchMediaCacheIdentity.key(for: descriptor)
        if let cached = mediaCache[cacheKey] {
            if WatchMediaCacheIdentity.accepts(cached, descriptor: descriptor) {
                return cached
            }
            mediaCache[cacheKey] = nil
        }
        guard let link else { return nil }
        do {
            let payload = try await link.makeService().media(descriptor)
            guard WatchMediaCacheIdentity.accepts(payload.bytes, descriptor: descriptor) else { return nil }
            mediaCache[cacheKey] = payload.bytes
            return payload.bytes
        } catch {
            return nil
        }
    }

    public func sendVoiceNote(audio: Data, filename: String, to key: SessionKey) async -> RunKey? {
        guard offersReplyControls else { return nil }
        guard canMutate, let link, let scope = selectedScope else { return nil }
        let revision = await refreshRevision(using: link.makeService())
        do {
            let request = try WatchVoiceNoteRequest(
                scope: scope,
                expectedRevision: revision,
                session: key,
                filename: filename,
                audio: audio
            )
            let receipt = try await link.sendVoiceNote(request)
            if let run = receipt.value {
                lastErrorCode = nil
                await loadSessions()
                activeRunBySession[key] = run
                markLocalRun(on: key)
                return run
            }
            lastErrorCode = "sendRejected"
            return nil
        } catch WatchVoiceNoteValidationError.audioTooLarge {
            lastErrorCode = "tooLarge"
            return nil
        } catch {
            lastErrorCode = "sendFailed"
            return nil
        }
    }

    public func send(text: String, to key: SessionKey) async -> RunKey? {
        guard offersReplyControls else { return nil }
        guard canMutate, let link else { return nil }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        let created = Date()
        do {
            let context = try CommandContext(
                stableCommandID: CommandID(rawValue: UUID()),
                scope: key.scope,
                expectedRevision: revision,
                createdAt: created,
                expiresAt: created.addingTimeInterval(60)
            )
            let receipt = await service.send(text: text, to: key, context: context)
            if let run = receipt.value {
                lastErrorCode = nil
                // Reload first: the optimistic run marker has to outlive the
                // reload, which drops runs the server reports as finished.
                await loadSessions()
                activeRunBySession[key] = run
                markLocalRun(on: key)
                return run
            }
            lastErrorCode = "sendRejected"
            return nil
        } catch {
            lastErrorCode = "sendFailed"
            return nil
        }
    }

    public func session(for key: SessionKey) -> WatchSessionSummary? {
        sessions.first(where: { $0.key == key })
    }

    public func createSession() async -> SessionKey? {
        guard canMutate, let scope = selectedScope else { return nil }
        guard let link else {
            return insertLocalSession(scope: scope, title: "New session")
        }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        let created = Date()
        do {
            let context = try CommandContext(
                stableCommandID: CommandID(rawValue: UUID()),
                scope: scope,
                expectedRevision: revision,
                createdAt: created,
                expiresAt: created.addingTimeInterval(60)
            )
            let receipt = await service.createSession(
                scope: scope,
                profileID: nil,
                workspaceHandle: nil,
                context: context
            )
            guard let key = receipt.value else {
                lastErrorCode = "createRejected"
                return nil
            }
            focusedSessionKey = key
            lastErrorCode = nil
            await loadSessions()
            if session(for: key) == nil {
                _ = insertLocalSession(scope: scope, title: "New session", key: key)
            }
            return key
        } catch {
            lastErrorCode = "createFailed"
            return nil
        }
    }

    public func stop(_ session: WatchSessionSummary) async -> Bool {
        guard canMutate, let link, let run = activeRun(for: session) else { return false }
        let service = link.makeService()
        let revision = await refreshRevision(using: service)
        let created = Date()
        do {
            let context = try CommandContext(
                stableCommandID: CommandID(rawValue: UUID()),
                scope: run.session.scope,
                expectedRevision: revision,
                createdAt: created,
                expiresAt: created.addingTimeInterval(60)
            )
            let receipt = await service.stop(run: run, context: context)
            if receipt.value != nil {
                activeRunBySession[session.key] = nil
                lastErrorCode = nil
                await loadSessions()
                return true
            }
            lastErrorCode = "stopRejected"
            return false
        } catch {
            lastErrorCode = "stopFailed"
            return false
        }
    }

    public func activeRun(for session: WatchSessionSummary) -> RunKey? {
        activeRunBySession[session.key]
    }

    public func widgetSnapshot(observedAt: Date = Date()) -> RedactedWidgetSnapshot? {
        guard state == .ready, let scope = selectedScope else { return nil }
        let server = servers.first(where: { $0.scope == scope }) ?? servers.first
        guard let server else { return nil }
        let route: RedactedRoute
        if let nowSession {
            route = .session(nowSession.key)
        } else {
            route = .sessions(scope)
        }
        return try? RedactedWidgetSnapshot(
            scope: scope,
            displayName: server.displayName,
            activity: WatchNowSession.widgetActivity(from: scopedSessions),
            attentionCount: min(scopedSessions.filter(WatchNowSession.needsAttention).count, 999),
            observedAt: observedAt,
            route: route
        )
    }

    public var primaryMessage: String {
        switch state {
        case .setupRequired:
            return "Set up on iPhone"
        case .connecting:
            return "Connecting"
        case .unavailable:
            return "Hermex is unavailable"
        case .signedOut:
            return "Sign in on iPhone"
        case .ready:
            return servers.first?.displayName.rawValue ?? "Sessions"
        }
    }

    /// Mutations (create / send / stop / voice) are only allowed when the watch
    /// is genuinely ready: not connecting, not unreachable, and not signed out.
    public var canMutate: Bool {
        state == .ready
    }

    /// Message, voice notes, and photos. Older phones omit `writesUnsupported`,
    /// and that still means the server accepts a reply. Listen and Stop stay.
    public var offersReplyControls: Bool {
        guard let selectedScope,
              let entry = servers.first(where: { $0.scope == selectedScope })
        else { return true }
        return entry.writesUnsupported != true
    }

    /// Failures that belong to a reply control — Message, voice note, photo,
    /// Stop run. The control that failed shows these itself and drops them the
    /// moment the user tries again, so echoing them as a banner over Now left
    /// "Couldn't send. Try again." sitting above a composer that works.
    private static let replyControlErrorCodes: Set<String> = [
        "sendFailed",
        "sendRejected",
        "tooLarge",
        "stopFailed",
        "stopRejected",
    ]

    /// A glance, a transcript, a reply control, or a one-tap wrist action owns
    /// its own failure. Now and Sessions must not repeat it: opening Tasks used
    /// to leave "Couldn't load this list." on the session screens.
    private static let screenLocalErrorCodes: Set<String> = [
        "transcriptUnavailable",
        "glanceUnavailable",
        "profileSwitchFailed",
        "taskControlFailed",
        "skillToggleFailed",
        "kanbanMoveFailed",
        "kanbanCreateFailed",
        "kanbanDispatchFailed",
    ]

    /// Session lists and Now already have their rows. A transcript miss belongs
    /// on the open chat, and a reply-control failure belongs next to its own
    /// control, not as a red banner above every session.
    public var sidebarErrorCopy: String? {
        guard let code = lastErrorCode else { return nil }
        guard !Self.screenLocalErrorCodes.contains(code), !Self.replyControlErrorCodes.contains(code) else { return nil }
        return errorCopy
    }

    /// Drops a reply-control failure because the user started another attempt
    /// (opened the keyboard, started recording, picked a photo, pressed Stop).
    /// Leaves sessions-load and auth failures alone — those are Now's to show.
    public func clearReplyControlError() {
        guard let code = lastErrorCode, Self.replyControlErrorCodes.contains(code) else { return }
        lastErrorCode = nil
    }

    /// A short, user-facing explanation of the last failure so create / send /
    /// stop / transcript errors are not haptic-only. `nil` when there is nothing
    /// to surface.
    public var errorCopy: String? {
        lastErrorCode.map(Self.errorCopy(for:))
    }

    /// Copy for one failure code, so a control that owns its own error renders
    /// the same sentence the model would have shown.
    public static func errorCopy(for code: String) -> String {
        switch code {
        case "authRequired":
            return "Sign in on iPhone to continue."
        case "sessionsUnavailable":
            return "Couldn’t load sessions. Try again."
        case "transcriptUnavailable":
            return "Couldn’t load the conversation."
        case "sendFailed":
            return "Couldn’t send. Try again."
        case "sendRejected":
            return "Hermex didn’t accept that message."
        case "tooLarge":
            return "That photo is too large to send from Apple Watch."
        case "createFailed":
            return "Couldn’t create a session. Try again."
        case "createRejected":
            return "Hermex didn’t create that session."
        case "stopFailed":
            return "Couldn’t stop the run."
        case "stopRejected":
            return "Hermex didn’t stop that run."
        case "profileSwitchFailed":
            return "Couldn’t switch profile."
        case "taskControlFailed":
            return "Couldn’t update that task."
        case "skillToggleFailed":
            return "Couldn’t update that skill."
        case "kanbanMoveFailed":
            return "Couldn’t move that card."
        case "kanbanCreateFailed":
            return "Couldn’t create that card."
        case "kanbanDispatchFailed":
            return "Couldn’t run the dispatcher."
        case "glanceUnavailable":
            return "Couldn’t load this list."
        default:
            return "Something went wrong. Try again."
        }
    }

    #if DEBUG
    /// Demo-only fixture for screenshot capture and UI tests. Wrapped in
    /// `DEBUG` so the demo strings ("Stand-up notes", etc.) never ship in the
    /// release module. UI tests opt in via the `HERMEX_WATCH_SCREENSHOT_FIXTURE`
    /// launch argument, which the app reads under its own `#if DEBUG` guard.
    /// `replyError` seeds a reply-control failure code so a screenshot can show
    /// that a failed send no longer paints a banner over Now.
    public func applyScreenshotFixture(replyError: String? = nil) {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            server: ServerID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            generation: try! Generation(1)
        )
        let running = try! WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "stand-up"),
            title: "Stand-up notes",
            profile: "default",
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_120),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: .responding
        )
        let pinned = try! WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "weekend"),
            title: "Weekend plan",
            profile: "default",
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_080),
            isPinned: true,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let attention = try! WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "review"),
            title: "PR review",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_040),
            isPinned: false,
            isArchived: false,
            attention: true,
            runState: .attention
        )
        applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try! RedactedDisplayName("Studio"))],
            sessions: [running, pinned, attention]
        )
        let now = Date()
        let digestRuns = [
            try! WatchTaskRun(task: TaskKey(scope: scope, jobID: "digest"), runID: "digest-today.md", startedAt: now.addingTimeInterval(-3_700), finishedAt: now.addingTimeInterval(-3_600), status: "finished", output: nil, isTruncated: false),
            try! WatchTaskRun(task: TaskKey(scope: scope, jobID: "digest"), runID: "digest-yesterday.md", startedAt: now.addingTimeInterval(-90_100), finishedAt: now.addingTimeInterval(-90_000), status: "finished", output: nil, isTruncated: false),
        ]
        func card(_ id: String, _ title: String, _ status: String, assignee: String? = nil, priority: Int? = nil, body: String? = nil) -> WatchSkillSummary {
            let card = WatchKanbanCard(id: id, title: title, status: status, assignee: assignee, priority: priority, body: body)
            return try! WatchSkillSummary(key: SkillKey(scope: scope, name: id), summary: card.wireSummary, enabled: nil)
        }
        fixtureGlances = FixtureGlances(
            tasks: [
                try! WatchTaskSummary(key: TaskKey(scope: scope, jobID: "digest"), name: "Morning digest", schedule: "Every day at 8:00 AM", enabled: true, running: false, lastResult: "ok", lastRunAt: now.addingTimeInterval(-3_600), nextRunAt: now.addingTimeInterval(20 * 3_600)),
                try! WatchTaskSummary(key: TaskKey(scope: scope, jobID: "backup"), name: "Repo backup", schedule: "Every 6 hours", enabled: true, running: true, lastResult: nil, lastRunAt: now.addingTimeInterval(-6 * 3_600), nextRunAt: now.addingTimeInterval(6 * 3_600)),
                try! WatchTaskSummary(key: TaskKey(scope: scope, jobID: "prices"), name: "Price watch", schedule: "Hourly", enabled: false, running: false, lastResult: "error", lastRunAt: now.addingTimeInterval(-2 * 86_400), nextRunAt: nil, failureSummary: "Timed out after 300s fetching prices"),
            ],
            kanban: [
                card("c1", "Ship watch reply controls", "running", assignee: "default", priority: 2, body: "Stop, voice note and **photo** on Now. Verify on a 41mm screen."),
                card("c2", "Audit session sync", "ready", assignee: "research"),
                card("c3", "Write release notes", "todo", priority: 1),
                card("c4", "Fix desktop session ids", "done"),
            ],
            skills: [
                try! WatchSkillSummary(key: SkillKey(scope: scope, name: "web-search"), summary: "Search the web and cite sources.", enabled: true),
                try! WatchSkillSummary(key: SkillKey(scope: scope, name: "calendar"), summary: "Read and draft calendar events.", enabled: false),
            ],
            usage: try! WatchInsightsAggregate(
                days: InsightsDays(30),
                totalSessions: 142,
                totalMessages: 3_918,
                totalInputTokens: 8_420_000,
                totalOutputTokens: 1_310_000,
                totalTokens: 9_730_000,
                totalCost: Decimal(string: "48.72")!,
                models: BoundedCollection(items: ["gpt-5.6-sol", "claude-opus-5.5"], isTruncated: false),
                dailyTokens: BoundedCollection(
                    items: (0..<30).map { day in 180_000 + ((day * 7_919) % 13) * 41_000 },
                    isTruncated: false
                ),
                activityByDay: BoundedCollection(items: [], isTruncated: false),
                activityByHour: BoundedCollection(items: [], isTruncated: false),
                modelUsage: BoundedCollection(items: [
                    WatchModelUsage(name: "gpt-5.6-sol", totalTokens: 6_100_000, cost: Decimal(string: "31.40")!, sessions: 96),
                    WatchModelUsage(name: "claude-opus-5.5", totalTokens: 3_630_000, cost: Decimal(string: "17.32")!, sessions: 46),
                ], isTruncated: false)
            ),
            // Same layout a real USER.md / MEMORY.md has: one fact per entry,
            // `§` between entries, bold labels, and an email the line breaker
            // used to hyphenate.
            memory: try! WatchMemoryDocument(sections: [
                WatchMemorySection(
                    key: MemoryKey(scope: scope, remoteID: "memory"),
                    section: "memory",
                    redactedContent: WatchMemoryProjection.wireContent(WatchMemoryProjection.wristEntries(from: """
                    Prefers short replies on the watch.
                    §
                    Ships builds from the **Mac mini** over Tailscale.
                    §
                    Voice: ElevenLabs v4 is the current external TTS for long PDFs.
                    """).entries),
                    isTruncated: false
                ),
                WatchMemorySection(
                    key: MemoryKey(scope: scope, remoteID: "user"),
                    section: "user",
                    redactedContent: WatchMemoryProjection.wireContent(WatchMemoryProjection.wristEntries(from: """
                    **Name:** Aaryan Guglani (goes by Aaryan)
                    §
                    **Email:** guglaniaaryan@gmail.com
                    §
                    **Timezone:** GMT+5:30 (Asia/Calcutta)
                    §
                    **Stack:**
                    - SwiftUI and watchOS
                    - Self-hosted Hermes on a Mac mini
                    """).entries),
                    isTruncated: false
                ),
            ]),
            composer: try! WatchComposerOptions(
                scope: scope,
                profiles: [
                    WatchComposerOptions.ProfileChoice(id: ProfileID("default"), label: "Default\ngpt-5.6-sol"),
                    WatchComposerOptions.ProfileChoice(id: ProfileID("research"), label: "Research\nclaude-opus-5.5"),
                ],
                workspaces: [
                    WatchComposerOptions.WorkspaceChoice(handle: WorkspaceHandle("hermex"), label: "hermex"),
                    WatchComposerOptions.WorkspaceChoice(handle: WorkspaceHandle("dotfiles"), label: "dotfiles"),
                ],
                defaultProfileID: ProfileID("default"),
                defaultWorkspaceHandle: nil
            ),
            taskRuns: ["digest": digestRuns],
            taskOutputs: [
                "digest-today.md": WatchTranscriptProjection.wristMarkdown("""
                ### Morning digest
                - 3 PRs waiting on review
                - Build **42** passed on TestFlight
                - Calendar: stand-up at 10:00
                """),
            ]
        )
        // Mirrors the real reply that printed raw Markdown on the watch: a bold
        // bare tailnet URL, an ATX heading, an untagged fence and a list. Run
        // through the phone projection so the fixture exercises the same
        // normalization the broker does.
        let richReply = WatchTranscriptProjection.blocks(
            for: WatchPhoneMessageHint(
                id: "2",
                role: .assistant,
                text: """
                I reached the server. Open **https://aaryans-mac-mini.taild36793.ts.net/** on your \
                iPhone while Tailscale is connected.

                ### Verified configuration

                ```text
                https://aaryans-mac-mini.taild36793.ts.net (tailnet only)
                ```

                - `brew services` is running
                - Tailscale is up on *both* machines
                - Full write-up: [the setup notes](https://get-hermes.ai/api-docs/setup)

                1. Open the link above
                2. Sign in once

                > Keep the tunnel off until this works.
                """
            )
        )
        fixtureTranscriptBySessionID = [
            "stand-up": [
                .text(id: "1", role: .user, text: "Summarize stand-up."),
            ] + richReply.compactMap { block in
                switch block.kind {
                case .text(let role, let text):
                    return .text(id: block.id, role: role, text: text)
                case .code(let language, let text, let isTruncated):
                    return .code(id: block.id, language: language, text: text, isTruncated: isTruncated)
                default:
                    return nil
                }
            },
        ]
        applyNowReply(from: fixtureTranscriptBySessionID["stand-up"] ?? [])
        lastErrorCode = replyError
    }
    #endif

    @discardableResult
    private func insertLocalSession(
        scope: ServerScope,
        title: String,
        key: SessionKey? = nil
    ) -> SessionKey? {
        let resolvedKey: SessionKey
        if let key {
            resolvedKey = key
        } else if let created = try? SessionKey(
            scope: scope,
            sessionID: "local-\(UUID().uuidString.prefix(8))"
        ) {
            resolvedKey = created
        } else {
            return nil
        }
        guard let summary = try? WatchSessionSummary(
            key: resolvedKey,
            title: title,
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        ) else { return nil }
        sessions.insert(summary, at: 0)
        focusedSessionKey = resolvedKey
        applyNowReply(from: fixtureTranscriptBySessionID[resolvedKey.sessionID] ?? [])
        lastErrorCode = nil
        return resolvedKey
    }

    func applyReadyStateForTesting(
        servers: [RegistryEntry],
        sessions: [WatchSessionSummary],
        revision: Revision = Revision(1)
    ) {
        self.servers = servers
        self.sessions = sessions
        hasLoadedSessions = true
        selectedScope = servers.first?.scope
        registryRevision = revision
        state = .ready
    }

    private func refreshNowPreview() async {
        guard let session = nowSession else {
            clearNowReply()
            return
        }
        let blocks = await transcript(for: session)
        // The Now session can change while its transcript loads; a late reply
        // must not label the card it no longer belongs to.
        guard nowSession?.key == session.key else { return }
        applyNowReply(from: blocks)
    }

    private func applyNowReply(from blocks: [WatchTranscriptBlock]) {
        nowPreview = WatchTranscriptPreview.lastAssistantText(in: blocks)
        nowSpokenReply = WatchTranscriptPreview.lastAssistantReply(in: blocks)
    }

    private func clearNowReply() {
        nowPreview = nil
        nowSpokenReply = nil
    }

    private func loadRegistry(using service: any WatchCompanionServicing) async {
        let snapshot = await service.registry()
        applyRegistry(snapshot)
        if !snapshot.entries.isEmpty, state == .ready {
            await loadSessions()
        }
    }

    private func applyRegistry(_ snapshot: RegistrySnapshot) {
        if snapshot.entries.isEmpty {
            // A failed wake is the unavailable placeholder. A confirmed empty
            // registry means the phone has no servers left, so the board goes.
            if !servers.isEmpty, snapshot.isUnavailableWake {
                return
            }
            // Drop the old server list too. A later failed wake treats a
            // nonempty list as "keep the board", which would leave the watch
            // on Connecting after the phone said there are no servers.
            servers = []
            registryRevision = snapshot.revision
            state = .setupRequired
            adopt(nil)
            return
        }
        servers = snapshot.entries
        registryRevision = snapshot.revision
        // The iPhone lists its active server first. A selection that is gone from
        // the registry is always replaced; an unpinned watch also follows the
        // iPhone when it switches servers, so the wrist never operates on a
        // server the phone left behind.
        let preferred = snapshot.entries.first?.scope
        let selectionIsStale = snapshot.entries.contains(where: { $0.scope == selectedScope }) == false
        if selectionIsStale || (followsPhoneActiveServer && preferred != selectedScope) {
            adopt(preferred)
        }
        state = .ready
        phoneStatusNote = nil
        discardUnusableComplicationRecording()
    }

    private func adopt(_ scope: ServerScope?) {
        selectedScope = scope
        sessions = []
        hasLoadedSessions = false
        clearNowReply()
        focusedSessionKey = nil
        activeRunBySession = [:]
    }

    /// Keeps Stop honest: a run the server no longer reports as active is not
    /// stoppable, and a session that fell out of the current page cannot be shown.
    private func dropRunsTheServerNoLongerReports() {
        for key in Array(activeRunBySession.keys) {
            let isRunning = sessions.first(where: { $0.key == key })
                .map { WatchNowSession.isRunning($0.runState) } ?? false
            if !isRunning {
                activeRunBySession[key] = nil
            }
        }
    }

    private var scopedSessions: [WatchSessionSummary] {
        guard let selectedScope else { return sessions }
        return sessions.filter { $0.key.scope == selectedScope }
    }

    private func markLocalRun(on key: SessionKey) {
        guard let index = sessions.firstIndex(where: { $0.key == key }) else { return }
        let current = sessions[index]
        guard !WatchNowSession.isRunning(current.runState) else { return }
        guard let updated = try? WatchSessionSummary(
            key: current.key,
            title: current.title,
            profile: current.profile,
            workspaceLabel: current.workspaceLabel,
            updatedAt: current.updatedAt,
            isPinned: current.isPinned,
            isArchived: current.isArchived,
            attention: current.attention,
            runState: .responding
        ) else { return }
        sessions[index] = updated
    }

    func attachLinkWithoutRefreshingForTesting(_ link: any WatchCompanionLinking) {
        self.link = link
    }

    /// Awaitable stand-in for the `Task` that `refreshConnection()` spawns.
    func reloadRegistryForTesting() async {
        guard let link else { return }
        await loadRegistry(using: link.makeService())
    }

    func applyRegistrySnapshotForTesting(_ snapshot: RegistrySnapshot) {
        applyRegistry(snapshot)
    }
}

/// Cache identity for a watch image. The handle is often just the file path,
/// so two sessions can share it and still be different pictures.
enum WatchMediaCacheIdentity {
    static func key(for descriptor: WatchMediaDescriptor) -> String {
        [
            descriptor.scope.server.rawValue.uuidString,
            descriptor.session.sessionID,
            descriptor.handle.rawValue,
            descriptor.sha256.lowercased(),
        ].joined(separator: "|")
    }

    static func accepts(_ bytes: Data, descriptor: WatchMediaDescriptor) -> Bool {
        guard bytes.count == descriptor.byteSize else { return false }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return digest == descriptor.sha256.lowercased()
    }
}
