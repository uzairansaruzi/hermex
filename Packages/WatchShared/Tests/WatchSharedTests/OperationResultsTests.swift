import Foundation
import Testing
@testable import WatchShared

@Suite struct OperationResultsTests {
    private struct Fixtures {
        let scope: ServerScope
        let otherScope: ServerScope
        let session: SessionKey
        let run: RunKey
        let task: TaskKey
        let skill: SkillKey
        let memory: MemoryKey
        let path: PathHandle
        let bot: BotKey
        let context: CommandContext
        let freshness: Freshness
        let media: WatchMediaDescriptor
    }

    private func fixtures() throws -> Fixtures {
        let epoch = InstallationEpoch(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
        let scope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!), generation: try Generation(1))
        let otherScope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!), generation: try Generation(1))
        let session = try SessionKey(scope: scope, sessionID: "session")
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let media = try WatchMediaDescriptor(
            scope: scope,
            session: session,
            origin: OriginBinding(digest: "origin"),
            handle: MediaHandle("media"),
            mimeType: "image/png",
            byteSize: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        return Fixtures(
            scope: scope,
            otherScope: otherScope,
            session: session,
            run: try RunKey(session: session, streamID: "run"),
            task: try TaskKey(scope: scope, jobID: "task"),
            skill: try SkillKey(scope: scope, name: "skill"),
            memory: try MemoryKey(scope: scope, remoteID: "memory"),
            path: try PathHandle("path"),
            bot: try BotKey(scope: scope, connectionID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!, profile: "profile"),
            context: try CommandContext(stableCommandID: CommandID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!), scope: scope, expectedRevision: Revision(9), createdAt: now, expiresAt: now.addingTimeInterval(60)),
            freshness: try Freshness(observedAt: now, expiresAt: now.addingTimeInterval(60), source: .phoneProjection),
            media: media
        )
    }

    private func snapshot<Value: Codable & Sendable>(_ value: Value, _ f: Fixtures) throws -> ScopedSnapshot<Value> {
        try ScopedSnapshot(schema: 1, scope: f.scope, revision: Revision(10), freshness: f.freshness, value: value)
    }

    private func receipt(_ kind: WatchOperationKind, _ f: Fixtures) throws -> MutationReceipt {
        try MutationReceipt(context: f.context, operationKind: kind, phase: .acknowledged, updatedAt: f.context.createdAt, nonSecretResultID: "result")
    }

    @Test func semanticCoverage_WatchOperationResult() throws {
        let f = try fixtures()
        let sessionSummary = try WatchSessionSummary(key: f.session, title: "Session", profile: "profile", workspaceLabel: "workspace", updatedAt: f.context.createdAt, isPinned: true, isArchived: false, attention: false, runState: .thinking)
        let composer = try WatchComposerOptions(
            scope: f.scope,
            profiles: [try .init(id: ProfileID("profile"), label: "Profile")],
            workspaces: [try .init(handle: WorkspaceHandle("workspace"), label: "Workspace")],
            defaultProfileID: try ProfileID("profile"),
            defaultWorkspaceHandle: try WorkspaceHandle("workspace")
        )
        let transcript = try WatchTranscript(session: f.session, blocks: [.text(id: "block", role: .assistant, text: "hello")], nextBefore: 4, isTruncated: true)
        let runState = try WatchRunState(key: f.run, phase: .responding, lastEventID: "event", lastSequence: 5, isTerminal: false, summary: "working")
        let approval = try WatchApproval(key: ApprovalKey(session: f.session, remoteID: "approval"), title: "Approve", detail: "detail", choices: [.once, .deny], requestedAt: f.context.createdAt)
        let clarification = try WatchClarification(key: ClarificationKey(session: f.session, remoteID: "clarification"), question: "Question?", choices: ["yes", "no"], requestedAt: f.context.createdAt)
        let taskSummary = try WatchTaskSummary(key: f.task, name: "Task", schedule: "daily", enabled: true, running: false, lastResult: "ok")
        let taskRun = try WatchTaskRun(task: f.task, runID: "task-run", startedAt: f.context.createdAt, finishedAt: f.context.createdAt.addingTimeInterval(1), status: "complete", output: "output", isTruncated: false)
        let skillSummary = try WatchSkillSummary(key: f.skill, summary: "summary", enabled: true)
        let linkedFile = try WatchSkillDetail.LinkedFile(handle: f.path, name: "SKILL.md", byteSize: 12)
        let skillDetail = try WatchSkillDetail(key: f.skill, summary: "summary", linkedFiles: BoundedCollection(items: [linkedFile], isTruncated: false))
        let skillContent = try WatchSkillContent(key: f.skill, fileHandle: f.path, content: "content", isTruncated: false)
        let memoryDocument = try WatchMemoryDocument(sections: [WatchMemorySection(key: f.memory, section: "memory", redactedContent: "content", isTruncated: false)])
        let insights = try WatchInsightsAggregate(days: InsightsDays(7), totalSessions: 1, totalMessages: 2, totalInputTokens: 3, totalOutputTokens: 4, totalTokens: 7, totalCost: Decimal(string: "0.25")!, models: BoundedCollection(items: ["model"], isTruncated: false), dailyTokens: BoundedCollection(items: [7], isTruncated: false), activityByDay: BoundedCollection(items: [1], isTruncated: false), activityByHour: BoundedCollection(items: [1], isTruncated: false))
        let workspace = try WatchWorkspaceEntry(session: f.session, pathHandle: f.path, name: "file.txt", kind: .text, byteSize: 4)
        let git = try WatchGitAggregate(session: f.session, branch: "main", isRepository: true, dirty: true, modifiedCount: 1, untrackedCount: 2, ahead: 3, behind: 4)
        let diagnostics = try WatchDiagnosticsProjection(scope: f.scope, source: .phoneBroker, observedAt: f.context.createdAt, expiresAt: f.context.expiresAt, codes: [.timeout])
        let botSummary = try WatchBotSummary(key: f.bot, title: "Bot", phase: .thinking)
        let botConversation = try WatchBotConversation(key: f.bot, blocks: [.text(id: "bot-block", role: .assistant, text: "hello")], replayEpoch: "epoch", lastSequence: 2, phase: .responding, history: .complete)
        let runEvent = try WatchRunEvent(key: f.run, eventID: "event", sequence: 6, phase: .completed, textDelta: "done", terminal: true)
        let botEvent = try WatchBotEvent(key: f.bot, replayEpoch: "epoch", runtimeSessionID: "runtime", sequence: 7, activity: .messageDelta(delta: "delta"))

        let results: [WatchOperationResult] = [
            .sessions(try snapshot(BoundedCollection(items: [sessionSummary], isTruncated: false), f)),
            .composerOptions(try snapshot(composer, f)),
            .transcript(try snapshot(transcript, f)),
            .runState(try snapshot(runState, f)),
            .pendingApprovalHead(try snapshot(WatchAttentionHead(item: approval, reportedPendingCount: 1), f)),
            .pendingClarificationHead(try snapshot(WatchAttentionHead(item: clarification, reportedPendingCount: 1), f)),
            .tasks(try snapshot(BoundedCollection(items: [taskSummary], isTruncated: false), f)),
            .taskRuns(try snapshot(BoundedPage(items: [taskRun], continuation: "next", isTruncated: true), f)),
            .taskRunDetail(try snapshot(WatchTaskRunDetail(run: taskRun, output: "full output", outputTruncated: false), f)),
            .skills(try snapshot(BoundedCollection(items: [skillSummary], isTruncated: false), f)),
            .skillDetail(try snapshot(skillDetail, f)),
            .skillContent(try snapshot(skillContent, f)),
            .memoryDocument(try snapshot(memoryDocument, f)),
            .insightsAggregate(try snapshot(insights, f)),
            .workspace(try snapshot(BoundedCollection(items: [workspace], isTruncated: false), f)),
            .filePreview(try snapshot(WatchFilePreview.text(pathHandle: f.path, text: "preview", isTruncated: false), f)),
            .gitAggregate(try snapshot(git, f)),
            .diagnostics(try snapshot(diagnostics, f)),
            .media(try WatchMediaPayload(descriptor: f.media, bytes: Data())),
            .bots(try snapshot([botSummary], f)),
            .botConversation(try snapshot(botConversation, f)),
            .createdSession(CommandReceipt(receipt: try receipt(.createSession, f), value: f.session)),
            .startedRun(CommandReceipt(receipt: try receipt(.send, f), value: f.run)),
            .mutation(CommandReceipt(receipt: try receipt(.controlTask, f), value: EmptyValue())),
            .runEvent(runEvent),
            .botEvent(botEvent),
            .failure(.rejected(status: 409, sanitizedCode: "conflict")),
        ]
        let expectedKinds: [WatchOperationKind?] = [
            .sessions, .composerOptions, .transcript, .runState,
            .pendingApprovalHead, .pendingClarificationHead, .tasks, .taskRuns,
            .taskRunDetail, .skills, .skillDetail, .skillContent,
            .memoryDocument, .insightsAggregate, .workspace, .filePreview,
            .gitAggregate, .diagnostics, .media, .bots, .botConversation,
            .createSession, .send, .controlTask, .runStream, .botStream, nil,
        ]

        #expect(results.count == 27)
        #expect(results.map(\.kind) == expectedKinds)
        #expect(results.dropLast().map(\.scope).allSatisfy { $0 == f.scope })
        #expect(results.last?.scope == nil)
        for value in results {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchOperationResult.self, from: encoded)
            #expect(decoded == value)
        }

        let otherSession = try SessionKey(scope: f.otherScope, sessionID: "other")
        let mismatchedSummary = try WatchSessionSummary(key: otherSession, title: "Other", profile: nil, workspaceLabel: nil, updatedAt: nil, isPinned: false, isArchived: false, attention: false, runState: nil)
        let mismatched = WatchOperationResult.sessions(try snapshot(BoundedCollection(items: [mismatchedSummary], isTruncated: false), f))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchOperationResult.self, from: JSONEncoder().encode(mismatched))
        }

        let oversized = WatchOperationResult.sessions(try snapshot(BoundedCollection(items: Array(repeating: sessionSummary, count: 101), isTruncated: false), f))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchOperationResult.self, from: JSONEncoder().encode(oversized))
        }

        let wrongReceipt = WatchOperationResult.createdSession(CommandReceipt(receipt: try receipt(.send, f), value: f.session))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchOperationResult.self, from: JSONEncoder().encode(wrongReceipt))
        }
    }
}
