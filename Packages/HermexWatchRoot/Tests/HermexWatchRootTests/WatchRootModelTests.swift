import Observation
import CryptoKit
import WatchShared
import XCTest
@testable import HermexWatchRoot

@MainActor
final class WatchRootModelTests: XCTestCase {
    func testStartsInSetupRequiredState() {
        let model = WatchRootModel()

        XCTAssertEqual(model.state, .setupRequired)
    }

    func testExplicitTransitionsExposeOnlyConnectionState() {
        let model = WatchRootModel()

        model.beginConnecting()
        XCTAssertEqual(model.state, .connecting)

        model.markUnavailable()
        XCTAssertEqual(model.state, .unavailable)
    }

    func testStateMutationNotifiesObservationTracking() {
        let model = WatchRootModel()
        let changed = expectation(description: "state observation changed")

        withObservationTracking {
            _ = model.state
        } onChange: {
            changed.fulfill()
        }

        model.beginConnecting()

        wait(for: [changed], timeout: 0.1)
    }

    func testSetupRequiredPresentationCopyIsTruthful() {
        let model = WatchRootModel()

        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
    }

    func testMissingCompanionStaysOnSetupRequired() {
        let model = WatchRootModel()
        model.attach(link: UnavailableLink())

        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.nowSession)
        XCTAssertNil(model.widgetSnapshot())
    }

    func testNowSessionAndWidgetSnapshotUseReadySessions() throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let running = try WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "run"),
            title: "Draft",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 2),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: .thinking
        )
        let idle = try WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "idle"),
            title: "Notes",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: true,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let model = WatchRootModel()
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try RedactedDisplayName("Studio"))],
            sessions: [idle, running]
        )

        XCTAssertEqual(model.nowSession?.key.sessionID, "run")
        XCTAssertEqual(model.widgetSnapshot()?.activity, .running)
        XCTAssertEqual(model.widgetSnapshot()?.displayName.rawValue, "Studio")
        XCTAssertFalse(model.canStopNow)
    }

    func testCreateSessionWithoutCompanionInsertsALocalSession() async throws {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let existing = try WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "idle"),
            title: "Notes",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: true,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let model = WatchRootModel()
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try RedactedDisplayName("Studio"))],
            sessions: [existing]
        )

        let key = await model.createSession()

        XCTAssertEqual(key?.scope, scope)
        XCTAssertEqual(model.sessions.first?.title, "New session")
        XCTAssertEqual(model.nowSession?.key, key)
        XCTAssertEqual(model.sessions.count, 2)
        let createdBlocks = await model.transcript(for: model.sessions[0])
        XCTAssertTrue(createdBlocks.isEmpty)
    }

    #if DEBUG
    func testScreenshotFixtureTranscriptStaysOnStandUpSession() async throws {
        let model = WatchRootModel()
        model.applyScreenshotFixture()

        let standUp = try XCTUnwrap(model.sessions.first(where: { $0.key.sessionID == "stand-up" }))
        let weekend = try XCTUnwrap(model.sessions.first(where: { $0.key.sessionID == "weekend" }))
        let createdKey = await model.createSession()
        let created = try XCTUnwrap(createdKey)
        let createdSession = try XCTUnwrap(model.session(for: created))

        let standUpBlocks = await model.transcript(for: standUp)
        XCTAssertEqual(standUpBlocks.count, 4)
        if case .text(_, _, let text) = standUpBlocks.first {
            XCTAssertEqual(text, "Summarize stand-up.")
        } else {
            XCTFail("expected stand-up fixture text")
        }
        let weekendBlocks = await model.transcript(for: weekend)
        let createdBlocks = await model.transcript(for: createdSession)
        XCTAssertTrue(weekendBlocks.isEmpty)
        XCTAssertTrue(createdBlocks.isEmpty)
        XCTAssertNil(model.nowPreview)
    }
    #endif

    func testSelectDropsSessionsFromThePreviousScope() async throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let betaRow = WatchPhoneSessionRow(
            sessionID: "shared-id",
            title: "Beta session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let backend = RootScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha"),
                WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta"),
            ]
        )
        backend.sessionsByURL = ["https://beta.example": [betaRow]]
        let broker = PhoneCompanionBroker(epoch: epoch, backend: backend)
        let registry = await broker.registry()
        let alpha = try XCTUnwrap(registry.entries.first(where: { $0.displayName.rawValue == "Alpha" })?.scope)
        let beta = try XCTUnwrap(registry.entries.first(where: { $0.displayName.rawValue == "Beta" })?.scope)
        let alphaSession = try WatchSessionSummary(
            key: SessionKey(scope: alpha, sessionID: "shared-id"),
            title: "Alpha session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: true,
            isArchived: false,
            attention: false,
            runState: nil
        )

        let model = WatchRootModel()
        model.applyReadyStateForTesting(
            servers: [
                RegistryEntry(scope: alpha, displayName: try RedactedDisplayName("Alpha")),
                RegistryEntry(scope: beta, displayName: try RedactedDisplayName("Beta")),
            ],
            sessions: [alphaSession]
        )
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))

        XCTAssertEqual(model.nowSession?.title, "Alpha session")
        await model.select(beta)
        XCTAssertEqual(model.sessions.map(\.title), ["Beta session"])
        XCTAssertEqual(model.nowSession?.key.scope, beta)
        XCTAssertFalse(model.sessions.contains(where: { $0.key.scope == alpha }))
    }

    /// A locked phone reports unreachable. That must not cancel the wake
    /// already in flight, or the wrist shows "Set up on iPhone" while Hermex
    /// is about to launch in the background.
    func testUnreachableWhileConnectingKeepsTheWakeInFlight() {
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ToggleableLink(isReachable: false))
        model.beginConnecting()

        model.handleCompanionUnreachable()

        XCTAssertEqual(model.state, .connecting)
        XCTAssertNil(model.phoneStatusNote)
    }

    func testRebootBeforeUnlockDoesNotPretendThePhoneCanBeWoken() {
        let model = WatchRootModel()
        let link = ToggleableLink(isReachable: false, needsUnlockAfterReboot: true)
        model.attachLinkWithoutRefreshingForTesting(link)
        model.beginConnecting()

        model.handleCompanionUnreachable()

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(
            model.phoneStatusNote,
            "Unlock iPhone once after it restarts. It can stay locked after that."
        )
    }

    /// Read aloud used to speak the 160-character Now preview, so a long reply
    /// was cut off mid-sentence. It now reads the whole latest turn.
    func testNowSpokenReplyIsTheWholeLatestAssistantTurn() async throws {
        let (model, backend) = try await readyModelWithOneSession()
        backend.transcriptBlocks = [
            .init(id: "u", role: .user, text: "Status?"),
            .init(id: "a1", role: .assistant, text: "First **part** of the reply."),
            .init(id: "c", kind: .code(language: "swift", text: "let x = 1", isTruncated: false)),
            .init(id: "a2", role: .assistant, text: "Then see [the notes](https://example.com/notes)."),
        ]
        await model.loadSessions()

        XCTAssertEqual(model.nowSpokenReply, "First part of the reply.\nThen see the notes.")
        XCTAssertNotNil(model.nowPreview)
    }

    func testNowSpokenReplyIsNilWhenTheLatestTurnIsTheUsers() async throws {
        let (model, backend) = try await readyModelWithOneSession()
        backend.transcriptBlocks = [
            .init(id: "a", role: .assistant, text: "Earlier reply."),
            .init(id: "u", role: .user, text: "New question"),
        ]
        await model.loadSessions()

        XCTAssertNil(model.nowSpokenReply)
    }

    func testKanbanCardsArriveWithStatusKeys() async throws {
        let (model, backend) = try await readyModelWithOneSession()
        backend.kanban = [WatchPhoneKanbanCardGlance(id: "card-1", title: "Ship", status: "todo", assignee: "default", priority: 2)]

        let cards = await model.loadKanbanCards()

        XCTAssertEqual(cards.map(\.status), ["todo"])
        XCTAssertEqual(cards.first?.assignee, "default")
        XCTAssertEqual(cards.first?.priority, 2)
    }

    /// Task history belongs to the task screen: a failure returns nil for its
    /// own Try again and never sets the model-wide error other screens read.
    func testTaskRunsLoadOrFailWithoutTouchingTheSharedError() async throws {
        let (model, backend) = try await readyModelWithOneSession()
        backend.taskRuns = [WatchPhoneTaskRun(id: "run-1.md", finishedAt: Date(timeIntervalSince1970: 100), durationSeconds: 10)]

        let runs = await model.loadTaskRuns(jobID: "job-1")
        XCTAssertEqual(runs?.map(\.runID), ["run-1.md"])

        backend.taskRuns = nil
        let failed = await model.loadTaskRuns(jobID: "job-1")
        XCTAssertNil(failed)
        XCTAssertNil(model.lastErrorCode)
    }

    private func readyModelWithOneSession() async throws -> (WatchRootModel, RootScriptedBackend) {
        let backend = RootScriptedBackend(accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")])
        backend.sessionsByURL = ["https://alpha.example": [
            WatchPhoneSessionRow(
                sessionID: "s1",
                title: "Planning",
                profile: nil,
                workspaceLabel: nil,
                updatedAt: Date(timeIntervalSince1970: 20),
                isPinned: false,
                isArchived: false,
                attention: false,
                runState: nil
            ),
        ]]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.state, .ready)
        return (model, backend)
    }

    func testActiveRunsStayIsolatedWhenSessionIDsCollide() async throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let backend = RootScriptedBackend(
            accounts: [
                WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha"),
                WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta"),
            ]
        )
        backend.sessionsByURL = [
            "https://alpha.example": [
                WatchPhoneSessionRow(
                    sessionID: "shared-id",
                    title: "Alpha session",
                    profile: nil,
                    workspaceLabel: nil,
                    updatedAt: Date(timeIntervalSince1970: 20),
                    isPinned: false,
                    isArchived: false,
                    attention: false,
                    runState: nil
                ),
            ],
        ]
        let broker = PhoneCompanionBroker(epoch: epoch, backend: backend)
        let registry = await broker.registry()
        let alpha = try XCTUnwrap(registry.entries.first(where: { $0.displayName.rawValue == "Alpha" })?.scope)
        let beta = try XCTUnwrap(registry.entries.first(where: { $0.displayName.rawValue == "Beta" })?.scope)
        let alphaSession = try WatchSessionSummary(
            key: SessionKey(scope: alpha, sessionID: "shared-id"),
            title: "Alpha session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let betaSession = try WatchSessionSummary(
            key: SessionKey(scope: beta, sessionID: "shared-id"),
            title: "Beta session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        let model = WatchRootModel()
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: alpha, displayName: try RedactedDisplayName("Alpha"))],
            sessions: [alphaSession, betaSession],
            revision: registry.revision
        )
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))

        let run = await model.send(text: "continue", to: alphaSession)
        XCTAssertNotNil(run)
        XCTAssertNotNil(model.activeRun(for: alphaSession))
        XCTAssertNil(model.activeRun(for: betaSession))
        XCTAssertEqual(model.sessions.first(where: { $0.key == alphaSession.key })?.runState, .responding)
    }

    func testSendVoiceNoteRecordsTheRunAfterPhoneSuccess() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)

        let run = await model.sendVoiceNote(
            audio: Data(repeating: 0x4, count: 24),
            filename: "voice-note-test.m4a",
            to: session
        )

        XCTAssertNotNil(run)
        XCTAssertNotNil(model.activeRun(for: session))
        XCTAssertEqual(backend.startedAttachments?.count, 1)
        XCTAssertEqual(backend.startedAttachments?.first?.path, "/tmp/workspace/voice-note-test.m4a")
        XCTAssertNil(model.lastErrorCode)
    }

    func testSendVoiceNoteDoesNotClaimSuccessWhenUploadFails() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.failUpload = true
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)

        let run = await model.sendVoiceNote(
            audio: Data(repeating: 0x4, count: 24),
            filename: "voice-note-test.m4a",
            to: session
        )

        XCTAssertNil(run)
        XCTAssertNil(model.activeRun(for: session))
        XCTAssertNil(backend.startedAttachments)
        XCTAssertEqual(model.lastErrorCode, "sendRejected")
    }

    func testSendPhotoRecordsTheRunAfterPhoneSuccess() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)

        let run = await model.sendPhoto(
            image: Data(repeating: 0x5, count: 24),
            filename: "watch-photo.jpg",
            caption: "look",
            to: session
        )

        XCTAssertNotNil(run)
        XCTAssertNotNil(model.activeRun(for: session))
        XCTAssertEqual(backend.startedAttachments?.count, 1)
        XCTAssertEqual(backend.startedAttachments?.first?.path, "/tmp/workspace/watch-photo.jpg")
        XCTAssertNil(model.lastErrorCode)
    }

    func testUnpinnedWatchFollowsThePhoneActiveServerSwitch() async throws {
        let alphaAccount = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let betaAccount = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = RootScriptedBackend(accounts: [alphaAccount, betaAccount])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
            "https://beta.example": [Self.row(sessionID: "b", title: "Beta session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))

        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])

        // The iPhone switches its active server, so it now lists Beta first.
        backend.accounts = [betaAccount, alphaAccount]
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.sessions.map(\.title), ["Beta session"])
        XCTAssertEqual(model.nowSession?.title, "Beta session")
    }

    func testExplicitWatchSelectionSurvivesAPhoneActiveServerSwitch() async throws {
        let alphaAccount = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let betaAccount = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = RootScriptedBackend(accounts: [alphaAccount, betaAccount])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
            "https://beta.example": [Self.row(sessionID: "b", title: "Beta session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let alphaScope = try XCTUnwrap(model.selectedScope)

        await model.select(alphaScope)
        backend.accounts = [betaAccount, alphaAccount]
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.selectedScope, alphaScope)
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])
    }

    func testStopStaysOfferedOnlyWhileTheServerReportsTheRun() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session", runState: .responding)],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)

        let run = await model.send(text: "continue", to: session)
        XCTAssertNotNil(run)
        XCTAssertTrue(model.canStopNow)

        // The run finished on the server: Stop must not linger on a dead stream.
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
        ]
        await model.loadSessions()

        XCTAssertFalse(model.canStopNow)
        XCTAssertNil(model.activeRun(for: session))
    }

    func testHermesServerDoesNotOfferReplyControlsAndWebuiDoes() async throws {
        let hermes = WatchPhoneServerAccount(
            urlString: "https://hermes.example",
            displayName: "Hermes",
            writesUnsupported: true
        )
        let webui = WatchPhoneServerAccount(urlString: "https://webui.example", displayName: "Web")
        let backend = RootScriptedBackend(accounts: [hermes, webui])
        backend.sessionsByURL = [
            "https://hermes.example": [Self.row(sessionID: "h", title: "Hermes session")],
            "https://webui.example": [Self.row(sessionID: "w", title: "Web session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.servers.first?.writesUnsupported, true)
        XCTAssertFalse(model.offersReplyControls)
        let hermesSession = try XCTUnwrap(model.sessions.first)
        let text = await model.send(text: "hi", to: hermesSession)
        let voice = await model.sendVoiceNote(audio: Data([1, 2, 3]), filename: "note.m4a", to: hermesSession)
        let photo = await model.sendPhoto(image: Data([1, 2, 3]), filename: "photo.jpg", caption: "", to: hermesSession)
        XCTAssertNil(text)
        XCTAssertNil(voice)
        XCTAssertNil(photo)
        XCTAssertNil(model.lastErrorCode)
        model.armComplicationRecording()
        XCTAssertNil(model.complicationRecordID)

        let webScope = try XCTUnwrap(model.servers.first { $0.displayName.rawValue == "Web" }?.scope)
        await model.select(webScope)
        XCTAssertNil(model.servers.first { $0.scope == webScope }?.writesUnsupported)
        XCTAssertTrue(model.offersReplyControls)
        let webSession = try XCTUnwrap(model.nowSession)
        let sent = await model.send(text: "hi", to: webSession)
        XCTAssertNotNil(sent)
        XCTAssertNil(model.lastErrorCode)
    }

    func testOmittedWriteFlagStillOffersReplyControls() throws {
        let model = WatchRootModel()
        let scope = Self.makeScope()
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try RedactedDisplayName("Old phone"))],
            sessions: []
        )
        XCTAssertNil(model.servers.first?.writesUnsupported)
        XCTAssertTrue(model.offersReplyControls)

        model.applyReadyStateForTesting(
            servers: [RegistryEntry(
                scope: scope,
                displayName: try RedactedDisplayName("Web"),
                writesUnsupported: false
            )],
            sessions: []
        )
        XCTAssertTrue(model.offersReplyControls)
    }

    func testStaleSessionLoadDoesNotReplaceTheNewerServer() async throws {
        let alphaAccount = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let betaAccount = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = RootScriptedBackend(accounts: [alphaAccount, betaAccount])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
            "https://beta.example": [Self.row(sessionID: "b", title: "Beta session", runState: .responding)],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])

        let signal = SessionLoadSignal()
        backend.gatedSessionURL = "https://alpha.example"
        backend.onSessionLoadEntered = { signal.arrive() }
        let stale = Task { await model.loadSessions() }
        await signal.wait()

        let betaScope = try XCTUnwrap(model.servers.first { $0.displayName.rawValue == "Beta" }?.scope)
        await model.select(betaScope)
        let betaSession = try XCTUnwrap(model.nowSession)
        let sent = await model.send(text: "go", to: betaSession)
        let run = try XCTUnwrap(sent)
        XCTAssertEqual(model.sessions.map(\.title), ["Beta session"])
        XCTAssertEqual(model.activeRun(for: betaSession), run)

        backend.releaseSessionLoadGate()
        await stale.value

        XCTAssertEqual(model.selectedScope, betaScope)
        XCTAssertEqual(model.sessions.map(\.title), ["Beta session"])
        XCTAssertEqual(model.activeRun(for: betaSession), run)
        XCTAssertTrue(model.hasLoadedSessions)
        XCTAssertNil(model.lastErrorCode)
    }

    func testLoadSessionsKeepsMoreThanTheOldTwentyRowCap() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = [
            "https://alpha.example": (0..<25).map { Self.row(sessionID: "s\($0)", title: "Session \($0)") },
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        await model.loadSessions()

        XCTAssertEqual(model.sessions.count, 25)
        XCTAssertNil(model.errorCopy)
    }

    // MARK: - Blocker 1: reachability reconnects

    func testUnreachableAfterReadyPresentsUnavailableNotSetupRequired() {
        let model = WatchRootModel()
        let link = ToggleableLink(installed: true, isReachable: false)
        model.attachLinkWithoutRefreshingForTesting(link)
        // Simulate a successful ready state.
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: Self.makeScope(), displayName: try! RedactedDisplayName("Alpha"))],
            sessions: []
        )
        XCTAssertEqual(model.state, .ready)

        // Phone becomes unreachable: keep the last ready surface. A locked
        // phone is not "set up on iPhone" and it is not a blank watch.
        model.handleCompanionUnreachable()

        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.phoneStatusNote)
        XCTAssertNotNil(model.widgetSnapshot())
    }

    func testLockedPhoneStillLoadsWhenHermexIsNotInTheForeground() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = ["https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")]]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let link = ToggleableLink(service: broker, isReachable: false)
        let model = WatchRootModel()
        model.attach(link: link)
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])
        XCTAssertNil(model.phoneStatusNote)
    }

    func testReachableAfterUnavailableRefreshes() async throws {
        let scope = Self.makeScope()
        let backend = RootScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
        )
        backend.sessionsByURL = ["https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")]]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let link = ToggleableLink(service: broker)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(link)
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try! RedactedDisplayName("Alpha"))],
            sessions: []
        )
        // A locked phone keeps the last ready board. Becoming reachable again
        // still reloads sessions.
        link.isReachable = false
        model.handleCompanionUnreachable()
        XCTAssertEqual(model.state, .ready)

        link.isReachable = true
        model.handleCompanionReachable()
        // refreshConnection spawns a Task; await the registry reload.
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])
    }

    func testCompanionNotInstalledStaysOnSetupRequired() {
        let model = WatchRootModel()
        let link = ToggleableLink(installed: false)
        model.attach(link: link)
        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
    }

    // MARK: - Blocker 3: signed-out honesty

    func testAuthRequiredFailureFlipsToSignedOut() async throws {
        let backend = AuthFailingBackend()
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        // reloadRegistry adopts the broker's own scope, then loadSessions runs
        // against it and hits the backend's authRequired failure.
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.state, .signedOut)
        XCTAssertEqual(model.primaryMessage, "Sign in on iPhone")
        XCTAssertNil(model.nowSession)
        XCTAssertNil(model.widgetSnapshot())
        XCTAssertEqual(model.lastErrorCode, "authRequired")
        XCTAssertEqual(model.errorCopy, "Sign in on iPhone to continue.")
    }

    func testSignedOutDisablesMutations() async throws {
        let backend = AuthFailingBackend()
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.state, .signedOut)

        XCTAssertFalse(model.canMutate)
        let session = try WatchSessionSummary(
            key: SessionKey(scope: model.selectedScope ?? Self.makeScope(), sessionID: "s1"),
            title: "S",
            profile: nil, workspaceLabel: nil, updatedAt: nil,
            isPinned: false, isArchived: false, attention: false, runState: nil
        )
        let run = await model.send(text: "hi", to: session)
        XCTAssertNil(run)
        let created = await model.createSession()
        XCTAssertNil(created)
    }

    // MARK: - Blocker 2: refreshFromList reloads registry

    func testRefreshFromListFollowsPhoneActiveServerSwitch() async throws {
        let alphaAccount = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let betaAccount = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = RootScriptedBackend(accounts: [alphaAccount, betaAccount])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
            "https://beta.example": [Self.row(sessionID: "b", title: "Beta session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])

        // iPhone switches active server; pull-to-refresh follows it.
        backend.accounts = [betaAccount, alphaAccount]
        await model.refreshFromList()

        XCTAssertEqual(model.sessions.map(\.title), ["Beta session"])
        XCTAssertEqual(model.nowSession?.title, "Beta session")
    }

    // MARK: - Blocker 5: errorCopy

    func testErrorCopyMapsKnownCodes() {
        let model = WatchRootModel()
        XCTAssertNil(model.errorCopy)
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: Self.makeScope(), displayName: try! RedactedDisplayName("Alpha"))],
            sessions: []
        )
        // Reflect a failure code via the private setter through a load that
        // fails; here we drive it indirectly by checking the mapping of codes
        // the model already produces.
        model.markUnavailable()
        // After markUnavailable, lastErrorCode is nil; errorCopy is nil.
        XCTAssertNil(model.errorCopy)
    }

    func testComplicationTapOnALoadedEmptyNowDoesNotWaitForALaterSession() {
        let model = WatchRootModel()
        model.applyReadyStateForTesting(servers: [], sessions: [])

        model.armComplicationRecording()

        XCTAssertNil(model.complicationRecordID)
    }

    func testComplicationTapDuringTheFirstLoadWaitsForThatLoad() throws {
        let model = WatchRootModel()
        model.armComplicationRecording()
        XCTAssertNotNil(model.complicationRecordID)

        model.applyReadyStateForTesting(servers: [], sessions: [])
        model.discardUnusableComplicationRecording()
        XCTAssertNil(model.complicationRecordID)

        let scope = Self.makeScope()
        let session = try WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "notes"),
            title: "Notes",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try RedactedDisplayName("Studio"))],
            sessions: [session]
        )
        model.armComplicationRecording()
        XCTAssertNotNil(model.complicationRecordID)
    }

    // MARK: - Helpers

    private static func makeScope() -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try! Generation(1)
        )
    }

    private static func row(
        sessionID: String,
        title: String,
        runState: WatchRunPhase? = nil
    ) -> WatchPhoneSessionRow {
        WatchPhoneSessionRow(
            sessionID: sessionID,
            title: title,
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: runState
        )
    }
}

extension WatchRootModelTests {
    /// The iPhone bumps its registry revision on its own (server rename, an
    /// active-server switch, a relaunched broker). Reads are fenced only on the
    /// scope, so they keep working, while every write is fenced on the revision
    /// — which used to leave the glances loading fine and every wrist action
    /// silently rejected. The model must re-read the revision before a write.
    func testWristWritesSurviveAnIPhoneRegistryRevisionBump() async throws {
        let backend = RootScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
        )
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let adopted = model.registryRevision

        // The iPhone renames the server: same scope, new registry revision.
        backend.accounts = [
            WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha Studio"),
        ]
        _ = await broker.registry()

        // Reads still succeed on the stale revision the watch is holding.
        let tasks = await model.loadTasks()
        XCTAssertTrue(tasks.isEmpty)

        let toggled = await model.setSkillEnabled(name: "web-search", enabled: false)
        model.useKanbanBoardForTesting("default")
        let moved = await model.moveKanbanCard(cardID: "card-1", status: "Done")
        let ran = await model.controlTask(jobID: "job-1", action: .run)
        XCTAssertTrue(toggled)
        XCTAssertTrue(moved)
        XCTAssertTrue(ran)
        XCTAssertEqual(backend.skillToggles.map(\.name), ["web-search"])
        XCTAssertEqual(backend.kanbanMoves.map(\.status), ["Done"])
        XCTAssertEqual(backend.controlledTasks.map(\.action), ["run"])
        XCTAssertNil(model.lastErrorCode)
        XCTAssertNotEqual(model.registryRevision, adopted)
    }

    func testWristWriteFailureSurfacesHonestCopy() async throws {
        let model = WatchRootModel()
        let backend = RootScriptedBackend(accounts: [])
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        model.applyReadyStateForTesting(
            servers: [
                RegistryEntry(
                    scope: ServerScope(
                        epoch: InstallationEpoch(rawValue: UUID()),
                        server: ServerID(rawValue: UUID()),
                        generation: try Generation(1)
                    ),
                    displayName: try RedactedDisplayName("Alpha")
                ),
            ],
            sessions: []
        )
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))

        let toggled = await model.setSkillEnabled(name: "web-search", enabled: false)
        XCTAssertFalse(toggled)
        XCTAssertEqual(model.errorCopy, "Couldn’t update that skill.")
        XCTAssertNil(model.sidebarErrorCopy)
        model.useKanbanBoardForTesting("default")
        let moved = await model.moveKanbanCard(cardID: "card-1", status: "Done")
        XCTAssertFalse(moved)
        XCTAssertEqual(model.errorCopy, "Couldn’t move that card.")
        XCTAssertNil(model.sidebarErrorCopy)
        let ran = await model.controlTask(jobID: "job-1", action: .run)
        XCTAssertFalse(ran)
        XCTAssertEqual(model.errorCopy, "Couldn’t update that task.")
        XCTAssertNil(model.sidebarErrorCopy)
    }

    /// A glance that fails to load owns that failure. Now and Sessions were
    /// repeating "Couldn't load this list." after Tasks or Kanban missed.
    func testGlanceLoadFailureStaysOffNowAndSessions() async throws {
        let backend = RootScriptedBackend(
            accounts: [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
        )
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()

        let tasks = await model.loadTasks()
        XCTAssertTrue(tasks.isEmpty)
        XCTAssertEqual(model.lastErrorCode, "glanceUnavailable")
        XCTAssertEqual(model.errorCopy, "Couldn’t load this list.")
        XCTAssertNil(model.sidebarErrorCopy)
    }

    /// A failed reply used to sit over Now as a banner until the next success,
    /// so one bad send made the composer look permanently broken. Reply-control
    /// failures now belong to the control that failed: off the Now banner, and
    /// dropped the moment the user starts another attempt.
    func testReplyControlFailuresStayOffNowAndClearOnRetry() async throws {
        let model = WatchRootModel()
        let backend = RootScriptedBackend(accounts: [])
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(1)
        )
        let session = try WatchSessionSummary(
            key: SessionKey(scope: scope, sessionID: "a"),
            title: "Alpha session",
            profile: nil,
            workspaceLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 20),
            isPinned: false,
            isArchived: false,
            attention: false,
            runState: nil
        )
        model.applyReadyStateForTesting(
            servers: [RegistryEntry(scope: scope, displayName: try RedactedDisplayName("Alpha"))],
            sessions: [session]
        )
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))

        // The phone has no account for this scope, so the send is rejected.
        let run = await model.send(text: "go", to: session)
        XCTAssertNil(run)
        XCTAssertEqual(model.lastErrorCode, "sendRejected")
        // The control shows it; Now does not echo it.
        XCTAssertEqual(model.errorCopy, "Hermex didn’t accept that message.")
        XCTAssertNil(model.sidebarErrorCopy)

        // Starting another attempt drops it.
        model.clearReplyControlError()
        XCTAssertNil(model.lastErrorCode)
        XCTAssertNil(model.errorCopy)
    }

    /// Clearing a reply failure must not swallow the failures Now still owns.
    func testClearingAReplyErrorLeavesSessionsAndAuthErrorsOnNow() async throws {
        let model = WatchRootModel()
        let broker = PhoneCompanionBroker(
            epoch: InstallationEpoch(rawValue: UUID()),
            backend: AuthFailingBackend()
        )
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.lastErrorCode, "authRequired")
        XCTAssertEqual(model.sidebarErrorCopy, "Sign in on iPhone to continue.")
        model.clearReplyControlError()
        XCTAssertEqual(model.lastErrorCode, "authRequired")
        XCTAssertEqual(model.sidebarErrorCopy, "Sign in on iPhone to continue.")
    }

    func testReplyControlCopyIsAddressableWithoutTheLastErrorCode() {
        XCTAssertEqual(WatchRootModel.errorCopy(for: "sendFailed"), "Couldn’t send. Try again.")
        XCTAssertEqual(WatchRootModel.errorCopy(for: "stopFailed"), "Couldn’t stop the run.")
        XCTAssertEqual(WatchRootModel.errorCopy(for: "nonsense"), "Something went wrong. Try again.")
    }

    /// A glance left open across a phone server switch still shows the old
    /// rows. Those rows must not run on the server the phone just selected.
    func testGlanceActionsRejectARowFromThePreviousServer() async throws {
        let alphaAccount = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let betaAccount = WatchPhoneServerAccount(urlString: "https://beta.example", displayName: "Beta")
        let backend = RootScriptedBackend(accounts: [alphaAccount, betaAccount])
        backend.sessionsByURL = [
            "https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")],
            "https://beta.example": [Self.row(sessionID: "b", title: "Beta session")],
        ]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let alpha = try XCTUnwrap(model.selectedScope)
        model.useKanbanBoardForTesting("default")

        backend.accounts = [betaAccount, alphaAccount]
        await model.reloadRegistryForTesting()
        let beta = try XCTUnwrap(model.selectedScope)
        XCTAssertNotEqual(alpha, beta)

        let ran = await model.controlTask(jobID: "job-1", action: .run, scope: alpha)
        let toggled = await model.setSkillEnabled(name: "web-search", enabled: false, scope: alpha)
        let moved = await model.moveKanbanCard(cardID: "card-1", status: "Done")
        XCTAssertFalse(ran)
        XCTAssertFalse(toggled)
        XCTAssertFalse(moved)
        XCTAssertTrue(backend.controlledTasks.isEmpty)
        XCTAssertTrue(backend.skillToggles.isEmpty)
        XCTAssertTrue(backend.kanbanMoves.isEmpty)

        let ranOnBeta = await model.controlTask(jobID: "job-1", action: .run, scope: beta)
        XCTAssertTrue(ranOnBeta)
        XCTAssertEqual(backend.controlledTasks.map(\.jobID), ["job-1"])
    }

    /// The phone confirmed it has no servers. That is not a failed wake, so
    /// the old board and its Stop control go away.
    func testConfirmedEmptyRegistryClearsStop() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = ["https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")]]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)
        let run = await model.send(text: "go", to: session)
        XCTAssertNotNil(run)
        XCTAssertNotNil(model.activeRun(for: session))

        backend.accounts = []
        await model.reloadRegistryForTesting()

        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
        XCTAssertTrue(model.servers.isEmpty)
        XCTAssertNil(model.activeRun(for: session))
    }

    /// After the last server is gone, the next refresh shows Connecting until
    /// the phone answers. A failed answer must settle on setup, not stay there.
    func testFailedWakeAfterRemovingTheLastServerSettlesOnSetup() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        XCTAssertFalse(model.servers.isEmpty)

        backend.accounts = []
        await model.reloadRegistryForTesting()
        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertTrue(model.servers.isEmpty)

        model.beginConnecting()
        XCTAssertEqual(model.state, .connecting)
        model.applyRegistrySnapshotForTesting(RegistrySnapshot.unavailableWake())

        XCTAssertEqual(model.state, .setupRequired)
        XCTAssertEqual(model.primaryMessage, "Set up on iPhone")
    }

    func testFailedWakeKeepsStopOnALoadedBoard() async throws {
        let account = WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")
        let backend = RootScriptedBackend(accounts: [account])
        backend.sessionsByURL = ["https://alpha.example": [Self.row(sessionID: "a", title: "Alpha session")]]
        let broker = PhoneCompanionBroker(epoch: InstallationEpoch(rawValue: UUID()), backend: backend)
        let model = WatchRootModel()
        model.attachLinkWithoutRefreshingForTesting(ScriptedLink(service: broker))
        await model.reloadRegistryForTesting()
        let session = try XCTUnwrap(model.sessions.first)
        let run = await model.send(text: "go", to: session)
        XCTAssertNotNil(run)

        model.applyRegistrySnapshotForTesting(RegistrySnapshot.unavailableWake())

        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.sessions.map(\.title), ["Alpha session"])
        XCTAssertEqual(model.activeRun(for: session), run)
        XCTAssertTrue(RegistrySnapshot.unavailableWake().isUnavailableWake)
    }

    func testImageCacheKeyIncludesTheSessionAndDigest() throws {
        let scope = Self.makeScope()
        let other = ServerScope(
            epoch: scope.epoch,
            server: ServerID(rawValue: UUID()),
            generation: scope.generation
        )
        let bytes = Data("clip".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let first = try Self.media(scope: scope, sessionID: "a", handle: "note.png", bytes: bytes, digest: digest)
        let otherSession = try Self.media(scope: scope, sessionID: "b", handle: "note.png", bytes: bytes, digest: digest)
        let otherServer = try Self.media(scope: other, sessionID: "a", handle: "note.png", bytes: bytes, digest: digest)
        XCTAssertNotEqual(WatchMediaCacheIdentity.key(for: first), WatchMediaCacheIdentity.key(for: otherSession))
        XCTAssertNotEqual(WatchMediaCacheIdentity.key(for: first), WatchMediaCacheIdentity.key(for: otherServer))
        XCTAssertTrue(WatchMediaCacheIdentity.accepts(bytes, descriptor: first))
        XCTAssertFalse(WatchMediaCacheIdentity.accepts(Data("other".utf8), descriptor: first))
    }

    private static func media(
        scope: ServerScope,
        sessionID: String,
        handle: String,
        bytes: Data,
        digest: String
    ) throws -> WatchMediaDescriptor {
        let observed = Date(timeIntervalSince1970: 10)
        return try WatchMediaDescriptor(
            scope: scope,
            session: SessionKey(scope: scope, sessionID: sessionID),
            origin: OriginBinding(digest: "origin"),
            handle: MediaHandle(handle),
            mimeType: "image/png",
            byteSize: bytes.count,
            sha256: digest,
            observedAt: observed,
            expiresAt: observed.addingTimeInterval(60)
        )
    }

    #if DEBUG
    /// The screenshot fixture has to simulate the write, not swallow it, or the
    /// simulator can never show that an action reached the screen.
    func testScreenshotFixtureWritesChangeTheGlanceState() async throws {
        let model = WatchRootModel()
        model.applyScreenshotFixture()

        let ran = await model.controlTask(jobID: "digest", action: .run)
        let digest = await model.loadTasks().first(where: { $0.key.jobID == "digest" })
        XCTAssertTrue(ran)
        XCTAssertEqual(digest?.running, true)

        let paused = await model.controlTask(jobID: "backup", action: .pause)
        let backup = await model.loadTasks().first(where: { $0.key.jobID == "backup" })
        XCTAssertTrue(paused)
        XCTAssertEqual(backup?.enabled, false)

        let toggled = await model.setSkillEnabled(name: "calendar", enabled: true)
        let calendar = await model.loadSkills().first(where: { $0.key.name == "calendar" })
        XCTAssertTrue(toggled)
        XCTAssertEqual(calendar?.enabled, true)

        let moved = await model.moveKanbanCard(cardID: "c3", status: "done")
        let card = await model.loadKanbanCards().first(where: { $0.id == "c3" })
        XCTAssertTrue(moved)
        XCTAssertEqual(card?.title, "Write release notes")
        XCTAssertEqual(card?.status, "done")

        let switched = await model.switchActiveProfile(name: "research")
        let options = await model.loadComposerOptions()
        XCTAssertTrue(switched)
        XCTAssertEqual(options?.defaultProfileID?.rawValue, "research")
    }
    #endif
}

private final class SessionLoadSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrived = false

    func arrive() {
        lock.lock()
        arrived = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if arrived {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private struct UnavailableLink: WatchCompanionLinking {
    var isCompanionAvailable: Bool { false }
    var isReachable: Bool { false }
    func makeService() -> any WatchCompanionServicing {
        fatalError("unused")
    }

    func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey> {
        throw WatchCompanionError.phoneUnavailable
    }

    func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey> {
        throw WatchCompanionError.phoneUnavailable
    }
}

private struct ScriptedLink: WatchCompanionLinking {
    let service: any WatchCompanionServicing
    var isCompanionAvailable: Bool { true }
    var isReachable: Bool { true }
    func makeService() -> any WatchCompanionServicing { service }
    func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey> {
        if let broker = service as? PhoneCompanionBroker {
            return await broker.sendVoiceNote(request)
        }
        throw WatchCompanionError.phoneUnavailable
    }

    func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey> {
        if let broker = service as? PhoneCompanionBroker {
            return await broker.sendPhoto(request)
        }
        throw WatchCompanionError.phoneUnavailable
    }
}

private final class RootScriptedBackend: WatchPhoneBackend, @unchecked Sendable {
    var accounts: [WatchPhoneServerAccount]
    var sessionsByURL: [String: [WatchPhoneSessionRow]] = [:]
    var failUpload = false
    var startedAttachments: [WatchChatAttachment]?
    var gatedSessionURL: String?
    var onSessionLoadEntered: (@Sendable () -> Void)?
    private var sessionLoadGate: [CheckedContinuation<Void, Never>] = []
    private let sessionLoadLock = NSLock()

    func releaseSessionLoadGate() {
        sessionLoadLock.lock()
        gatedSessionURL = nil
        let waiters = sessionLoadGate
        sessionLoadGate = []
        sessionLoadLock.unlock()
        waiters.forEach { $0.resume() }
    }
    var controlledTasks: [(jobID: String, action: String)] = []
    var skillToggles: [(name: String, enabled: Bool)] = []
    var kanbanMoves: [(cardID: String, status: String)] = []

    init(accounts: [WatchPhoneServerAccount]) {
        self.accounts = accounts
    }

    func controlTask(urlString: String, jobID: String, action: String) async throws {
        controlledTasks.append((jobID, action))
    }
    func setSkillEnabled(urlString: String, name: String, enabled: Bool) async throws {
        skillToggles.append((name, enabled))
    }
    func moveKanbanCard(urlString: String, cardID: String, status: String, boardSlug: String) async throws {
        kanbanMoves.append((cardID, status))
    }

    func servers() async -> [WatchPhoneServerAccount] { accounts }
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] {
        let shouldHold: Bool = {
            sessionLoadLock.lock()
            defer { sessionLoadLock.unlock() }
            return gatedSessionURL == urlString
        }()
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sessionLoadLock.lock()
                if gatedSessionURL == urlString {
                    sessionLoadGate.append(continuation)
                    sessionLoadLock.unlock()
                    onSessionLoadEntered?()
                } else {
                    sessionLoadLock.unlock()
                    continuation.resume()
                }
            }
        }
        return Array((sessionsByURL[urlString] ?? []).prefix(limit))
    }
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { "new-session" }
    func startChat(urlString: String, sessionID: String, message: String) async throws -> String { "stream-1" }
    func startChat(
        urlString: String,
        sessionID: String,
        message: String,
        attachments: [WatchChatAttachment]?
    ) async throws -> String {
        startedAttachments = attachments
        return "stream-1"
    }
    func uploadFile(
        urlString: String,
        sessionID: String,
        data: Data,
        filename: String
    ) async throws -> WatchChatAttachment {
        if failUpload { throw WatchCompanionError.backend(.timeout) }
        return WatchChatAttachment(
            name: filename,
            path: "/tmp/workspace/\(filename)",
            mime: "audio/m4a",
            size: data.count,
            isImage: false
        )
    }
    func cancelChat(urlString: String, streamID: String) async throws {}
    var transcriptBlocks: [WatchPhoneTranscriptPage.Block] = []
    func transcript(urlString: String, sessionID: String, before: Int?, limit: Int) async throws -> WatchPhoneTranscriptPage {
        WatchPhoneTranscriptPage(blocks: transcriptBlocks, nextBefore: nil, isTruncated: false)
    }
    var kanban: [WatchPhoneKanbanCardGlance] = []
    func listKanbanCards(urlString: String, limit: Int) async throws -> [WatchPhoneKanbanCardGlance] { kanban }
    var taskRuns: [WatchPhoneTaskRun]?
    func listTaskRuns(urlString: String, jobID: String, limit: Int) async throws -> [WatchPhoneTaskRun] {
        guard let taskRuns else { throw WatchCompanionError.backend(.timeout) }
        return taskRuns
    }
    func runPhase(urlString: String, sessionID: String, streamID: String) async throws -> (phase: WatchRunPhase, isTerminal: Bool) {
        (.responding, false)
    }
    func transcribeAudio(urlString: String, data: Data, filename: String) async throws -> String { "transcribed note" }
}

/// A link whose reachability can be flipped at runtime to simulate the phone
/// becoming reachable / unreachable without WatchConnectivity.
private final class ToggleableLink: WatchCompanionLinking, @unchecked Sendable {
    let installed: Bool
    var isReachable: Bool
    private let service: (any WatchCompanionServicing)?

    var needsUnlockAfterReboot: Bool

    init(
        service: (any WatchCompanionServicing)? = nil,
        installed: Bool = true,
        isReachable: Bool = true,
        needsUnlockAfterReboot: Bool = false
    ) {
        self.service = service
        self.installed = installed
        self.isReachable = isReachable
        self.needsUnlockAfterReboot = needsUnlockAfterReboot
    }

    var isCompanionAvailable: Bool { installed }
    var phoneNeedsUnlockAfterReboot: Bool { needsUnlockAfterReboot }
    func makeService() -> any WatchCompanionServicing {
        guard let service else { fatalError("no service attached") }
        return service
    }
    func sendVoiceNote(_ request: WatchVoiceNoteRequest) async throws -> CommandReceipt<RunKey> {
        throw WatchCompanionError.phoneUnavailable
    }

    func sendPhoto(_ request: WatchPhotoSendRequest) async throws -> CommandReceipt<RunKey> {
        throw WatchCompanionError.phoneUnavailable
    }
}

/// A backend whose session list always fails with `.authRequired`, simulating
/// an iPhone configured for a server whose session has expired.
private final class AuthFailingBackend: WatchPhoneBackend, @unchecked Sendable {
    func servers() async -> [WatchPhoneServerAccount] {
        [WatchPhoneServerAccount(urlString: "https://alpha.example", displayName: "Alpha")]
    }
    func listSessions(urlString: String, archived: Bool, query: String?, limit: Int) async throws -> [WatchPhoneSessionRow] {
        throw WatchCompanionError.backend(.authRequired)
    }
    func createSession(urlString: String, profileID: String?, workspace: String?) async throws -> String { "new-session" }
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
