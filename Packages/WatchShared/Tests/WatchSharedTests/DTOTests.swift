import Foundation
import Testing
@testable import WatchShared

@Suite struct DTOTests {
    private func scope() throws -> ServerScope { ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1)) }

    @Test func approvalChoicePreservesIterableCodableWireContract() throws {
        func requireCaseIterable<T: CaseIterable>(_: T.Type) {}
        requireCaseIterable(ApprovalChoice.self)

        let choices = ApprovalChoice.allCases
        #expect(choices.map(\.rawValue) == ["once", "session", "always", "deny"])
        #expect(try JSONDecoder().decode([ApprovalChoice].self, from: JSONEncoder().encode(choices)) == choices)
    }

    @Test func boundedContainersAndPageRequestsValidateAtInitAndDecode() throws {
        #expect(throws: (any Error).self) { try PageRequest(continuation: nil, limit: 0) }
        let page = try BoundedPage(items: [1, 2], continuation: "next", isTruncated: true, maximumItems: 2)
        #expect(try JSONDecoder().decode(BoundedPage<Int>.self, from: JSONEncoder().encode(page)) == page)
        #expect(throws: (any Error).self) { try BoundedCollection(items: [1, 2], isTruncated: false, maximumItems: 1) }
    }

    @Test func insightsDaysAndTextPayloadsRejectInvalidBounds() throws {
        #expect(try InsightsDays(365).value == 365)
        #expect(throws: (any Error).self) { try InsightsDays(0) }
        let scope = try scope(); let session = try SessionKey(scope: scope, sessionID: "s")
        #expect(throws: (any Error).self) { try WatchTranscript(session: session, blocks: [.text(id: "id", role: .user, text: String(repeating: "x", count: 16_385))], nextBefore: nil, isTruncated: false) }
    }

    @Test func attentionAndBotContractsPreserveRealRequestIdentity() throws {
        let projection = try WatchBotApprovalProjection(requestID: "request-1", choices: nil, redactedCommand: nil, toolName: nil, displaySummary: nil)
        #expect(projection.requestID == "request-1")
        #expect(throws: (any Error).self) { try WatchBotApprovalProjection(requestID: " ", choices: nil, redactedCommand: nil, toolName: nil, displaySummary: nil) }
        let clarification = try WatchBotClarificationProjection(requestID: "request-2", form: .open, displaySummary: nil)
        #expect(try JSONDecoder().decode(WatchBotClarificationProjection.self, from: JSONEncoder().encode(clarification)) == clarification)
    }

    private func replacing<T: Encodable>(_ value: T, _ key: String, with replacement: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func mediaDescriptorMalformedEncodedFixtureReentersValidation() throws {
        let scope = try scope(); let session = try SessionKey(scope: scope, sessionID: "s")
        let observed = Date(timeIntervalSinceReferenceDate: 100), expires = Date(timeIntervalSinceReferenceDate: 200)
        let descriptor = try WatchMediaDescriptor(scope: scope, session: session, origin: OriginBinding(digest: "sha256:origin"), handle: MediaHandle("m"), mimeType: "image/png", byteSize: 4, sha256: "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a", observedAt: observed, expiresAt: expires)
        #expect(try WatchMediaPayload(descriptor: descriptor, bytes: Data([1,2,3,4])).bytes.count == 4)
        #expect(throws: (any Error).self) { try WatchMediaPayload(descriptor: descriptor, bytes: Data([1])) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchMediaDescriptor.self, from: replacing(descriptor, "byteSize", with: 1_048_577)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchMediaDescriptor.self, from: replacing(descriptor, "sha256", with: "bad")) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchMediaDescriptor.self, from: replacing(descriptor, "expiresAt", with: observed.timeIntervalSinceReferenceDate)) }
    }

    @Test func alertProjectionMalformedEncodedFixtureReentersValidation() throws {
        let alertScope = try scope(), now = Date(timeIntervalSinceReferenceDate: 100)
        let alert = try WatchAlertProjection(scope: alertScope, alertID: UUID(), kind: .serverDisconnected, dedupeKey: "dedupe", source: .brokerSnapshot, observedAt: now, expiresAt: now.addingTimeInterval(60), route: .diagnostics(alertScope), genericTitleCode: "title", genericBodyCode: "body")
        #expect(try JSONDecoder().decode(WatchAlertProjection.self, from: JSONEncoder().encode(alert)) == alert)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchAlertProjection.self, from: replacing(alert, "dedupeKey", with: " ")) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchAlertProjection.self, from: replacing(alert, "expiresAt", with: now.timeIntervalSinceReferenceDate)) }
        let other = try scope()
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchAlertProjection.self, from: replacing(alert, "route", with: try JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchAlertRoute.diagnostics(other))))) }
    }

    @Test func transcriptBlockDirectDecodeRejectsMalformedAssociatedValues() throws {
        let scope=try scope(),session=try SessionKey(scope:scope,sessionID:"s"),descriptor=try WatchMediaDescriptor(scope:scope,session:session,origin:OriginBinding(digest:"o"),handle:MediaHandle("m"),mimeType:"image/png",byteSize:0,sha256:String(repeating:"a",count:64),observedAt:Date(timeIntervalSinceReferenceDate:1),expiresAt:Date(timeIntervalSinceReferenceDate:2))
        let invalid:[WatchTranscriptBlock]=[.text(id:" ",role:.user,text:"x"),.text(id:"i",role:.user,text:String(repeating:"x",count:16_385)),.code(id:"i",language:String(repeating:"x",count:257),text:"",isTruncated:false),.tool(id:"i",title:" ",state:"ok",summary:nil),.image(id:"i",descriptor:descriptor,alt:String(repeating:"x",count:1025)),.unsupported(id:"i",kind:" ",summary:"x")]
        for value in invalid{#expect(throws:(any Error).self){try JSONDecoder().decode(WatchTranscriptBlock.self,from:JSONEncoder().encode(value))}}
    }

    @Test func botActivityDirectDecodeRejectsMalformedValues() throws {
        let invalid:[WatchBotActivity]=[.sessionInfo(profileName:" ",model:nil,provider:nil),.status(kind:" ",text:nil),.messageDelta(delta:String(repeating:"x",count:16_385)),.toolStart(toolCallID:" ",name:"n",summary:nil),.toolComplete(toolCallID:"id",name:"n",summary:nil,status:nil,durationSeconds:-1),.todoUpdated(completed:-1,total:1,currentTask:nil),.todoUpdated(completed:2,total:1,currentTask:nil),.notification(notificationID:" ",level:"info",message:"m"),.sanitizedError(code:" ")]
        for value in invalid{#expect(throws:(any Error).self){try JSONDecoder().decode(WatchBotActivity.self,from:JSONEncoder().encode(value))}}
    }

    @Test func historyAndFilePreviewDirectDecodeRejectMalformedValues() throws {
        let path=try PathHandle("p")
        let invalidPreviews:[WatchFilePreview]=[.text(pathHandle:path,text:String(repeating:"x",count:262_145),isTruncated:false),.unsupported(pathHandle:path,kind:" "),.unsupported(pathHandle:path,kind:String(repeating:"x",count:257))]
        for value in invalidPreviews{#expect(throws:(any Error).self){try JSONDecoder().decode(WatchFilePreview.self,from:JSONEncoder().encode(value))}}
        for limit in [0,-1]{#expect(throws:(any Error).self){try JSONDecoder().decode(WatchBotHistoryAvailability.self,from:JSONEncoder().encode(WatchBotHistoryAvailability.unavailableOversize(limit:limit)))}}
    }

    @Test func allDTOFamiliesArePublicCodableSendableHashable() throws {
        func require<T: Codable & Sendable & Hashable>(_: T.Type) {}
        require(WatchServerDescriptor.self); require(WatchSessionSummary.self); require(WatchComposerOptions.self)
        require(WatchRunEvent.self); require(WatchApproval.self); require(WatchClarification.self); require(WatchTaskSummary.self)
        require(WatchSkillDetail.self); require(WatchMemoryDocument.self); require(WatchInsightsAggregate.self); require(WatchWorkspaceEntry.self)
        require(WatchGitAggregate.self); require(WatchBotConversation.self); require(WatchAlertProjection.self)
    }
}

@Suite struct DTOSemanticCoverageTests {
    private func scope() throws -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            server: ServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            generation: try Generation(3)
        )
    }

    private func session() throws -> SessionKey { try SessionKey(scope: scope(), sessionID: "session-semantic") }
    private func bot() throws -> BotKey { try BotKey(scope: scope(), connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, profile: "profile-semantic") }
    private func run() throws -> RunKey { try RunKey(session: session(), streamID: "stream-semantic") }
    private func task() throws -> TaskKey { try TaskKey(scope: scope(), jobID: "task-semantic") }
    private func approval() throws -> ApprovalKey { try ApprovalKey(session: session(), remoteID: "approval-semantic") }
    private func clarification() throws -> ClarificationKey { try ClarificationKey(session: session(), remoteID: "clarification-semantic") }
    private func skill() throws -> SkillKey { try SkillKey(scope: scope(), name: "skill-semantic") }
    private func memory() throws -> MemoryKey { try MemoryKey(scope: scope(), remoteID: "memory-semantic") }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoded = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: encoded)
    }

    private func replacing<T: Encodable>(_ value: T, _ key: String, with replacement: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func mediaDescriptor(bytes: Data = Data([1, 2, 3, 4]), sha256: String = "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a") throws -> WatchMediaDescriptor {
        try WatchMediaDescriptor(
            scope: scope(),
            session: session(),
            origin: OriginBinding(digest: "sha256:semantic-origin"),
            handle: MediaHandle("media-semantic"),
            mimeType: "image/png",
            byteSize: bytes.count,
            sha256: sha256,
            observedAt: Date(timeIntervalSinceReferenceDate: 100),
            expiresAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }

    @Test func semanticCoverage_AlertKind() throws {
        let values: [AlertKind] = [.approvalHead, .clarificationHead, .runTerminal, .taskFailure, .taskDue, .serverDisconnected]
        #expect(values.map(\.rawValue) == ["approvalHead", "clarificationHead", "runTerminal", "taskFailure", "taskDue", "serverDisconnected"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AlertKind.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_AlertSource() throws {
        let values: [AlertSource] = [.foregroundRefresh, .brokerSnapshot, .localSchedule]
        #expect(values.map(\.rawValue) == ["foregroundRefresh", "brokerSnapshot", "localSchedule"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AlertSource.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_ApprovalChoice() throws {
        let values: [ApprovalChoice] = [.once, .session, .always, .deny]
        #expect(values == ApprovalChoice.allCases)
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ApprovalChoice.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_BotPhoneDestination() throws {
        let values: [BotPhoneDestination] = [.conversation, .activity, .historyUnavailable]
        #expect(values.map(\.rawValue) == ["conversation", "activity", "historyUnavailable"])
        #expect(try values.map { try roundTrip($0) } == values)
        let route: WatchRouteTarget = .bot(try bot(), destination: .activity, requestID: "request-semantic")
        #expect(try roundTrip(route) == route)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BotPhoneDestination.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_BoundedCollection() throws {
        let value: BoundedCollection<String> = try BoundedCollection(items: ["alpha", "beta"], isTruncated: true, maximumItems: 2)
        let decoded: BoundedCollection<String> = try roundTrip(value)
        #expect(decoded.items == ["alpha", "beta"] && decoded.isTruncated)
        #expect(throws: (any Error).self) { try BoundedCollection(items: [1, 2], isTruncated: false, maximumItems: 1) }
    }

    @Test func semanticCoverage_BoundedPage() throws {
        let value: BoundedPage<Int> = try BoundedPage(items: [7, 11], continuation: "cursor", isTruncated: true, maximumItems: 2)
        let decoded: BoundedPage<Int> = try roundTrip(value)
        #expect(decoded.items == [7, 11] && decoded.continuation == "cursor" && decoded.isTruncated)
        #expect(throws: (any Error).self) { try BoundedPage(items: [1], continuation: nil, isTruncated: false, maximumItems: 0) }
    }

    @Test func semanticCoverage_DirectAccessState() throws {
        let values: [DirectAccessState] = [.notConfigured, .provisioning, .available, .revocationPending, .authRequired, .unavailable]
        #expect(values.map(\.rawValue) == ["notConfigured", "provisioning", "available", "revocationPending", "authRequired", "unavailable"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(DirectAccessState.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_GitDiffKind() throws {
        let values: [GitDiffKind] = [.workingTree, .staged]
        #expect(values.map(\.rawValue) == ["workingTree", "staged"])
        #expect(try values.map { try roundTrip($0) } == values)
        let route: WatchRouteTarget = .git(try session(), pathHandle: try PathHandle("src/App.swift"), diffKind: .staged, destination: .browse)
        #expect(try roundTrip(route) == route)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GitDiffKind.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_InsightsDays() throws {
        let value: InsightsDays = try InsightsDays(365)
        #expect(try roundTrip(value).value == 365)
        #expect(throws: (any Error).self) { try InsightsDays(0) }
    }

    @Test func semanticCoverage_PageRequest() throws {
        let value: PageRequest = try PageRequest(continuation: "cursor", limit: 50)
        let decoded: PageRequest = try roundTrip(value)
        #expect(decoded.continuation == "cursor" && decoded.limit == 50)
        #expect(throws: (any Error).self) { try PageRequest(continuation: nil, limit: 51) }
    }

    @Test func semanticCoverage_SessionCollection() throws {
        let values: [SessionCollection] = [.current, .archived]
        #expect(values.map(\.rawValue) == ["current", "archived"])
        #expect(try values.map { try roundTrip($0) } == values)
        let route: WatchRouteTarget = .sessions(collection: .current)
        #expect(try roundTrip(route) == route)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SessionCollection.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_TaskControl() throws {
        let values: [TaskControl] = [.run, .pause, .resume]
        #expect(values.map(\.rawValue) == ["run", "pause", "resume"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TaskControl.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_WatchAlertProjection() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let value: WatchAlertProjection = try WatchAlertProjection(scope: scope(), alertID: UUID(), kind: .serverDisconnected, dedupeKey: "dedupe-semantic", source: .brokerSnapshot, observedAt: now, expiresAt: now.addingTimeInterval(60), route: .diagnostics(scope()), genericTitleCode: "offline", genericBodyCode: "retry")
        let decoded: WatchAlertProjection = try roundTrip(value)
        #expect(decoded.kind == .serverDisconnected && decoded.source == .brokerSnapshot && decoded.dedupeKey == "dedupe-semantic")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchAlertProjection.self, from: replacing(value, "dedupeKey", with: " ")) }
    }

    @Test func semanticCoverage_WatchAlertRoute() throws {
        let value: WatchAlertRoute = .run(try run())
        let decoded: WatchAlertRoute = try roundTrip(value)
        guard case .run(let key) = decoded else { Issue.record("expected run alert route"); return }
        let expectedKey = try run()
        #expect(key == expectedKey)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WatchAlertRoute.self, from: Data(#"{"future":{}}"#.utf8)) }
    }

    @Test func semanticCoverage_WatchApproval() throws {
        let value: WatchApproval = try WatchApproval(key: approval(), title: "Deploy?", detail: "Production", choices: [.once, .deny], requestedAt: Date(timeIntervalSinceReferenceDate: 42))
        let decoded: WatchApproval = try roundTrip(value)
        #expect(decoded.title == "Deploy?" && decoded.choices == [.once, .deny])
        #expect(throws: (any Error).self) { try WatchApproval(key: approval(), title: "Deploy?", detail: nil, choices: [], requestedAt: nil) }
    }

    @Test func semanticCoverage_WatchAttentionHead() throws {
        let item = try WatchApproval(key: approval(), title: "Approve", detail: nil, choices: [.once], requestedAt: nil)
        let value: WatchAttentionHead<WatchApproval> = try WatchAttentionHead(item: item, reportedPendingCount: 2)
        let decoded: WatchAttentionHead<WatchApproval> = try roundTrip(value)
        #expect(decoded.item == item && decoded.reportedPendingCount == 2)
        #expect(throws: (any Error).self) { try WatchAttentionHead<WatchApproval>(item: item, reportedPendingCount: -1) }
    }

    @Test func semanticCoverage_WatchAuthMode() throws {
        let values: [WatchAuthMode] = [.none, .password, .trustedHeader, .oidc, .passkey, .unknown]
        #expect(values.map(\.rawValue) == ["none", "password", "trustedHeader", "oidc", "passkey", "unknown"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WatchAuthMode.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_WatchBotActivity() throws {
        let value: WatchBotActivity = .toolComplete(toolCallID: "call-7", name: "shell", summary: "done", status: "ok", durationSeconds: 1.25)
        let decoded: WatchBotActivity = try roundTrip(value)
        guard case .toolComplete(let callID, let name, let summary, let status, let duration) = decoded else { Issue.record("expected toolComplete"); return }
        #expect(callID == "call-7" && name == "shell" && summary == "done" && status == "ok" && duration == 1.25)
        let invalid: WatchBotActivity = .toolComplete(toolCallID: "call", name: "shell", summary: nil, status: nil, durationSeconds: -1)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchBotActivity.self, from: JSONEncoder().encode(invalid)) }
    }

    @Test func semanticCoverage_WatchBotApprovalProjection() throws {
        let choices: BoundedCollection<String> = try BoundedCollection(items: ["once", "deny"], isTruncated: false)
        let value: WatchBotApprovalProjection = try WatchBotApprovalProjection(requestID: "request-approval", choices: choices, redactedCommand: "deploy", toolName: "shell", displaySummary: "Approval needed")
        let decoded: WatchBotApprovalProjection = try roundTrip(value)
        #expect(decoded.requestID == "request-approval" && decoded.choices?.items == ["once", "deny"])
        #expect(throws: (any Error).self) { try WatchBotApprovalProjection(requestID: " ", choices: choices, redactedCommand: nil, toolName: nil, displaySummary: nil) }
    }

    @Test func semanticCoverage_WatchBotClarificationForm() throws {
        let question = try WatchBotClarificationQuestion(prompt: "Which branch?", choices: try BoundedCollection(items: ["main", "release"], isTruncated: false))
        let value: WatchBotClarificationForm = .single(question)
        let decoded: WatchBotClarificationForm = try roundTrip(value)
        guard case .single(let decodedQuestion) = decoded else { Issue.record("expected single clarification form"); return }
        #expect(decodedQuestion == question)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WatchBotClarificationForm.self, from: Data(#"{"future":{}}"#.utf8)) }
    }

    @Test func semanticCoverage_WatchBotClarificationProjection() throws {
        let value: WatchBotClarificationProjection = try WatchBotClarificationProjection(requestID: "request-question", form: .open, displaySummary: "Need input")
        let decoded: WatchBotClarificationProjection = try roundTrip(value)
        #expect(decoded.requestID == "request-question" && decoded.form == .open)
        #expect(throws: (any Error).self) { try WatchBotClarificationProjection(requestID: " ", form: .open, displaySummary: nil) }
    }

    @Test func semanticCoverage_WatchBotClarificationQuestion() throws {
        let choices: BoundedCollection<String> = try BoundedCollection(items: ["main", "release"], isTruncated: false)
        let value: WatchBotClarificationQuestion = try WatchBotClarificationQuestion(prompt: "Which branch?", choices: choices)
        let decoded: WatchBotClarificationQuestion = try roundTrip(value)
        #expect(decoded.prompt == "Which branch?" && decoded.choices?.items == ["main", "release"])
        #expect(throws: (any Error).self) { try WatchBotClarificationQuestion(prompt: String(repeating: "x", count: 2_049), choices: nil) }
    }

    @Test func semanticCoverage_WatchBotConversation() throws {
        let block: WatchTranscriptBlock = .text(id: "message-1", role: .assistant, text: "Ready")
        let value: WatchBotConversation = try WatchBotConversation(key: bot(), blocks: [block], replayEpoch: "epoch-1", lastSequence: 9, phase: .responding, history: .complete)
        let decoded: WatchBotConversation = try roundTrip(value)
        #expect(decoded.blocks == [block] && decoded.lastSequence == 9 && decoded.phase == .responding)
        #expect(throws: (any Error).self) { try WatchBotConversation(key: bot(), blocks: [block], replayEpoch: "epoch", lastSequence: -1, phase: nil, history: .complete) }
    }

    @Test func semanticCoverage_WatchBotEvent() throws {
        let value: WatchBotEvent = try WatchBotEvent(key: bot(), replayEpoch: "epoch-1", runtimeSessionID: "runtime-1", sequence: 12, activity: .messageDelta(delta: "hello"))
        let decoded: WatchBotEvent = try roundTrip(value)
        #expect(decoded.sequence == 12 && decoded.activity == .messageDelta(delta: "hello"))
        #expect(throws: (any Error).self) { try WatchBotEvent(key: bot(), replayEpoch: "epoch", runtimeSessionID: "runtime", sequence: -1, activity: .messageStart) }
    }

    @Test func semanticCoverage_WatchBotHistoryAvailability() throws {
        let value: WatchBotHistoryAvailability = .unavailableOversize(limit: 50)
        let decoded: WatchBotHistoryAvailability = try roundTrip(value)
        guard case .unavailableOversize(let limit) = decoded else { Issue.record("expected unavailableOversize"); return }
        #expect(limit == 50)
        let invalid: WatchBotHistoryAvailability = .unavailableOversize(limit: 0)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchBotHistoryAvailability.self, from: JSONEncoder().encode(invalid)) }
    }

    @Test func semanticCoverage_WatchBotSummary() throws {
        let value: WatchBotSummary = try WatchBotSummary(key: bot(), title: "Build bot", phase: .thinking)
        let decoded: WatchBotSummary = try roundTrip(value)
        #expect(decoded.title == "Build bot" && decoded.phase == .thinking)
        #expect(throws: (any Error).self) { try WatchBotSummary(key: bot(), title: String(repeating: "x", count: 1_025), phase: nil) }
    }

    @Test func semanticCoverage_WatchClarification() throws {
        let value: WatchClarification = try WatchClarification(key: clarification(), question: "Choose target", choices: ["one", "two"], requestedAt: Date(timeIntervalSinceReferenceDate: 44))
        let decoded: WatchClarification = try roundTrip(value)
        #expect(decoded.question == "Choose target" && decoded.choices == ["one", "two"])
        #expect(throws: (any Error).self) { try WatchClarification(key: clarification(), question: " ", choices: [], requestedAt: nil) }
    }

    @Test func semanticCoverage_WatchComposerOptions() throws {
        let profile = try WatchComposerOptions.ProfileChoice(id: ProfileID("profile-id"), label: "Profile")
        let workspace = try WatchComposerOptions.WorkspaceChoice(handle: WorkspaceHandle("workspace-id"), label: "Workspace")
        let value: WatchComposerOptions = try WatchComposerOptions(scope: scope(), profiles: [profile], workspaces: [workspace], defaultProfileID: profile.id, defaultWorkspaceHandle: workspace.handle)
        let decoded: WatchComposerOptions = try roundTrip(value)
        #expect(decoded.profiles == [profile] && decoded.workspaces == [workspace] && decoded.defaultProfileID == profile.id)
        #expect(throws: (any Error).self) { try WatchComposerOptions(scope: scope(), profiles: Array(repeating: profile, count: 129), workspaces: [], defaultProfileID: nil, defaultWorkspaceHandle: nil) }
    }

    @Test func semanticCoverage_WatchFilePreview() throws {
        let path = try PathHandle("README.md")
        let value: WatchFilePreview = .text(pathHandle: path, text: "preview", isTruncated: true)
        let decoded: WatchFilePreview = try roundTrip(value)
        guard case .text(let decodedPath, let text, let truncated) = decoded else { Issue.record("expected text preview"); return }
        #expect(decodedPath == path && text == "preview" && truncated)
        let invalid: WatchFilePreview = .text(pathHandle: path, text: String(repeating: "x", count: 262_145), isTruncated: false)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchFilePreview.self, from: JSONEncoder().encode(invalid)) }
    }

    @Test func semanticCoverage_WatchGitAggregate() throws {
        let value: WatchGitAggregate = try WatchGitAggregate(session: session(), branch: "feature/semantic", isRepository: true, dirty: true, modifiedCount: 2, untrackedCount: 1, ahead: 3, behind: 4)
        let decoded: WatchGitAggregate = try roundTrip(value)
        #expect(decoded.branch == "feature/semantic" && decoded.modifiedCount == 2 && decoded.ahead == 3 && decoded.behind == 4)
        #expect(throws: (any Error).self) { try WatchGitAggregate(session: session(), branch: nil, isRepository: true, dirty: false, modifiedCount: -1, untrackedCount: 0, ahead: 0, behind: 0) }
    }

    @Test func semanticCoverage_WatchInsightsAggregate() throws {
        let models: BoundedCollection<String> = try BoundedCollection(items: ["model-a"], isTruncated: false)
        let counts: BoundedCollection<Int> = try BoundedCollection(items: [3, 5], isTruncated: false)
        let value: WatchInsightsAggregate = try WatchInsightsAggregate(days: InsightsDays(7), totalSessions: 2, totalMessages: 8, totalInputTokens: 13, totalOutputTokens: 21, totalTokens: 34, totalCost: Decimal(string: "1.25")!, models: models, dailyTokens: counts, activityByDay: counts, activityByHour: counts)
        let decoded: WatchInsightsAggregate = try roundTrip(value)
        #expect(decoded.days.value == 7 && decoded.totalTokens == 34 && decoded.models.items == ["model-a"])
        #expect(throws: (any Error).self) { try WatchInsightsAggregate(days: InsightsDays(1), totalSessions: -1, totalMessages: 0, totalInputTokens: 0, totalOutputTokens: 0, totalTokens: 0, totalCost: 0, models: models, dailyTokens: counts, activityByDay: counts, activityByHour: counts) }
    }

    @Test func semanticCoverage_WatchMediaDescriptor() throws {
        let value: WatchMediaDescriptor = try mediaDescriptor()
        let decoded: WatchMediaDescriptor = try roundTrip(value)
        #expect(decoded.mimeType == "image/png" && decoded.byteSize == 4 && decoded.sha256.count == 64)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchMediaDescriptor.self, from: replacing(value, "sha256", with: "bad")) }
    }

    @Test func semanticCoverage_WatchMediaPayload() throws {
        let bytes = Data([1, 2, 3, 4])
        let value: WatchMediaPayload = try WatchMediaPayload(descriptor: mediaDescriptor(), bytes: bytes)
        let decoded: WatchMediaPayload = try roundTrip(value)
        #expect(decoded.bytes == bytes && decoded.descriptor.byteSize == 4)
        #expect(throws: (any Error).self) { try WatchMediaPayload(descriptor: mediaDescriptor(), bytes: Data([1])) }

        let malformedFixture = try replacing(value, "bytes", with: Data([1]).base64EncodedString())
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchMediaPayload.self, from: malformedFixture)
        }
    }

    @Test func mediaPayloadVerifiesKnownSHA256AtInitAndDecode() throws {
        let abc = Data("abc".utf8)
        let uppercaseDigest = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        let descriptor = try mediaDescriptor(bytes: abc, sha256: uppercaseDigest)
        let value = try WatchMediaPayload(descriptor: descriptor, bytes: abc)

        #expect(value.descriptor.sha256 == uppercaseDigest)
        #expect(try JSONDecoder().decode(WatchMediaPayload.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func mediaPayloadRejectsDigestMismatchAndByteMutation() throws {
        let bytes = Data([1, 2, 3, 4])
        let descriptor = try mediaDescriptor(bytes: bytes)
        #expect(throws: DTOValidationError.invalidDigest) {
            try WatchMediaPayload(descriptor: try mediaDescriptor(bytes: bytes, sha256: String(repeating: "0", count: 64)), bytes: bytes)
        }
        #expect(throws: DTOValidationError.invalidDigest) {
            try WatchMediaPayload(descriptor: descriptor, bytes: Data([1, 2, 3, 5]))
        }

        let valid = try WatchMediaPayload(descriptor: descriptor, bytes: bytes)
        let mutatedFixture = try replacing(valid, "bytes", with: Data([1, 2, 3, 5]).base64EncodedString())
        #expect(throws: DTOValidationError.invalidDigest) {
            try JSONDecoder().decode(WatchMediaPayload.self, from: mutatedFixture)
        }
    }

    @Test func semanticCoverage_WatchMemoryDocument() throws {
        let first = try WatchMemorySection(key: memory(), section: "preferences", redactedContent: "dark mode", isTruncated: false)
        let second = try WatchMemorySection(key: memory(), section: "facts", redactedContent: "swift", isTruncated: true)
        let value: WatchMemoryDocument = try WatchMemoryDocument(sections: [first, second])
        let decoded: WatchMemoryDocument = try roundTrip(value)
        #expect(decoded.sections == [first, second])
        #expect(throws: (any Error).self) { try WatchMemoryDocument(sections: [first, first]) }
    }

    @Test func semanticCoverage_WatchMemorySection() throws {
        let value: WatchMemorySection = try WatchMemorySection(key: memory(), section: "preferences", redactedContent: "dark mode", isTruncated: true)
        let decoded: WatchMemorySection = try roundTrip(value)
        #expect(decoded.section == "preferences" && decoded.redactedContent == "dark mode" && decoded.isTruncated)
        #expect(throws: (any Error).self) { try WatchMemorySection(key: memory(), section: " ", redactedContent: "content", isTruncated: false) }
    }

    @Test func semanticCoverage_WatchMessageRole() throws {
        let values: [WatchMessageRole] = [.user, .assistant, .system]
        #expect(values.map(\.rawValue) == ["user", "assistant", "system"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WatchMessageRole.self, from: Data(#""tool""#.utf8)) }
    }

    @Test func semanticCoverage_WatchRunEvent() throws {
        let value: WatchRunEvent = try WatchRunEvent(key: run(), eventID: "event-7", sequence: 7, phase: .responding, textDelta: "hello", terminal: false)
        let decoded: WatchRunEvent = try roundTrip(value)
        #expect(decoded.eventID == "event-7" && decoded.sequence == 7 && decoded.textDelta == "hello")
        #expect(throws: (any Error).self) { try WatchRunEvent(key: run(), eventID: "event", sequence: -1, phase: .failed, textDelta: nil, terminal: true) }
    }

    @Test func semanticCoverage_WatchRunPhase() throws {
        let values: [WatchRunPhase] = [.starting, .thinking, .tool, .searching, .files, .command, .responding, .attention, .completed, .failed, .stopped, .unknown]
        #expect(values.map(\.rawValue) == ["starting", "thinking", "tool", "searching", "files", "command", "responding", "attention", "completed", "failed", "stopped", "unknown"])
        #expect(try values.map { try roundTrip($0) } == values)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WatchRunPhase.self, from: Data(#""future""#.utf8)) }
    }

    @Test func semanticCoverage_WatchRunState() throws {
        let value: WatchRunState = try WatchRunState(key: run(), phase: .attention, lastEventID: "event-8", lastSequence: 8, isTerminal: false, summary: "Needs approval")
        let decoded: WatchRunState = try roundTrip(value)
        #expect(decoded.phase == .attention && decoded.lastEventID == "event-8" && decoded.lastSequence == 8)
        #expect(throws: (any Error).self) { try WatchRunState(key: run(), phase: .starting, lastEventID: "event", lastSequence: -1, isTerminal: false, summary: nil) }
    }

    @Test func semanticCoverage_WatchServerDescriptor() throws {
        let value: WatchServerDescriptor = WatchServerDescriptor(scope: try scope(), displayName: try RedactedDisplayName("Semantic Server"), authMode: .oidc, directState: .available)
        let decoded: WatchServerDescriptor = try roundTrip(value)
        #expect(decoded.authMode == .oidc && decoded.directState == .available && decoded.displayName.rawValue == "Semantic Server")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchServerDescriptor.self, from: replacing(value, "authMode", with: "future")) }
    }

    @Test func semanticCoverage_WatchSessionSummary() throws {
        let value: WatchSessionSummary = try WatchSessionSummary(key: session(), title: "Semantic session", profile: "profile", workspaceLabel: "workspace", updatedAt: Date(timeIntervalSinceReferenceDate: 50), isPinned: true, isArchived: false, attention: true, runState: .attention)
        let decoded: WatchSessionSummary = try roundTrip(value)
        #expect(decoded.title == "Semantic session" && decoded.isPinned && decoded.attention && decoded.runState == .attention)
        #expect(throws: (any Error).self) { try WatchSessionSummary(key: session(), title: " ", profile: nil, workspaceLabel: nil, updatedAt: nil, isPinned: false, isArchived: false, attention: false, runState: nil) }
    }

    @Test func semanticCoverage_WatchSkillContent() throws {
        let value: WatchSkillContent = try WatchSkillContent(key: skill(), fileHandle: PathHandle("SKILL.md"), content: "# Semantic", isTruncated: false)
        let decoded: WatchSkillContent = try roundTrip(value)
        #expect(decoded.content == "# Semantic" && decoded.fileHandle?.rawValue == "SKILL.md")
        #expect(throws: (any Error).self) { try WatchSkillContent(key: skill(), fileHandle: nil, content: String(repeating: "x", count: 262_145), isTruncated: false) }
    }

    @Test func semanticCoverage_WatchSkillDetail() throws {
        let linked = try WatchSkillDetail.LinkedFile(handle: PathHandle("references/api.md"), name: "API", byteSize: 128)
        let files: BoundedCollection<WatchSkillDetail.LinkedFile> = try BoundedCollection(items: [linked], isTruncated: false)
        let value: WatchSkillDetail = try WatchSkillDetail(key: skill(), summary: "Skill details", linkedFiles: files)
        let decoded: WatchSkillDetail = try roundTrip(value)
        #expect(decoded.summary == "Skill details" && decoded.linkedFiles.items == [linked])
        #expect(throws: (any Error).self) { try WatchSkillDetail(key: skill(), summary: String(repeating: "x", count: 4_097), linkedFiles: files) }
    }

    @Test func semanticCoverage_WatchSkillSummary() throws {
        let value: WatchSkillSummary = try WatchSkillSummary(key: skill(), summary: "Skill summary", enabled: true)
        let decoded: WatchSkillSummary = try roundTrip(value)
        #expect(decoded.summary == "Skill summary" && decoded.enabled == true)
        #expect(throws: (any Error).self) { try WatchSkillSummary(key: skill(), summary: String(repeating: "x", count: 4_097), enabled: nil) }
    }

    @Test func semanticCoverage_WatchTaskRun() throws {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let value: WatchTaskRun = try WatchTaskRun(task: task(), runID: "run-1", startedAt: start, finishedAt: start.addingTimeInterval(30), status: "completed", output: "done", isTruncated: false)
        let decoded: WatchTaskRun = try roundTrip(value)
        #expect(decoded.runID == "run-1" && decoded.status == "completed" && decoded.output == "done")
        #expect(throws: (any Error).self) { try WatchTaskRun(task: task(), runID: "run", startedAt: start, finishedAt: start.addingTimeInterval(-1), status: "failed", output: nil, isTruncated: false) }
    }

    @Test func semanticCoverage_WatchTaskRunDetail() throws {
        let run = try WatchTaskRun(task: task(), runID: "run-2", startedAt: nil, finishedAt: nil, status: "running", output: nil, isTruncated: false)
        let value: WatchTaskRunDetail = try WatchTaskRunDetail(run: run, output: "verbose output", outputTruncated: true)
        let decoded: WatchTaskRunDetail = try roundTrip(value)
        #expect(decoded.run == run && decoded.output == "verbose output" && decoded.outputTruncated)
        #expect(throws: (any Error).self) { try WatchTaskRunDetail(run: run, output: String(repeating: "x", count: 262_145), outputTruncated: false) }
    }

    @Test func semanticCoverage_WatchTaskSummary() throws {
        let value: WatchTaskSummary = try WatchTaskSummary(key: task(), name: "Nightly build", schedule: "0 2 * * *", enabled: true, running: false, lastResult: "success")
        let decoded: WatchTaskSummary = try roundTrip(value)
        #expect(decoded.name == "Nightly build" && decoded.schedule == "0 2 * * *" && decoded.lastResult == "success")
        #expect(throws: (any Error).self) { try WatchTaskSummary(key: task(), name: " ", schedule: "daily", enabled: true, running: false, lastResult: nil) }
    }

    @Test func semanticCoverage_WatchTranscript() throws {
        let block: WatchTranscriptBlock = .text(id: "block-1", role: .assistant, text: "hello")
        let value: WatchTranscript = try WatchTranscript(session: session(), blocks: [block], nextBefore: 17, isTruncated: true)
        let decoded: WatchTranscript = try roundTrip(value)
        #expect(decoded.blocks == [block] && decoded.nextBefore == 17 && decoded.isTruncated)
        #expect(throws: (any Error).self) { try WatchTranscript(session: session(), blocks: Array(repeating: block, count: 51), nextBefore: nil, isTruncated: false) }
    }

    @Test func transcriptRejectsImageDescriptorForDifferentSameScopeSessionAtInitAndDecode() throws {
        let transcriptSession = try session()
        let foreignSession = try SessionKey(scope: scope(), sessionID: "foreign-session")
        let descriptor = try WatchMediaDescriptor(
            scope: scope(),
            session: foreignSession,
            origin: OriginBinding(digest: "sha256:foreign-transcript-image"),
            handle: MediaHandle("foreign-transcript-image"),
            mimeType: "image/png",
            byteSize: 0,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            observedAt: Date(timeIntervalSinceReferenceDate: 100),
            expiresAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let foreignImage: WatchTranscriptBlock = .image(id: "image", descriptor: descriptor, alt: nil)

        #expect(throws: DTOValidationError.scopeMismatch) {
            try WatchTranscript(session: transcriptSession, blocks: [foreignImage], nextBefore: nil, isTruncated: false)
        }

        let valid = try WatchTranscript(session: transcriptSession, blocks: [], nextBefore: nil, isTruncated: false)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["blocks"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([foreignImage]))
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DTOValidationError.scopeMismatch) {
            try JSONDecoder().decode(WatchTranscript.self, from: malformed)
        }
    }

    @Test func semanticCoverage_WatchTranscriptBlock() throws {
        let value: WatchTranscriptBlock = .text(id: "block-2", role: .assistant, text: "semantic text")
        let decoded: WatchTranscriptBlock = try roundTrip(value)
        guard case .text(let id, let role, let text) = decoded else { Issue.record("expected text transcript block"); return }
        #expect(id == "block-2" && role == .assistant && text == "semantic text")
        let invalid: WatchTranscriptBlock = .text(id: " ", role: .user, text: "bad")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchTranscriptBlock.self, from: JSONEncoder().encode(invalid)) }
    }

    @Test func semanticCoverage_WatchWorkspaceEntry() throws {
        let value: WatchWorkspaceEntry = try WatchWorkspaceEntry(session: session(), pathHandle: PathHandle("Sources/App.swift"), name: "App.swift", kind: .text, byteSize: 512)
        let decoded: WatchWorkspaceEntry = try roundTrip(value)
        #expect(decoded.name == "App.swift" && decoded.kind == .text && decoded.byteSize == 512)
        #expect(throws: (any Error).self) { try WatchWorkspaceEntry(session: session(), pathHandle: PathHandle("file"), name: "file", kind: .binary, byteSize: -1) }
    }
}
