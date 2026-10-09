import Foundation
import Testing
@testable import WatchShared

@Suite struct OperationsTests {
    private struct Fixtures {
        let scope: ServerScope
        let session: SessionKey
        let run: RunKey
        let task: TaskKey
        let skill: SkillKey
        let path: PathHandle
        let bot: BotKey
        let media: WatchMediaDescriptor
    }

    private func fixtures() throws -> Fixtures {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            server: ServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            generation: try Generation(3)
        )
        let session = try SessionKey(scope: scope, sessionID: "session")
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let media = try WatchMediaDescriptor(
            scope: scope,
            session: session,
            origin: OriginBinding(digest: "origin"),
            handle: MediaHandle("media"),
            mimeType: "image/png",
            byteSize: 0,
            sha256: String(repeating: "a", count: 64),
            observedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        return Fixtures(
            scope: scope,
            session: session,
            run: try RunKey(session: session, streamID: "run"),
            task: try TaskKey(scope: scope, jobID: "task"),
            skill: try SkillKey(scope: scope, name: "skill"),
            path: try PathHandle("path"),
            bot: try BotKey(scope: scope, connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, profile: "profile"),
            media: media
        )
    }

    @Test func semanticCoverage_WatchOperationKind() throws {
        let allKinds: [WatchOperationKind] = [
            .sessions, .composerOptions, .transcript, .runState,
            .pendingApprovalHead, .pendingClarificationHead, .tasks, .taskRuns,
            .taskRunDetail, .skills, .skillDetail, .skillContent,
            .memoryDocument, .insightsAggregate, .workspace, .filePreview,
            .gitAggregate, .diagnostics, .media, .bots, .botConversation,
            .createSession, .send, .stop, .respondApproval,
            .respondClarification, .controlTask, .sendBot, .interruptBot,
            .runStream, .botStream,
        ]
        let expectedRawValues = [
            "sessions", "composerOptions", "transcript", "runState",
            "pendingApprovalHead", "pendingClarificationHead", "tasks", "taskRuns",
            "taskRunDetail", "skills", "skillDetail", "skillContent",
            "memoryDocument", "insightsAggregate", "workspace", "filePreview",
            "gitAggregate", "diagnostics", "media", "bots", "botConversation",
            "createSession", "send", "stop", "respondApproval",
            "respondClarification", "controlTask", "sendBot", "interruptBot",
            "runStream", "botStream",
        ]

        #expect(allKinds.count == 31)
        #expect(Set(allKinds).count == allKinds.count)
        #expect(allKinds.map(\.rawValue) == expectedRawValues)
        for value in allKinds {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchOperationKind.self, from: encoded)
            #expect(decoded == value)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchOperationKind.self, from: Data("\"futureOperation\"".utf8))
        }
    }

    @Test func semanticCoverage_WatchReadOperation() throws {
        let f = try fixtures()
        let operations: [WatchReadOperation] = [
            .sessions(scope: f.scope, collection: .current, query: "query", localLimit: 10),
            .composerOptions(scope: f.scope),
            .transcript(session: f.session, before: 12, limit: 25),
            .runState(run: f.run),
            .pendingApprovalHead(session: f.session),
            .pendingClarificationHead(session: f.session),
            .tasks(scope: f.scope, localLimit: 32),
            .taskRuns(task: f.task, page: try PageRequest(continuation: "next", limit: 20)),
            .taskRunDetail(task: f.task, runID: "task-run"),
            .skills(scope: f.scope, query: "swift", localLimit: 64),
            .skillDetail(skill: f.skill),
            .skillContent(skill: f.skill, fileHandle: f.path),
            .memoryDocument(scope: f.scope),
            .insightsAggregate(scope: f.scope, days: try InsightsDays(30)),
            .workspace(session: f.session, parentPathHandle: f.path),
            .filePreview(session: f.session, pathHandle: f.path),
            .gitAggregate(session: f.session),
            .diagnostics(scope: f.scope),
            .media(f.media),
            .bots(scope: f.scope),
            .botConversation(bot: f.bot),
        ]
        let expectedKinds: [WatchOperationKind] = [
            .sessions, .composerOptions, .transcript, .runState,
            .pendingApprovalHead, .pendingClarificationHead, .tasks, .taskRuns,
            .taskRunDetail, .skills, .skillDetail, .skillContent,
            .memoryDocument, .insightsAggregate, .workspace, .filePreview,
            .gitAggregate, .diagnostics, .media, .bots, .botConversation,
        ]

        #expect(operations.map(\.kind) == expectedKinds)
        #expect(operations.map(\.scope) == Array(repeating: f.scope, count: operations.count))
        for value in operations {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchReadOperation.self, from: encoded)
            #expect(decoded == value)
        }

        let invalid: [WatchReadOperation] = [
            .sessions(scope: f.scope, collection: .current, query: nil, localLimit: 0),
            .sessions(scope: f.scope, collection: .current, query: String(repeating: "q", count: 257), localLimit: 1),
            .transcript(session: f.session, before: -1, limit: 1),
            .transcript(session: f.session, before: nil, limit: 51),
            .tasks(scope: f.scope, localLimit: 65),
            .skills(scope: f.scope, query: "   ", localLimit: 1),
            .skills(scope: f.scope, query: nil, localLimit: 129),
            .taskRunDetail(task: f.task, runID: " "),
        ]
        for value in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchReadOperation.self, from: JSONEncoder().encode(value))
            }
        }
    }

    @Test func semanticCoverage_WatchStreamOperation() throws {
        let f = try fixtures()
        let operations: [WatchStreamOperation] = [
            .run(f.run, afterEventID: "event-7"),
            .bot(f.bot, replayEpoch: "epoch-2", afterSequence: 8),
        ]
        #expect(operations.map(\.kind) == [.runStream, .botStream])
        #expect(operations.map(\.scope) == [f.scope, f.scope])
        for value in operations {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchStreamOperation.self, from: encoded)
            #expect(decoded == value)
        }

        let invalid: [WatchStreamOperation] = [
            .run(f.run, afterEventID: " "),
            .run(f.run, afterEventID: String(repeating: "x", count: 257)),
            .bot(f.bot, replayEpoch: " ", afterSequence: nil),
            .bot(f.bot, replayEpoch: String(repeating: "e", count: 257), afterSequence: nil),
            .bot(f.bot, replayEpoch: nil, afterSequence: -1),
        ]
        for value in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchStreamOperation.self, from: JSONEncoder().encode(value))
            }
        }
    }
}
