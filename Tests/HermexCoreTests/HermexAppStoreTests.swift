import XCTest
@testable import HermexCore

@MainActor
final class HermexAppStoreTests: XCTestCase {
    func testRefreshLoadsSessionsIntoSharedState() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(appState: HermexAppState(route: .sessions), environment: environment(probe: probe))

        await store.send(.refresh)

        XCTAssertEqual(store.sessions.sessions.map(\.id), ["s1"])
        XCTAssertFalse(store.sessions.isLoading)
        XCTAssertNil(store.sessions.errorMessage)
    }

    func testOpenSessionLoadsTranscriptAndMovesToChatRoute() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(environment: environment(probe: probe))

        await store.send(.openSession("s1"))

        XCTAssertEqual(store.appState.route, .chat)
        XCTAssertEqual(store.appState.selectedSessionID, "s1")
        XCTAssertEqual(store.chat.session?.title, "Workspace")
        XCTAssertEqual(store.chat.messages.first?.content, "Hello")
        XCTAssertFalse(store.chat.isLoading)
    }

    func testSendDraftStartsChatAndUpdatesStreamState() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            appState: HermexAppState(selectedSessionID: "s1", route: .chat),
            chat: HermexChatState(composer: HermexComposerState(
                draft: "Build it",
                selectedModel: "gpt-5.5",
                selectedModelProvider: "codex",
                selectedWorkspace: "Home",
                selectedProfile: "default"
            )),
            environment: environment(probe: probe)
        )

        await store.send(.sendDraft)

        let request = await probe.startedChat
        XCTAssertEqual(request?.sessionID, "s1")
        XCTAssertEqual(request?.message, "Build it")
        XCTAssertEqual(request?.workspace, "Home")
        XCTAssertEqual(request?.model, "gpt-5.5")
        XCTAssertEqual(request?.modelProvider, "codex")
        XCTAssertEqual(request?.profile, "default")
        XCTAssertEqual(store.chat.composer.draft, "")
        XCTAssertEqual(store.chat.messages.last?.role, "user")
        XCTAssertEqual(store.chat.stream.streamID, "stream-1")
        XCTAssertTrue(store.chat.stream.isStreaming)
    }

    func testCancelStreamRoutesThroughEnvironment() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            chat: HermexChatState(stream: HermexStreamState(streamID: "stream-1", isStreaming: true)),
            environment: environment(probe: probe)
        )

        await store.send(.cancelStream)

        let cancelledStreamID = await probe.cancelledStreamID
        XCTAssertEqual(cancelledStreamID, "stream-1")
        XCTAssertFalse(store.chat.stream.isStreaming)
    }

    func testApplyStreamEventsUpdatesTranscriptAndStreamState() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            chat: HermexChatState(stream: HermexStreamState(streamID: "stream-1", isStreaming: true)),
            environment: environment(probe: probe)
        )

        await store.send(.applyStreamEvent(.token("Hel")))
        await store.send(.applyStreamEvent(.token("lo")))
        await store.send(.applyStreamEvent(.named(event: "reasoning", data: "thinking")))
        await store.send(.applyStreamEvent(.named(event: "tool", data: "git/status")))
        await store.send(.applyStreamEvent(.done(nil)))

        XCTAssertEqual(store.chat.messages.last?.role, "assistant")
        XCTAssertEqual(store.chat.messages.last?.content, "Hello")
        XCTAssertEqual(store.chat.stream.liveReasoning, "thinking")
        XCTAssertFalse(store.chat.stream.isStreaming)
        XCTAssertNil(store.chat.stream.liveToolActivity)
    }

    func testUndoRetryAndCompressMutateSelectedSessionAndReloadTranscript() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            appState: HermexAppState(selectedSessionID: "s1", route: .chat),
            environment: environment(probe: probe)
        )

        await store.send(.undo)
        await store.send(.retry)
        await store.send(.compress)
        let mutations = await probe.mutations
        let loadedSessionIDs = await probe.loadedSessionIDs

        XCTAssertEqual(mutations, ["undo:s1", "retry:s1", "compress:s1"])
        XCTAssertEqual(loadedSessionIDs, ["s1", "s1", "s1"])
        XCTAssertEqual(store.chat.messages.first?.content, "Hello")
    }

    func testComposerConfigurationLoadsAndSelectionsUpdateDraftContext() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            chat: HermexChatState(session: HermexSessionDTO(sessionId: "s1", workspace: "Repo", model: "cached-model")),
            environment: environment(probe: probe)
        )

        await store.send(.refreshComposerConfiguration)

        XCTAssertEqual(store.chat.composer.availableModels.map(\.id), ["gpt-5.5"])
        XCTAssertEqual(store.chat.composer.availableProfiles.map(\.name), ["default"])
        XCTAssertEqual(store.chat.composer.availableWorkspaces.map(\.path), ["/repo"])
        XCTAssertEqual(store.chat.composer.selectedModel, "gpt-5.5")
        XCTAssertEqual(store.chat.composer.selectedModelProvider, "codex")
        XCTAssertEqual(store.chat.composer.selectedProfile, "default")
        XCTAssertEqual(store.chat.composer.selectedWorkspace, "Repo")
        XCTAssertEqual(store.chat.composer.supportedReasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(store.chat.composer.selectedReasoningEffort, "medium")

        await store.send(.selectModel(HermexModelOption(id: "fast", provider: "local", label: "Fast")))
        await store.send(.selectWorkspace(HermexWorkspaceRootDTO(path: "/tmp", name: "Temp")))
        await store.send(.selectProfile(HermexProfileOption(name: "ops", displayName: "Ops")))
        await store.send(.selectReasoningEffort("high"))

        XCTAssertEqual(store.chat.composer.selectedModel, "fast")
        XCTAssertEqual(store.chat.composer.selectedModelProvider, "local")
        XCTAssertEqual(store.chat.composer.selectedWorkspace, "/tmp")
        XCTAssertEqual(store.chat.composer.selectedProfile, "ops")
        XCTAssertEqual(store.chat.composer.selectedReasoningEffort, "high")
        let savedReasoningEffort = await probe.savedReasoningEffort
        XCTAssertEqual(savedReasoningEffort, "high")
    }

    func testOnboardingConnectionAndLoginNormalizeServerWithoutStoringPassword() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            onboarding: HermexOnboardingState(
                serverURLString: "Example.TEST/",
                displayName: "Example",
                password: "secret",
                customHeaderText: "Origin: bad\nCF-Access-Client-Id: abc\nCF-Access-Client-Secret: xyz"
            ),
            environment: environment(probe: probe)
        )

        await store.send(.testOnboardingConnection)
        let maybeTestedServer = await probe.testedServer
        let testedServer = try XCTUnwrap(maybeTestedServer)
        XCTAssertEqual(testedServer.baseURL.absoluteString, "https://example.test/")
        XCTAssertEqual(store.appState.auth, .loggedOut(server: testedServer))
        XCTAssertEqual(store.settings.servers.first?.customHeaders["CF-Access-Client-Id"], "abc")
        XCTAssertNil(store.settings.servers.first?.customHeaders["Origin"])

        await store.send(.connectOnboarding)

        let loginPassword = await probe.loginPassword
        XCTAssertEqual(loginPassword, "secret")
        XCTAssertEqual(store.onboarding.password, "")
        XCTAssertEqual(store.appState.route, .sessions)
        XCTAssertEqual(store.sessions.sessions.map(\.id), ["s1"])
        XCTAssertEqual(store.settings.activeServer?.displayName, "Example")
    }

    func testWorkspaceGitAndPanelsLoadThroughSharedEnvironment() async throws {
        let probe = StoreProbe()
        let store = HermexAppStore(
            appState: HermexAppState(selectedSessionID: "s1", route: .workspace),
            environment: environment(probe: probe)
        )

        await store.send(.refresh)
        XCTAssertEqual(store.workspace.entries.map(\.path), ["/repo/README.md"])

        await store.send(.openWorkspaceEntry(HermexWorkspaceEntryDTO(name: "README.md", path: "/repo/README.md", isDirectory: false)))
        XCTAssertEqual(store.workspace.preview?.content, "Hello")

        await store.send(.openRoute(.git))
        await store.send(.refresh)
        XCTAssertEqual(store.git.branch, "main")
        XCTAssertEqual(store.git.files.map(\.path), ["README.md"])

        await store.send(.gitAction("fetch"))
        let gitActions = await probe.gitActions
        XCTAssertEqual(gitActions, ["fetch"])

        await store.send(.gitCommand(.diff(path: "README.md", kind: "unstaged")))
        XCTAssertEqual(store.git.diffPath, "README.md")
        XCTAssertEqual(store.git.diffText, "diff --git README.md")
        await store.send(.gitCommand(.stage(path: "README.md")))
        await store.send(.updateGitCommitMessage("Update README"))
        await store.send(.gitCommand(.commit(message: store.git.commitMessage)))
        let gitCommands = await probe.gitCommands
        XCTAssertEqual(store.git.commitMessage, "")
        XCTAssertEqual(gitCommands, ["diff", "stage", "commit"])

        await store.send(.selectPanel(.tasks))
        XCTAssertEqual(store.panels.tasks.map(\.id), ["job-1"])
        await store.send(.selectPanel(.skills))
        XCTAssertEqual(store.panels.skills.map(\.name), ["swift"])
        await store.send(.selectPanel(.memory))
        XCTAssertEqual(store.panels.memory.map(\.section), ["profile"])
        await store.send(.selectPanel(.insights))
        XCTAssertEqual(store.panels.insights, .object(["ok": .bool(true)]))
    }

    private func environment(probe: StoreProbe) -> HermexAppEnvironment {
        HermexAppEnvironment(
            testServerConnection: { server in
                try await probe.testServerConnection(server: server)
            },
            loginToServer: { server, password in
                try await probe.loginToServer(server: server, password: password)
            },
            loadSessions: { includeArchived, archivedLimit in
                try await probe.loadSessions(includeArchived: includeArchived, archivedLimit: archivedLimit)
            },
            loadSession: { sessionID in
                try await probe.loadSession(sessionID: sessionID)
            },
            startChat: { sessionID, message, workspace, model, modelProvider, profile, attachments in
                try await probe.startChat(
                    sessionID: sessionID,
                    message: message,
                    workspace: workspace,
                    model: model,
                    modelProvider: modelProvider,
                    profile: profile,
                    attachments: attachments
                )
            },
            cancelStream: { streamID in
                try await probe.cancelStream(streamID: streamID)
            },
            respondApproval: { sessionID, choice, approvalID in
                try await probe.respondApproval(sessionID: sessionID, choice: choice, approvalID: approvalID)
            },
            respondClarification: { sessionID, response, clarifyID in
                try await probe.respondClarification(sessionID: sessionID, response: response, clarifyID: clarifyID)
            },
            undoSession: { sessionID in
                try await probe.undoSession(sessionID: sessionID)
            },
            retrySession: { sessionID in
                try await probe.retrySession(sessionID: sessionID)
            },
            compressSession: { sessionID, focusTopic in
                try await probe.compressSession(sessionID: sessionID, focusTopic: focusTopic)
            },
            loadModels: {
                try await probe.loadModels()
            },
            loadProfiles: {
                try await probe.loadProfiles()
            },
            loadWorkspaces: {
                try await probe.loadWorkspaces()
            },
            loadReasoning: { model, provider in
                try await probe.loadReasoning(model: model, provider: provider)
            },
            saveReasoningEffort: { effort, model, provider in
                try await probe.saveReasoningEffort(effort: effort, model: model, provider: provider)
            },
            loadDirectory: { sessionID, path in
                try await probe.loadDirectory(sessionID: sessionID, path: path)
            },
            loadFile: { sessionID, path in
                try await probe.loadFile(sessionID: sessionID, path: path)
            },
            loadGitStatus: { sessionID in
                try await probe.loadGitStatus(sessionID: sessionID)
            },
            performGitAction: { sessionID, action in
                try await probe.performGitAction(sessionID: sessionID, action: action)
            },
            performGitCommand: { sessionID, command in
                try await probe.performGitCommand(sessionID: sessionID, command: command)
            },
            loadTasks: {
                try await probe.loadTasks()
            },
            loadSkills: {
                try await probe.loadSkills()
            },
            loadMemory: {
                try await probe.loadMemory()
            },
            loadInsights: { days in
                try await probe.loadInsights(days: days)
            },
            logout: {
                try await probe.logout()
            }
        )
    }
}

private actor StoreProbe {
    struct StartedChat: Equatable {
        var sessionID: String?
        var message: String
        var workspace: String?
        var model: String?
        var modelProvider: String?
        var profile: String?
    }

    private(set) var startedChat: StartedChat?
    private(set) var cancelledStreamID: String?
    private(set) var loadedSessionIDs: [String] = []
    private(set) var mutations: [String] = []
    private(set) var savedReasoningEffort: String?
    private(set) var gitActions: [String] = []
    private(set) var gitCommands: [String] = []
    private(set) var testedServer: HermexServerIdentity?
    private(set) var loginServer: HermexServerIdentity?
    private(set) var loginPassword: String?

    func testServerConnection(server: HermexServerIdentity) async throws -> HermexJSONValue {
        testedServer = server
        return .object(["ok": .bool(true)])
    }

    func loginToServer(server: HermexServerIdentity, password: String) async throws -> HermexJSONValue {
        loginServer = server
        loginPassword = password
        return .object(["ok": .bool(true)])
    }

    func loadSessions(includeArchived: Bool, archivedLimit: Int?) async throws -> HermexSessionsResponse {
        HermexSessionsResponse(sessions: [
            HermexSessionDTO(sessionId: "s1", title: "Workspace", messageCount: 1, workspace: "Home")
        ])
    }

    func loadSession(sessionID: String) async throws -> HermexSessionResponse {
        loadedSessionIDs.append(sessionID)
        return HermexSessionResponse(
            session: HermexSessionDTO(sessionId: sessionID, title: "Workspace", messageCount: 1, workspace: "Home"),
            messages: [HermexChatMessageDTO(role: "assistant", content: "Hello")]
        )
    }

    func startChat(
        sessionID: String?,
        message: String,
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?,
        attachments: [HermexJSONValue]?
    ) async throws -> HermexJSONValue {
        startedChat = StartedChat(
            sessionID: sessionID,
            message: message,
            workspace: workspace,
            model: model,
            modelProvider: modelProvider,
            profile: profile
        )
        return .object([
            "session_id": .string(sessionID ?? "s1"),
            "stream_id": .string("stream-1")
        ])
    }

    func cancelStream(streamID: String) async throws -> HermexJSONValue {
        cancelledStreamID = streamID
        return .object(["ok": .bool(true)])
    }

    func respondApproval(sessionID: String, choice: String, approvalID: String?) async throws -> HermexJSONValue {
        .object(["ok": .bool(true)])
    }

    func respondClarification(sessionID: String, response: String, clarifyID: String?) async throws -> HermexJSONValue {
        .object(["ok": .bool(true)])
    }

    func undoSession(sessionID: String) async throws -> HermexJSONValue {
        mutations.append("undo:\(sessionID)")
        return .object(["ok": .bool(true)])
    }

    func retrySession(sessionID: String) async throws -> HermexJSONValue {
        mutations.append("retry:\(sessionID)")
        return .object(["ok": .bool(true)])
    }

    func compressSession(sessionID: String, focusTopic: String?) async throws -> HermexJSONValue {
        mutations.append("compress:\(sessionID)")
        return .object(["ok": .bool(true)])
    }

    func loadModels() async throws -> HermexModelsResponse {
        HermexModelsResponse(
            groups: nil,
            models: [
                .object([
                    "id": .string("gpt-5.5"),
                    "provider": .string("codex"),
                    "label": .string("GPT 5.5")
                ])
            ],
            defaultModel: "gpt-5.5",
            activeProvider: "codex"
        )
    }

    func loadProfiles() async throws -> HermexProfilesResponse {
        HermexProfilesResponse(
            profiles: [HermexProfileOption(name: "default", displayName: "Default", isActive: true)],
            active: "default"
        )
    }

    func loadWorkspaces() async throws -> HermexWorkspacesResponse {
        HermexWorkspacesResponse(workspaces: [HermexWorkspaceRootDTO(path: "/repo", name: "Repo")], last: "Repo")
    }

    func loadReasoning(model: String?, provider: String?) async throws -> HermexReasoningResponse {
        HermexReasoningResponse(effort: "medium", supportedEfforts: ["low", "medium", "high"], supportsReasoningEffort: true)
    }

    func saveReasoningEffort(effort: String, model: String?, provider: String?) async throws -> HermexJSONValue {
        savedReasoningEffort = effort
        return .object(["ok": .bool(true)])
    }

    func loadDirectory(sessionID: String, path: String?) async throws -> HermexJSONValue {
        .object([
            "path": .string(path ?? "/repo"),
            "entries": .array([
                .object([
                    "name": .string("README.md"),
                    "path": .string("/repo/README.md"),
                    "type": .string("file"),
                    "size": .number(42)
                ])
            ])
        ])
    }

    func loadFile(sessionID: String, path: String) async throws -> HermexJSONValue {
        .object(["path": .string(path), "content": .string("Hello"), "mime_type": .string("text/markdown")])
    }

    func loadGitStatus(sessionID: String) async throws -> HermexJSONValue {
        .object([
            "branch": .string("main"),
            "ahead": .number(1),
            "behind": .number(0),
            "files": .array([
                .object(["path": .string("README.md"), "status": .string("M"), "additions": .number(2), "deletions": .number(1)])
            ])
        ])
    }

    func performGitAction(sessionID: String, action: String) async throws -> HermexJSONValue {
        gitActions.append(action)
        return .object(["ok": .bool(true)])
    }

    func performGitCommand(sessionID: String, command: HermexGitCommand) async throws -> HermexJSONValue {
        switch command {
        case .diff:
            gitCommands.append("diff")
            return .object(["diff": .string("diff --git README.md")])
        case .stage:
            gitCommands.append("stage")
        case .unstage:
            gitCommands.append("unstage")
        case .discard:
            gitCommands.append("discard")
        case .commit:
            gitCommands.append("commit")
        case .fetch:
            gitCommands.append("fetch")
        case .pull:
            gitCommands.append("pull")
        case .push:
            gitCommands.append("push")
        }
        return .object(["ok": .bool(true)])
    }

    func loadTasks() async throws -> HermexJSONValue {
        .object(["jobs": .array([.object(["id": .string("job-1"), "title": .string("Morning"), "status": .string("active")])])])
    }

    func loadSkills() async throws -> HermexJSONValue {
        .object(["skills": .array([.object(["name": .string("swift"), "enabled": .bool(true), "summary": .string("Swift helper")])])])
    }

    func loadMemory() async throws -> HermexJSONValue {
        .object(["profile": .string("Likes concise answers")])
    }

    func loadInsights(days: Int) async throws -> HermexJSONValue {
        .object(["ok": .bool(true)])
    }

    func logout() async throws -> HermexJSONValue {
        .object(["ok": .bool(true)])
    }
}
