import CryptoKit
import Foundation
import os

/// Maps watch operations onto a phone-owned backend. The watch never reaches
/// `hermes-webui`; this type is the iPhone-side `WatchCompanionServicing`.
public final class PhoneCompanionBroker: WatchCompanionServicing, @unchecked Sendable {
    private let epoch: InstallationEpoch
    private let backend: any WatchPhoneBackend
    private let now: @Sendable () -> Date
    private let storage: OSAllocatedUnfairLock<State>

    private struct State {
        var fence: ScopeFence
        var revision: UInt64
        var urlByServer: [ServerID: String]
        var generationByServer: [ServerID: UInt64]
        var lastSnapshot: RegistrySnapshot?
        var issuedRuns: [String: RunKey]
        var mediaByHandle: [String: CachedMedia]
    }

    private let issuedRunStore: (any WatchIssuedRunStoring)?

    private struct CachedMedia {
        let path: String
        let bytes: Data
    }

    public init(
        epoch: InstallationEpoch,
        backend: any WatchPhoneBackend,
        now: @escaping @Sendable () -> Date = { Date() },
        issuedRunStore: (any WatchIssuedRunStoring)? = nil
    ) {
        self.epoch = epoch
        self.backend = backend
        self.now = now
        self.issuedRunStore = issuedRunStore
        var restoredRuns: [String: RunKey] = [:]
        for run in issuedRunStore?.load() ?? [] {
            restoredRuns[run.streamID] = run
        }
        self.storage = OSAllocatedUnfairLock(initialState: State(
            fence: ScopeFence(epoch: epoch),
            revision: 0,
            urlByServer: [:],
            generationByServer: [:],
            lastSnapshot: nil,
            issuedRuns: restoredRuns,
            mediaByHandle: [:]
        ))
    }

    public func registry() async -> RegistrySnapshot {
        let accounts = await backend.servers()
        return storage.withLock { state in
            var nextGenerations = state.generationByServer
            var urlByServer: [ServerID: String] = [:]
            var entries: [RegistryEntry] = []

            for account in accounts {
                let server = ServerID.derived(from: account.urlString)
                // A registry that lists one URL twice must not invalidate the whole
                // snapshot: keep the first entry, which is the phone's own order.
                guard urlByServer[server] == nil else { continue }
                let wasActive = state.fence.activeScopes[server] != nil
                let previous = nextGenerations[server] ?? 0
                let generationValue: UInt64
                if wasActive {
                    generationValue = previous == 0 ? 1 : previous
                } else if previous == 0 {
                    generationValue = 1
                } else if previous == UInt64.max {
                    continue
                } else {
                    generationValue = previous + 1
                }
                guard let generation = try? Generation(generationValue) else { continue }
                nextGenerations[server] = generationValue
                urlByServer[server] = account.urlString
                entries.append(RegistryEntry(
                    scope: ServerScope(epoch: epoch, server: server, generation: generation),
                    displayName: .sanitized(account.displayName),
                    writesUnsupported: account.writesUnsupported ? true : nil
                ))
            }

            if let lastSnapshot = state.lastSnapshot,
               registryIdentity(lastSnapshot.entries) == registryIdentity(entries) {
                return lastSnapshot
            }

            let snapshot = try? RegistrySnapshot(
                epoch: epoch,
                revision: Revision(state.revision + 1),
                generatedAt: now(),
                entries: entries
            )
            if let snapshot, (try? state.fence.apply(snapshot)) != nil {
                state.revision = snapshot.revision.rawValue
                state.urlByServer = urlByServer
                state.generationByServer = nextGenerations
                state.lastSnapshot = snapshot
                return snapshot
            }
            return state.lastSnapshot ?? fallbackEmptyRegistry(revision: state.revision)
        }
    }

    public func refreshSessions(
        scope: ServerScope,
        collection: SessionCollection,
        query: String?,
        localLimit: Int
    ) async throws -> ScopedSnapshot<BoundedCollection<WatchSessionSummary>> {
        let urlString = try resolvedURL(for: scope)
        let rows = try await backend.listSessions(
            urlString: urlString,
            archived: collection == .archived,
            query: query,
            limit: localLimit
        )
        let items = rows.compactMap { row -> WatchSessionSummary? in
            guard let key = try? SessionKey(scope: scope, sessionID: row.sessionID) else { return nil }
            // A long workspace path or title used to fail DTO validation and
            // drop the whole row, so a server full of real sessions arrived as
            // an empty wrist. Truncate the labels; only an unusable session id
            // (blank or over the identity limit) drops the row.
            let updatedAt = row.updatedAt.flatMap {
                $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil
            }
            return try? WatchSessionSummary(
                key: key,
                title: Self.boundedLabel(row.title, maxUTF8: 1024) ?? "Untitled",
                profile: Self.boundedLabel(row.profile, maxUTF8: ContractLimits.identifierUTF8Bytes),
                workspaceLabel: Self.boundedLabel(row.workspaceLabel, maxUTF8: ContractLimits.identifierUTF8Bytes),
                updatedAt: updatedAt,
                isPinned: row.isPinned,
                isArchived: row.isArchived,
                attention: row.attention,
                runState: row.runState
            )
        }
        let limited = Array(items.prefix(min(localLimit, 100)))
        return try scopedList(
            scope: scope,
            items: limited,
            truncated: items.count > limited.count,
            maximumItems: 100
        )
    }

    public func transcript(
        key: SessionKey,
        before: Int?,
        limit: Int
    ) async throws -> ScopedSnapshot<WatchTranscript> {
        let urlString = try resolvedURL(for: key.scope)
        let page = try await backend.transcript(
            urlString: urlString,
            sessionID: key.sessionID,
            before: before,
            limit: limit
        )
        var projected: [WatchTranscriptBlock] = []
        var imagesProjected = 0
        for block in page.blocks.prefix(50) {
            guard projected.count < 50 else { break }
            switch block.kind {
            case .text(let role, let text):
                projected.append(.text(id: block.id, role: role, text: text))
            case .code(let language, let text, let isTruncated):
                projected.append(.code(id: block.id, language: language, text: text, isTruncated: isTruncated))
            case .tool(let title, let state, let summary):
                projected.append(.tool(id: block.id, title: title, state: state, summary: summary))
            case .image(let path, let mime, let alt):
                if imagesProjected < 4,
                   let path,
                   let image = await projectImage(
                    session: key,
                    urlString: urlString,
                    id: block.id,
                    path: path,
                    mime: mime,
                    alt: alt
                   ) {
                    projected.append(image)
                    imagesProjected += 1
                } else {
                    projected.append(
                        .unsupported(
                            id: block.id,
                            kind: "image",
                            summary: alt ?? "Image — open on iPhone"
                        )
                    )
                }
            case .unsupported(let kind, let summary):
                projected.append(.unsupported(id: block.id, kind: kind, summary: summary))
            }
        }
        return try scoped(
            key.scope,
            WatchTranscript(
                session: key,
                blocks: projected,
                nextBefore: page.nextBefore,
                isTruncated: page.isTruncated || page.blocks.count > 50
            )
        )
    }

    public func createSession(
        scope: ServerScope,
        profileID: ProfileID?,
        workspaceHandle: WorkspaceHandle?,
        context: CommandContext
    ) async -> CommandReceipt<SessionKey> {
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.createSession) else {
            return rejected(context, kind: .createSession)
        }
        guard let urlString = try? resolvedURL(for: scope), matchesRevision(context) else {
            return rejected(context, kind: .createSession)
        }
        do {
            let sessionID = try await backend.createSession(
                urlString: urlString,
                profileID: profileID?.rawValue,
                workspace: workspaceHandle?.rawValue
            )
            let key = try SessionKey(scope: scope, sessionID: sessionID)
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .createSession,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: sessionID
            )
            return CommandReceipt(receipt: receipt, value: key)
        } catch {
            return rejected(context, kind: .createSession)
        }
    }

    public func send(text: String, to key: SessionKey, context: CommandContext) async -> CommandReceipt<RunKey> {
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.send) else {
            return rejected(context, kind: .send)
        }
        guard let urlString = try? resolvedURL(for: key.scope), matchesRevision(context) else {
            return rejected(context, kind: .send)
        }
        do {
            let streamID = try await backend.startChat(
                urlString: urlString,
                sessionID: key.sessionID,
                message: text,
                attachments: nil
            )
            let run = try RunKey(session: key, streamID: streamID)
            recordIssuedRun(run)
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .send,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: streamID
            )
            return CommandReceipt(receipt: receipt, value: run)
        } catch {
            return rejected(context, kind: .send)
        }
    }

    public func events(for run: RunKey, afterEventID: String?) -> AsyncThrowingStream<WatchRunEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let urlString = try resolvedURL(for: run.session.scope)
                    let status = try await backend.runPhase(
                        urlString: urlString,
                        sessionID: run.session.sessionID,
                        streamID: run.streamID
                    )
                    let event = try WatchRunEvent(
                        key: run,
                        eventID: afterEventID.map { "\($0)-next" } ?? "0",
                        sequence: 0,
                        phase: status.phase,
                        textDelta: nil,
                        terminal: status.isTerminal
                    )
                    continuation.yield(event)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func reconcile(run: RunKey) async throws -> ScopedSnapshot<WatchRunState> {
        let urlString = try resolvedURL(for: run.session.scope)
        let status = try await backend.runPhase(
            urlString: urlString,
            sessionID: run.session.sessionID,
            streamID: run.streamID
        )
        return try scoped(
            run.session.scope,
            WatchRunState(
                key: run,
                phase: status.phase,
                lastEventID: nil,
                lastSequence: nil,
                isTerminal: status.isTerminal,
                summary: nil
            )
        )
    }

    /// Transcribe → upload → start chat with the bare transcript and the clip,
    /// matching iOS `ChatViewModel.sendVoiceNote`. Failure at any step rejects
    /// so the watch never claims a send that did not start.
    public func sendVoiceNote(_ request: WatchVoiceNoteRequest) async -> CommandReceipt<RunKey> {
        let context = voiceNoteContext(for: request)
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.send) else {
            return rejected(context, kind: .send)
        }
        guard request.session.scope == request.scope,
              let urlString = try? resolvedURL(for: request.scope),
              matchesRevision(request.expectedRevision)
        else {
            return rejected(context, kind: .send)
        }
        do {
            let transcript = try await backend.transcribeAudio(
                urlString: urlString,
                data: request.audio,
                filename: request.filename
            )
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return rejected(context, kind: .send)
            }
            let uploaded = try await backend.uploadFile(
                urlString: urlString,
                sessionID: request.session.sessionID,
                data: request.audio,
                filename: request.filename
            )
            let streamID = try await backend.startChat(
                urlString: urlString,
                sessionID: request.session.sessionID,
                message: trimmed,
                attachments: [uploaded]
            )
            let run = try RunKey(session: request.session, streamID: streamID)
            recordIssuedRun(run)
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .send,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: streamID
            )
            return CommandReceipt(receipt: receipt, value: run)
        } catch {
            return rejected(context, kind: .send)
        }
    }

    /// Upload a watch photo and start chat on the same composer attachment path.
    public func sendPhoto(_ request: WatchPhotoSendRequest) async -> CommandReceipt<RunKey> {
        let context = photoContext(for: request)
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.send) else {
            return rejected(context, kind: .send)
        }
        guard request.session.scope == request.scope,
              let urlString = try? resolvedURL(for: request.scope),
              matchesRevision(request.expectedRevision)
        else {
            return rejected(context, kind: .send)
        }
        do {
            let uploaded = try await backend.uploadFile(
                urlString: urlString,
                sessionID: request.session.sessionID,
                data: request.image,
                filename: request.filename
            )
            let message = WatchTranscriptProjection.chatMessageText(
                draft: request.caption,
                attachments: [uploaded]
            )
            let streamID = try await backend.startChat(
                urlString: urlString,
                sessionID: request.session.sessionID,
                message: message,
                attachments: [uploaded]
            )
            let run = try RunKey(session: request.session, streamID: streamID)
            recordIssuedRun(run)
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .send,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: streamID
            )
            return CommandReceipt(receipt: receipt, value: run)
        } catch {
            return rejected(context, kind: .send)
        }
    }

    public func transcribeVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> String {
        guard let urlString = try? resolvedURL(for: request.scope),
              matchesRevision(request.expectedRevision)
        else {
            throw WatchCompanionError.scopeRejected
        }
        return try await backend.transcribeAudio(
            urlString: urlString,
            data: request.audio,
            filename: request.filename
        )
    }

    private func photoContext(for request: WatchPhotoSendRequest) -> CommandContext {
        let created = now()
        return try! CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: request.scope,
            expectedRevision: request.expectedRevision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
    }

    private func voiceNoteContext(for request: WatchVoiceNoteRequest) -> CommandContext {
        let created = now()
        return try! CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: request.scope,
            expectedRevision: request.expectedRevision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
    }

    public func stop(run: RunKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.stop) else {
            return rejected(context, kind: .stop)
        }
        guard matchesRevision(context) else {
            return rejected(context, kind: .stop)
        }
        // Leave the saved copy in place until cancel succeeds. A phone restart
        // in the middle of Stop can then still cancel this run.
        guard takeIssuedRun(run) else {
            return rejected(context, kind: .stop)
        }
        guard let urlString = urlForIssuedRun(run) else {
            recordIssuedRun(run)
            return rejected(context, kind: .stop)
        }
        do {
            try await backend.cancelChat(urlString: urlString, streamID: run.streamID)
            persistIssuedRuns()
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .stop,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: run.streamID
            )
            return CommandReceipt(receipt: receipt, value: EmptyValue())
        } catch {
            recordIssuedRun(run)
            return rejected(context, kind: .stop)
        }
    }

    public func composerOptions(scope: ServerScope) async throws -> ScopedSnapshot<WatchComposerOptions> {
        let urlString = try resolvedURL(for: scope)
        let page = try await backend.listProfiles(urlString: urlString)
        let projects = (try? await backend.listProjects(urlString: urlString, limit: 128)) ?? []
        let profiles: [WatchComposerOptions.ProfileChoice] = page.profiles.compactMap { choice in
            guard let id = try? ProfileID(choice.name) else { return nil }
            return try? WatchComposerOptions.ProfileChoice(id: id, label: choice.label)
        }
        let workspaces: [WatchComposerOptions.WorkspaceChoice] = projects.compactMap { project in
            guard let handle = try? WorkspaceHandle(project.id) else { return nil }
            return try? WatchComposerOptions.WorkspaceChoice(handle: handle, label: project.name)
        }
        let active = page.activeName.flatMap { try? ProfileID($0) }
        let options = try WatchComposerOptions(
            scope: scope,
            profiles: Array(profiles.prefix(128)),
            workspaces: Array(workspaces.prefix(128)),
            defaultProfileID: active,
            defaultWorkspaceHandle: nil
        )
        return try scoped(scope, options)
    }

    public func switchActiveProfile(
        scope: ServerScope,
        name: String,
        expectedRevision: Revision
    ) async throws -> String {
        guard matchesRevision(expectedRevision) else {
            throw WatchCompanionError.scopeRejected
        }
        let urlString = try resolvedURL(for: scope)
        try await backend.switchProfile(urlString: urlString, name: name)
        return name
    }

    public func setSkillEnabled(
        scope: ServerScope,
        name: String,
        enabled: Bool,
        expectedRevision: Revision
    ) async throws {
        guard matchesRevision(expectedRevision) else { throw WatchCompanionError.scopeRejected }
        let urlString = try resolvedURL(for: scope)
        try await backend.setSkillEnabled(urlString: urlString, name: name, enabled: enabled)
    }

    public func createKanbanCard(
        scope: ServerScope,
        boardSlug: String,
        title: String,
        status: String,
        expectedRevision: Revision
    ) async throws {
        guard matchesRevision(expectedRevision) else { throw WatchCompanionError.scopeRejected }
        let urlString = try resolvedURL(for: scope)
        try await backend.createKanbanCard(urlString: urlString, boardSlug: boardSlug, title: title, status: status)
    }

    public func dispatchKanban(
        scope: ServerScope,
        boardSlug: String,
        dryRun: Bool,
        expectedRevision: Revision
    ) async throws -> String {
        guard matchesRevision(expectedRevision) else { throw WatchCompanionError.scopeRejected }
        let urlString = try resolvedURL(for: scope)
        return try await backend.dispatchKanban(urlString: urlString, boardSlug: boardSlug, dryRun: dryRun)
    }

    public func moveKanbanCard(
        scope: ServerScope,
        cardID: String,
        status: String,
        boardSlug: String,
        expectedRevision: Revision
    ) async throws {
        guard matchesRevision(expectedRevision) else { throw WatchCompanionError.scopeRejected }
        let urlString = try resolvedURL(for: scope)
        try await backend.moveKanbanCard(urlString: urlString, cardID: cardID, status: status, boardSlug: boardSlug)
    }

    public func pendingApprovalHead(
        session: SessionKey
    ) async throws -> ScopedSnapshot<WatchAttentionHead<WatchApproval>> {
        throw WatchCompanionError.unsupported(.pendingApprovalHead)
    }

    public func pendingClarificationHead(
        session: SessionKey
    ) async throws -> ScopedSnapshot<WatchAttentionHead<WatchClarification>> {
        throw WatchCompanionError.unsupported(.pendingClarificationHead)
    }

    public func tasks(
        scope: ServerScope,
        localLimit: Int
    ) async throws -> ScopedSnapshot<BoundedCollection<WatchTaskSummary>> {
        let urlString = try resolvedURL(for: scope)
        let cap = min(max(localLimit, 1), 64)
        let glances = try await backend.listTasks(urlString: urlString, limit: cap)
        let items: [WatchTaskSummary] = glances.prefix(cap).compactMap { glance in
            guard let key = try? TaskKey(scope: scope, jobID: glance.id) else { return nil }
            return try? WatchTaskSummary(
                key: key,
                name: Self.boundedLabel(glance.name, maxUTF8: 1024) ?? "Untitled task",
                schedule: Self.boundedLabel(glance.schedule, maxUTF8: 1024) ?? "Scheduled",
                enabled: glance.enabled,
                running: glance.running,
                lastResult: Self.boundedLabel(glance.lastResult, maxUTF8: 2048),
                lastRunAt: glance.lastRunAt.flatMap(Self.finiteDate),
                nextRunAt: glance.nextRunAt.flatMap(Self.finiteDate),
                failureSummary: Self.boundedLabel(glance.failureSummary, maxUTF8: 2048)
            )
        }
        return try scopedList(
            scope: scope,
            items: items,
            truncated: glances.count > items.count,
            maximumItems: 64
        )
    }

    /// Newest first. A history row is a finished run's output file, so every
    /// row reports `finished`; whether it succeeded lives in its output.
    public func taskRuns(
        key: TaskKey,
        page: PageRequest
    ) async throws -> ScopedSnapshot<BoundedPage<WatchTaskRun>> {
        let urlString = try resolvedURL(for: key.scope)
        let runs = try await backend.listTaskRuns(urlString: urlString, jobID: key.jobID, limit: page.limit)
        let items: [WatchTaskRun] = runs.prefix(page.limit).compactMap { run in
            let finished = run.finishedAt.flatMap(Self.finiteDate)
            let started = finished.flatMap { end in
                run.durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? end.addingTimeInterval(-$0) : nil }
            }
            return try? WatchTaskRun(
                task: key,
                runID: run.id,
                startedAt: started,
                finishedAt: finished,
                status: "finished",
                output: nil,
                isTruncated: false
            )
        }
        return try scoped(
            key.scope,
            try BoundedPage(items: items, continuation: nil, isTruncated: runs.count > items.count, maximumItems: 50)
        )
    }

    /// One run's output, shaped and clipped for the wrist.
    public func taskRunDetail(key: TaskKey, runID: String) async throws -> ScopedSnapshot<WatchTaskRunDetail> {
        let urlString = try resolvedURL(for: key.scope)
        let raw = try await backend.taskRunOutput(urlString: urlString, jobID: key.jobID, runID: runID)
        let normalized = raw.map { WatchTranscriptProjection.wristMarkdown(WatchTaskRunProjection.responseBody($0)) }
        let clipped = normalized.flatMap {
            WatchTranscriptProjection.clippedMarkdown($0, max: Self.maximumTaskOutputCharacters)
        }
        let run = try WatchTaskRun(
            task: key,
            runID: runID,
            startedAt: nil,
            finishedAt: nil,
            status: "finished",
            output: nil,
            isTruncated: false
        )
        return try scoped(
            key.scope,
            WatchTaskRunDetail(
                run: run,
                output: clipped,
                outputTruncated: (normalized?.count ?? 0) > (clipped?.count ?? 0)
            )
        )
    }

    /// Wrist-sized run output; the full file is on iPhone.
    static let maximumTaskOutputCharacters = 1_500

    private static func finiteDate(_ date: Date) -> Date? {
        date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    public func controlTask(
        key: TaskKey,
        action: TaskControl,
        context: CommandContext
    ) async -> CommandReceipt<EmptyValue> {
        guard WatchMutationOperation.currentlyEnabledKinds.contains(.controlTask) else {
            return rejected(context, kind: .controlTask)
        }
        guard let urlString = try? resolvedURL(for: key.scope), matchesRevision(context) else {
            return rejected(context, kind: .controlTask)
        }
        do {
            try await backend.controlTask(urlString: urlString, jobID: key.jobID, action: action.rawValue)
            let receipt = try MutationReceipt(
                context: context,
                operationKind: .controlTask,
                phase: .acknowledged,
                updatedAt: now(),
                nonSecretResultID: key.jobID
            )
            return CommandReceipt(receipt: receipt, value: EmptyValue())
        } catch {
            return rejected(context, kind: .controlTask)
        }
    }

    public func skills(
        scope: ServerScope,
        query: String?,
        localLimit: Int
    ) async throws -> ScopedSnapshot<BoundedCollection<WatchSkillSummary>> {
        let urlString = try resolvedURL(for: scope)
        let cap = min(max(localLimit, 1), 128)
        let glances: [WatchPhoneSkillGlance]
        if let request = WatchGlanceQuery.kanbanRequest(from: query) {
            let board = try await backend.listKanbanBoard(
                urlString: urlString,
                slug: request.slug,
                includeArchived: request.includeArchived,
                onlyMine: request.onlyMine,
                limit: cap
            )
            let chrome = WatchKanbanBoardChrome(
                name: board.name,
                slug: board.slug,
                columns: board.columns,
                boards: board.boards,
                movePolicy: board.movePolicy
            )
            let header = WatchPhoneSkillGlance(name: WatchKanbanBoardChrome.cardID, summary: chrome.wireSummary, enabled: nil)
            let cards = board.cards.map { card in
                WatchPhoneSkillGlance(
                    name: card.id,
                    summary: WatchKanbanCard(
                        id: card.id,
                        title: card.title,
                        status: card.status,
                        assignee: card.assignee,
                        priority: card.priority,
                        body: card.body,
                        tenant: card.tenant,
                        commentCount: card.commentCount,
                        linkCount: card.linkCount,
                        ageSeconds: card.ageSeconds,
                        skills: card.skills
                    ).wireSummary,
                    enabled: nil
                )
            }
            glances = [header] + cards
        } else {
            glances = try await backend.listSkills(urlString: urlString, query: query, limit: cap)
        }
        let items: [WatchSkillSummary] = glances.prefix(cap).compactMap { glance in
            guard let key = try? SkillKey(scope: scope, name: glance.name) else { return nil }
            return try? WatchSkillSummary(key: key, summary: glance.summary, enabled: glance.enabled)
        }
        return try scopedList(
            scope: scope,
            items: items,
            truncated: glances.count > items.count,
            maximumItems: 128
        )
    }

    public func skillDetail(key: SkillKey) async throws -> ScopedSnapshot<WatchSkillDetail> {
        throw WatchCompanionError.unsupported(.skillDetail)
    }

    public func skillContent(
        key: SkillKey,
        fileHandle: PathHandle?
    ) async throws -> ScopedSnapshot<WatchSkillContent> {
        throw WatchCompanionError.unsupported(.skillContent)
    }

    public func memoryDocument(scope: ServerScope) async throws -> ScopedSnapshot<WatchMemoryDocument> {
        let urlString = try resolvedURL(for: scope)
        let glances = try await backend.memoryGlance(urlString: urlString)
        var seen = Set<String>()
        let sections: [WatchMemorySection] = glances.prefix(2).compactMap { glance in
            guard seen.insert(glance.section).inserted else { return nil }
            guard let key = try? MemoryKey(scope: scope, remoteID: glance.section) else { return nil }
            return try? WatchMemorySection(
                key: key,
                section: glance.section,
                redactedContent: Self.boundedLabel(glance.text, maxUTF8: 16_384) ?? "",
                isTruncated: glance.isTruncated || glance.text.utf8.count > 16_384
            )
        }
        return try scoped(scope, try WatchMemoryDocument(sections: sections))
    }

    public func insightsAggregate(
        scope: ServerScope,
        days: InsightsDays
    ) async throws -> ScopedSnapshot<WatchInsightsAggregate> {
        let urlString = try resolvedURL(for: scope)
        let glance = try await backend.usageGlance(urlString: urlString, days: days.value)
        let models = Array(glance.models.prefix(32))
        let usage: [WatchModelUsage] = glance.modelUsage.prefix(32).compactMap { model in
            guard let name = Self.boundedLabel(model.name, maxUTF8: ContractLimits.identifierUTF8Bytes),
                  model.cost.isFinite
            else { return nil }
            return try? WatchModelUsage(
                name: name,
                totalTokens: max(model.totalTokens, 0),
                cost: Decimal(max(model.cost, 0)),
                sessions: max(model.sessions, 0)
            )
        }
        let daily = Array(glance.dailyTokens.suffix(min(days.value, 90)).map { max($0, 0) })
        let aggregate = try WatchInsightsAggregate(
            days: days,
            totalSessions: max(glance.totalSessions, 0),
            totalMessages: max(glance.totalMessages, 0),
            totalInputTokens: max(glance.totalInputTokens, 0),
            totalOutputTokens: max(glance.totalOutputTokens, 0),
            totalTokens: max(glance.totalTokens, 0),
            totalCost: glance.totalCost.isFinite ? Decimal(max(glance.totalCost, 0)) : 0,
            models: try BoundedCollection(items: models, isTruncated: glance.models.count > models.count),
            dailyTokens: try BoundedCollection(items: daily, isTruncated: glance.dailyTokens.count > daily.count),
            activityByDay: try BoundedCollection(items: [], isTruncated: false),
            activityByHour: try BoundedCollection(items: [], isTruncated: false),
            modelUsage: try BoundedCollection(items: usage, isTruncated: glance.modelUsage.count > usage.count, maximumItems: 32)
        )
        return try scoped(scope, aggregate)
    }

    public func workspace(
        session: SessionKey,
        parentPathHandle: PathHandle?
    ) async throws -> ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>> {
        throw WatchCompanionError.unsupported(.workspace)
    }

    public func filePreview(
        session: SessionKey,
        pathHandle: PathHandle
    ) async throws -> ScopedSnapshot<WatchFilePreview> {
        throw WatchCompanionError.unsupported(.filePreview)
    }

    public func gitAggregate(session: SessionKey) async throws -> ScopedSnapshot<WatchGitAggregate> {
        throw WatchCompanionError.unsupported(.gitAggregate)
    }

    public func diagnostics(scope: ServerScope) async throws -> ScopedSnapshot<WatchDiagnosticsProjection> {
        let observed = now()
        return try scoped(
            scope,
            WatchDiagnosticsProjection(
                scope: scope,
                source: .phoneBroker,
                observedAt: observed,
                expiresAt: observed.addingTimeInterval(30),
                codes: storage.withLock { $0.fence.decision(for: scope) == .accept ? [] : [.routeUnavailable] }
            )
        )
    }

    public func media(_ descriptor: WatchMediaDescriptor) async throws -> WatchMediaPayload {
        let urlString = try resolvedURL(for: descriptor.scope)
        let key = Self.mediaCacheKey(descriptor)
        let cached = storage.withLock { $0.mediaByHandle[key] }
        if let cached, let payload = try? WatchMediaPayload(descriptor: descriptor, bytes: cached.bytes) {
            return payload
        }
        // A digest or size miss must refetch. The cached entry stays until that
        // fetch succeeds: a long workspace path lives only there, and the
        // handle is its hash. Dropping the entry first made a failed retry
        // ask the server for the hash.
        let path = cached?.path ?? descriptor.handle.rawValue
        let raw = try await backend.mediaData(
            urlString: urlString,
            sessionID: descriptor.session.sessionID,
            path: path
        )
        guard let bytes = WatchImageThumbnail.jpeg(from: raw) ?? (raw.count <= WatchImageThumbnail.watchFaceMaxBytes ? raw : nil) else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        cacheMedia(key: key, path: path, bytes: bytes)
        return try WatchMediaPayload(descriptor: descriptor, bytes: bytes)
    }

    public func bots(scope: ServerScope) async throws -> ScopedSnapshot<[WatchBotSummary]> {
        throw WatchCompanionError.unsupported(.bots)
    }

    public func botConversation(key: BotKey) async throws -> ScopedSnapshot<WatchBotConversation> {
        throw WatchCompanionError.unsupported(.botConversation)
    }

    public func botEvents(
        for key: BotKey,
        replayEpoch: String?,
        afterSequence: Int?
    ) -> AsyncThrowingStream<WatchBotEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: WatchCompanionError.unsupported(.botStream)) }
    }

    public func sendBot(text: String, to key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        rejected(context, kind: .sendBot)
    }

    public func interruptBot(key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        rejected(context, kind: .interruptBot)
    }

    private func projectImage(
        session: SessionKey,
        urlString: String,
        id: String,
        path: String,
        mime: String?,
        alt: String?
    ) async -> WatchTranscriptBlock? {
        guard !path.hasPrefix("http://"), !path.hasPrefix("https://") else { return nil }
        do {
            let raw = try await backend.mediaData(
                urlString: urlString,
                sessionID: session.sessionID,
                path: path
            )
            guard let bytes = WatchImageThumbnail.jpeg(from: raw) else { return nil }
            let handle = try mediaHandle(for: path)
            let observed = now()
            let digest = sha256Hex(bytes)
            let descriptor = try WatchMediaDescriptor(
                scope: session.scope,
                session: session,
                origin: OriginBinding(digest: sha256Hex(Data(path.utf8))),
                handle: handle,
                mimeType: "image/jpeg",
                byteSize: bytes.count,
                sha256: digest,
                observedAt: observed,
                expiresAt: observed.addingTimeInterval(120)
            )
            cacheMedia(key: Self.mediaCacheKey(descriptor), path: path, bytes: bytes)
            return .image(id: id, descriptor: descriptor, alt: alt)
        } catch {
            return nil
        }
    }

    private func mediaHandle(for path: String) throws -> MediaHandle {
        if path.utf8.count <= ContractLimits.identifierUTF8Bytes {
            return try MediaHandle(path)
        }
        return try MediaHandle(sha256Hex(Data(path.utf8)))
    }

    /// Session and server ride in the key. The same path on two sessions is
    /// not the same image, even when the byte counts match.
    private static func mediaCacheKey(_ descriptor: WatchMediaDescriptor) -> String {
        "\(descriptor.scope.server.rawValue.uuidString)|\(descriptor.session.sessionID)|\(descriptor.handle.rawValue)"
    }

    private func cacheMedia(key: String, path: String, bytes: Data) {
        storage.withLock { state in
            if state.mediaByHandle.count >= 16 {
                state.mediaByHandle.removeAll()
            }
            state.mediaByHandle[key] = CachedMedia(path: path, bytes: bytes)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func registryIdentity(_ entries: [RegistryEntry]) -> [String] {
        entries.map {
            let writes = $0.writesUnsupported == true ? "read-only" : "writes"
            return "\($0.scope.server.rawValue.uuidString)|\($0.scope.generation.rawValue)|\($0.displayName.rawValue)|\(writes)"
        }
    }

    private func recordIssuedRun(_ run: RunKey) {
        storage.withLock { state in
            state.issuedRuns[run.streamID] = run
            issuedRunStore?.save(Array(state.issuedRuns.values))
        }
    }

    /// Drops the run from memory only. The file still has it until cancel
    /// succeeds and `persistIssuedRuns` writes the smaller set.
    private func takeIssuedRun(_ run: RunKey) -> Bool {
        storage.withLock { state in
            guard state.issuedRuns[run.streamID] == run else { return false }
            state.issuedRuns[run.streamID] = nil
            return true
        }
    }

    private func persistIssuedRuns() {
        storage.withLock { state in
            issuedRunStore?.save(Array(state.issuedRuns.values))
        }
    }

    /// The URL for a run this phone started. After a relaunch the same server
    /// can have a new generation; the saved run still belongs on that URL.
    private func urlForIssuedRun(_ run: RunKey) -> String? {
        storage.withLock { state in
            state.urlByServer[run.session.scope.server]
        }
    }

    /// Fits a label into the watch DTO byte budget. Returns nil for blank input.
    private static func boundedLabel(_ value: String?, maxUTF8: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, maxUTF8 > 0 else { return nil }
        if trimmed.utf8.count <= maxUTF8 { return trimmed }
        let ellipsis = "…"
        let budget = maxUTF8 - ellipsis.utf8.count
        guard budget > 0 else { return nil }
        var kept = ""
        var used = 0
        for character in trimmed {
            let next = used + character.utf8.count
            if next > budget { break }
            kept.append(character)
            used = next
        }
        guard !kept.isEmpty else { return nil }
        return kept + ellipsis
    }

    private func resolvedURL(for scope: ServerScope) throws -> String {
        try storage.withLock { state in
            guard state.fence.decision(for: scope) == .accept, let url = state.urlByServer[scope.server] else {
                throw WatchCompanionError.scopeRejected
            }
            return url
        }
    }

    private func matchesRevision(_ context: CommandContext) -> Bool {
        matchesRevision(context.expectedRevision)
    }

    private func matchesRevision(_ revision: Revision) -> Bool {
        storage.withLock { $0.fence.registryRevision == revision }
    }

    /// Drops rows from the end until the encoded snapshot fits a `sendMessage`
    /// reply. One oversized list used to be dropped by WatchConnectivity with
    /// no error, and the watch stayed on its spinner.
    private func scopedList<Item: Codable & Sendable>(
        scope: ServerScope,
        items: [Item],
        truncated: Bool,
        maximumItems: Int
    ) throws -> ScopedSnapshot<BoundedCollection<Item>> {
        var kept = items
        var isTruncated = truncated
        while true {
            let snapshot = try scoped(
                scope,
                try BoundedCollection(items: kept, isTruncated: isTruncated, maximumItems: maximumItems)
            )
            let encoded = try JSONEncoder().encode(snapshot)
            if kept.isEmpty || encoded.count <= WatchVoiceNoteWire.maximumSnapshotJSONBytes {
                return snapshot
            }
            kept.removeLast()
            isTruncated = true
        }
    }

    private func scoped<Value: Codable & Sendable>(_ scope: ServerScope, _ value: Value) throws -> ScopedSnapshot<Value> {
        let observed = now()
        let revision = storage.withLock { $0.fence.registryRevision }
        return try ScopedSnapshot(
            schema: 1,
            scope: scope,
            revision: revision,
            freshness: Freshness(
                observedAt: observed,
                expiresAt: observed.addingTimeInterval(30),
                source: .phoneProjection
            ),
            value: value
        )
    }

    private func rejected<Value: Hashable & Codable & Sendable>(
        _ context: CommandContext,
        kind: WatchOperationKind
    ) -> CommandReceipt<Value> {
        let receipt = try? MutationReceipt(
            context: context,
            operationKind: kind,
            phase: .rejected,
            updatedAt: now(),
            nonSecretResultID: "rejected"
        )
        if let receipt {
            return CommandReceipt(receipt: receipt, value: nil)
        }
        let fallback = try! MutationReceipt(
            context: context,
            operationKind: kind,
            phase: .rejected,
            updatedAt: context.createdAt,
            nonSecretResultID: "rejected"
        )
        return CommandReceipt(receipt: fallback, value: nil)
    }

    private func fallbackEmptyRegistry(revision: UInt64) -> RegistrySnapshot {
        try! RegistrySnapshot(
            epoch: epoch,
            revision: Revision(revision),
            generatedAt: Date(timeIntervalSince1970: 1),
            entries: []
        )
    }
}
