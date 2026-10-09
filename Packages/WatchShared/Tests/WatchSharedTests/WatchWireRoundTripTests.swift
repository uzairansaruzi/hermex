import Foundation
import Testing
@testable import WatchShared

/// Loops a wire message straight into the dispatcher so tests exercise the
/// full encode/validate path in-process without WatchConnectivity.
private final class LoopTransport: WatchWireTransporting, @unchecked Sendable {
    let dispatcher: WatchWireDispatcher
    init(dispatcher: WatchWireDispatcher) { self.dispatcher = dispatcher }
    func send(_ message: WatchWireMessage) async throws -> WatchWireReply {
        await dispatcher.handle(message)
    }
}

@Suite struct WatchWireRoundTripTests {

    @Test func registryAndSendRoundTripThroughTheWire() async throws {
        let backend = ScriptedPhoneBackend()
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        // The client validates reply envelopes against the request, including
        // expiry, so its `now` must sit inside the request's validity window
        // (the broker uses a fixed clock; the client must agree with it).
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_010) }
        let client = WatchWireClient(transport: LoopTransport(dispatcher: WatchWireDispatcher(service: broker)), now: now)

        let registry = await client.registry()
        #expect(registry.entries.count == 1)
        let scope = try #require(registry.entries.first?.scope)
        let sessions = try await client.refreshSessions(scope: scope, collection: .current, query: nil, localLimit: 10)
        #expect(sessions.value.items.map(\.title) == ["Planning"])

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
        let receipt = await client.send(text: "go", to: sessions.value.items[0].key, context: context)
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(receipt.value?.streamID == "stream-1")

        let transcribeDispatcher = WatchWireDispatcher(service: broker) { request in
            await broker.sendVoiceNote(request)
        }
        let voiceClient = WatchWireClient(transport: LoopTransport(dispatcher: transcribeDispatcher), now: now)
        let note = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x1, count: 32)
        )
        let voiceReceipt = try await voiceClient.sendVoiceNote(note)
        #expect(voiceReceipt.receipt.phase == .acknowledged)
        #expect(voiceReceipt.value?.streamID == "stream-1")
    }

    /// Task control, skill toggles, Kanban moves and the profile switch each
    /// ride their own wire case. A case the dispatcher does not route, or a
    /// reply shape the client does not recognise, silently turns every wrist
    /// action into a no-op, so loop all four end to end.
    @Test func glanceWritesRoundTripThroughTheWire() async throws {
        let backend = ScriptedPhoneBackend()
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_010) }
        let client = WatchWireClient(transport: LoopTransport(dispatcher: WatchWireDispatcher(service: broker)), now: now)

        let registry = await client.registry()
        let scope = try #require(registry.entries.first?.scope)

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
        let taskReceipt = await client.controlTask(
            key: try TaskKey(scope: scope, jobID: "job-1"),
            action: .resume,
            context: context
        )
        #expect(taskReceipt.receipt.phase == .acknowledged)
        #expect(backend.controlledTasks.map(\.action) == ["resume"])

        try await client.setSkillEnabled(scope: scope, name: "web-search", enabled: false, expectedRevision: registry.revision)
        #expect(backend.skillToggles.map { "\($0.name):\($0.enabled)" } == ["web-search:false"])

        try await client.moveKanbanCard(scope: scope, cardID: "card-1", status: "Done", boardSlug: "default", expectedRevision: registry.revision)
        #expect(backend.kanbanMoves.map(\.status) == ["Done"])

        let active = try await client.switchActiveProfile(scope: scope, name: "builder", expectedRevision: registry.revision)
        #expect(active == "builder")
        #expect(backend.switchedProfiles == ["builder"])
    }

    @Test func glanceWriteRequestsSurviveJSONEncoding() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let messages: [WatchWireMessage] = [
            .setSkillEnabled(try WatchSkillToggleRequest(scope: scope, expectedRevision: Revision(3), name: " web-search ", enabled: true)),
            .moveKanbanCard(try WatchKanbanMoveRequest(scope: scope, expectedRevision: Revision(3), cardID: " card-1 ", status: " Done ", boardSlug: " default ")),
            .createKanbanCard(try WatchKanbanCreateRequest(scope: scope, expectedRevision: Revision(3), boardSlug: " default ", title: " Ship it ", status: " ToDo ")),
            .dispatchKanban(try WatchKanbanDispatchRequest(scope: scope, expectedRevision: Revision(3), boardSlug: " default ", dryRun: true)),
            .switchProfile(try WatchProfileSwitchRequest(scope: scope, expectedRevision: Revision(3), name: " builder ")),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(WatchWireMessage.self, from: data) == message)
        }
        // Blank identifiers never reach the wire.
        #expect(throws: (any Error).self) {
            _ = try WatchSkillToggleRequest(scope: scope, expectedRevision: Revision(3), name: "   ", enabled: true)
        }
        #expect(throws: (any Error).self) {
            _ = try WatchKanbanMoveRequest(scope: scope, expectedRevision: Revision(3), cardID: "card-1", status: "  ", boardSlug: "default")
        }
        #expect(throws: (any Error).self) {
            _ = try WatchKanbanCreateRequest(scope: scope, expectedRevision: Revision(3), boardSlug: "default", title: "  ", status: "triage")
        }
        #expect(throws: (any Error).self) {
            _ = try WatchKanbanCreateRequest(scope: scope, expectedRevision: Revision(3), boardSlug: "default", title: "Ship it", status: "running")
        }
    }
}

private final class ScriptedPhoneBackend: WatchPhoneBackend, @unchecked Sendable {
    var controlledTasks: [(jobID: String, action: String)] = []
    var skillToggles: [(name: String, enabled: Bool)] = []
    var kanbanMoves: [(cardID: String, status: String)] = []
    var switchedProfiles: [String] = []

    func controlTask(urlString: String, jobID: String, action: String) async throws {
        controlledTasks.append((jobID, action))
    }
    func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws {
        skillToggles.append((name, enabled))
    }
    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
        kanbanMoves.append((cardID, status))
    }
    func switchProfile(urlString: String, name: String) async throws {
        switchedProfiles.append(name)
    }
    func servers() async -> [WatchPhoneServerAccount] {
        [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
    }
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] {
        [
            WatchPhoneSessionRow(
                sessionID: "s1",
                title: "Planning",
                profile: nil,
                workspaceLabel: nil,
                updatedAt: nil,
                isPinned: false,
                isArchived: false,
                attention: false,
                runState: nil
            ),
        ]
    }
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { "s2" }
    func startChat(urlString: String, sessionID: String, message: String) async throws -> String { "stream-1" }
    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String { "stream-1" }
    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment {
        WatchChatAttachment(
            name: filename,
            path: "/tmp/workspace/\(filename)",
            mime: "audio/m4a",
            size: data.count,
            isImage: false
        )
    }
    func cancelChat(urlString: String, streamID: String) async throws {}
    func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage {
        WatchPhoneTranscriptPage(blocks: [], nextBefore: nil, isTruncated: false)
    }
    func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool) {
        (.responding, false)
    }
    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String {
        "transcribed note"
    }
    func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance] {
        [
            WatchPhoneTaskGlance(
                id: "job-1",
                name: "Digest",
                schedule: "Every day at 8:00 AM",
                enabled: true,
                running: false,
                lastResult: "error",
                lastRunAt: Date(timeIntervalSince1970: 1_699_990_000),
                nextRunAt: Date(timeIntervalSince1970: 1_700_050_000),
                failureSummary: "Timed out after 300s"
            ),
        ]
    }
    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
        [WatchPhoneTaskRun(id: "run-1.md", finishedAt: Date(timeIntervalSince1970: 1_699_990_000), durationSeconds: 90)]
    }
    func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String? {
        "---\nmodel: sol\n---\n\n## Response\n\n**Done.** Shipped `v2`."
    }
    func memoryGlance(urlString: String) async throws -> [WatchPhoneMemoryGlance] {
        [WatchPhoneMemoryGlance(
            section: "user",
            text: WatchMemoryProjection.wireContent(["**Name:** Aaryan", "**Email:** a@example.com"]),
            isTruncated: true
        )]
    }
    func usageGlance(urlString: String, days: Int) async throws -> WatchPhoneUsageGlance {
        WatchPhoneUsageGlance(
            days: days, totalSessions: 3, totalMessages: 9,
            totalInputTokens: 600, totalOutputTokens: 400, totalTokens: 1_000,
            totalCost: 2.5, models: ["sol"],
            modelUsage: [WatchPhoneModelUsage(name: "sol", totalTokens: 1_000, cost: 2.5, sessions: 3)],
            dailyTokens: [100, 0, 900]
        )
    }
    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] {
        [WatchPhoneKanbanCardGlance(id: "card-1", title: "Ship\nit", status: "running", assignee: "default", priority: 1, body: "Line one\n\nLine two")]
    }
}

/// Encodes every message and reply as JSON, the way WatchConnectivity carries
/// them, so a field that is not Codable end to end fails here.
private final class JSONLoopTransport: WatchWireTransporting, @unchecked Sendable {
    let dispatcher: WatchWireDispatcher
    init(dispatcher: WatchWireDispatcher) { self.dispatcher = dispatcher }
    func send(_ message: WatchWireMessage) async throws -> WatchWireReply {
        let decodedMessage = try JSONDecoder().decode(WatchWireMessage.self, from: JSONEncoder().encode(message))
        let reply = await dispatcher.handle(decodedMessage)
        return try JSONDecoder().decode(WatchWireReply.self, from: JSONEncoder().encode(reply))
    }
}

@Suite struct WatchGlanceWireTests {
    /// Wall-clock time on both ends: decoding a snapshot checks its freshness
    /// against the real clock, as it does on a paired watch.
    private func client() async throws -> (WatchWireClient, ServerScope) {
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: ScriptedPhoneBackend()
        )
        let client = WatchWireClient(
            transport: JSONLoopTransport(dispatcher: WatchWireDispatcher(service: broker))
        )
        let scope = try #require(await client.registry().entries.first?.scope)
        return (client, scope)
    }

    @Test func taskTimesAndFailureSurviveTheWire() async throws {
        let (client, scope) = try await client()
        let task = try #require(try await client.tasks(scope: scope, localLimit: 8).value.items.first)
        #expect(task.lastRunAt == Date(timeIntervalSince1970: 1_699_990_000))
        #expect(task.nextRunAt == Date(timeIntervalSince1970: 1_700_050_000))
        #expect(task.failureSummary == "Timed out after 300s")
        #expect(task.lastResult == "error")
    }

    @Test func taskRunsAndOutputAreReadable() async throws {
        let (client, scope) = try await client()
        let key = try TaskKey(scope: scope, jobID: "job-1")
        let runs = try await client.taskRuns(key: key, page: PageRequest(continuation: nil, limit: 5)).value.items
        let run = try #require(runs.first)
        #expect(run.runID == "run-1.md")
        #expect(run.finishedAt == Date(timeIntervalSince1970: 1_699_990_000))
        #expect(run.startedAt == Date(timeIntervalSince1970: 1_699_989_910))

        let detail = try await client.taskRunDetail(key: key, runID: "run-1.md").value
        // Front matter and the Response heading never reach the wrist.
        #expect(detail.output == "**Done.** Shipped `v2`.")
        #expect(detail.outputTruncated == false)
    }

    @Test func memoryEntriesUsageBreakdownAndCardsSurviveTheWire() async throws {
        let (client, scope) = try await client()

        let memory = try await client.memoryDocument(scope: scope).value
        let section = try #require(memory.sections.first)
        #expect(WatchMemoryProjection.entries(in: section.redactedContent) == ["**Name:** Aaryan", "**Email:** a@example.com"])
        #expect(section.isTruncated)

        let usage = try await client.insightsAggregate(scope: scope, days: InsightsDays(7)).value
        #expect(usage.dailyTokens.items == [100, 0, 900])
        #expect(usage.modelUsage?.items.first?.name == "sol")
        #expect(usage.modelUsage?.items.first?.cost == Decimal(2.5))

        let items = try await client.skills(scope: scope, query: WatchGlanceQuery.kanban, localLimit: 8).value.items
        #expect(items.first?.key.name == WatchKanbanBoardChrome.cardID)
        let summary = try #require(items.first { $0.key.name == "card-1" })
        let card = WatchKanbanCard(id: summary.key.name, wireSummary: summary.summary)
        #expect(card.title == "Ship it")
        #expect(card.status == "running")
        #expect(card.priority == 1)
        #expect(card.body == "Line one\n\nLine two")
    }
}

/// A transport that returns a canned reply so the client's envelope-validation
/// path can be exercised without the broker.
private final class CannedTransport: WatchWireTransporting, @unchecked Sendable {
    let reply: WatchWireReply
    init(_ reply: WatchWireReply) { self.reply = reply }
    func send(_ message: WatchWireMessage) async throws -> WatchWireReply { reply }
}

private final class ThrowingSessionsBackend: WatchPhoneBackend, @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
    func servers() async -> [WatchPhoneServerAccount] {
        [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
    }
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] {
        throw error
    }
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { "s2" }
    func startChat(urlString: String, sessionID: String, message: String) async throws -> String { "stream-1" }
    func cancelChat(urlString: String, streamID: String) async throws {}
    func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage {
        WatchPhoneTranscriptPage(blocks: [], nextBefore: nil, isTruncated: false)
    }
    func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool) {
        (.responding, false)
    }
    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String { "transcribed note" }
}

@Suite struct WatchWireValidationTests {
    private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_010) }

    @Test func readRejectsAMismatchedEnvelope() async throws {
        // A reply whose scope does not match the request must not populate
        // watch state.
        let foreignScope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let response = try WatchResponseEnvelope(
            requestID: UUID(),
            scope: foreignScope,
            requestOperationKind: .sessions,
            requestCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            requestExpiresAt: Date(timeIntervalSince1970: 1_700_000_060),
            commandContext: nil,
            result: .sessions(try ScopedSnapshot(
                schema: 1,
                scope: foreignScope,
                revision: Revision(1),
                freshness: Freshness(
                    observedAt: Date(timeIntervalSince1970: 1_700_000_010),
                    expiresAt: Date(timeIntervalSince1970: 1_700_000_040),
                    source: .phoneProjection
                ),
                value: BoundedCollection(items: [], isTruncated: false, maximumItems: 100)
            ))
        )
        let client = WatchWireClient(transport: CannedTransport(.envelope(response)), now: fixedNow)
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        do {
            _ = try await client.refreshSessions(scope: scope, collection: .current, query: nil, localLimit: 10)
            Issue.record("refreshSessions should have thrown for a mismatched envelope")
        } catch is EnvelopeValidationError {
            // expected: scope mismatch rejected the reply
        } catch {
            Issue.record("expected EnvelopeValidationError, got \(error)")
        }
    }

    @Test func authRequiredFailureSurfacesAsADistinctError() async throws {
        // A 401 from the phone's session list must reach the watch as
        // `.authRequired`, not a generic invalidResponse, so the watch can
        // show "sign in on iPhone".
        let backend = ThrowingSessionsBackend(WatchCompanionError.backend(.authRequired))
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: backend,
            now: fixedNow
        )
        let client = WatchWireClient(
            transport: LoopTransport(dispatcher: WatchWireDispatcher(service: broker)),
            now: fixedNow
        )
        let registry = await client.registry()
        let scope = try #require(registry.entries.first?.scope)
        do {
            _ = try await client.refreshSessions(scope: scope, collection: .current, query: nil, localLimit: 10)
            Issue.record("refreshSessions should have thrown")
        } catch WatchCompanionError.backend(.authRequired) {
            // expected
        } catch {
            Issue.record("expected .authRequired, got \(error)")
        }
    }
}
