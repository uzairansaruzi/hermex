import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WatchShared

@Suite struct PhoneCompanionBrokerTests {
    private final class ScriptedBackend: WatchPhoneBackend, @unchecked Sendable {
        var accounts: [WatchPhoneServerAccount]
        var sessions: [WatchPhoneSessionRow]
        var createdSessionID = "new-session"
        var startedStreamID = "stream-1"
        var cancelledStreamIDs: [String] = []
        var transcriptPage = WatchPhoneTranscriptPage(
            blocks: [WatchPhoneTranscriptPage.Block(id: "m1", role: .user, text: "hello")],
            nextBefore: nil,
            isTruncated: false
        )
        var phase: (WatchRunPhase, Bool) = (.responding, false)
        var failSessions = false
        var failTranscribe = false
        var failUpload = false
        var failStartChat = false
        var sessionsByURL: [String: [WatchPhoneSessionRow]] = [:]
        var listedURLs: [String] = []
        var transcribedFilenames: [String] = []
        var uploaded: [(sessionID: String, filename: String, bytes: Int)] = []
        var startedChats: [(sessionID: String, message: String, attachments: [WatchChatAttachment]?)] = []
        var mediaByPath: [String: Data] = [:]
        var uploadedIsImage = false
        var profiles = WatchPhoneProfilePage(profiles: [], activeName: nil)
        var switchedProfile: String?
        var tasks: [WatchPhoneTaskGlance] = []
        var skills: [WatchPhoneSkillGlance] = []
        var memory: [WatchPhoneMemoryGlance] = []
        var usage = WatchPhoneUsageGlance(
            days: 30, totalSessions: 0, totalMessages: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalTokens: 0,
            totalCost: 0, models: []
        )
        var projects: [WatchPhoneProjectGlance] = []
        var kanban: [WatchPhoneKanbanCardGlance] = []
        var controlledTasks: [(jobID: String, action: String)] = []
        var skillToggles: [(name: String, enabled: Bool)] = []
        var kanbanMoves: [(cardID: String, status: String, boardSlug: String)] = []
        var mediaBySessionAndPath: [String: Data] = [:]
        var mediaPaths: [String] = []
        var failMedia = false
        var failCancel = false
        var failWrites = false

        init(
            accounts: [WatchPhoneServerAccount],
            sessions: [WatchPhoneSessionRow]
        ) {
            self.accounts = accounts
            self.sessions = sessions
        }

        func servers() async -> [WatchPhoneServerAccount] { accounts }
        func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] {
            listedURLs.append(urlString)
            if failSessions { throw WatchCompanionError.backend(.timeout) }
            let source = sessionsByURL[urlString] ?? (sessionsByURL.isEmpty ? sessions : [])
            let filtered = source.filter { archived ? $0.isArchived : !$0.isArchived }
            if let query, !query.isEmpty {
                return Array(filtered.filter { $0.title.localizedCaseInsensitiveContains(query) }.prefix(limit))
            }
            return Array(filtered.prefix(limit))
        }
        func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { createdSessionID }
        func startChat(urlString: String, sessionID: String, message: String) async throws -> String {
            try await startChat(urlString: urlString, sessionID: sessionID, message: message, attachments: nil)
        }
        func startChat(
            urlString: String,
            sessionID: String,
            message: String,
            attachments: [WatchChatAttachment]?
        ) async throws -> String {
            startedChats.append((sessionID, message, attachments))
            if failStartChat { throw WatchCompanionError.backend(.timeout) }
            return startedStreamID
        }
        func uploadFile(
            urlString: String,
            sessionID: String,
            data: Data,
            filename: String
        ) async throws -> WatchChatAttachment {
            uploaded.append((sessionID, filename, data.count))
            if failUpload { throw WatchCompanionError.backend(.timeout) }
            return WatchChatAttachment(
                name: filename,
                path: "/tmp/workspace/\(filename)",
                mime: uploadedIsImage ? "image/jpeg" : "audio/m4a",
                size: data.count,
                isImage: uploadedIsImage
            )
        }
        func mediaData(urlString: String, sessionID: String, path: String) async throws -> Data {
            mediaPaths.append(path)
            if failMedia { throw WatchCompanionError.backend(.timeout) }
            if let data = mediaBySessionAndPath["\(sessionID)|\(path)"] {
                return data
            }
            guard let data = mediaByPath[path] else {
                throw WatchCompanionError.backend(.invalidResponse)
            }
            return data
        }
        func cancelChat(urlString: String, streamID: String) async throws {
            if failCancel { throw WatchCompanionError.backend(.timeout) }
            cancelledStreamIDs.append(streamID)
        }
        func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage { transcriptPage }
        func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool) { phase }
        func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String {
            transcribedFilenames.append(filename)
            if failTranscribe { throw WatchCompanionError.backend(.timeout) }
            return "transcribed note"
        }
        func listProfiles(urlString: String) async throws -> WatchPhoneProfilePage { profiles }
        func switchProfile(urlString: String, name: String) async throws { switchedProfile = name }
        func listTasks(urlString: String, limit: Int) async throws -> [WatchPhoneTaskGlance] { Array(tasks.prefix(limit)) }
        func listSkills(urlString: String, query: String?, limit: Int) async throws -> [WatchPhoneSkillGlance] { Array(skills.prefix(limit)) }
        func memoryGlance(urlString: String) async throws -> [WatchPhoneMemoryGlance] { memory }
        func usageGlance(urlString: String, days: Int) async throws -> WatchPhoneUsageGlance { usage }
        func listProjects(urlString: String, limit: Int) async throws -> [WatchPhoneProjectGlance] { Array(projects.prefix(limit)) }
        func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] { Array(kanban.prefix(limit)) }
        var kanbanBoardQuery: (slug: String?, includeArchived: Bool, onlyMine: Bool)?
        var kanbanMovePolicy: String?
        func listKanbanBoard(
            urlString: String,
            slug: String?,
            includeArchived: Bool,
            onlyMine: Bool,
            limit: Int
        ) async throws -> WatchPhoneKanbanBoardGlance {
            kanbanBoardQuery = (slug, includeArchived, onlyMine)
            return WatchPhoneKanbanBoardGlance(
                name: "Default",
                slug: slug ?? "default",
                columns: WatchKanbanStatus.boardOrder,
                boards: [WatchKanbanBoardChrome.Choice(slug: "default", name: "Default")],
                cards: Array(kanban.prefix(limit)),
                movePolicy: kanbanMovePolicy
            )
        }
        func controlTask(urlString: String, jobID: String, action: String) async throws {
            if failWrites { throw WatchCompanionError.backend(.timeout) }
            controlledTasks.append((jobID, action))
        }
        func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws {
            if failWrites { throw WatchCompanionError.backend(.timeout) }
            skillToggles.append((name, enabled))
        }
        func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
            if failWrites { throw WatchCompanionError.backend(.timeout) }
            kanbanMoves.append((cardID, status, boardSlug))
        }
        var taskRuns: [WatchPhoneTaskRun] = []
        var taskOutput: String?
        var requestedRunLimit: Int?
        func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
            requestedRunLimit = limit
            return taskRuns
        }
        func taskRunOutput(urlString: String, jobID: String, runID: String) async throws -> String? { taskOutput }
    }

    private func makeBroker(_ backend: ScriptedBackend, epoch: InstallationEpoch = InstallationEpoch(rawValue: UUID())) -> PhoneCompanionBroker {
        PhoneCompanionBroker(epoch: epoch, backend: backend, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    @Test func registryMapsServersIntoScopedEntries() async throws {
        let backend = ScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha"),
                WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta"),
            ],
            sessions: []
        )
        let epoch = InstallationEpoch(rawValue: UUID())
        let broker = makeBroker(backend, epoch: epoch)

        let snapshot = await broker.registry()
        #expect(snapshot.epoch == epoch)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.map(\.displayName.rawValue) == ["Alpha", "Beta"])
        #expect(snapshot.entries[0].scope.server == ServerID.derived(from: "https://alpha.example"))
        #expect(Set(snapshot.entries.map(\.scope.server)).count == 2)
        #expect(snapshot.entries.allSatisfy { $0.writesUnsupported == nil })
    }

    @Test func hermesRegistryMarksWritesUnsupportedAndWebuiDoesNot() async throws {
        let backend = ScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(
                    urlString: "https://hermes.example",
                    displayName: "Hermes",
                    writesUnsupported: true
                ),
                WatchPhoneServerAccount(urlString: "https://webui.example", displayName: "Web"),
            ],
            sessions: []
        )
        let snapshot = await makeBroker(backend).registry()

        #expect(snapshot.entries.map(\.displayName.rawValue) == ["Hermes", "Web"])
        #expect(snapshot.entries[0].writesUnsupported == true)
        #expect(snapshot.entries[1].writesUnsupported == nil)
    }

    @Test func sendStartsARunOnTheScopedServer() async throws {
        let row = WatchPhoneSessionRow(
            sessionID: "s1",
            title: "Planning",
            profile: "default",
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 10),
            isPinned: true,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: [row]
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )

        let receipt = await broker.send(text: "continue", to: session, context: context)
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(receipt.receipt.operationKind == .send)
        #expect(receipt.value?.streamID == "stream-1")
        #expect(receipt.value?.session == session)
    }

    @Test func sendRejectsUnknownScope() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        _ = await broker.registry()
        let foreign = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let session = try SessionKey(scope: foreign, sessionID: "s1")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: foreign,
            expectedRevision: Revision(1),
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )

        let receipt = await broker.send(text: "nope", to: session, context: context)
        #expect(receipt.receipt.phase == .rejected)
        #expect(receipt.value == nil)
    }

    @Test func refreshSessionsAndTranscriptStayOnTheActiveScope() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: [
                WatchPhoneSessionRow(
                    sessionID: "s1",
                    title: "Planning",
                    profile: nil,
                    workspaceLabel: "~/src",
                    updatedAt: nil,
                    isPinned: false,
                    isArchived: false,
                    attention: true,
                    runState: .responding
                ),
            ]
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        let sessions = try await broker.refreshSessions(scope: scope, collection: .current, query: nil, localLimit: 20)
        #expect(sessions.value.items.count == 1)
        #expect(sessions.value.items[0].title == "Planning")
        #expect(sessions.value.items[0].key.scope == scope)

        let longWorkspace = String(repeating: "w", count: 400)
        let longTitle = String(repeating: "t", count: 1_100)
        let longBackend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: [
                WatchPhoneSessionRow(
                    sessionID: "long",
                    title: longTitle,
                    profile: String(repeating: "p", count: 300),
                    workspaceLabel: longWorkspace,
                    updatedAt: nil,
                    isPinned: true,
                    isArchived: false,
                    attention: false,
                    runState: nil
                ),
            ]
        )
        let longBroker = makeBroker(longBackend)
        let longRegistry = await longBroker.registry()
        let longScope = try #require(longRegistry.entries.first?.scope)
        let kept = try await longBroker.refreshSessions(
            scope: longScope,
            collection: .current,
            query: nil,
            localLimit: 20
        )
        #expect(kept.value.items.count == 1)
        #expect(kept.value.items[0].title.utf8.count <= 1024)
        #expect(kept.value.items[0].title.hasSuffix("…"))
        #expect((kept.value.items[0].workspaceLabel?.utf8.count ?? 0) <= 256)
        #expect((kept.value.items[0].profile?.utf8.count ?? 0) <= 256)
        #expect(kept.value.items[0].isPinned)

        let transcript = try await broker.transcript(key: sessions.value.items[0].key, before: nil, limit: 20)
        #expect(transcript.value.blocks.count == 1)
        if case .text(_, .user, let text) = transcript.value.blocks[0] {
            #expect(text == "hello")
        } else {
            Issue.record("expected a user text block")
        }
    }

    @Test func registryRefreshKeepsRevisionWhenMembershipIsUnchanged() async {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let first = await broker.registry()
        let second = await broker.registry()
        #expect(first.revision == second.revision)
        #expect(first.entries == second.entries)
        #expect(first.generatedAt == second.generatedAt)
    }

    @Test func activeServerOrderChangeIsANewRevision() async throws {
        let alpha = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let beta = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = ScriptedBackend(accounts: [alpha, beta], sessions: [])
        let broker = makeBroker(backend)
        let first = await broker.registry()
        #expect(first.entries.map(\.displayName.rawValue) == ["Alpha", "Beta"])

        // The phone switched its active server, so it lists Beta first.
        backend.accounts = [beta, alpha]
        let second = await broker.registry()

        #expect(second.entries.map(\.displayName.rawValue) == ["Beta", "Alpha"])
        #expect(second.revision.rawValue > first.revision.rawValue)
        #expect(second.entries.map(\.scope.generation.rawValue) == [1, 1])
    }

    @Test func duplicateServerURLCollapsesInsteadOfEmptyingTheRegistry() async throws {
        let backend = ScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha"),
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha copy"),
            ],
            sessions: []
        )
        let broker = makeBroker(backend)

        let snapshot = await broker.registry()

        #expect(snapshot.entries.map(\.displayName.rawValue) == ["Alpha"])
        #expect(snapshot.revision.rawValue == 1)
    }

    @Test func removedServerReappearsAtANewerGeneration() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let first = await broker.registry()
        let original = try #require(first.entries.first?.scope)
        #expect(original.generation.rawValue == 1)

        backend.accounts = []
        let empty = await broker.registry()
        #expect(empty.entries.isEmpty)
        #expect(empty.revision.rawValue > first.revision.rawValue)

        backend.accounts = [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
        let restored = await broker.registry()
        let readded = try #require(restored.entries.first?.scope)
        #expect(readded.server == original.server)
        #expect(readded.generation.rawValue == 2)
        #expect(restored.revision.rawValue > empty.revision.rawValue)
    }

    @Test func sessionsStayIsolatedToTheScopedServerURL() async throws {
        let alphaRow = WatchPhoneSessionRow(
            sessionID: "shared-id",
            title: "Alpha session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: nil,
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let betaRow = WatchPhoneSessionRow(
            sessionID: "shared-id",
            title: "Beta session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: nil,
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let backend = ScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha"),
                WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta"),
            ],
            sessions: []
        )
        backend.sessionsByURL = [
            "https://alpha.example": [alphaRow],
            "https://beta.example": [betaRow],
        ]
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let alpha = try #require(registry.entries.first(where: { $0.displayName.rawValue == "Alpha" })?.scope)
        let beta = try #require(registry.entries.first(where: { $0.displayName.rawValue == "Beta" })?.scope)

        let alphaSessions = try await broker.refreshSessions(scope: alpha, collection: .current, query: nil, localLimit: 20)
        let betaSessions = try await broker.refreshSessions(scope: beta, collection: .current, query: nil, localLimit: 20)
        #expect(alphaSessions.value.items.map(\.title) == ["Alpha session"])
        #expect(betaSessions.value.items.map(\.title) == ["Beta session"])
        #expect(alphaSessions.value.items[0].key.scope == alpha)
        #expect(betaSessions.value.items[0].key.scope == beta)
        #expect(backend.listedURLs == ["https://alpha.example", "https://beta.example"])
    }

    @Test func stopRejectsRunsTheWatchDidNotStart() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let run = try RunKey(session: SessionKey(scope: scope, sessionID: "s1"), streamID: "phone-stream")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )

        let receipt = await broker.stop(run: run, context: context)
        #expect(receipt.receipt.phase == .rejected)
        #expect(receipt.value == nil)
        #expect(backend.cancelledStreamIDs.isEmpty)
    }

    @Test func stopCancelsAWatchStartedRun() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )

        let started = await broker.send(text: "continue", to: session, context: context)
        let run = try #require(started.value)
        let receipt = await broker.stop(run: run, context: context)
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(backend.cancelledStreamIDs == ["stream-1"])
    }

    @Test func stopStillWorksAfterThePhoneBrokerIsRecreated() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WatchIssuedRunFileStore(directory: directory)
        let epoch = InstallationEpoch(rawValue: UUID())
        let first = PhoneCompanionBroker(epoch: epoch, backend: backend, now: { Date(timeIntervalSince1970: 1_700_000_000) }, issuedRunStore: store)
        let registry = await first.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let context = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: registry.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
        let started = await first.send(text: "continue", to: session, context: context)
        let run = try #require(started.value)

        let restarted = PhoneCompanionBroker(epoch: epoch, backend: backend, now: { Date(timeIntervalSince1970: 1_700_000_000) }, issuedRunStore: store)
        let refreshed = await restarted.registry()
        let stopContext = try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: refreshed.revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
        let receipt = await restarted.stop(run: run, context: stopContext)
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(backend.cancelledStreamIDs == ["stream-1"])
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func aFailedStopLeavesTheRunStoppableAfterThePhoneRestarts() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WatchIssuedRunFileStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let epoch = InstallationEpoch(rawValue: UUID())
        let first = PhoneCompanionBroker(epoch: epoch, backend: backend, now: { Date(timeIntervalSince1970: 1_700_000_000) }, issuedRunStore: store)
        let registry = await first.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let context = try context(scope: scope, revision: registry.revision)
        let started = await first.send(text: "continue", to: session, context: context)
        let run = try #require(started.value)

        backend.failCancel = true
        let failed = await first.stop(run: run, context: context)
        #expect(failed.receipt.phase == .rejected)
        #expect(backend.cancelledStreamIDs.isEmpty)

        backend.failCancel = false
        let restarted = PhoneCompanionBroker(epoch: epoch, backend: backend, now: { Date(timeIntervalSince1970: 1_700_000_000) }, issuedRunStore: store)
        let refreshed = await restarted.registry()
        let receipt = await restarted.stop(run: run, context: try self.context(scope: scope, revision: refreshed.revision))
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(backend.cancelledStreamIDs == ["stream-1"])
    }

    @Test func stopStillReachesTheServerAfterItsGenerationChanges() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let context = try context(scope: scope, revision: registry.revision)
        let started = await broker.send(text: "continue", to: session, context: context)
        let run = try #require(started.value)

        backend.accounts = []
        _ = await broker.registry()
        backend.accounts = [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
        let refreshed = await broker.registry()
        let moved = try #require(refreshed.entries.first?.scope)
        #expect(moved.generation != scope.generation)

        let receipt = await broker.stop(run: run, context: try self.context(scope: moved, revision: refreshed.revision))
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(backend.cancelledStreamIDs == ["stream-1"])
    }

    @Test func transcribeVoiceNoteUsesTheScopedServer() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let request = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x2, count: 24)
        )
        #expect(try await broker.transcribeVoiceNote(request) == "transcribed note")
    }

    @Test func sendVoiceNoteUploadsTheClipAndStartsChatWithTheAttachment() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let audio = Data(repeating: 0x2, count: 24)
        let request = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: session,
            filename: "voice-note-test.m4a",
            audio: audio
        )

        let receipt = await broker.sendVoiceNote(request)

        #expect(receipt.receipt.phase == .acknowledged)
        #expect(receipt.receipt.operationKind == .send)
        #expect(receipt.value?.streamID == "stream-1")
        #expect(receipt.value?.session == session)
        #expect(backend.transcribedFilenames == ["voice-note-test.m4a"])
        #expect(backend.uploaded.map(\.sessionID) == ["s1"])
        #expect(backend.uploaded.map(\.filename) == ["voice-note-test.m4a"])
        #expect(backend.uploaded.map(\.bytes) == [audio.count])
        #expect(backend.startedChats.count == 1)
        #expect(backend.startedChats[0].sessionID == "s1")
        #expect(backend.startedChats[0].message == "transcribed note")
        #expect(backend.startedChats[0].message.contains("[Attached files:") == false)
        let attachments = try #require(backend.startedChats[0].attachments)
        #expect(attachments.count == 1)
        #expect(attachments[0].path == "/tmp/workspace/voice-note-test.m4a")
        #expect(attachments[0].mime == "audio/m4a")
        #expect(attachments[0].isImage == false)
    }

    @Test func sendVoiceNoteRejectsWhenUploadFailsAfterTranscribe() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.failUpload = true
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let request = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x2, count: 24)
        )

        let receipt = await broker.sendVoiceNote(request)

        #expect(receipt.receipt.phase == .rejected)
        #expect(receipt.value == nil)
        #expect(backend.transcribedFilenames == ["voice-note-test.m4a"])
        #expect(backend.startedChats.isEmpty)
    }

    @Test func sendVoiceNoteRejectsWhenTranscribeFails() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.failTranscribe = true
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let request = try WatchVoiceNoteRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: try SessionKey(scope: scope, sessionID: "s1"),
            filename: "voice-note-test.m4a",
            audio: Data(repeating: 0x2, count: 24)
        )

        let receipt = await broker.sendVoiceNote(request)

        #expect(receipt.receipt.phase == .rejected)
        #expect(receipt.value == nil)
        #expect(backend.uploaded.isEmpty)
        #expect(backend.startedChats.isEmpty)
    }

    @Test func derivedServerIDIsStableAndUrlFree() {
        let first = ServerID.derived(from: "https://alpha.example")
        let second = ServerID.derived(from: "https://alpha.example")
        let other = ServerID.derived(from: "https://beta.example")
        #expect(first == second)
        #expect(first != other)
        #expect(first.rawValue.uuidString.contains("://") == false)
    }

    @Test func transcriptProjectsCodeToolAndHonestImageFallback() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: [
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
        )
        backend.transcriptPage = WatchPhoneTranscriptPage(
            blocks: [
                WatchPhoneTranscriptPage.Block(id: "c1", kind: .code(language: "swift", text: "let x = 1", isTruncated: false)),
                WatchPhoneTranscriptPage.Block(id: "t1", kind: .tool(title: "read", state: "done", summary: "ok")),
                WatchPhoneTranscriptPage.Block(id: "i1", kind: .image(path: "/tmp/missing.png", mime: "image/png", alt: "shot")),
            ],
            nextBefore: nil,
            isTruncated: false
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let transcript = try await broker.transcript(
            key: try SessionKey(scope: scope, sessionID: "s1"),
            before: nil,
            limit: 20
        )
        #expect(transcript.value.blocks.count == 3)
        guard case .code(_, "swift", "let x = 1", false) = transcript.value.blocks[0] else {
            Issue.record("expected a code block")
            return
        }
        guard case .tool(_, "read", "done", "ok") = transcript.value.blocks[1] else {
            Issue.record("expected a tool block")
            return
        }
        guard case .unsupported(_, "image", let summary) = transcript.value.blocks[2] else {
            Issue.record("expected an honest image fallback")
            return
        }
        #expect(summary == "shot")
    }

    @Test func transcriptImageBecomesAMediaDescriptorWhenBytesFit() async throws {
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00,
            0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.mediaByPath["/tmp/workspace/shot.png"] = png
        backend.transcriptPage = WatchPhoneTranscriptPage(
            blocks: [
                WatchPhoneTranscriptPage.Block(
                    id: "i1",
                    kind: .image(path: "/tmp/workspace/shot.png", mime: "image/png", alt: "shot")
                ),
            ],
            nextBefore: nil,
            isTruncated: false
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let transcript = try await broker.transcript(key: session, before: nil, limit: 20)
        guard case .image(_, let descriptor, "shot") = transcript.value.blocks[0] else {
            Issue.record("expected an image block")
            return
        }
        let payload = try await broker.media(descriptor)
        #expect(payload.bytes.count == descriptor.byteSize)
        #expect(payload.descriptor.handle.rawValue == "/tmp/workspace/shot.png")
    }

    @Test func sendPhotoUploadsAndStartsChatOnTheComposerPath() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.uploadedIsImage = true
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "s1")
        let image = Data(repeating: 0x3, count: 24)
        let request = try WatchPhotoSendRequest(
            scope: scope,
            expectedRevision: registry.revision,
            session: session,
            filename: "watch-photo.jpg",
            image: image,
            caption: "look"
        )

        let receipt = await broker.sendPhoto(request)

        #expect(receipt.receipt.phase == .acknowledged)
        #expect(receipt.value?.streamID == "stream-1")
        #expect(backend.uploaded.map(\.filename) == ["watch-photo.jpg"])
        #expect(backend.startedChats[0].message.contains("look"))
        #expect(backend.startedChats[0].message.contains("[Attached files:"))
        let attachments = try #require(backend.startedChats[0].attachments)
        #expect(attachments[0].path == "/tmp/workspace/watch-photo.jpg")
        #expect(attachments[0].isImage)
    }

    @Test func sidebarGlancesMapProfilesTasksAndKanbanThroughTheBroker() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.profiles = WatchPhoneProfilePage(
            profiles: [WatchPhoneProfileChoice(name: "default", label: "Default\ngpt-5-6-sol")],
            activeName: "default"
        )
        backend.projects = [WatchPhoneProjectGlance(id: "proj-1", name: "Hermex")]
        backend.tasks = [WatchPhoneTaskGlance(id: "job-1", name: "Standup", schedule: "daily", enabled: true, running: false, lastResult: nil)]
        backend.kanban = [WatchPhoneKanbanCardGlance(
            id: "card-1", title: "Watch layout", status: "running", assignee: "default", priority: 2,
            tenant: "studio", commentCount: 2, linkCount: 1, ageSeconds: 3_700, skills: ["swift"]
        )]
        backend.memory = [WatchPhoneMemoryGlance(section: "memory", text: "Prefer short notes")]
        backend.usage = WatchPhoneUsageGlance(
            days: 30, totalSessions: 4, totalMessages: 12,
            totalInputTokens: 100, totalOutputTokens: 40, totalTokens: 140,
            totalCost: 1.5, models: ["gpt-5-6-sol"]
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        let options = try await broker.composerOptions(scope: scope).value
        #expect(options.profiles.map(\.label) == ["Default\ngpt-5-6-sol"])
        #expect(options.defaultProfileID?.rawValue == "default")
        #expect(options.workspaces.map(\.label) == ["Hermex"])

        let switched = try await broker.switchActiveProfile(scope: scope, name: "builder", expectedRevision: registry.revision)
        #expect(switched == "builder")
        #expect(backend.switchedProfile == "builder")

        let tasks = try await broker.tasks(scope: scope, localLimit: 8).value.items
        #expect(tasks.map(\.name) == ["Standup"])

        backend.kanbanMovePolicy = WatchKanbanMovePolicy.hermes.rawValue
        let cards = try await broker.skills(scope: scope, query: WatchGlanceQuery.kanban, localLimit: 8).value.items
        #expect(cards.first?.key.name == WatchKanbanBoardChrome.cardID)
        let header = try #require(cards.first?.summary)
        let chrome = try #require(WatchKanbanBoardChrome(wireSummary: header))
        #expect(chrome.resolvedMovePolicy == .hermes)
        #expect(WatchKanbanStatus.moveDestinations(from: "todo", policy: chrome.resolvedMovePolicy) == ["triage", "ready"])
        #expect(chrome.name == "Default")
        #expect(chrome.columns == WatchKanbanStatus.boardOrder)
        let cardSummary = try #require(cards.first { $0.key.name == "card-1" })
        let card = WatchKanbanCard(id: cardSummary.key.name, wireSummary: cardSummary.summary)
        #expect(card.title == "Watch layout")
        #expect(card.status == "running")
        #expect(card.assignee == "default")
        #expect(card.priority == 2)
        #expect(card.tenant == "studio")
        #expect(card.commentCount == 2)
        #expect(card.linkCount == 1)
        #expect(card.ageSeconds == 3_700)
        #expect(card.skills == ["swift"])
        _ = try await broker.skills(
            scope: scope,
            query: WatchGlanceQuery.kanban(slug: "ops", includeArchived: true, onlyMine: true),
            localLimit: 8
        )
        #expect(backend.kanbanBoardQuery?.slug == "ops")
        #expect(backend.kanbanBoardQuery?.includeArchived == true)
        #expect(backend.kanbanBoardQuery?.onlyMine == true)

        let memory = try await broker.memoryDocument(scope: scope).value
        #expect(memory.sections.map(\.section) == ["memory"])

        let usage = try await broker.insightsAggregate(scope: scope, days: try InsightsDays(30)).value
        #expect(usage.totalSessions == 4)
        #expect(usage.models.items == ["gpt-5-6-sol"])
    }

    /// A full task list with long names used to exceed `sendMessage` and never
    /// arrive, so Tasks stayed on its spinner. The phone keeps a prefix that fits.
    @Test func oversizedTaskListFitsTheWatchReply() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let fat = String(repeating: "n", count: 900)
        backend.tasks = (0..<40).map { index in
            WatchPhoneTaskGlance(
                id: "job-\(index)",
                name: fat,
                schedule: fat,
                enabled: true,
                running: false,
                lastResult: fat,
                failureSummary: fat
            )
        }
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let fitted = try await broker.tasks(scope: scope, localLimit: 64)
        let encoded = try JSONEncoder().encode(fitted)
        #expect(encoded.count <= WatchVoiceNoteWire.maximumSnapshotJSONBytes)
        #expect(fitted.value.isTruncated)
        #expect(!fitted.value.items.isEmpty)
    }

    @Test func wristWritesReachTheBackendWithTheCurrentRevision() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        let receipt = await broker.controlTask(
            key: try TaskKey(scope: scope, jobID: "job-1"),
            action: .run,
            context: try context(scope: scope, revision: registry.revision)
        )
        #expect(receipt.receipt.phase == .acknowledged)
        #expect(backend.controlledTasks.map(\.action) == ["run"])

        try await broker.setSkillEnabled(scope: scope, name: "web-search", enabled: false, expectedRevision: registry.revision)
        #expect(backend.skillToggles.map(\.enabled) == [false])

        try await broker.moveKanbanCard(scope: scope, cardID: "card-1", status: "Done", boardSlug: "default", expectedRevision: registry.revision)
        #expect(backend.kanbanMoves.map(\.status) == ["Done"])
        #expect(backend.kanbanMoves.map(\.boardSlug) == ["default"])
    }

    /// Reads are fenced only on the scope, writes also on the registry revision.
    /// A watch holding a revision the iPhone has moved past therefore kept
    /// loading every list while every wrist action was rejected.
    @Test func wristWritesAreRejectedWhenTheRevisionIsStale() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let stale = Revision(registry.revision.rawValue + 7)

        // Reads still work on the same stale state.
        _ = try await broker.tasks(scope: scope, localLimit: 8)

        let receipt = await broker.controlTask(
            key: try TaskKey(scope: scope, jobID: "job-1"),
            action: .run,
            context: try context(scope: scope, revision: stale)
        )
        #expect(receipt.receipt.phase == .rejected)
        #expect(backend.controlledTasks.isEmpty)

        await #expect(throws: WatchCompanionError.scopeRejected) {
            try await broker.setSkillEnabled(scope: scope, name: "web-search", enabled: false, expectedRevision: stale)
        }
        await #expect(throws: WatchCompanionError.scopeRejected) {
            try await broker.moveKanbanCard(scope: scope, cardID: "card-1", status: "Done", boardSlug: "default", expectedRevision: stale)
        }
        await #expect(throws: WatchCompanionError.scopeRejected) {
            _ = try await broker.switchActiveProfile(scope: scope, name: "builder", expectedRevision: stale)
        }
        #expect(backend.skillToggles.isEmpty)
        #expect(backend.kanbanMoves.isEmpty)
        #expect(backend.switchedProfile == nil)
    }

    @Test func wristWriteFailureStaysAFailure() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        backend.failWrites = true
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        let receipt = await broker.controlTask(
            key: try TaskKey(scope: scope, jobID: "job-1"),
            action: .pause,
            context: try context(scope: scope, revision: registry.revision)
        )
        #expect(receipt.receipt.phase == .rejected)
        await #expect(throws: (any Error).self) {
            try await broker.setSkillEnabled(scope: scope, name: "web-search", enabled: true, expectedRevision: registry.revision)
        }
    }

    @Test func samePathOnTwoSessionsLoadsBothImages() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let first = Data([1, 2, 3, 4])
        let second = Data([9, 8, 7, 6])
        backend.mediaBySessionAndPath["sess-a|shot.jpg"] = first
        backend.mediaBySessionAndPath["sess-b|shot.jpg"] = second
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        let loadedFirst = try await broker.media(imageDescriptor(scope: scope, sessionID: "sess-a", bytes: first))
        let loadedSecond = try await broker.media(imageDescriptor(scope: scope, sessionID: "sess-b", bytes: second))

        #expect(loadedFirst.bytes == first)
        #expect(loadedSecond.bytes == second)
    }

    @Test func aReplacedImageOfTheSameSizeIsFetchedAgain() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let first = Data([1, 2, 3, 4])
        let second = Data([9, 8, 7, 6])
        backend.mediaByPath["shot.jpg"] = first
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)

        _ = try await broker.media(imageDescriptor(scope: scope, sessionID: "sess-a", bytes: first))
        backend.mediaByPath["shot.jpg"] = second
        let replaced = try await broker.media(imageDescriptor(scope: scope, sessionID: "sess-a", bytes: second))

        #expect(replaced.bytes == second)
    }

    @Test func aFailedImageRetryKeepsTheRealPathBehindAHashHandle() async throws {
        let backend = ScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")],
            sessions: []
        )
        let longPath = "/" + String(repeating: "workspace/", count: 40) + "shot.jpg"
        #expect(longPath.utf8.count > 256)
        backend.mediaByPath[longPath] = tinyJPEG()
        backend.transcriptPage = WatchPhoneTranscriptPage(
            blocks: [WatchPhoneTranscriptPage.Block(id: "img", kind: .image(path: longPath, mime: "image/jpeg", alt: nil))],
            nextBefore: nil,
            isTruncated: false
        )
        let broker = makeBroker(backend)
        let registry = await broker.registry()
        let scope = try #require(registry.entries.first?.scope)
        let session = try SessionKey(scope: scope, sessionID: "sess-a")
        let transcript = try await broker.transcript(key: session, before: nil, limit: 8)
        let descriptor: WatchMediaDescriptor
        if case .image(_, let image, _) = transcript.value.blocks.first {
            descriptor = image
        } else {
            Issue.record("The long path should arrive as an image, not a hash the server cannot open")
            return
        }
        #expect(descriptor.handle.rawValue != longPath)

        backend.failMedia = true
        backend.mediaPaths = []
        let replacement = Data([9, 8, 7, 6])
        let asking = try imageDescriptor(
            scope: scope,
            sessionID: "sess-a",
            bytes: replacement,
            handle: descriptor.handle.rawValue
        )
        await #expect(throws: (any Error).self) { try await broker.media(asking) }
        await #expect(throws: (any Error).self) { try await broker.media(asking) }
        #expect(backend.mediaPaths == [longPath, longPath])
    }

    @Test func issuedRunsStayStoppableForSixHoursAndThenExpire() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermex-issued-runs-\(UUID().uuidString)", isDirectory: true)
        let store = WatchIssuedRunFileStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID.derived(from: "https://alpha.example"),
            generation: try Generation(1)
        )
        let run = try RunKey(session: SessionKey(scope: scope, sessionID: "sess-a"), streamID: "stream-1")
        store.save([run])
        #expect(store.load().map(\.streamID) == ["stream-1"])

        let file = directory.appendingPathComponent("hermex-watch-issued-runs.json")
        let fresh = try JSONDecoder().decode([StampedIssuedRun].self, from: Data(contentsOf: file))
        let aged = fresh.map { StampedIssuedRun(run: $0.run, savedAt: Date().addingTimeInterval(-(7 * 60 * 60))) }
        try JSONEncoder().encode(aged).write(to: file)
        #expect(store.load().isEmpty)

        let stillValid = fresh.map { StampedIssuedRun(run: $0.run, savedAt: Date().addingTimeInterval(-(5 * 60 * 60))) }
        try JSONEncoder().encode(stillValid).write(to: file)
        store.save([run])
        let kept = try JSONDecoder().decode([StampedIssuedRun].self, from: Data(contentsOf: file))
        let savedAt = try #require(kept.first?.savedAt)
        #expect(abs(savedAt.timeIntervalSinceNow) > 4 * 60 * 60)
    }

    private func imageDescriptor(
        scope: ServerScope,
        sessionID: String,
        bytes: Data,
        handle: String = "shot.jpg"
    ) throws -> WatchMediaDescriptor {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        return try WatchMediaDescriptor(
            scope: scope,
            session: SessionKey(scope: scope, sessionID: sessionID),
            origin: OriginBinding(digest: digest),
            handle: MediaHandle(handle),
            mimeType: "image/jpeg",
            byteSize: bytes.count,
            sha256: digest,
            observedAt: observed,
            expiresAt: observed.addingTimeInterval(120)
        )
    }

    private func context(scope: ServerScope, revision: Revision) throws -> CommandContext {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return try CommandContext(
            stableCommandID: CommandID(rawValue: UUID()),
            scope: scope,
            expectedRevision: revision,
            createdAt: created,
            expiresAt: created.addingTimeInterval(60)
        )
    }
}

private func tinyJPEG() -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let image = context?.makeImage() else { return Data() }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
        return Data()
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Mirrors the phone's issued-run file so a test can age a stamp without
/// calling the clock inside the store.
private struct StampedIssuedRun: Codable {
    var run: RunKey
    var savedAt: Date
}
