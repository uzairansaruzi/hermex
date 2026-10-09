import Foundation
import Testing
@testable import WatchShared

@Suite struct ServiceBoundaryTests {
    private final class CurrentPinService: WatchCompanionServicing, @unchecked Sendable {
        private(set) var sideEffects: [String] = []
        private(set) var persistenceCount = 0
        private(set) var serializationCount = 0
        private(set) var endpointConstructionCount = 0
        private(set) var adapterSubmissionCount = 0
        private(set) var watchConnectivityCount = 0
        private(set) var urlSessionCount = 0
        private(set) var networkObservationCount = 0
        func registry() async -> RegistrySnapshot { fatalError("unused") }
        func refreshSessions(scope: ServerScope, collection: SessionCollection, query: String?, localLimit: Int) async throws -> ScopedSnapshot<BoundedCollection<WatchSessionSummary>> { fatalError("unused") }
        func composerOptions(scope: ServerScope) async throws -> ScopedSnapshot<WatchComposerOptions> { fatalError("unused") }
        func transcript(key: SessionKey, before: Int?, limit: Int) async throws -> ScopedSnapshot<WatchTranscript> { fatalError("unused") }
        func createSession(scope: ServerScope, profileID: ProfileID?, workspaceHandle: WorkspaceHandle?, context: CommandContext) async -> CommandReceipt<SessionKey> { fatalError("unused") }
        func send(text: String, to key: SessionKey, context: CommandContext) async -> CommandReceipt<RunKey> { fatalError("unused") }
        func events(for run: RunKey, afterEventID: String?) -> AsyncThrowingStream<WatchRunEvent, Error> { fatalError("unused") }
        func reconcile(run: RunKey) async throws -> ScopedSnapshot<WatchRunState> { fatalError("unused") }
        func stop(run: RunKey, context: CommandContext) async -> CommandReceipt<EmptyValue> { fatalError("unused") }
        func pendingApprovalHead(session: SessionKey) async throws -> ScopedSnapshot<WatchAttentionHead<WatchApproval>> { fatalError("unused") }
        func pendingClarificationHead(session: SessionKey) async throws -> ScopedSnapshot<WatchAttentionHead<WatchClarification>> { fatalError("unused") }
        func tasks(scope: ServerScope, localLimit: Int) async throws -> ScopedSnapshot<BoundedCollection<WatchTaskSummary>> { fatalError("unused") }
        func taskRuns(key: TaskKey, page: PageRequest) async throws -> ScopedSnapshot<BoundedPage<WatchTaskRun>> { fatalError("unused") }
        func taskRunDetail(key: TaskKey, runID: String) async throws -> ScopedSnapshot<WatchTaskRunDetail> { fatalError("unused") }
        func controlTask(key: TaskKey, action: TaskControl, context: CommandContext) async -> CommandReceipt<EmptyValue> { fatalError("unused") }
        func skills(scope: ServerScope, query: String?, localLimit: Int) async throws -> ScopedSnapshot<BoundedCollection<WatchSkillSummary>> { fatalError("unused") }
        func skillDetail(key: SkillKey) async throws -> ScopedSnapshot<WatchSkillDetail> { fatalError("unused") }
        func skillContent(key: SkillKey, fileHandle: PathHandle?) async throws -> ScopedSnapshot<WatchSkillContent> { fatalError("unused") }
        func memoryDocument(scope: ServerScope) async throws -> ScopedSnapshot<WatchMemoryDocument> { fatalError("unused") }
        func insightsAggregate(scope: ServerScope, days: InsightsDays) async throws -> ScopedSnapshot<WatchInsightsAggregate> { fatalError("unused") }
        func workspace(session: SessionKey, parentPathHandle: PathHandle?) async throws -> ScopedSnapshot<BoundedCollection<WatchWorkspaceEntry>> { fatalError("unused") }
        func filePreview(session: SessionKey, pathHandle: PathHandle) async throws -> ScopedSnapshot<WatchFilePreview> { fatalError("unused") }
        func gitAggregate(session: SessionKey) async throws -> ScopedSnapshot<WatchGitAggregate> { fatalError("unused") }
        func diagnostics(scope: ServerScope) async throws -> ScopedSnapshot<WatchDiagnosticsProjection> { fatalError("unused") }
        func media(_ descriptor: WatchMediaDescriptor) async throws -> WatchMediaPayload { fatalError("unused") }
        func bots(scope: ServerScope) async throws -> ScopedSnapshot<[WatchBotSummary]> { fatalError("unused") }
        func botConversation(key: BotKey) async throws -> ScopedSnapshot<WatchBotConversation> { fatalError("unused") }
        func botEvents(for key: BotKey, replayEpoch: String?, afterSequence: Int?) -> AsyncThrowingStream<WatchBotEvent, Error> { fatalError("unused") }
        func sendBot(text: String, to key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> { fatalError("unused") }
        func interruptBot(key: BotKey, context: CommandContext) async -> CommandReceipt<EmptyValue> { fatalError("unused") }
    }

    private func fixture() throws -> (ApprovalKey, ClarificationKey, CommandContext) {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let session = try SessionKey(scope: scope, sessionID: "session")
        let created = Date(timeIntervalSinceReferenceDate: 100)
        let context = try CommandContext(stableCommandID: CommandID(rawValue: UUID()), scope: scope, expectedRevision: Revision(7), createdAt: created, expiresAt: created.addingTimeInterval(60))
        return (try ApprovalKey(session: session, remoteID: "approval"), try ClarificationKey(session: session, remoteID: "clarification"), context)
    }

    @Test func semanticCoverage_WatchCompanionServicing() async throws {
        let concrete = CurrentPinService()
        let service: any WatchCompanionServicing = concrete
        let _: any Sendable = service
        let stop: (RunKey, CommandContext) async -> CommandReceipt<EmptyValue> = service.stop(run:context:)
        let controlTask: (TaskKey, TaskControl, CommandContext) async -> CommandReceipt<EmptyValue> = service.controlTask(key:action:context:)
        let sendBot: (String, BotKey, CommandContext) async -> CommandReceipt<EmptyValue> = service.sendBot(text:to:context:)
        let interruptBot: (BotKey, CommandContext) async -> CommandReceipt<EmptyValue> = service.interruptBot(key:context:)
        _ = (stop, controlTask, sendBot, interruptBot)
        let (approval, clarification, context) = try fixture()

        let approvalReceipt = await service.respond(approval: approval, choice: .once, context: context)
        let clarificationReceipt = await service.respond(clarification: clarification, answer: "answer", context: context)

        #expect(approvalReceipt.value == nil)
        #expect(approvalReceipt.receipt.context == context)
        #expect(approvalReceipt.receipt.operationKind == .respondApproval)
        #expect(approvalReceipt.receipt.phase == .rejected)
        #expect(approvalReceipt.receipt.updatedAt == context.createdAt)
        #expect(approvalReceipt.receipt.nonSecretResultID == "attentionExactIDUnavailable")
        #expect(clarificationReceipt.value == nil)
        #expect(clarificationReceipt.receipt.context == context)
        #expect(clarificationReceipt.receipt.operationKind == .respondClarification)
        #expect(clarificationReceipt.receipt.phase == .rejected)
        #expect(clarificationReceipt.receipt.updatedAt == context.createdAt)
        #expect(clarificationReceipt.receipt.nonSecretResultID == "attentionExactIDUnavailable")
        #expect(concrete.sideEffects.isEmpty)
        #expect(concrete.persistenceCount == 0)
        #expect(concrete.serializationCount == 0)
        #expect(concrete.endpointConstructionCount == 0)
        #expect(concrete.adapterSubmissionCount == 0)
        #expect(concrete.watchConnectivityCount == 0)
        #expect(concrete.urlSessionCount == 0)
        #expect(concrete.networkObservationCount == 0)
        #expect(!WatchMutationOperation.currentlyEnabledKinds.contains(.respondApproval))
        #expect(!WatchMutationOperation.currentlyEnabledKinds.contains(.respondClarification))

        let invalidContext = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: context.scope,
            expectedRevision: context.expectedRevision,
            createdAt: context.createdAt,
            expiresAt: context.expiresAt
        )
        let secondReceipt = await service.respond(approval: approval, choice: .deny, context: invalidContext)
        #expect(secondReceipt.receipt.context.stableCommandID == invalidContext.stableCommandID)
        #expect(secondReceipt.receipt.nonSecretResultID == "attentionExactIDUnavailable")
        #expect(concrete.sideEffects.isEmpty)
        #expect(concrete.persistenceCount == 0)
        #expect(concrete.serializationCount == 0)
        #expect(concrete.endpointConstructionCount == 0)
        #expect(concrete.adapterSubmissionCount == 0)
        #expect(concrete.watchConnectivityCount == 0)
        #expect(concrete.urlSessionCount == 0)
        #expect(concrete.networkObservationCount == 0)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WatchShared")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let owners = try files.filter {
            try String(contentsOf: $0, encoding: .utf8).contains("protocol WatchCompanionServicing")
        }
        #expect(owners.map(\.lastPathComponent) == ["ServiceBoundary.swift"])
    }
}
