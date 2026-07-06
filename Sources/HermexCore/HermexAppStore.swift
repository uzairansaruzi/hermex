import Foundation
import Observation

public enum HermexAppAction: Equatable, Sendable {
    case openRoute(HermexRoute)
    case refresh
    case updateOnboardingServerURL(String)
    case updateOnboardingDisplayName(String)
    case updateOnboardingPassword(String)
    case updateOnboardingCustomHeaders(String)
    case testOnboardingConnection
    case connectOnboarding
    case selectServer(HermexServerIdentity)
    case openSession(String)
    case newChat
    case searchSessions(String)
    case toggleArchived
    case updateDraft(String)
    case appendDraftText(String)
    case applySharedDraft(HermexSharedDraft)
    case hydrateCachedSessions([HermexSessionDTO])
    case hydrateCachedMessages(sessionID: String, [HermexChatMessageDTO])
    case setVoiceRecording(Bool)
    case refreshComposerConfiguration
    case selectModel(HermexModelOption)
    case selectWorkspace(HermexWorkspaceRootDTO)
    case selectProfile(HermexProfileOption)
    case selectReasoningEffort(String)
    case sendDraft
    case cancelStream
    case undo
    case retry
    case compress
    case approval(String)
    case clarify(String)
    case applyStreamEvent(HermexSSEEvent)
    case openWorkspaceEntry(HermexWorkspaceEntryDTO)
    case openFile(String)
    case gitAction(String)
    case gitCommand(HermexGitCommand)
    case updateGitCommitMessage(String)
    case selectPanel(HermexPanel)
    case signOut
}

public struct HermexAppEnvironment: Sendable {
    public var testServerConnection: @Sendable (_ server: HermexServerIdentity) async throws -> HermexJSONValue
    public var loginToServer: @Sendable (_ server: HermexServerIdentity, _ password: String) async throws -> HermexJSONValue
    public var loadSessions: @Sendable (_ includeArchived: Bool, _ archivedLimit: Int?) async throws -> HermexSessionsResponse
    public var loadSession: @Sendable (_ sessionID: String) async throws -> HermexSessionResponse
    public var startChat: @Sendable (
        _ sessionID: String?,
        _ message: String,
        _ workspace: String?,
        _ model: String?,
        _ modelProvider: String?,
        _ profile: String?,
        _ attachments: [HermexJSONValue]?
    ) async throws -> HermexJSONValue
    public var cancelStream: @Sendable (_ streamID: String) async throws -> HermexJSONValue
    public var respondApproval: @Sendable (_ sessionID: String, _ choice: String, _ approvalID: String?) async throws -> HermexJSONValue
    public var respondClarification: @Sendable (_ sessionID: String, _ response: String, _ clarifyID: String?) async throws -> HermexJSONValue
    public var undoSession: @Sendable (_ sessionID: String) async throws -> HermexJSONValue
    public var retrySession: @Sendable (_ sessionID: String) async throws -> HermexJSONValue
    public var compressSession: @Sendable (_ sessionID: String, _ focusTopic: String?) async throws -> HermexJSONValue
    public var loadModels: @Sendable () async throws -> HermexModelsResponse
    public var loadProfiles: @Sendable () async throws -> HermexProfilesResponse
    public var loadWorkspaces: @Sendable () async throws -> HermexWorkspacesResponse
    public var loadReasoning: @Sendable (_ model: String?, _ provider: String?) async throws -> HermexReasoningResponse
    public var saveReasoningEffort: @Sendable (_ effort: String, _ model: String?, _ provider: String?) async throws -> HermexJSONValue
    public var loadDirectory: @Sendable (_ sessionID: String, _ path: String?) async throws -> HermexJSONValue
    public var loadFile: @Sendable (_ sessionID: String, _ path: String) async throws -> HermexJSONValue
    public var loadGitStatus: @Sendable (_ sessionID: String) async throws -> HermexJSONValue
    public var performGitAction: @Sendable (_ sessionID: String, _ action: String) async throws -> HermexJSONValue
    public var performGitCommand: @Sendable (_ sessionID: String, _ command: HermexGitCommand) async throws -> HermexJSONValue
    public var loadTasks: @Sendable () async throws -> HermexJSONValue
    public var loadSkills: @Sendable () async throws -> HermexJSONValue
    public var loadMemory: @Sendable () async throws -> HermexJSONValue
    public var loadInsights: @Sendable (_ days: Int) async throws -> HermexJSONValue
    public var logout: @Sendable () async throws -> HermexJSONValue

    public init(
        testServerConnection: @escaping @Sendable (_ server: HermexServerIdentity) async throws -> HermexJSONValue,
        loginToServer: @escaping @Sendable (_ server: HermexServerIdentity, _ password: String) async throws -> HermexJSONValue,
        loadSessions: @escaping @Sendable (_ includeArchived: Bool, _ archivedLimit: Int?) async throws -> HermexSessionsResponse,
        loadSession: @escaping @Sendable (_ sessionID: String) async throws -> HermexSessionResponse,
        startChat: @escaping @Sendable (
            _ sessionID: String?,
            _ message: String,
            _ workspace: String?,
            _ model: String?,
            _ modelProvider: String?,
            _ profile: String?,
            _ attachments: [HermexJSONValue]?
        ) async throws -> HermexJSONValue,
        cancelStream: @escaping @Sendable (_ streamID: String) async throws -> HermexJSONValue,
        respondApproval: @escaping @Sendable (_ sessionID: String, _ choice: String, _ approvalID: String?) async throws -> HermexJSONValue,
        respondClarification: @escaping @Sendable (_ sessionID: String, _ response: String, _ clarifyID: String?) async throws -> HermexJSONValue,
        undoSession: @escaping @Sendable (_ sessionID: String) async throws -> HermexJSONValue,
        retrySession: @escaping @Sendable (_ sessionID: String) async throws -> HermexJSONValue,
        compressSession: @escaping @Sendable (_ sessionID: String, _ focusTopic: String?) async throws -> HermexJSONValue,
        loadModels: @escaping @Sendable () async throws -> HermexModelsResponse,
        loadProfiles: @escaping @Sendable () async throws -> HermexProfilesResponse,
        loadWorkspaces: @escaping @Sendable () async throws -> HermexWorkspacesResponse,
        loadReasoning: @escaping @Sendable (_ model: String?, _ provider: String?) async throws -> HermexReasoningResponse,
        saveReasoningEffort: @escaping @Sendable (_ effort: String, _ model: String?, _ provider: String?) async throws -> HermexJSONValue,
        loadDirectory: @escaping @Sendable (_ sessionID: String, _ path: String?) async throws -> HermexJSONValue,
        loadFile: @escaping @Sendable (_ sessionID: String, _ path: String) async throws -> HermexJSONValue,
        loadGitStatus: @escaping @Sendable (_ sessionID: String) async throws -> HermexJSONValue,
        performGitAction: @escaping @Sendable (_ sessionID: String, _ action: String) async throws -> HermexJSONValue,
        performGitCommand: @escaping @Sendable (_ sessionID: String, _ command: HermexGitCommand) async throws -> HermexJSONValue,
        loadTasks: @escaping @Sendable () async throws -> HermexJSONValue,
        loadSkills: @escaping @Sendable () async throws -> HermexJSONValue,
        loadMemory: @escaping @Sendable () async throws -> HermexJSONValue,
        loadInsights: @escaping @Sendable (_ days: Int) async throws -> HermexJSONValue,
        logout: @escaping @Sendable () async throws -> HermexJSONValue
    ) {
        self.testServerConnection = testServerConnection
        self.loginToServer = loginToServer
        self.loadSessions = loadSessions
        self.loadSession = loadSession
        self.startChat = startChat
        self.cancelStream = cancelStream
        self.respondApproval = respondApproval
        self.respondClarification = respondClarification
        self.undoSession = undoSession
        self.retrySession = retrySession
        self.compressSession = compressSession
        self.loadModels = loadModels
        self.loadProfiles = loadProfiles
        self.loadWorkspaces = loadWorkspaces
        self.loadReasoning = loadReasoning
        self.saveReasoningEffort = saveReasoningEffort
        self.loadDirectory = loadDirectory
        self.loadFile = loadFile
        self.loadGitStatus = loadGitStatus
        self.performGitAction = performGitAction
        self.performGitCommand = performGitCommand
        self.loadTasks = loadTasks
        self.loadSkills = loadSkills
        self.loadMemory = loadMemory
        self.loadInsights = loadInsights
        self.logout = logout
    }

    public static func live(client: HermexAPIClient) -> HermexAppEnvironment {
        let sessions = HermexSessionRepository(client: client)
        let chat = HermexChatRepository(client: client)
        let auth = HermexAuthRepository(client: client)
        let workspace = HermexWorkspaceRepository(client: client)
        let git = HermexGitRepository(client: client)
        let panels = HermexPanelsRepository(client: client)
        return HermexAppEnvironment(
            testServerConnection: { _ in
                try await client.health()
            },
            loginToServer: { _, password in
                try await auth.login(password: password)
            },
            loadSessions: { includeArchived, archivedLimit in
                try await sessions.list(includeArchived: includeArchived, archivedLimit: archivedLimit)
            },
            loadSession: { sessionID in
                try await sessions.detail(id: sessionID)
            },
            startChat: { sessionID, message, workspace, model, modelProvider, profile, attachments in
                try await chat.start(
                    sessionID: sessionID,
                    message: message,
                    workspace: workspace,
                    model: model,
                    modelProvider: modelProvider,
                    profile: profile,
                    explicitModelPick: model != nil,
                    attachments: attachments
                )
            },
            cancelStream: { streamID in
                try await chat.cancel(streamID: streamID)
            },
            respondApproval: { sessionID, choice, approvalID in
                try await chat.respondApproval(sessionID: sessionID, choice: choice, approvalID: approvalID)
            },
            respondClarification: { sessionID, response, clarifyID in
                try await chat.respondClarification(sessionID: sessionID, response: response, clarifyID: clarifyID)
            },
            undoSession: { sessionID in
                try await sessions.undo(id: sessionID)
            },
            retrySession: { sessionID in
                try await sessions.retry(id: sessionID)
            },
            compressSession: { sessionID, focusTopic in
                try await sessions.compress(id: sessionID, focusTopic: focusTopic)
            },
            loadModels: {
                try await client.models()
            },
            loadProfiles: {
                try await client.profilesResponse()
            },
            loadWorkspaces: {
                try await client.workspacesResponse()
            },
            loadReasoning: { model, provider in
                try await client.reasoningResponse(model: model, provider: provider)
            },
            saveReasoningEffort: { effort, model, provider in
                try await client.saveReasoningEffort(effort, model: model, provider: provider)
            },
            loadDirectory: { sessionID, path in
                try await workspace.list(sessionID: sessionID, path: path)
            },
            loadFile: { sessionID, path in
                try await workspace.file(sessionID: sessionID, path: path)
            },
            loadGitStatus: { sessionID in
                try await git.status(sessionID: sessionID)
            },
            performGitAction: { sessionID, action in
                switch action {
                case "fetch": return try await git.fetch(sessionID: sessionID)
                case "pull": return try await git.pull(sessionID: sessionID)
                case "push": return try await git.push(sessionID: sessionID)
                default: return .object(["ok": .bool(false), "error": .string("Unsupported git action")])
                }
            },
            performGitCommand: { sessionID, command in
                switch command {
                case .fetch:
                    return try await git.fetch(sessionID: sessionID)
                case .pull:
                    return try await git.pull(sessionID: sessionID)
                case .push:
                    return try await git.push(sessionID: sessionID)
                case .diff(let path, let kind):
                    return try await git.diff(sessionID: sessionID, path: path, kind: kind)
                case .stage(let path):
                    return try await git.stage(sessionID: sessionID, paths: [path])
                case .unstage(let path):
                    return try await git.unstage(sessionID: sessionID, paths: [path])
                case .discard(let path, let deleteUntracked):
                    return try await git.discard(sessionID: sessionID, paths: [path], deleteUntracked: deleteUntracked)
                case .commit(let message):
                    return try await git.commit(sessionID: sessionID, message: message)
                }
            },
            loadTasks: {
                try await panels.crons()
            },
            loadSkills: {
                try await panels.skills()
            },
            loadMemory: {
                try await panels.memory()
            },
            loadInsights: { days in
                try await panels.insights(days: days)
            },
            logout: {
                try await auth.logout()
            }
        )
    }
}

@MainActor
@Observable
public final class HermexAppStore {
    public private(set) var appState: HermexAppState
    public private(set) var onboarding: HermexOnboardingState
    public private(set) var sessions: HermexSessionListState
    public private(set) var chat: HermexChatState
    public private(set) var settings: HermexSettingsState
    public private(set) var workspace: HermexWorkspaceState
    public private(set) var git: HermexGitState
    public private(set) var panels: HermexPanelsState

    private let environment: HermexAppEnvironment

    public init(
        appState: HermexAppState = HermexAppState(),
        onboarding: HermexOnboardingState = HermexOnboardingState(),
        sessions: HermexSessionListState = HermexSessionListState(),
        chat: HermexChatState = HermexChatState(),
        settings: HermexSettingsState = HermexSettingsState(),
        workspace: HermexWorkspaceState = HermexWorkspaceState(),
        git: HermexGitState = HermexGitState(),
        panels: HermexPanelsState = HermexPanelsState(),
        environment: HermexAppEnvironment
    ) {
        self.appState = appState
        self.onboarding = onboarding
        self.sessions = sessions
        self.chat = chat
        self.settings = settings
        self.workspace = workspace
        self.git = git
        self.panels = panels
        self.environment = environment
    }

    public func send(_ action: HermexAppAction) async {
        switch action {
        case .openRoute(let route):
            appState.route = route
        case .refresh:
            await refreshCurrentRoute()
        case .updateOnboardingServerURL(let value):
            onboarding.serverURLString = value
            onboarding.errorMessage = nil
            onboarding.statusMessage = nil
        case .updateOnboardingDisplayName(let value):
            onboarding.displayName = value
        case .updateOnboardingPassword(let value):
            onboarding.password = value
        case .updateOnboardingCustomHeaders(let value):
            onboarding.customHeaderText = value
        case .testOnboardingConnection:
            await testOnboardingConnection()
        case .connectOnboarding:
            await connectOnboarding()
        case .selectServer(let server):
            selectServer(server)
        case .openSession(let sessionID):
            await openSession(sessionID)
        case .newChat:
            appState.selectedSessionID = nil
            appState.route = .chat
            chat = HermexChatState(composer: chat.composer)
        case .searchSessions(let query):
            sessions.searchQuery = query
            await refreshSessions()
        case .toggleArchived:
            sessions.isShowingArchived.toggle()
            await refreshSessions()
        case .updateDraft(let draft):
            chat.composer.draft = draft
        case .appendDraftText(let text):
            appendDraftText(text)
        case .applySharedDraft(let draft):
            applySharedDraft(draft)
        case .hydrateCachedSessions(let cachedSessions):
            sessions.sessions = cachedSessions
            sessions.isViewingCachedData = true
        case .hydrateCachedMessages(let sessionID, let messages):
            appState.selectedSessionID = sessionID
            appState.route = .chat
            chat.messages = messages
            chat.isViewingCachedData = true
        case .setVoiceRecording(let isRecording):
            chat.composer.isRecordingVoice = isRecording
        case .refreshComposerConfiguration:
            await refreshComposerConfiguration()
        case .selectModel(let model):
            chat.composer.selectedModel = model.id
            chat.composer.selectedModelProvider = model.provider
            await refreshReasoningConfiguration()
        case .selectWorkspace(let workspace):
            chat.composer.selectedWorkspace = workspace.path
        case .selectProfile(let profile):
            chat.composer.selectedProfile = profile.name
        case .selectReasoningEffort(let effort):
            await selectReasoningEffort(effort)
        case .sendDraft:
            await sendDraft()
        case .cancelStream:
            await cancelStream()
        case .undo:
            await mutateCurrentSession(environment.undoSession)
        case .retry:
            await mutateCurrentSession(environment.retrySession)
        case .compress:
            await compressCurrentSession()
        case .approval(let choice):
            await respondApproval(choice)
        case .clarify(let response):
            await respondClarification(response)
        case .applyStreamEvent(let event):
            applyStreamEvent(event)
        case .openWorkspaceEntry(let entry):
            if entry.isDirectory {
                await loadWorkspace(path: entry.path)
            } else {
                await loadFilePreview(path: entry.path)
            }
        case .openFile(let path):
            appState.route = .workspace
            await loadFilePreview(path: path)
        case .gitAction(let action):
            await runGitAction(action)
        case .gitCommand(let command):
            await runGitCommand(command)
        case .updateGitCommitMessage(let message):
            git.commitMessage = message
        case .selectPanel(let panel):
            panels.selectedPanel = panel
            appState.route = .panels
            await loadPanel(panel)
        case .signOut:
            await signOut()
        }
    }

    private func refreshCurrentRoute() async {
        switch appState.route {
        case .onboarding:
            await testOnboardingConnection()
        case .sessions:
            await refreshSessions()
        case .chat:
            if let sessionID = appState.selectedSessionID {
                await openSession(sessionID)
            }
        case .workspace:
            await loadWorkspace(path: workspace.currentPath)
        case .git:
            await loadGitStatus()
        case .panels:
            await loadPanel(panels.selectedPanel)
        default:
            break
        }
    }

    private func refreshSessions() async {
        sessions.isLoading = true
        sessions.errorMessage = nil
        do {
            let response = try await environment.loadSessions(sessions.isShowingArchived, sessions.isShowingArchived ? 50 : nil)
            sessions.sessions = response.sessions ?? []
            sessions.projects = response.projects ?? []
        } catch {
            sessions.errorMessage = String(describing: error)
        }
        sessions.isLoading = false
    }

    private func testOnboardingConnection() async {
        guard let server = onboardingServerIdentity() else { return }
        onboarding.isTestingConnection = true
        onboarding.errorMessage = nil
        onboarding.statusMessage = "Testing \(server.displayName)"
        do {
            _ = try await environment.testServerConnection(server)
            onboarding.lastValidatedServer = server
            onboarding.statusMessage = "Connection OK"
            appState.auth = .loggedOut(server: server)
            upsertServer(server)
        } catch {
            onboarding.errorMessage = String(describing: error)
            onboarding.statusMessage = nil
        }
        onboarding.isTestingConnection = false
    }

    private func connectOnboarding() async {
        guard let server = onboardingServerIdentity() else { return }
        let password = onboarding.password
        guard !password.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            onboarding.errorMessage = "Password is required."
            return
        }

        onboarding.isSigningIn = true
        onboarding.errorMessage = nil
        onboarding.statusMessage = "Signing in"
        do {
            _ = try await environment.loginToServer(server, password)
            onboarding.password = ""
            onboarding.lastValidatedServer = server
            onboarding.statusMessage = "Connected"
            appState.auth = .loggedIn(server: server)
            appState.route = .sessions
            settings.activeServer = server
            upsertServer(server)
            await refreshSessions()
        } catch {
            onboarding.errorMessage = String(describing: error)
            onboarding.statusMessage = nil
        }
        onboarding.isSigningIn = false
    }

    private func selectServer(_ server: HermexServerIdentity) {
        onboarding.serverURLString = server.baseURL.absoluteString
        onboarding.displayName = server.displayName
        onboarding.customHeaderText = server.customHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == ComparisonResult.orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        onboarding.errorMessage = nil
        onboarding.statusMessage = nil
        appState.auth = .loggedOut(server: server)
        settings.activeServer = server
    }

    private func openSession(_ sessionID: String) async {
        appState.selectedSessionID = sessionID
        appState.route = .chat
        chat.isLoading = true
        chat.errorMessage = nil
        do {
            let response = try await environment.loadSession(sessionID)
            chat.session = response.session
            chat.messages = response.messages ?? []
        } catch {
            chat.errorMessage = String(describing: error)
        }
        chat.isLoading = false
    }

    private func sendDraft() async {
        let draft = chat.composer.draft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !draft.isEmpty else { return }

        let existingSessionID = appState.selectedSessionID
        let composer = chat.composer
        chat.composer.draft = ""
        chat.messages.append(HermexChatMessageDTO(role: "user", content: draft, timestamp: Date().timeIntervalSince1970))
        chat.stream = HermexStreamState(isStreaming: true, liveToolActivity: "Starting response")
        chat.errorMessage = nil

        do {
            let response = try await environment.startChat(
                existingSessionID,
                draft,
                composer.selectedWorkspace,
                composer.selectedModel,
                composer.selectedModelProvider,
                composer.selectedProfile,
                composer.attachments.map(\.jsonValue)
            )
            if let sessionID = response.stringValue(forKey: "session_id") ?? response.stringValue(forKey: "sessionId") {
                appState.selectedSessionID = sessionID
            }
            chat.stream.streamID = response.stringValue(forKey: "stream_id") ?? response.stringValue(forKey: "streamId")
        } catch {
            chat.stream.isStreaming = false
            chat.errorMessage = String(describing: error)
            chat.composer.draft = draft
        }
    }

    private func appendDraftText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if chat.composer.draft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            chat.composer.draft = trimmed
        } else {
            chat.composer.draft += "\n\(trimmed)"
        }
    }

    private func applySharedDraft(_ draft: HermexSharedDraft) {
        appState.pendingSharedDraft = draft
        appState.route = .chat
        if let text = draft.text {
            appendDraftText(text)
        }
        let sharedAttachments = draft.attachmentURLs.map { url in
            HermexAttachmentDTO(
                name: url.lastPathComponent.isEmpty ? "shared-file" : url.lastPathComponent,
                path: url.path,
                mime: nil,
                size: nil,
                isImage: nil
            )
        }
        chat.composer.attachments.append(contentsOf: sharedAttachments)
    }

    private func refreshComposerConfiguration() async {
        chat.composer.isLoadingConfiguration = true
        chat.composer.configurationErrorMessage = nil
        do {
            async let models = environment.loadModels()
            async let profiles = environment.loadProfiles()
            async let workspaces = environment.loadWorkspaces()
            let loadedModels = try await models
            let loadedProfiles = try await profiles
            let loadedWorkspaces = try await workspaces

            chat.composer.availableModels = loadedModels.normalizedModels
            chat.composer.availableProfiles = loadedProfiles.profiles ?? []
            chat.composer.availableWorkspaces = loadedWorkspaces.normalizedRoots
            if chat.composer.selectedModel == nil {
                chat.composer.selectedModel = loadedModels.defaultModel ?? chat.session?.model
                chat.composer.selectedModelProvider = loadedModels.activeProvider ?? chat.session?.modelProvider
            }
            if chat.composer.selectedProfile == nil {
                chat.composer.selectedProfile = loadedProfiles.active
                    ?? loadedProfiles.profiles?.first(where: { $0.isActive == true })?.name
                    ?? loadedProfiles.profiles?.first?.name
            }
            if chat.composer.selectedWorkspace == nil {
                chat.composer.selectedWorkspace = chat.session?.workspace
                    ?? loadedWorkspaces.last
                    ?? loadedWorkspaces.normalizedRoots.first?.path
            }
            await refreshReasoningConfiguration()
        } catch {
            chat.composer.configurationErrorMessage = String(describing: error)
        }
        chat.composer.isLoadingConfiguration = false
    }

    private func refreshReasoningConfiguration() async {
        do {
            let response = try await environment.loadReasoning(chat.composer.selectedModel, chat.composer.selectedModelProvider)
            chat.composer.supportedReasoningEfforts = response.supportedEfforts ?? []
            chat.composer.showsReasoningControl = response.supportsReasoningEffort ?? !(response.supportedEfforts ?? []).isEmpty
            chat.composer.selectedReasoningEffort = response.effort ?? chat.composer.selectedReasoningEffort
        } catch {
            chat.composer.configurationErrorMessage = String(describing: error)
        }
    }

    private func selectReasoningEffort(_ effort: String) async {
        chat.composer.selectedReasoningEffort = effort
        do {
            _ = try await environment.saveReasoningEffort(
                effort,
                chat.composer.selectedModel,
                chat.composer.selectedModelProvider
            )
        } catch {
            chat.composer.configurationErrorMessage = String(describing: error)
        }
    }

    private func cancelStream() async {
        guard let streamID = chat.stream.streamID else {
            chat.stream.isStreaming = false
            return
        }
        do {
            _ = try await environment.cancelStream(streamID)
            chat.stream.isStreaming = false
        } catch {
            chat.errorMessage = String(describing: error)
        }
    }

    private func respondApproval(_ choice: String) async {
        guard let sessionID = appState.selectedSessionID else { return }
        do {
            _ = try await environment.respondApproval(sessionID, choice, chat.pendingApproval?.approvalID)
            chat.pendingApproval = nil
        } catch {
            chat.errorMessage = String(describing: error)
        }
    }

    private func mutateCurrentSession(_ mutation: @Sendable (_ sessionID: String) async throws -> HermexJSONValue) async {
        guard let sessionID = appState.selectedSessionID else { return }
        chat.errorMessage = nil
        do {
            _ = try await mutation(sessionID)
            await openSession(sessionID)
        } catch {
            chat.errorMessage = String(describing: error)
        }
    }

    private func compressCurrentSession() async {
        guard let sessionID = appState.selectedSessionID else { return }
        chat.errorMessage = nil
        do {
            _ = try await environment.compressSession(sessionID, nil)
            await openSession(sessionID)
        } catch {
            chat.errorMessage = String(describing: error)
        }
    }

    private func respondClarification(_ response: String) async {
        guard let sessionID = appState.selectedSessionID else { return }
        do {
            _ = try await environment.respondClarification(sessionID, response, chat.pendingClarification?.promptID)
            chat.pendingClarification = nil
        } catch {
            chat.errorMessage = String(describing: error)
        }
    }

    private func applyStreamEvent(_ event: HermexSSEEvent) {
        switch event {
        case .token(let token):
            appendAssistantToken(token)
            chat.stream.liveToolActivity = nil
        case .usage(let usage):
            chat.stream.liveToolActivity = usage
        case .done:
            chat.stream.isStreaming = false
            chat.stream.isRecovering = false
            chat.stream.liveToolActivity = nil
        case .error(let message):
            chat.stream.isStreaming = false
            chat.stream.isRecovering = false
            chat.errorMessage = message
        case .named(let event, let data):
            applyNamedStreamEvent(event: event, data: data)
        }
    }

    private func applyNamedStreamEvent(event: String, data: String) {
        switch event {
        case "reasoning", "thinking":
            if chat.stream.liveReasoning.isEmpty {
                chat.stream.liveReasoning = data
            } else {
                chat.stream.liveReasoning += data
            }
        case "tool", "tool_call", "tool_status":
            chat.stream.liveToolActivity = data
        case "done":
            chat.stream.isStreaming = false
            chat.stream.isRecovering = false
            chat.stream.liveToolActivity = nil
        case "error":
            chat.stream.isStreaming = false
            chat.errorMessage = data
        default:
            chat.stream.liveToolActivity = data
        }
    }

    private func appendAssistantToken(_ token: String) {
        guard !token.isEmpty else { return }
        if let lastIndex = chat.messages.indices.last,
           chat.messages[lastIndex].role == "assistant" {
            let existing = chat.messages[lastIndex].content ?? ""
            chat.messages[lastIndex].content = existing + token
        } else {
            chat.messages.append(HermexChatMessageDTO(role: "assistant", content: token, timestamp: Date().timeIntervalSince1970))
        }
    }

    private func loadWorkspace(path: String?) async {
        guard let sessionID = appState.selectedSessionID else { return }
        appState.route = .workspace
        workspace.isLoading = true
        workspace.errorMessage = nil
        do {
            let roots = try await environment.loadWorkspaces()
            let targetPath = path ?? workspace.currentPath ?? chat.composer.selectedWorkspace ?? roots.last ?? roots.normalizedRoots.first?.path
            let response = try await environment.loadDirectory(sessionID, targetPath)
            var mapped = HermexWorkspaceState.fromDirectoryResponse(response, fallbackPath: targetPath)
            mapped.roots = roots.normalizedRoots
            workspace = mapped
        } catch {
            workspace.errorMessage = String(describing: error)
        }
        workspace.isLoading = false
    }

    private func loadFilePreview(path: String) async {
        guard let sessionID = appState.selectedSessionID else { return }
        appState.route = .workspace
        workspace.isLoading = true
        workspace.errorMessage = nil
        do {
            let response = try await environment.loadFile(sessionID, path)
            workspace.preview = HermexFilePreview.fromJSON(response, fallbackPath: path)
            workspace.currentPath = path
        } catch {
            workspace.errorMessage = String(describing: error)
        }
        workspace.isLoading = false
    }

    private func loadGitStatus() async {
        guard let sessionID = appState.selectedSessionID else { return }
        appState.route = .git
        git.isMutating = true
        git.errorMessage = nil
        do {
            git = git.mergingStatus(from: try await environment.loadGitStatus(sessionID))
        } catch {
            git.errorMessage = String(describing: error)
        }
        git.isMutating = false
    }

    private func runGitAction(_ action: String) async {
        guard let sessionID = appState.selectedSessionID else { return }
        appState.route = .git
        git.isMutating = true
        git.errorMessage = nil
        do {
            _ = try await environment.performGitAction(sessionID, action)
            git = HermexGitState.fromStatusResponse(try await environment.loadGitStatus(sessionID))
        } catch {
            git.errorMessage = String(describing: error)
        }
        git.isMutating = false
    }

    private func runGitCommand(_ command: HermexGitCommand) async {
        guard let sessionID = appState.selectedSessionID else { return }
        appState.route = .git
        git.isMutating = true
        git.errorMessage = nil
        do {
            let response = try await environment.performGitCommand(sessionID, command)
            switch command {
            case .diff(let path, _):
                git.diffPath = path
                git.diffText = HermexGitState.diffText(from: response) ?? ""
            case .commit:
                git.commitMessage = ""
                git = git.mergingStatus(from: try await environment.loadGitStatus(sessionID))
            default:
                git = git.mergingStatus(from: try await environment.loadGitStatus(sessionID))
            }
        } catch {
            git.errorMessage = String(describing: error)
        }
        git.isMutating = false
    }

    private func loadPanel(_ panel: HermexPanel) async {
        appState.route = .panels
        panels.selectedPanel = panel
        panels.isLoading = true
        panels.errorMessage = nil
        do {
            switch panel {
            case .tasks:
                let mapped = HermexPanelsState.tasks(from: try await environment.loadTasks(), selectedPanel: panel)
                panels.tasks = mapped.tasks
                panels.errorMessage = mapped.errorMessage
            case .skills:
                let mapped = HermexPanelsState.skills(from: try await environment.loadSkills(), selectedPanel: panel)
                panels.skills = mapped.skills
                panels.errorMessage = mapped.errorMessage
            case .memory:
                let mapped = HermexPanelsState.memory(from: try await environment.loadMemory(), selectedPanel: panel)
                panels.memory = mapped.memory
                panels.errorMessage = mapped.errorMessage
            case .insights:
                panels.insights = try await environment.loadInsights(7)
            }
        } catch {
            panels.errorMessage = String(describing: error)
        }
        panels.isLoading = false
    }

    private func signOut() async {
        do {
            _ = try await environment.logout()
        } catch {
            settings.notificationsEnabled = false
        }

        appState.selectedSessionID = nil
        if let server = settings.activeServer {
            appState.auth = .loggedOut(server: server)
            onboarding.serverURLString = server.baseURL.absoluteString
            onboarding.displayName = server.displayName
        } else {
            appState.auth = .unconfigured
        }
        appState.route = .onboarding
        onboarding.password = ""
        chat = HermexChatState()
        sessions = HermexSessionListState()
    }

    private func onboardingServerIdentity() -> HermexServerIdentity? {
        let trimmedURL = onboarding.serverURLString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            onboarding.errorMessage = "Server URL is required."
            return nil
        }

        let candidate = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        guard let rawURL = URL(string: candidate),
              let scheme = rawURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              rawURL.host?.isEmpty == false
        else {
            onboarding.errorMessage = "Enter a valid HTTP or HTTPS server URL."
            return nil
        }

        let normalizedURL = URL(string: HermexServerURLNormalizer.normalizedID(for: rawURL)) ?? rawURL
        let displayName = onboarding.displayName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let headers = parsedCustomHeaders()
        return HermexServerIdentity(
            baseURL: normalizedURL,
            displayName: displayName.isEmpty ? (normalizedURL.host ?? normalizedURL.absoluteString) : displayName,
            customHeaders: headers.reduce(into: [:]) { result, header in
                result[header.sanitizedName] = header.sanitizedValue
            }
        )
    }

    private func parsedCustomHeaders() -> [HermexCustomHeader] {
        onboarding.customHeaderText
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> HermexCustomHeader? in
                let pieces = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                return HermexCustomHeader(name: String(pieces[0]), value: String(pieces[1]))
            }
            .sanitizedForClient()
    }

    private func upsertServer(_ server: HermexServerIdentity) {
        settings.activeServer = server
        if let existingIndex = settings.servers.firstIndex(where: {
            HermexServerURLNormalizer.normalizedID(for: $0.baseURL) == HermexServerURLNormalizer.normalizedID(for: server.baseURL)
        }) {
            settings.servers[existingIndex] = server
        } else {
            settings.servers.append(server)
        }
    }
}

private extension HermexAttachmentDTO {
    var jsonValue: HermexJSONValue {
        var object: [String: HermexJSONValue] = [:]
        if let name { object["name"] = .string(name) }
        if let path { object["path"] = .string(path) }
        if let mime { object["mime"] = .string(mime) }
        if let size { object["size"] = .number(Double(size)) }
        if let isImage { object["is_image"] = .bool(isImage) }
        return .object(object)
    }
}

private extension HermexJSONValue {
    func stringValue(forKey key: String) -> String? {
        guard case .object(let object) = self else { return nil }
        guard case .string(let value) = object[key] else { return nil }
        return value
    }
}
