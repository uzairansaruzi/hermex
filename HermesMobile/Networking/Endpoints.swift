import Foundation

enum Endpoint {
    case health
    case authStatus
    case login
    case logout
    case sessions
    case sessionsSearch(query: String, content: Bool, depth: Int)
    case session(id: String, includeMessages: Bool, messageLimit: Int?, messageBefore: Int?, expandRenderable: Bool = false)
    case sessionStatus(id: String)
    case newSession
    case renameSession
    case deleteSession
    case pinSession
    case archiveSession
    case branchSession
    case compressSession
    case undoSession
    case retrySession
    case truncateSession
    case updateSession
    case moveSession
    case sessionYolo(sessionID: String?)
    case projects
    case createProject
    case renameProject
    case deleteProject
    case chatStart
    case chatStream(streamID: String)
    case chatCancel(streamID: String)
    case chatStreamStatus(streamID: String)
    case chatSteer
    case submitGoal
    case approvalPending(sessionID: String)
    case approvalStream(sessionID: String)
    case approvalRespond
    case clarifyPending(sessionID: String)
    case clarifyStream(sessionID: String)
    case clarifyRespond
    case btw
    case background
    case backgroundStatus(sessionID: String)
    case workspaces
    case workspaceSuggestions(prefix: String)
    case directoryList(sessionID: String, path: String?)
    case file(sessionID: String, path: String)
    case rawFile(sessionID: String, path: String)
    case media(path: String)
    case gitInfo(sessionID: String)
    case gitStatus(sessionID: String)
    case gitBranches(sessionID: String)
    case gitDiff(sessionID: String, path: String, kind: String)
    case gitFetch
    case gitPull
    case gitPush
    case gitCheckout
    case gitStashCheckout
    case gitStage
    case gitUnstage
    case gitDiscard
    case gitCommit
    case gitCommitSelected
    case gitCommitMessage
    case gitCommitMessageSelected
    case models
    case modelsLive
    case commands
    case defaultModel
    case reasoning
    case personalities
    case setPersonality
    case profiles
    case switchProfile
    case createProfile
    case providers
    case settings
    case updatesCheck
    case updatesApply
    case insights(days: Int)
    case crons
    case cronCreate
    case cronUpdate
    case cronDelete
    case cronRun
    case cronPause
    case cronResume
    case cronStatus(jobID: String?)
    case cronOutput(jobID: String, limit: Int?)
    case memory
    case memoryWrite
    case skills
    case skillContent(name: String, file: String?)
    case upload
    case transcribe

    var path: String {
        switch self {
        case .health:
            return "/health"
        case .authStatus:
            return "/api/auth/status"
        case .login:
            return "/api/auth/login"
        case .logout:
            return "/api/auth/logout"
        case .sessions:
            return "/api/sessions"
        case .sessionsSearch:
            return "/api/sessions/search"
        case .session:
            return "/api/session"
        case .sessionStatus:
            return "/api/session/status"
        case .newSession:
            return "/api/session/new"
        case .renameSession:
            return "/api/session/rename"
        case .deleteSession:
            return "/api/session/delete"
        case .pinSession:
            return "/api/session/pin"
        case .archiveSession:
            return "/api/session/archive"
        case .branchSession:
            return "/api/session/branch"
        case .compressSession:
            return "/api/session/compress"
        case .undoSession:
            return "/api/session/undo"
        case .retrySession:
            return "/api/session/retry"
        case .truncateSession:
            return "/api/session/truncate"
        case .updateSession:
            return "/api/session/update"
        case .moveSession:
            return "/api/session/move"
        case .sessionYolo:
            return "/api/session/yolo"
        case .projects:
            return "/api/projects"
        case .createProject:
            return "/api/projects/create"
        case .renameProject:
            return "/api/projects/rename"
        case .deleteProject:
            return "/api/projects/delete"
        case .chatStart:
            return "/api/chat/start"
        case .chatStream:
            return "/api/chat/stream"
        case .chatCancel:
            return "/api/chat/cancel"
        case .chatStreamStatus:
            return "/api/chat/stream/status"
        case .chatSteer:
            return "/api/chat/steer"
        case .submitGoal:
            return "/api/goal"
        case .approvalPending:
            return "/api/approval/pending"
        case .approvalStream:
            return "/api/approval/stream"
        case .approvalRespond:
            return "/api/approval/respond"
        case .clarifyPending:
            return "/api/clarify/pending"
        case .clarifyStream:
            return "/api/clarify/stream"
        case .clarifyRespond:
            return "/api/clarify/respond"
        case .btw:
            return "/api/btw"
        case .background:
            return "/api/background"
        case .backgroundStatus:
            return "/api/background/status"
        case .workspaces:
            return "/api/workspaces"
        case .workspaceSuggestions:
            return "/api/workspaces/suggest"
        case .directoryList:
            return "/api/list"
        case .file:
            return "/api/file"
        case .rawFile:
            return "/api/file/raw"
        case .media:
            return "/api/media"
        case .gitInfo:
            return "/api/git-info"
        case .gitStatus:
            return "/api/git/status"
        case .gitBranches:
            return "/api/git/branches"
        case .gitDiff:
            return "/api/git/diff"
        case .gitFetch:
            return "/api/git/fetch"
        case .gitPull:
            return "/api/git/pull"
        case .gitPush:
            return "/api/git/push"
        case .gitCheckout:
            return "/api/git/checkout"
        case .gitStashCheckout:
            return "/api/git/stash-checkout"
        case .gitStage:
            return "/api/git/stage"
        case .gitUnstage:
            return "/api/git/unstage"
        case .gitDiscard:
            return "/api/git/discard"
        case .gitCommit:
            return "/api/git/commit"
        case .gitCommitSelected:
            return "/api/git/commit-selected"
        case .gitCommitMessage:
            return "/api/git/commit-message"
        case .gitCommitMessageSelected:
            return "/api/git/commit-message-selected"
        case .models:
            return "/api/models"
        case .modelsLive:
            return "/api/models/live"
        case .commands:
            return "/api/commands"
        case .defaultModel:
            return "/api/default-model"
        case .reasoning:
            return "/api/reasoning"
        case .personalities:
            return "/api/personalities"
        case .setPersonality:
            return "/api/personality/set"
        case .profiles:
            return "/api/profiles"
        case .switchProfile:
            return "/api/profile/switch"
        case .createProfile:
            return "/api/profile/create"
        case .providers:
            return "/api/providers"
        case .settings:
            return "/api/settings"
        case .updatesCheck:
            return "/api/updates/check"
        case .updatesApply:
            return "/api/updates/apply"
        case .insights:
            return "/api/insights"
        case .crons:
            return "/api/crons"
        case .cronCreate:
            return "/api/crons/create"
        case .cronUpdate:
            return "/api/crons/update"
        case .cronDelete:
            return "/api/crons/delete"
        case .cronRun:
            return "/api/crons/run"
        case .cronPause:
            return "/api/crons/pause"
        case .cronResume:
            return "/api/crons/resume"
        case .cronStatus:
            return "/api/crons/status"
        case .cronOutput:
            return "/api/crons/output"
        case .memory:
            return "/api/memory"
        case .memoryWrite:
            return "/api/memory/write"
        case .skills:
            return "/api/skills"
        case .skillContent:
            return "/api/skills/content"
        case .upload:
            return "/api/upload"
        case .transcribe:
            return "/api/transcribe"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .sessionsSearch(query, content, depth):
            return [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "content", value: content ? "1" : "0"),
                URLQueryItem(name: "depth", value: "\(depth)")
            ]
        case let .session(id, includeMessages, messageLimit, messageBefore, expandRenderable):
            var items = [
                URLQueryItem(name: "session_id", value: id),
                URLQueryItem(name: "messages", value: includeMessages ? "1" : "0")
            ]

            if let messageLimit {
                items.append(URLQueryItem(name: "msg_limit", value: "\(messageLimit)"))
            }

            if let messageBefore {
                items.append(URLQueryItem(name: "msg_before", value: "\(messageBefore)"))
            }

            // Opt-in (upstream #3790): on cold load only, ask the server to widen the
            // window until it holds ~msg_limit *renderable* rows so tool-heavy sessions
            // don't open showing 1–2 bubbles. Omitted when false; older servers ignore it.
            if expandRenderable {
                items.append(URLQueryItem(name: "expand_renderable", value: "1"))
            }

            return items
        case let .sessionStatus(id):
            return [URLQueryItem(name: "session_id", value: id)]
        case let .chatStream(streamID),
            let .chatCancel(streamID),
            let .chatStreamStatus(streamID):
            return [URLQueryItem(name: "stream_id", value: streamID)]
        case let .sessionYolo(sessionID):
            guard let sessionID else { return [] }
            return [URLQueryItem(name: "session_id", value: sessionID)]
        case let .approvalPending(sessionID),
            let .approvalStream(sessionID),
            let .clarifyPending(sessionID),
            let .clarifyStream(sessionID):
            return [URLQueryItem(name: "session_id", value: sessionID)]
        case let .backgroundStatus(sessionID):
            return [URLQueryItem(name: "session_id", value: sessionID)]
        case let .directoryList(sessionID, path):
            var items = [URLQueryItem(name: "session_id", value: sessionID)]
            if let path {
                items.append(URLQueryItem(name: "path", value: path))
            }
            return items
        case let .workspaceSuggestions(prefix):
            return [URLQueryItem(name: "prefix", value: prefix)]
        case let .file(sessionID, path),
            let .rawFile(sessionID, path):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ]
        case let .media(path):
            return [URLQueryItem(name: "path", value: path)]
        case let .gitInfo(sessionID),
            let .gitStatus(sessionID),
            let .gitBranches(sessionID):
            return [URLQueryItem(name: "session_id", value: sessionID)]
        case let .gitDiff(sessionID, path, kind):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "kind", value: kind)
            ]
        case let .cronStatus(jobID):
            guard let jobID else { return [] }
            return [URLQueryItem(name: "job_id", value: jobID)]
        case let .cronOutput(jobID, limit):
            var items = [URLQueryItem(name: "job_id", value: jobID)]
            if let limit {
                items.append(URLQueryItem(name: "limit", value: "\(limit)"))
            }
            return items
        case let .insights(days):
            return [URLQueryItem(name: "days", value: "\(days)")]
        case let .skillContent(name, file):
            var items = [URLQueryItem(name: "name", value: name)]
            if let file {
                items.append(URLQueryItem(name: "file", value: file))
            }
            return items
        default:
            return []
        }
    }

    func url(relativeTo baseURL: URL) -> URL {
        let url = baseURL.appending(path: path)
        guard !queryItems.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }
}
