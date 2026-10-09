import Foundation
import Testing
import WatchShared

@Suite struct TransportEnvelopeTests {
    private struct Fixtures {
        let scope: ServerScope
        let otherScope: ServerScope
        let session: SessionKey
        let run: RunKey
        let context: CommandContext
        let created: Date
        let expires: Date
    }

    private func fixtures() throws -> Fixtures {
        let epoch = InstallationEpoch(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)
        let scope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!), generation: try Generation(3))
        let otherScope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!), generation: try Generation(3))
        let session = try SessionKey(scope: scope, sessionID: "session")
        let created = Date().addingTimeInterval(60)
        let expires = created.addingTimeInterval(120)
        return Fixtures(
            scope: scope,
            otherScope: otherScope,
            session: session,
            run: try RunKey(session: session, streamID: "run"),
            context: try CommandContext(stableCommandID: CommandID(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!), scope: scope, expectedRevision: Revision(12), createdAt: created, expiresAt: expires),
            created: created,
            expires: expires
        )
    }

    private func mutate(_ value: some Encodable, key: String, to replacement: Any) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func semanticCoverage_WatchRequestEnvelope() throws {
        let f = try fixtures()
        let read = try WatchRequestEnvelope.read(
            requestID: UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
            scope: f.scope,
            operation: .diagnostics(scope: f.scope),
            createdAt: f.created,
            expiresAt: f.expires
        )
        let stream = try WatchRequestEnvelope.stream(
            requestID: UUID(uuidString: "30000000-0000-0000-0000-000000000006")!,
            scope: f.scope,
            operation: .run(f.run, afterEventID: "event"),
            createdAt: f.created,
            expiresAt: f.expires
        )
        #expect(read.operationKind == .diagnostics)
        #expect(stream.operationKind == .runStream)
        for value in [read, stream] {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WatchRequestEnvelope.self, from: encoded)
            #expect(decoded == value)
        }

        let invalid: [WatchRequestEnvelope] = [
            .read(schemaVersion: 2, requestID: UUID(), scope: f.scope, operationKind: .diagnostics, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.expires),
            .read(schemaVersion: 1, requestID: UUID(), scope: f.otherScope, operationKind: .diagnostics, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.expires),
            .read(schemaVersion: 1, requestID: UUID(), scope: f.scope, operationKind: .sessions, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.expires),
            .read(schemaVersion: 1, requestID: UUID(), scope: f.scope, operationKind: .diagnostics, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.created),
            .stream(schemaVersion: 1, requestID: UUID(), scope: f.scope, operationKind: .botStream, operation: .run(f.run, afterEventID: nil), createdAt: f.created, expiresAt: f.expires),
        ]
        for value in invalid {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchRequestEnvelope.self, from: JSONEncoder().encode(value))
            }
        }

        let expired = WatchRequestEnvelope.read(schemaVersion: 1, requestID: UUID(), scope: f.scope, operationKind: .diagnostics, operation: .diagnostics(scope: f.scope), createdAt: Date().addingTimeInterval(-120), expiresAt: Date().addingTimeInterval(-60))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchRequestEnvelope.self, from: JSONEncoder().encode(expired))
        }
    }

    @Test func semanticCoverage_WatchMutationRequest() throws {
        let f = try fixtures()
        let value = try WatchMutationRequest(
            requestID: UUID(uuidString: "30000000-0000-0000-0000-000000000007")!,
            context: f.context,
            operation: .send(session: f.session, text: "hello"),
            createdAt: f.created,
            expiresAt: f.expires
        )
        #expect(value.schemaVersion == 1)
        #expect(value.context == f.context)
        #expect(value.operationKind == .send)
        #expect(value.operation.scope == f.scope)
        #expect(value.createdAt == f.context.createdAt)
        #expect(value.expiresAt == f.context.expiresAt)

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WatchMutationRequest.self, from: encoded)
        #expect(decoded == value)

        #expect(throws: EnvelopeValidationError.contextMismatch) {
            try WatchMutationRequest(requestID: UUID(), context: f.context, operation: .send(session: f.session, text: "hello"), createdAt: f.created, expiresAt: f.expires.addingTimeInterval(1))
        }
        let otherSession = try SessionKey(scope: f.otherScope, sessionID: "other")
        #expect(throws: EnvelopeValidationError.scopeMismatch) {
            try WatchMutationRequest(requestID: UUID(), context: f.context, operation: .send(session: otherSession, text: "hello"), createdAt: f.created, expiresAt: f.expires)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchMutationRequest.self, from: mutate(value, key: "schemaVersion", to: 2))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchMutationRequest.self, from: mutate(value, key: "operationKind", to: "stop"))
        }

        let oldCreated = Date().addingTimeInterval(-120)
        let oldContext = try CommandContext(stableCommandID: CommandID(rawValue: UUID()), scope: f.scope, expectedRevision: Revision(1), createdAt: oldCreated, expiresAt: oldCreated.addingTimeInterval(30))
        let expired = try WatchMutationRequest(requestID: UUID(), context: oldContext, operation: .send(session: f.session, text: "hello"), createdAt: oldContext.createdAt, expiresAt: oldContext.expiresAt)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchMutationRequest.self, from: JSONEncoder().encode(expired))
        }

        let oversized = try WatchMutationRequest(requestID: UUID(), context: f.context, operation: .send(session: f.session, text: String(repeating: "x", count: 16_000)), createdAt: f.created, expiresAt: f.expires)
        #expect(throws: (any Error).self) {
            try WatchMutationRequest.decodeLive(JSONEncoder().encode(oversized))
        }
    }

    @Test func mutationRequestInitializerRejectsInvalidDirectOperation() throws {
        let f = try fixtures()
        let invalidOperation = WatchMutationOperation.send(session: f.session, text: " ")

        #expect(throws: (any Error).self) {
            try WatchMutationRequest(
                requestID: UUID(),
                context: f.context,
                operation: invalidOperation,
                createdAt: f.created,
                expiresAt: f.expires
            )
        }
    }

    @Test func responseInitializerRejectsInvalidNestedResultScope() throws {
        let f = try fixtures()
        let freshness = try Freshness(observedAt: f.created, expiresAt: f.expires, source: .phoneProjection)
        let foreignDiagnostics = try WatchDiagnosticsProjection(
            scope: f.otherScope,
            source: .phoneBroker,
            observedAt: f.created,
            expiresAt: f.expires,
            codes: [.timeout]
        )
        let invalidResult = WatchOperationResult.diagnostics(
            try ScopedSnapshot(
                schema: 1,
                scope: f.scope,
                revision: Revision(13),
                freshness: freshness,
                value: foreignDiagnostics
            )
        )

        #expect(throws: EnvelopeValidationError.scopeMismatch) {
            try WatchResponseEnvelope(
                requestID: UUID(),
                scope: f.scope,
                requestOperationKind: .diagnostics,
                requestCreatedAt: f.created,
                requestExpiresAt: f.expires,
                commandContext: nil,
                result: invalidResult
            )
        }
    }

    @Test func publicResponseRoutesRejectTranscriptImageForDifferentSameScopeSession() throws {
        let f = try fixtures()
        let foreignSession = try SessionKey(scope: f.scope, sessionID: "foreign-session")
        let descriptor = try WatchMediaDescriptor(
            scope: f.scope,
            session: foreignSession,
            origin: OriginBinding(digest: "sha256:foreign-transcript-image"),
            handle: MediaHandle("foreign-transcript-image"),
            mimeType: "image/png",
            byteSize: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            observedAt: f.created,
            expiresAt: f.expires
        )
        let validTranscript = try WatchTranscript(session: f.session, blocks: [], nextBefore: nil, isTruncated: false)
        var transcriptObject = try object(validTranscript)
        transcriptObject["blocks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([WatchTranscriptBlock.image(id: "image", descriptor: descriptor, alt: nil)]))
        let freshness = try Freshness(observedAt: f.created, expiresAt: f.expires, source: .phoneProjection)
        let snapshot = try ScopedSnapshot(schema: 1, scope: f.scope, revision: Revision(13), freshness: freshness, value: validTranscript)
        let result = WatchOperationResult.transcript(snapshot)
        let requestID = UUID(uuidString: "30000000-0000-0000-0000-000000000013")!
        let request = try WatchRequestEnvelope.read(
            requestID: requestID,
            scope: f.scope,
            operation: .transcript(session: f.session, before: nil, limit: 10),
            createdAt: f.created,
            expiresAt: f.expires
        )
        let validResponse = try WatchResponseEnvelope(
            requestID: requestID,
            scope: f.scope,
            requestOperationKind: .transcript,
            requestCreatedAt: f.created,
            requestExpiresAt: f.expires,
            commandContext: nil,
            result: result
        )
        var responseObject = try object(validResponse)
        var resultObject = try #require(responseObject["result"] as? [String: Any])
        var transcriptCase = try #require(resultObject["transcript"] as? [String: Any])
        var transcriptSnapshot = try #require(transcriptCase["_0"] as? [String: Any])
        transcriptSnapshot["value"] = transcriptObject
        transcriptCase["_0"] = transcriptSnapshot
        resultObject["transcript"] = transcriptCase
        responseObject["result"] = resultObject
        let malformedResponse = try data(responseObject)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: malformedResponse)
        }

        #expect(throws: (any Error).self) {
            try WatchResponseEnvelope.decodeLive(malformedResponse).validate(against: request, receivedAt: f.created)
        }
    }

    @Test func semanticCoverage_WatchResponseEnvelope() throws {
        let f = try fixtures()
        let freshness = try Freshness(observedAt: f.created, expiresAt: f.expires, source: .phoneProjection)
        let diagnostics = try WatchDiagnosticsProjection(scope: f.scope, source: .phoneBroker, observedAt: f.created, expiresAt: f.expires, codes: [.timeout])
        let snapshot = try ScopedSnapshot(schema: 1, scope: f.scope, revision: Revision(13), freshness: freshness, value: diagnostics)
        let requestID = UUID(uuidString: "30000000-0000-0000-0000-000000000008")!
        let request = try WatchRequestEnvelope.read(requestID: requestID, scope: f.scope, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.expires)
        let response = try WatchResponseEnvelope(requestID: requestID, scope: f.scope, requestOperationKind: .diagnostics, requestCreatedAt: f.created, requestExpiresAt: f.expires, commandContext: nil, result: .diagnostics(snapshot))
        #expect(response.schemaVersion == 1)
        #expect(response.result.kind == .diagnostics)
        #expect(response.result.scope == f.scope)

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WatchResponseEnvelope.self, from: encoded)
        #expect(decoded == response)
        try response.validate(against: request, receivedAt: f.created)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: mutate(response, key: "schemaVersion", to: 2))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: mutate(response, key: "requestOperationKind", to: "sessions"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: mutate(response, key: "scope", to: JSONSerialization.jsonObject(with: JSONEncoder().encode(f.otherScope))))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: mutate(response, key: "commandContext", to: JSONSerialization.jsonObject(with: JSONEncoder().encode(f.context))))
        }

        let wrongRequest = try WatchRequestEnvelope.read(requestID: UUID(), scope: f.scope, operation: .diagnostics(scope: f.scope), createdAt: f.created, expiresAt: f.expires)
        #expect(throws: (any Error).self) { try response.validate(against: wrongRequest, receivedAt: f.created) }
        #expect(throws: (any Error).self) { try response.validate(against: request, receivedAt: f.expires.addingTimeInterval(1)) }

        let mutationRequest = try WatchMutationRequest(requestID: requestID, context: f.context, operation: .send(session: f.session, text: "hello"), createdAt: f.created, expiresAt: f.expires)
        let mutationReceipt = try MutationReceipt(context: f.context, operationKind: .send, phase: .acknowledged, updatedAt: f.created, nonSecretResultID: "run")
        let mutationResponse = try WatchResponseEnvelope(requestID: requestID, scope: f.scope, requestOperationKind: .send, requestCreatedAt: f.created, requestExpiresAt: f.expires, commandContext: f.context, result: .startedRun(CommandReceipt(receipt: mutationReceipt, value: f.run)))
        let mutationEncoded = try JSONEncoder().encode(mutationResponse)
        #expect(try JSONDecoder().decode(WatchResponseEnvelope.self, from: mutationEncoded) == mutationResponse)
        try mutationResponse.validate(against: mutationRequest, receivedAt: f.created)

        var expiredObject = try object(response)
        expiredObject["requestCreatedAt"] = Date().addingTimeInterval(-120).timeIntervalSinceReferenceDate
        expiredObject["requestExpiresAt"] = Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate
        #expect(throws: EnvelopeValidationError.expired) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: data(expiredObject))
        }

        let wrongContext = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: f.scope,
            expectedRevision: f.context.expectedRevision,
            createdAt: f.created,
            expiresAt: f.expires
        )
        let tamperedMutationResponses: [Data] = try [
            mutate(mutationResponse, key: "requestID", to: UUID().uuidString),
            mutate(mutationResponse, key: "scope", to: JSONSerialization.jsonObject(with: JSONEncoder().encode(f.otherScope))),
            mutate(mutationResponse, key: "requestOperationKind", to: "stop"),
            mutate(mutationResponse, key: "requestCreatedAt", to: f.created.addingTimeInterval(1).timeIntervalSinceReferenceDate),
            mutate(mutationResponse, key: "requestExpiresAt", to: f.expires.addingTimeInterval(1).timeIntervalSinceReferenceDate),
            mutate(mutationResponse, key: "commandContext", to: JSONSerialization.jsonObject(with: JSONEncoder().encode(wrongContext))),
        ]
        for tampered in tamperedMutationResponses {
            #expect(throws: (any Error).self) {
                let decodedTampered = try JSONDecoder().decode(WatchResponseEnvelope.self, from: tampered)
                try decodedTampered.validate(against: mutationRequest, receivedAt: f.created)
            }
        }

        var receiptObject = try object(mutationResponse)
        var resultObject = try #require(receiptObject["result"] as? [String: Any])
        var startedRun = try #require(resultObject["startedRun"] as? [String: Any])
        var wrappedReceipt = try #require(startedRun["_0"] as? [String: Any])
        var receipt = try #require(wrappedReceipt["receipt"] as? [String: Any])
        receipt["operationKind"] = "stop"
        wrappedReceipt["receipt"] = receipt
        startedRun["_0"] = wrappedReceipt
        resultObject["startedRun"] = startedRun
        receiptObject["result"] = resultObject
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: data(receiptObject))
        }

        var resultFamilyObject = try object(mutationResponse)
        resultFamilyObject["result"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchOperationResult.mutation(CommandReceipt(receipt: mutationReceipt, value: EmptyValue()))))
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchResponseEnvelope.self, from: data(resultFamilyObject))
        }

        var oversized = encoded
        oversized.append(Data(repeating: 0x20, count: 262_145))
        #expect(throws: (any Error).self) { try WatchResponseEnvelope.decodeLive(oversized) }
    }

    @Test func responseValidationCorrelatesEveryRepresentedReadAndStreamIdentity() throws {
        struct ReadCase {
            let name: String
            let operation: WatchReadOperation
            let valid: WatchOperationResult
            let invalid: [WatchOperationResult]
        }
        struct StreamCase {
            let name: String
            let operation: WatchStreamOperation
            let valid: WatchOperationResult
            let invalid: WatchOperationResult
        }

        let f = try fixtures()
        let requestID = UUID(uuidString: "30000000-0000-0000-0000-000000000009")!
        let otherSession = try SessionKey(scope: f.scope, sessionID: "other-session")
        let otherRun = try RunKey(session: f.session, streamID: "other-run")
        let task = try TaskKey(scope: f.scope, jobID: "task")
        let otherTask = try TaskKey(scope: f.scope, jobID: "other-task")
        let skill = try SkillKey(scope: f.scope, name: "skill")
        let otherSkill = try SkillKey(scope: f.scope, name: "other-skill")
        let path = try PathHandle("path")
        let otherPath = try PathHandle("other-path")
        let memory = try MemoryKey(scope: f.scope, remoteID: "memory")
        let bot = try BotKey(scope: f.scope, connectionID: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!, profile: "bot")
        let otherBot = try BotKey(scope: f.scope, connectionID: UUID(uuidString: "30000000-0000-0000-0000-000000000011")!, profile: "bot")
        let freshness = try Freshness(observedAt: f.created, expiresAt: f.expires, source: .phoneProjection)

        func snapshot<Value: Codable & Sendable>(_ value: Value) throws -> ScopedSnapshot<Value> {
            try ScopedSnapshot(schema: 1, scope: f.scope, revision: Revision(13), freshness: freshness, value: value)
        }
        func descriptor(session: SessionKey, handle: String) throws -> WatchMediaDescriptor {
            try WatchMediaDescriptor(scope: f.scope, session: session, origin: OriginBinding(digest: "origin"), handle: MediaHandle(handle), mimeType: "image/png", byteSize: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", observedAt: f.created, expiresAt: f.expires)
        }
        func validate(_ result: WatchOperationResult, against operation: WatchReadOperation) throws {
            let request = try WatchRequestEnvelope.read(requestID: requestID, scope: f.scope, operation: operation, createdAt: f.created, expiresAt: f.expires)
            let response = try WatchResponseEnvelope(requestID: requestID, scope: f.scope, requestOperationKind: operation.kind, requestCreatedAt: f.created, requestExpiresAt: f.expires, commandContext: nil, result: result)
            try response.validate(against: request, receivedAt: f.created)
        }
        func validate(_ result: WatchOperationResult, against operation: WatchStreamOperation) throws {
            let request = try WatchRequestEnvelope.stream(requestID: requestID, scope: f.scope, operation: operation, createdAt: f.created, expiresAt: f.expires)
            let response = try WatchResponseEnvelope(requestID: requestID, scope: f.scope, requestOperationKind: operation.kind, requestCreatedAt: f.created, requestExpiresAt: f.expires, commandContext: nil, result: result)
            try response.validate(against: request, receivedAt: f.created)
        }

        let composer = try WatchComposerOptions(scope: f.scope, profiles: [], workspaces: [], defaultProfileID: nil, defaultWorkspaceHandle: nil)
        let transcript = try WatchTranscript(session: f.session, blocks: [], nextBefore: nil, isTruncated: false)
        let otherTranscript = try WatchTranscript(session: otherSession, blocks: [], nextBefore: nil, isTruncated: false)
        let runState = try WatchRunState(key: f.run, phase: .thinking, lastEventID: nil, lastSequence: nil, isTerminal: false, summary: nil)
        let otherRunState = try WatchRunState(key: otherRun, phase: .thinking, lastEventID: nil, lastSequence: nil, isTerminal: false, summary: nil)
        let approval = try WatchApproval(key: ApprovalKey(session: f.session, remoteID: "approval"), title: "Approve", detail: nil, choices: [.once], requestedAt: nil)
        let otherApproval = try WatchApproval(key: ApprovalKey(session: otherSession, remoteID: "approval"), title: "Approve", detail: nil, choices: [.once], requestedAt: nil)
        let clarification = try WatchClarification(key: ClarificationKey(session: f.session, remoteID: "clarification"), question: "Question?", choices: [], requestedAt: nil)
        let otherClarification = try WatchClarification(key: ClarificationKey(session: otherSession, remoteID: "clarification"), question: "Question?", choices: [], requestedAt: nil)
        let taskSummary = try WatchTaskSummary(key: task, name: "Task", schedule: "daily", enabled: true, running: false, lastResult: nil)
        let taskRun = try WatchTaskRun(task: task, runID: "task-run", startedAt: nil, finishedAt: nil, status: "running", output: nil, isTruncated: false)
        let otherTaskRun = try WatchTaskRun(task: otherTask, runID: "task-run", startedAt: nil, finishedAt: nil, status: "running", output: nil, isTruncated: false)
        let otherIDTaskRun = try WatchTaskRun(task: task, runID: "other-task-run", startedAt: nil, finishedAt: nil, status: "running", output: nil, isTruncated: false)
        let skillSummary = try WatchSkillSummary(key: skill, summary: "summary", enabled: true)
        let skillDetail = try WatchSkillDetail(key: skill, summary: "summary", linkedFiles: BoundedCollection(items: [], isTruncated: false))
        let otherSkillDetail = try WatchSkillDetail(key: otherSkill, summary: "summary", linkedFiles: BoundedCollection(items: [], isTruncated: false))
        let skillContent = try WatchSkillContent(key: skill, fileHandle: path, content: "content", isTruncated: false)
        let wrongSkillContent = try WatchSkillContent(key: otherSkill, fileHandle: path, content: "content", isTruncated: false)
        let wrongFileContent = try WatchSkillContent(key: skill, fileHandle: otherPath, content: "content", isTruncated: false)
        let memoryDocument = try WatchMemoryDocument(sections: [WatchMemorySection(key: memory, section: "memory", redactedContent: "content", isTruncated: false)])
        let insights = try WatchInsightsAggregate(days: InsightsDays(7), totalSessions: 0, totalMessages: 0, totalInputTokens: 0, totalOutputTokens: 0, totalTokens: 0, totalCost: 0, models: BoundedCollection(items: [], isTruncated: false), dailyTokens: BoundedCollection(items: [], isTruncated: false), activityByDay: BoundedCollection(items: [], isTruncated: false), activityByHour: BoundedCollection(items: [], isTruncated: false))
        let workspace = try WatchWorkspaceEntry(session: f.session, pathHandle: path, name: "file", kind: .text, byteSize: nil)
        let otherWorkspace = try WatchWorkspaceEntry(session: otherSession, pathHandle: path, name: "file", kind: .text, byteSize: nil)
        let git = try WatchGitAggregate(session: f.session, branch: nil, isRepository: false, dirty: false, modifiedCount: 0, untrackedCount: 0, ahead: 0, behind: 0)
        let otherGit = try WatchGitAggregate(session: otherSession, branch: nil, isRepository: false, dirty: false, modifiedCount: 0, untrackedCount: 0, ahead: 0, behind: 0)
        let diagnostics = try WatchDiagnosticsProjection(scope: f.scope, source: .phoneBroker, observedAt: f.created, expiresAt: f.expires, codes: [])
        let media = try descriptor(session: f.session, handle: "media")
        let otherMedia = try descriptor(session: f.session, handle: "other-media")
        let otherSessionMedia = try descriptor(session: otherSession, handle: "media")
        let botSummary = try WatchBotSummary(key: bot, title: "Bot", phase: nil)
        let botConversation = try WatchBotConversation(key: bot, blocks: [], replayEpoch: "epoch", lastSequence: nil, phase: nil, history: .complete)
        let otherBotConversation = try WatchBotConversation(key: otherBot, blocks: [], replayEpoch: "epoch", lastSequence: nil, phase: nil, history: .complete)

        let readCases: [ReadCase] = [
            .init(name: "sessions", operation: .sessions(scope: f.scope, collection: .current, query: nil, localLimit: 10), valid: .sessions(try snapshot(BoundedCollection(items: [], isTruncated: false))), invalid: []),
            .init(name: "composerOptions", operation: .composerOptions(scope: f.scope), valid: .composerOptions(try snapshot(composer)), invalid: []),
            .init(name: "transcript", operation: .transcript(session: f.session, before: nil, limit: 10), valid: .transcript(try snapshot(transcript)), invalid: [.transcript(try snapshot(otherTranscript))]),
            .init(name: "runState", operation: .runState(run: f.run), valid: .runState(try snapshot(runState)), invalid: [.runState(try snapshot(otherRunState))]),
            .init(name: "pendingApprovalHead", operation: .pendingApprovalHead(session: f.session), valid: .pendingApprovalHead(try snapshot(WatchAttentionHead(item: approval, reportedPendingCount: 1))), invalid: [.pendingApprovalHead(try snapshot(WatchAttentionHead(item: otherApproval, reportedPendingCount: 1)))]),
            .init(name: "pendingClarificationHead", operation: .pendingClarificationHead(session: f.session), valid: .pendingClarificationHead(try snapshot(WatchAttentionHead(item: clarification, reportedPendingCount: 1))), invalid: [.pendingClarificationHead(try snapshot(WatchAttentionHead(item: otherClarification, reportedPendingCount: 1)))]),
            .init(name: "tasks", operation: .tasks(scope: f.scope, localLimit: 10), valid: .tasks(try snapshot(BoundedCollection(items: [taskSummary], isTruncated: false))), invalid: []),
            .init(name: "taskRuns", operation: .taskRuns(task: task, page: try PageRequest(continuation: nil, limit: 10)), valid: .taskRuns(try snapshot(BoundedPage(items: [taskRun], continuation: nil, isTruncated: false))), invalid: [.taskRuns(try snapshot(BoundedPage(items: [otherTaskRun], continuation: nil, isTruncated: false)))]),
            .init(name: "taskRunDetail", operation: .taskRunDetail(task: task, runID: "task-run"), valid: .taskRunDetail(try snapshot(WatchTaskRunDetail(run: taskRun, output: nil, outputTruncated: false))), invalid: [.taskRunDetail(try snapshot(WatchTaskRunDetail(run: otherTaskRun, output: nil, outputTruncated: false))), .taskRunDetail(try snapshot(WatchTaskRunDetail(run: otherIDTaskRun, output: nil, outputTruncated: false)))]),
            .init(name: "skills", operation: .skills(scope: f.scope, query: nil, localLimit: 10), valid: .skills(try snapshot(BoundedCollection(items: [skillSummary], isTruncated: false))), invalid: []),
            .init(name: "skillDetail", operation: .skillDetail(skill: skill), valid: .skillDetail(try snapshot(skillDetail)), invalid: [.skillDetail(try snapshot(otherSkillDetail))]),
            .init(name: "skillContent", operation: .skillContent(skill: skill, fileHandle: path), valid: .skillContent(try snapshot(skillContent)), invalid: [.skillContent(try snapshot(wrongSkillContent)), .skillContent(try snapshot(wrongFileContent))]),
            .init(name: "memoryDocument", operation: .memoryDocument(scope: f.scope), valid: .memoryDocument(try snapshot(memoryDocument)), invalid: []),
            .init(name: "insightsAggregate", operation: .insightsAggregate(scope: f.scope, days: try InsightsDays(30)), valid: .insightsAggregate(try snapshot(insights)), invalid: []),
            .init(name: "workspace", operation: .workspace(session: f.session, parentPathHandle: nil), valid: .workspace(try snapshot(BoundedCollection(items: [workspace], isTruncated: false))), invalid: [.workspace(try snapshot(BoundedCollection(items: [otherWorkspace], isTruncated: false)))]),
            .init(name: "filePreview", operation: .filePreview(session: f.session, pathHandle: path), valid: .filePreview(try snapshot(WatchFilePreview.image(pathHandle: path, media: media))), invalid: [.filePreview(try snapshot(WatchFilePreview.image(pathHandle: otherPath, media: media))), .filePreview(try snapshot(WatchFilePreview.image(pathHandle: path, media: otherSessionMedia)))]),
            .init(name: "gitAggregate", operation: .gitAggregate(session: f.session), valid: .gitAggregate(try snapshot(git)), invalid: [.gitAggregate(try snapshot(otherGit))]),
            .init(name: "diagnostics", operation: .diagnostics(scope: f.scope), valid: .diagnostics(try snapshot(diagnostics)), invalid: []),
            .init(name: "media", operation: .media(media), valid: .media(try WatchMediaPayload(descriptor: media, bytes: Data())), invalid: [.media(try WatchMediaPayload(descriptor: otherMedia, bytes: Data()))]),
            .init(name: "bots", operation: .bots(scope: f.scope), valid: .bots(try snapshot([botSummary])), invalid: []),
            .init(name: "botConversation", operation: .botConversation(bot: bot), valid: .botConversation(try snapshot(botConversation)), invalid: [.botConversation(try snapshot(otherBotConversation))]),
        ]

        for row in readCases {
            try validate(row.valid, against: row.operation)
            for invalid in row.invalid {
                #expect(throws: EnvelopeValidationError.resultMismatch, "expected rejection for \(row.name)") {
                    try validate(invalid, against: row.operation)
                }
            }
            try validate(.failure(.rejected(status: 409, sanitizedCode: "rejected")), against: row.operation)
        }

        let runEvent = try WatchRunEvent(key: f.run, eventID: "event", sequence: 1, phase: .responding, textDelta: nil, terminal: false)
        let otherRunEvent = try WatchRunEvent(key: otherRun, eventID: "event", sequence: 1, phase: .responding, textDelta: nil, terminal: false)
        let botEvent = try WatchBotEvent(key: bot, replayEpoch: "epoch", runtimeSessionID: "runtime", sequence: 1, activity: .messageStart)
        let otherBotEvent = try WatchBotEvent(key: otherBot, replayEpoch: "epoch", runtimeSessionID: "runtime", sequence: 1, activity: .messageStart)
        let streamCases: [StreamCase] = [
            .init(name: "run", operation: .run(f.run, afterEventID: nil), valid: .runEvent(runEvent), invalid: .runEvent(otherRunEvent)),
            .init(name: "bot", operation: .bot(bot, replayEpoch: nil, afterSequence: nil), valid: .botEvent(botEvent), invalid: .botEvent(otherBotEvent)),
        ]
        for row in streamCases {
            try validate(row.valid, against: row.operation)
            #expect(throws: EnvelopeValidationError.resultMismatch, "expected rejection for \(row.name)") {
                try validate(row.invalid, against: row.operation)
            }
        }
    }

    @Test func responseValidationCorrelatesRepresentedMutationIdentity() throws {
        let f = try fixtures()
        let requestID = UUID(uuidString: "30000000-0000-0000-0000-000000000012")!
        let otherSession = try SessionKey(scope: f.scope, sessionID: "other-session")
        let otherRun = try RunKey(session: otherSession, streamID: "run")

        func receipt(_ kind: WatchOperationKind) throws -> MutationReceipt {
            try MutationReceipt(context: f.context, operationKind: kind, phase: .acknowledged, updatedAt: f.created, nonSecretResultID: "result")
        }
        func validate(_ result: WatchOperationResult, against operation: WatchMutationOperation) throws {
            let request = try WatchMutationRequest(requestID: requestID, context: f.context, operation: operation, createdAt: f.created, expiresAt: f.expires)
            let response = try WatchResponseEnvelope(requestID: requestID, scope: f.scope, requestOperationKind: operation.kind, requestCreatedAt: f.created, requestExpiresAt: f.expires, commandContext: f.context, result: result)
            try response.validate(against: request, receivedAt: f.created)
        }

        try validate(.createdSession(CommandReceipt(receipt: receipt(.createSession), value: f.session)), against: .createSession(scope: f.scope, profileID: nil, workspaceHandle: nil))
        try validate(.startedRun(CommandReceipt(receipt: receipt(.send), value: f.run)), against: .send(session: f.session, text: "hello"))

        #expect(throws: EnvelopeValidationError.resultMismatch) {
            try validate(.startedRun(CommandReceipt(receipt: receipt(.send), value: otherRun)), against: .send(session: f.session, text: "hello"))
        }

        for operation in [
            WatchMutationOperation.stop(run: f.run),
            .controlTask(task: try TaskKey(scope: f.scope, jobID: "task"), action: .run),
            .sendBot(bot: try BotKey(scope: f.scope, connectionID: UUID(), profile: "bot"), text: "hello"),
            .interruptBot(bot: try BotKey(scope: f.scope, connectionID: UUID(), profile: "bot")),
        ] {
            try validate(.mutation(CommandReceipt(receipt: receipt(operation.kind), value: EmptyValue())), against: operation)
        }
    }
}
