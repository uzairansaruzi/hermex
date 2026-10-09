import Foundation
import Testing
@testable import WatchShared

@Suite struct CommandsTests {
    private struct Fixtures {
        let scope: ServerScope
        let otherScope: ServerScope
        let session: SessionKey
        let run: RunKey
        let approval: ApprovalKey
        let clarification: ClarificationKey
        let task: TaskKey
        let bot: BotKey
    }

    private func fixtures() throws -> Fixtures {
        let epoch = InstallationEpoch(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        let scope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!), generation: try Generation(2))
        let otherScope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!), generation: try Generation(2))
        let session = try SessionKey(scope: scope, sessionID: "session")
        return Fixtures(
            scope: scope,
            otherScope: otherScope,
            session: session,
            run: try RunKey(session: session, streamID: "run"),
            approval: try ApprovalKey(session: session, remoteID: "approval"),
            clarification: try ClarificationKey(session: session, remoteID: "clarification"),
            task: try TaskKey(scope: scope, jobID: "task"),
            bot: try BotKey(scope: scope, connectionID: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!, profile: "profile")
        )
    }

    @Test func semanticCoverage_CommandID() throws {
        let raw = UUID(uuidString: "20000000-0000-0000-0000-000000000005")!
        let value = CommandID(rawValue: raw)
        #expect(value.rawValue == raw)
        #expect(value == CommandID(rawValue: raw))
        #expect(value != CommandID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000006")!))

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CommandID.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CommandID.self, from: Data("{\"rawValue\":\"not-a-uuid\"}".utf8))
        }
    }

    @Test func semanticCoverage_CommandContext() throws {
        let f = try fixtures()
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let commandID = CommandID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000007")!)
        let value = try CommandContext(stableCommandID: commandID, scope: f.scope, expectedRevision: Revision(11), createdAt: created, expiresAt: created.addingTimeInterval(90))
        #expect(value.stableCommandID == commandID)
        #expect(value.scope == f.scope)
        #expect(value.expectedRevision == Revision(11))
        #expect(value.createdAt == created)
        #expect(value.expiresAt == created.addingTimeInterval(90))

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CommandContext.self, from: encoded)
        #expect(decoded == value)
        #expect(throws: (any Error).self) {
            try CommandContext(stableCommandID: commandID, scope: f.scope, expectedRevision: Revision(11), createdAt: created, expiresAt: created)
        }
        #expect(throws: (any Error).self) {
            try CommandContext(stableCommandID: commandID, scope: f.scope, expectedRevision: Revision(11), createdAt: .distantFuture, expiresAt: .distantPast)
        }
    }

    @Test func semanticCoverage_WatchMutationOperation() throws {
        let f = try fixtures()
        let operations: [WatchMutationOperation] = [
            .createSession(scope: f.scope, profileID: try ProfileID("profile"), workspaceHandle: try WorkspaceHandle("workspace")),
            .send(session: f.session, text: "hello"),
            .stop(run: f.run),
            .respondApproval(approval: f.approval, choice: .once),
            .respondClarification(clarification: f.clarification, answer: "answer"),
            .controlTask(task: f.task, action: .pause),
            .sendBot(bot: f.bot, text: "bot message"),
            .interruptBot(bot: f.bot),
        ]
        let expectedKinds: [WatchOperationKind] = [
            .createSession, .send, .stop, .respondApproval,
            .respondClarification, .controlTask, .sendBot, .interruptBot,
        ]
        let expectedEnabled: Set<WatchOperationKind> = [.createSession, .send, .stop, .controlTask, .sendBot, .interruptBot]

        #expect(operations.map(\.kind) == expectedKinds)
        #expect(operations.map(\.scope) == Array(repeating: f.scope, count: operations.count))
        #expect(WatchMutationOperation.currentlyEnabledKinds == expectedEnabled)
        #expect(!WatchMutationOperation.currentlyEnabledKinds.contains(.respondApproval))
        #expect(!WatchMutationOperation.currentlyEnabledKinds.contains(.respondClarification))
        for value in operations {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchMutationOperation.self, from: encoded)
            #expect(decoded == value)
        }

        let otherSession = try SessionKey(scope: f.otherScope, sessionID: "other")
        #expect(WatchMutationOperation.send(session: otherSession, text: "hello").scope == f.otherScope)

        let invalid: [WatchMutationOperation] = [
            .send(session: f.session, text: " "),
            .send(session: f.session, text: String(repeating: "x", count: 16_385)),
            .respondClarification(clarification: f.clarification, answer: " "),
            .respondClarification(clarification: f.clarification, answer: String(repeating: "x", count: 16_385)),
            .sendBot(bot: f.bot, text: " "),
            .sendBot(bot: f.bot, text: String(repeating: "x", count: 16_385)),
        ]
        for value in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchMutationOperation.self, from: JSONEncoder().encode(value))
            }
        }
    }
}
