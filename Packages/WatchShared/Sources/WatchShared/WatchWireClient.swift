import Foundation

/// Watch-side `WatchCompanionServicing` that talks only through a wire transport.
public struct WatchWireClient: WatchCompanionServicing, Sendable {
    private let transport: any WatchWireTransporting
    private let now: @Sendable () -> Date

    public init(transport: any WatchWireTransporting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func registry() async -> RegistrySnapshot {
        do {
            if case .registry(let snapshot) = try await transport.send(.registry) {
                return snapshot
            }
        } catch {}
        return emptyRegistry()
    }

    public func refreshSessions(
        scope: ServerScope,
        collection: SessionCollection,
        query: String?,
        localLimit: Int
    ) async throws -> ScopedSnapshot<BoundedCollection<WatchSessionSummary>> {
        try await read(
            scope: scope,
            operation: .sessions(scope: scope, collection: collection, query: query, localLimit: localLimit)
        )
    }

    public func transcript(
        key: SessionKey,
        before: Int?,
        limit: Int
    ) async throws -> ScopedSnapshot<WatchTranscript> {
        try await read(scope: key.scope, operation: .transcript(session: key, before: before, limit: limit))
    }

    public func createSession(
        scope: ServerScope,
        profileID: ProfileID?,
        workspaceHandle: WorkspaceHandle?,
        context: CommandContext
    ) async -> CommandReceipt<SessionKey> {
        await mutate(WatchMutationOperation.createSession(
            scope: scope,
            profileID: profileID,
            workspaceHandle: workspaceHandle
        ), context: context)
    }

    public func send(text: String, to key: SessionKey, context: CommandContext) async -> CommandReceipt<RunKey> {
        await mutate(.send(session: key, text: text), context: context)
    }

    public func events(for run: RunKey, afterEventID: String?) -> AsyncThrowingStream<WatchRunEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let envelope = try WatchRequestEnvelope.stream(
                        requestID: UUID(),
                        scope: run.session.scope,
                        operation: .run(run, afterEventID: afterEventID),
                        createdAt: now(),
                        expiresAt: now().addingTimeInterval(30)
                    )
                    let reply = try await transport.send(.request(envelope))
                    guard case .envelope(let response) = reply else {
                        continuation.finish(throwing: WatchCompanionError.backend(.invalidResponse))
                        return
                    }
                    try response.validate(against: envelope, receivedAt: now())
                    if case .runEvent(let event) = response.result {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func reconcile(run: RunKey) async throws -> ScopedSnapshot<WatchRunState> {
        try await read(scope: run.session.scope, operation: .runState(run: run))
    }

    public func stop(run: RunKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        await mutate(.stop(run: run), context: context)
    }

    public func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey> {
        try await startedRun(from: .transcribe(request))
    }

    public func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey> {
        try await startedRun(from: .sendPhoto(request))
    }

    public func composerOptions(scope: ServerScope) async throws -> ScopedSnapshot<WatchComposerOptions> {
        try await read(scope: scope, operation: .composerOptions(scope: scope))
    }

    public func switchActiveProfile(scope: ServerScope, name: String, expectedRevision: Revision) async throws -> String {
        let request = try WatchProfileSwitchRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            name: name
        )
        let reply = try await transport.send(.switchProfile(request))
        if case .transcript(let active) = reply {
            let trimmed = active.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw failureAsError(reply)
    }

    public func setSkillEnabled(scope: ServerScope, name: String, enabled: Bool, expectedRevision: Revision) async throws {
        let request = try WatchSkillToggleRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            name: name,
            enabled: enabled
        )
        let reply = try await transport.send(.setSkillEnabled(request))
        if case .failure = reply { throw WatchCompanionError.backend(.invalidResponse) }
    }

    public func createKanbanCard(
        scope: ServerScope,
        boardSlug: String,
        title: String,
        status: String,
        expectedRevision: Revision
    ) async throws {
        let request = try WatchKanbanCreateRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            boardSlug: boardSlug,
            title: title,
            status: status
        )
        let reply = try await transport.send(.createKanbanCard(request))
        if case .failure = reply { throw failureAsError(reply) }
    }

    public func dispatchKanban(
        scope: ServerScope,
        boardSlug: String,
        dryRun: Bool,
        expectedRevision: Revision
    ) async throws -> String {
        let request = try WatchKanbanDispatchRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            boardSlug: boardSlug,
            dryRun: dryRun
        )
        let reply = try await transport.send(.dispatchKanban(request))
        if case .transcript(let summary) = reply { return summary }
        throw failureAsError(reply)
    }

    public func moveKanbanCard(scope: ServerScope, cardID: String, status: String, boardSlug: String, expectedRevision: Revision) async throws {
        let request = try WatchKanbanMoveRequest(
            scope: scope,
            expectedRevision: expectedRevision,
            cardID: cardID,
            status: status,
            boardSlug: boardSlug
        )
        let reply = try await transport.send(.moveKanbanCard(request))
        if case .failure = reply { throw WatchCompanionError.backend(.invalidResponse) }
    }

    public func tasks(scope: ServerScope, localLimit: Int) async throws -> ScopedSnapshot<BoundedCollection<WatchTaskSummary>> {
        try await read(scope: scope, operation: .tasks(scope: scope, localLimit: localLimit))
    }

    public func skills(scope: ServerScope, query: String?, localLimit: Int) async throws -> ScopedSnapshot<BoundedCollection<WatchSkillSummary>> {
        try await read(scope: scope, operation: .skills(scope: scope, query: query, localLimit: localLimit))
    }

    public func memoryDocument(scope: ServerScope) async throws -> ScopedSnapshot<WatchMemoryDocument> {
        try await read(scope: scope, operation: .memoryDocument(scope: scope))
    }

    public func insightsAggregate(scope: ServerScope, days: InsightsDays) async throws -> ScopedSnapshot<WatchInsightsAggregate> {
        try await read(scope: scope, operation: .insightsAggregate(scope: scope, days: days))
    }
    public func pendingApprovalHead(session: SessionKey) async throws -> ScopedSnapshot<WatchAttentionHead<WatchApproval>> {
        throw WatchCompanionError.unsupported(.pendingApprovalHead)
    }
    public func pendingClarificationHead(session: SessionKey) async throws -> ScopedSnapshot<WatchAttentionHead<WatchClarification>> {
        throw WatchCompanionError.unsupported(.pendingClarificationHead)
    }
    public func taskRuns(key: TaskKey, page: PageRequest) async throws -> ScopedSnapshot<BoundedPage<WatchTaskRun>> {
        try await read(scope: key.scope, operation: .taskRuns(task: key, page: page))
    }
    public func taskRunDetail(key: TaskKey, runID: String) async throws -> ScopedSnapshot<WatchTaskRunDetail> {
        try await read(scope: key.scope, operation: .taskRunDetail(task: key, runID: runID))
    }
    public func controlTask(key: TaskKey, action: TaskControl, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        await mutate(.controlTask(task: key, action: action), context: context)
    }
    public func skillDetail(key: SkillKey) async throws -> ScopedSnapshot<WatchSkillDetail> {
        throw WatchCompanionError.unsupported(.skillDetail)
    }
    public func skillContent(key: SkillKey, fileHandle: PathHandle?) async throws -> ScopedSnapshot<WatchSkillContent> {
        throw WatchCompanionError.unsupported(.skillContent)
    }
    public func workspace(session: SessionKey, parentPathHandle: PathHandle?) async throws -> ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>> {
        throw WatchCompanionError.unsupported(.workspace)
    }
    public func filePreview(session: SessionKey, pathHandle: PathHandle) async throws -> ScopedSnapshot<WatchFilePreview> {
        throw WatchCompanionError.unsupported(.filePreview)
    }
    public func gitAggregate(session: SessionKey) async throws -> ScopedSnapshot<WatchGitAggregate> {
        throw WatchCompanionError.unsupported(.gitAggregate)
    }
    public func diagnostics(scope: ServerScope) async throws -> ScopedSnapshot<WatchDiagnosticsProjection> {
        try await read(scope: scope, operation: .diagnostics(scope: scope))
    }
    public func media(_ descriptor: WatchMediaDescriptor) async throws -> WatchMediaPayload {
        try await read(scope: descriptor.scope, operation: .media(descriptor))
    }
    public func bots(scope: ServerScope) async throws -> ScopedSnapshot<[WatchBotSummary]> {
        throw WatchCompanionError.unsupported(.bots)
    }
    public func botConversation(key: BotKey) async throws -> ScopedSnapshot<WatchBotConversation> {
        throw WatchCompanionError.unsupported(.botConversation)
    }
    public func botEvents(for key: BotKey, replayEpoch: String?, afterSequence: Int?) -> AsyncThrowingStream<WatchBotEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: WatchCompanionError.unsupported(.botStream)) }
    }
    public func sendBot(text: String, to key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        currentPinRejection(context: context, kind: .sendBot)
    }
    public func interruptBot(key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> {
        currentPinRejection(context: context, kind: .interruptBot)
    }

    private func read<Value>(scope: ServerScope, operation: WatchReadOperation) async throws -> Value {
        let envelope = try WatchRequestEnvelope.read(
            requestID: UUID(),
            scope: scope,
            operation: operation,
            createdAt: now(),
            expiresAt: now().addingTimeInterval(30)
        )
        let reply = try await transport.send(.request(envelope))
        guard case .envelope(let response) = reply else {
            throw failureAsError(reply)
        }
        // Correlate the reply with the request: request id, scope, operation
        // kind, and expiry must all line up so a stale or misrouted envelope
        // never populates watch state.
        try response.validate(against: envelope, receivedAt: now())
        switch (operation, response.result) {
        case (.sessions, .sessions(let value)):
            return try cast(value)
        case (.composerOptions, .composerOptions(let value)):
            return try cast(value)
        case (.tasks, .tasks(let value)):
            return try cast(value)
        case (.taskRuns, .taskRuns(let value)):
            return try cast(value)
        case (.taskRunDetail, .taskRunDetail(let value)):
            return try cast(value)
        case (.skills, .skills(let value)):
            return try cast(value)
        case (.memoryDocument, .memoryDocument(let value)):
            return try cast(value)
        case (.insightsAggregate, .insightsAggregate(let value)):
            return try cast(value)
        case (.transcript, .transcript(let value)):
            return try cast(value)
        case (.runState, .runState(let value)):
            return try cast(value)
        case (.diagnostics, .diagnostics(let value)):
            return try cast(value)
        case (.media, .media(let value)):
            return try cast(value)
        default:
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    private func startedRun(from message: WatchWireMessage) async throws -> CommandReceipt<RunKey> {
        let reply = try await transport.send(message)
        switch reply {
        case .startedRun(let receipt):
            return receipt
        case .failure:
            throw WatchCompanionError.backend(.invalidResponse)
        default:
            throw WatchCompanionError.backend(.invalidResponse)
        }
    }

    private func cast<T, Value>(_ value: T) throws -> Value {
        guard let typed = value as? Value else {
            throw WatchCompanionError.backend(.invalidResponse)
        }
        return typed
    }

    private func mutate<Value: Hashable & Codable & Sendable>(
        _ operation: WatchMutationOperation,
        context: CommandContext
    ) async -> CommandReceipt<Value> {
        do {
            let request = try WatchMutationRequest(
                requestID: UUID(),
                context: context,
                operation: operation,
                createdAt: context.createdAt,
                expiresAt: context.expiresAt
            )
            let reply = try await transport.send(.mutation(request))
            guard case .envelope(let response) = reply else {
                return currentPinRejection(context: context, kind: operation.kind)
            }
            // Enforce request-id / scope / operation / context correlation so a
            // mismatched or replayed envelope cannot be mistaken for this mutation.
            do {
                try response.validate(against: request, receivedAt: now())
            } catch {
                return currentPinRejection(context: context, kind: operation.kind)
            }
            switch response.result {
            case .createdSession(let receipt as CommandReceipt<Value>),
                 .startedRun(let receipt as CommandReceipt<Value>),
                 .mutation(let receipt as CommandReceipt<Value>):
                return receipt
            default:
                return currentPinRejection(context: context, kind: operation.kind)
            }
        } catch {
            return currentPinRejection(context: context, kind: operation.kind)
        }
    }

    private func currentPinRejection<Value: Hashable & Codable & Sendable>(
        context: CommandContext,
        kind: WatchOperationKind
    ) -> CommandReceipt<Value> {
        let receipt = try! MutationReceipt(
            context: context,
            operationKind: kind,
            phase: .rejected,
            updatedAt: context.createdAt,
            nonSecretResultID: "rejected"
        )
        return CommandReceipt(receipt: receipt, value: nil)
    }

    private func emptyRegistry() -> RegistrySnapshot {
        RegistrySnapshot.unavailableWake()
    }

    /// Translates a non-envelope reply into the most specific watch error so the
    /// model can react: a 401 from the phone means the iPhone's session is gone
    /// and the user must sign in on iPhone; anything else is a generic backend
    /// failure.
    private func failureAsError(_ reply: WatchWireReply) -> Error {
        if case .failure(.rejected(let status, let code)) = reply, status == 401, code == "authRequired" {
            return WatchCompanionError.backend(.authRequired)
        }
        return WatchCompanionError.backend(.invalidResponse)
    }
}
