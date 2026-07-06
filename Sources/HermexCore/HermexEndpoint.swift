import Foundation

public struct HermexEndpoint: Equatable, Sendable {
    public let path: String
    public let queryItems: [URLQueryItem]

    public init(path: String, queryItems: [URLQueryItem] = []) {
        self.path = path
        self.queryItems = queryItems
    }

    public func url(relativeTo baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + endpointPath
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url ?? baseURL.appendingPathComponent(endpointPath)
    }
}

public enum HermexEndpoints {
    public static let health = HermexEndpoint(path: "/health")
    public static let authStatus = HermexEndpoint(path: "/api/auth/status")
    public static let login = HermexEndpoint(path: "/api/auth/login")
    public static let logout = HermexEndpoint(path: "/api/auth/logout")

    public static func sessions(includeArchived: Bool = false, archivedLimit: Int? = nil) -> HermexEndpoint {
        HermexEndpoint(
            path: "/api/sessions",
            queryItems: [
                URLQueryItem(name: "include_archived", value: includeArchived ? "1" : nil),
                URLQueryItem(name: "archived_limit", value: includeArchived ? archivedLimit.map(String.init) : nil)
            ].filter { $0.value != nil }
        )
    }

    public static func sessionsSearch(query: String, content: Bool, depth: Int) -> HermexEndpoint {
        HermexEndpoint(
            path: "/api/sessions/search",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "content", value: content ? "1" : "0"),
                URLQueryItem(name: "depth", value: String(depth))
            ]
        )
    }

    public static func session(
        id: String,
        includeMessages: Bool,
        messageLimit: Int? = nil,
        messageBefore: Int? = nil,
        expandRenderable: Bool = false
    ) -> HermexEndpoint {
        HermexEndpoint(
            path: "/api/session",
            queryItems: [
                URLQueryItem(name: "session_id", value: id),
                URLQueryItem(name: "messages", value: includeMessages ? "1" : "0"),
                URLQueryItem(name: "msg_limit", value: messageLimit.map(String.init)),
                URLQueryItem(name: "msg_before", value: messageBefore.map(String.init)),
                URLQueryItem(name: "expand_renderable", value: expandRenderable ? "1" : nil)
            ].filter { $0.value != nil }
        )
    }

    public static func sessionStatus(id: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/session/status", queryItems: [URLQueryItem(name: "session_id", value: id)])
    }

    public static let newSession = HermexEndpoint(path: "/api/session/new")
    public static let renameSession = HermexEndpoint(path: "/api/session/rename")
    public static let deleteSession = HermexEndpoint(path: "/api/session/delete")
    public static let pinSession = HermexEndpoint(path: "/api/session/pin")
    public static let archiveSession = HermexEndpoint(path: "/api/session/archive")
    public static let branchSession = HermexEndpoint(path: "/api/session/branch")
    public static let compressSession = HermexEndpoint(path: "/api/session/compress")
    public static let undoSession = HermexEndpoint(path: "/api/session/undo")
    public static let retrySession = HermexEndpoint(path: "/api/session/retry")
    public static let truncateSession = HermexEndpoint(path: "/api/session/truncate")
    public static let updateSession = HermexEndpoint(path: "/api/session/update")
    public static let moveSession = HermexEndpoint(path: "/api/session/move")

    public static func sessionYolo(id: String?) -> HermexEndpoint {
        HermexEndpoint(path: "/api/session/yolo", queryItems: id.map { [URLQueryItem(name: "session_id", value: $0)] } ?? [])
    }

    public static func exportSession(id: String, format: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/session/export", queryItems: [
            URLQueryItem(name: "session_id", value: id),
            URLQueryItem(name: "format", value: format)
        ])
    }

    public static let projects = HermexEndpoint(path: "/api/projects")
    public static let createProject = HermexEndpoint(path: "/api/projects/create")
    public static let renameProject = HermexEndpoint(path: "/api/projects/rename")
    public static let deleteProject = HermexEndpoint(path: "/api/projects/delete")

    public static let chatStart = HermexEndpoint(path: "/api/chat/start")

    public static func chatStream(id: String, replayAfterSeq: Int? = nil) -> HermexEndpoint {
        HermexEndpoint(
            path: "/api/chat/stream",
            queryItems: [
                URLQueryItem(name: "stream_id", value: id),
                URLQueryItem(name: "replay", value: replayAfterSeq.map { _ in "1" }),
                URLQueryItem(name: "after_seq", value: replayAfterSeq.map { String(max(0, $0)) })
            ].filter { $0.value != nil }
        )
    }

    public static func chatCancel(streamID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/chat/cancel", queryItems: [URLQueryItem(name: "stream_id", value: streamID)])
    }

    public static func chatStreamStatus(streamID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/chat/stream/status", queryItems: [URLQueryItem(name: "stream_id", value: streamID)])
    }

    public static let chatSteer = HermexEndpoint(path: "/api/chat/steer")
    public static let submitGoal = HermexEndpoint(path: "/api/goal")

    public static func approvalPending(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/approval/pending", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static func approvalStream(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/approval/stream", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static let approvalRespond = HermexEndpoint(path: "/api/approval/respond")

    public static func clarifyPending(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/clarify/pending", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static func clarifyStream(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/clarify/stream", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static let clarifyRespond = HermexEndpoint(path: "/api/clarify/respond")
    public static let btw = HermexEndpoint(path: "/api/btw")
    public static let background = HermexEndpoint(path: "/api/background")

    public static func backgroundStatus(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/background/status", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static let workspaces = HermexEndpoint(path: "/api/workspaces")
    public static func workspaceSuggestions(prefix: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/workspaces/suggest", queryItems: [URLQueryItem(name: "prefix", value: prefix)])
    }
    public static func directoryList(sessionID: String, path: String? = nil) -> HermexEndpoint {
        HermexEndpoint(
            path: "/api/list",
            queryItems: [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ].filter { $0.value != nil }
        )
    }
    public static func file(sessionID: String, path: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/file", queryItems: [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "path", value: path)
        ])
    }
    public static func rawFile(sessionID: String, path: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/file/raw", queryItems: [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "path", value: path)
        ])
    }
    public static func media(path: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/media", queryItems: [URLQueryItem(name: "path", value: path)])
    }
    public static func gitInfo(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/git-info", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }
    public static func gitStatus(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/git/status", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static func gitBranches(sessionID: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/git/branches", queryItems: [URLQueryItem(name: "session_id", value: sessionID)])
    }

    public static func gitDiff(sessionID: String, path: String, kind: String) -> HermexEndpoint {
        HermexEndpoint(path: "/api/git/diff", queryItems: [
            URLQueryItem(name: "session_id", value: sessionID),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "kind", value: kind)
        ])
    }

    public static let gitFetch = HermexEndpoint(path: "/api/git/fetch")
    public static let gitPull = HermexEndpoint(path: "/api/git/pull")
    public static let gitPush = HermexEndpoint(path: "/api/git/push")
    public static let gitCheckout = HermexEndpoint(path: "/api/git/checkout")
    public static let gitStashCheckout = HermexEndpoint(path: "/api/git/stash-checkout")
    public static let gitStage = HermexEndpoint(path: "/api/git/stage")
    public static let gitUnstage = HermexEndpoint(path: "/api/git/unstage")
    public static let gitDiscard = HermexEndpoint(path: "/api/git/discard")
    public static let gitCommit = HermexEndpoint(path: "/api/git/commit")
    public static let gitCommitSelected = HermexEndpoint(path: "/api/git/commit-selected")
    public static let gitCommitMessage = HermexEndpoint(path: "/api/git/commit-message")
    public static let gitCommitMessageSelected = HermexEndpoint(path: "/api/git/commit-message-selected")
    public static let models = HermexEndpoint(path: "/api/models")
    public static let modelsLive = HermexEndpoint(path: "/api/models/live")
    public static let commands = HermexEndpoint(path: "/api/commands")
    public static let defaultModel = HermexEndpoint(path: "/api/default-model")
    public static func reasoning(model: String? = nil, provider: String? = nil) -> HermexEndpoint {
        HermexEndpoint(path: "/api/reasoning", queryItems: [
            URLQueryItem(name: "model", value: model?.isEmpty == false ? model : nil),
            URLQueryItem(name: "provider", value: provider?.isEmpty == false ? provider : nil)
        ].filter { $0.value != nil })
    }

    public static let personalities = HermexEndpoint(path: "/api/personalities")
    public static let setPersonality = HermexEndpoint(path: "/api/personality/set")
    public static let profiles = HermexEndpoint(path: "/api/profiles")
    public static let switchProfile = HermexEndpoint(path: "/api/profile/switch")
    public static let createProfile = HermexEndpoint(path: "/api/profile/create")
    public static let providers = HermexEndpoint(path: "/api/providers")
    public static let settings = HermexEndpoint(path: "/api/settings")
    public static let updatesCheck = HermexEndpoint(path: "/api/updates/check")
    public static let updatesApply = HermexEndpoint(path: "/api/updates/apply")
    public static func insights(days: Int) -> HermexEndpoint {
        HermexEndpoint(path: "/api/insights", queryItems: [URLQueryItem(name: "days", value: String(days))])
    }

    public static let crons = HermexEndpoint(path: "/api/crons")
    public static let cronCreate = HermexEndpoint(path: "/api/crons/create")
    public static let cronUpdate = HermexEndpoint(path: "/api/crons/update")
    public static let cronDelete = HermexEndpoint(path: "/api/crons/delete")
    public static let cronRun = HermexEndpoint(path: "/api/crons/run")
    public static let cronPause = HermexEndpoint(path: "/api/crons/pause")
    public static let cronResume = HermexEndpoint(path: "/api/crons/resume")
    public static func cronStatus(jobID: String? = nil) -> HermexEndpoint {
        HermexEndpoint(path: "/api/crons/status", queryItems: jobID.map { [URLQueryItem(name: "job_id", value: $0)] } ?? [])
    }

    public static func cronOutput(jobID: String, limit: Int? = nil) -> HermexEndpoint {
        HermexEndpoint(path: "/api/crons/output", queryItems: [
            URLQueryItem(name: "job_id", value: jobID),
            URLQueryItem(name: "limit", value: limit.map(String.init))
        ].filter { $0.value != nil })
    }

    public static let memory = HermexEndpoint(path: "/api/memory")
    public static let memoryWrite = HermexEndpoint(path: "/api/memory/write")
    public static let skills = HermexEndpoint(path: "/api/skills")
    public static func skillContent(name: String, file: String? = nil) -> HermexEndpoint {
        HermexEndpoint(path: "/api/skills/content", queryItems: [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "file", value: file)
        ].filter { $0.value != nil })
    }

    public static let toggleSkill = HermexEndpoint(path: "/api/skills/toggle")
    public static let upload = HermexEndpoint(path: "/api/upload")
    public static let transcribe = HermexEndpoint(path: "/api/transcribe")
    public static let tts = HermexEndpoint(path: "/api/tts")
}
