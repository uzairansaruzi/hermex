import Foundation

public struct HermexAuthRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func status() async throws -> HermexJSONValue {
        try await client.authStatus()
    }

    public func login(password: String) async throws -> HermexJSONValue {
        try await client.login(password: password)
    }

    public func logout() async throws -> HermexJSONValue {
        try await client.logout()
    }
}

public struct HermexSessionRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func list(includeArchived: Bool = false, archivedLimit: Int? = nil) async throws -> HermexSessionsResponse {
        try await client.sessions(includeArchived: includeArchived, archivedLimit: archivedLimit)
    }

    public func search(query: String, content: Bool = true, depth: Int = 5) async throws -> HermexJSONValue {
        try await client.searchSessions(query: query, content: content, depth: depth)
    }

    public func detail(id: String, includeMessages: Bool = true, messageLimit: Int? = 50, messageBefore: Int? = nil) async throws -> HermexSessionResponse {
        try await client.session(id: id, includeMessages: includeMessages, messageLimit: messageLimit, messageBefore: messageBefore, expandRenderable: true)
    }

    public func create(workspace: String? = nil, model: String? = nil, modelProvider: String? = nil, profile: String? = nil) async throws -> HermexSessionResponse {
        try await client.createSession(workspace: workspace, model: model, modelProvider: modelProvider, profile: profile)
    }

    public func rename(id: String, title: String) async throws -> HermexJSONValue {
        try await client.renameSession(id: id, title: title)
    }

    public func delete(id: String) async throws -> HermexJSONValue {
        try await client.deleteSession(id: id)
    }

    public func pin(id: String, pinned: Bool) async throws -> HermexJSONValue {
        try await client.pinSession(id: id, pinned: pinned)
    }

    public func archive(id: String, archived: Bool) async throws -> HermexJSONValue {
        try await client.archiveSession(id: id, archived: archived)
    }

    public func move(id: String, projectID: String?) async throws -> HermexJSONValue {
        try await client.moveSession(id: id, projectID: projectID)
    }

    public func branch(id: String, keepCount: Int? = nil, title: String? = nil) async throws -> HermexJSONValue {
        try await client.branchSession(id: id, keepCount: keepCount, title: title)
    }

    public func compress(id: String, focusTopic: String? = nil) async throws -> HermexJSONValue {
        try await client.compressSession(id: id, focusTopic: focusTopic)
    }

    public func undo(id: String) async throws -> HermexJSONValue {
        try await client.undoSession(id: id)
    }

    public func retry(id: String) async throws -> HermexJSONValue {
        try await client.retrySession(id: id)
    }
}

public struct HermexChatRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func start(
        sessionID: String? = nil,
        message: String,
        workspace: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        profile: String? = nil,
        explicitModelPick: Bool = false,
        attachments: [HermexJSONValue]? = nil
    ) async throws -> HermexJSONValue {
        try await client.chatStart(
            sessionID: sessionID,
            message: message,
            workspace: workspace,
            model: model,
            modelProvider: modelProvider,
            profile: profile,
            explicitModelPick: explicitModelPick,
            attachments: attachments
        )
    }

    public func streamURL(streamID: String, replayAfterSeq: Int? = nil) -> URL {
        client.streamURL(streamID: streamID, replayAfterSeq: replayAfterSeq)
    }

    public func cancel(streamID: String) async throws -> HermexJSONValue {
        try await client.chatCancel(streamID: streamID)
    }

    public func steer(sessionID: String, text: String) async throws -> HermexJSONValue {
        try await client.chatSteer(sessionID: sessionID, text: text)
    }

    public func approvalPending(sessionID: String) async throws -> HermexJSONValue {
        try await client.approvalPending(sessionID: sessionID)
    }

    public func respondApproval(sessionID: String, choice: String, approvalID: String? = nil) async throws -> HermexJSONValue {
        try await client.respondApproval(sessionID: sessionID, choice: choice, approvalID: approvalID)
    }

    public func clarifyPending(sessionID: String) async throws -> HermexJSONValue {
        try await client.clarifyPending(sessionID: sessionID)
    }

    public func respondClarification(sessionID: String, response: String, clarifyID: String? = nil) async throws -> HermexJSONValue {
        try await client.respondClarification(sessionID: sessionID, response: response, clarifyID: clarifyID)
    }

    public func upload(sessionID: String, data: Data, filename: String, contentType: String = "application/octet-stream") async throws -> HermexUploadResponse {
        try await client.uploadFile(sessionID: sessionID, data: data, filename: filename, contentType: contentType)
    }

    public func transcribe(data: Data, filename: String, contentType: String = "application/octet-stream") async throws -> HermexTranscribeResponse {
        try await client.transcribeAudio(data: data, filename: filename, contentType: contentType)
    }

    public func synthesizeSpeech(text: String, voice: String) async throws -> Data {
        try await client.synthesizeSpeech(text: text, voice: voice)
    }
}

public struct HermexWorkspaceRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func roots() async throws -> HermexJSONValue {
        try await client.workspaces()
    }

    public func suggestions(prefix: String) async throws -> HermexJSONValue {
        try await client.workspaceSuggestions(prefix: prefix)
    }

    public func list(sessionID: String, path: String? = nil) async throws -> HermexJSONValue {
        try await client.directoryList(sessionID: sessionID, path: path)
    }

    public func file(sessionID: String, path: String) async throws -> HermexJSONValue {
        try await client.file(sessionID: sessionID, path: path)
    }

    public func rawFile(sessionID: String, path: String) async throws -> Data {
        try await client.rawFile(sessionID: sessionID, path: path)
    }
}

public struct HermexGitRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func info(sessionID: String) async throws -> HermexJSONValue { try await client.gitInfo(sessionID: sessionID) }
    public func status(sessionID: String) async throws -> HermexJSONValue { try await client.gitStatus(sessionID: sessionID) }
    public func branches(sessionID: String) async throws -> HermexJSONValue { try await client.gitBranches(sessionID: sessionID) }
    public func diff(sessionID: String, path: String, kind: String = "unstaged") async throws -> HermexJSONValue { try await client.gitDiff(sessionID: sessionID, path: path, kind: kind) }
    public func fetch(sessionID: String) async throws -> HermexJSONValue { try await client.gitFetch(sessionID: sessionID) }
    public func pull(sessionID: String) async throws -> HermexJSONValue { try await client.gitPull(sessionID: sessionID) }
    public func push(sessionID: String) async throws -> HermexJSONValue { try await client.gitPush(sessionID: sessionID) }
    public func stage(sessionID: String, paths: [String]) async throws -> HermexJSONValue { try await client.gitStage(sessionID: sessionID, paths: paths) }
    public func unstage(sessionID: String, paths: [String]) async throws -> HermexJSONValue { try await client.gitUnstage(sessionID: sessionID, paths: paths) }
    public func discard(sessionID: String, paths: [String], deleteUntracked: Bool = false) async throws -> HermexJSONValue { try await client.gitDiscard(sessionID: sessionID, paths: paths, deleteUntracked: deleteUntracked) }
    public func commit(sessionID: String, message: String) async throws -> HermexJSONValue { try await client.gitCommit(sessionID: sessionID, message: message) }
}

public struct HermexPanelsRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func models() async throws -> HermexModelsResponse { try await client.models() }
    public func commands() async throws -> HermexJSONValue { try await client.commands() }
    public func crons() async throws -> HermexJSONValue { try await client.crons() }
    public func skills() async throws -> HermexJSONValue { try await client.skills() }
    public func skillContent(name: String, file: String? = nil) async throws -> HermexJSONValue { try await client.skillContent(name: name, file: file) }
    public func memory() async throws -> HermexJSONValue { try await client.memory() }
    public func writeMemory(section: String, content: String) async throws -> HermexJSONValue { try await client.writeMemory(section: section, content: content) }
    public func insights(days: Int) async throws -> HermexJSONValue { try await client.insights(days: days) }
}

public struct HermexSettingsRepository: Sendable {
    private let client: HermexAPIClient

    public init(client: HermexAPIClient) {
        self.client = client
    }

    public func settings() async throws -> HermexJSONValue { try await client.settings() }
    public func updateShowCliSessions(_ enabled: Bool) async throws -> HermexJSONValue { try await client.updateSettings(showCliSessions: enabled) }
    public func profiles() async throws -> HermexJSONValue { try await client.profiles() }
    public func switchProfile(name: String) async throws -> HermexJSONValue { try await client.switchProfile(name: name) }
    public func providers() async throws -> HermexJSONValue { try await client.providers() }
    public func updatesCheck() async throws -> HermexJSONValue { try await client.updatesCheck() }
    public func updatesCheckForced() async throws -> HermexJSONValue { try await client.updatesCheckForced() }
    public func applyUpdate(target: String = "webui") async throws -> HermexJSONValue { try await client.applyUpdate(target: target) }
}
