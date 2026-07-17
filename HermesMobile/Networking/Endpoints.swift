import Foundation

enum Endpoint {
    case health
    case authStatus
    case login
    case logout
    case sessions(includeArchived: Bool = false, archivedLimit: Int? = nil)
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
    case exportSession(sessionID: String, format: SessionExportFormat)
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
    case workspaceAdd
    case workspaceRemove
    case workspaceRename
    case workspaceReorder
    case directoryList(sessionID: String, path: String?)
    case file(sessionID: String, path: String)
    case rawFile(sessionID: String, path: String)
    case media(sessionID: String, path: String)
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
    case reasoning(model: String? = nil, provider: String? = nil)
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
    case cronDeliveryOptions
    case kanbanConfig
    case kanbanBoards
    case kanbanBoard(KanbanBoardRequest)
    case kanbanStats(board: String)
    case kanbanAssignees(board: String)
    case kanbanEvents(KanbanEventsRequest)
    case kanbanEventsStream(KanbanEventsStreamRequest)
    case kanbanCardDetail(KanbanCardDetailRequest)
    case kanbanWorkerLog(KanbanWorkerLogRequest)
    case kanbanAddComment(KanbanAddCommentRequest)
    case kanbanCreateCard(KanbanCreateCardRequest)
    case kanbanEditCard(KanbanEditCardRequest)
    case kanbanCardStatus(KanbanCardStatusRequest)
    case kanbanBlockCard(KanbanCardActionRequest)
    case kanbanUnblockCard(KanbanCardActionRequest)
    case kanbanAddDependency(KanbanDependencyMutationRequest)
    case kanbanRemoveDependency(KanbanDependencyMutationRequest)
    case memory
    case memoryWrite
    case skills
    case skillContent(name: String, file: String?)
    case toggleSkill
    case upload
    case transcribe
    case tts

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
        case .exportSession:
            return "/api/session/export"
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
        case .workspaceAdd:
            return "/api/workspaces/add"
        case .workspaceRemove:
            return "/api/workspaces/remove"
        case .workspaceRename:
            return "/api/workspaces/rename"
        case .workspaceReorder:
            return "/api/workspaces/reorder"
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
        case .cronDeliveryOptions:
            return "/api/crons/delivery-options"
        case .kanbanConfig:
            return "/api/kanban/config"
        case .kanbanBoards:
            return "/api/kanban/boards"
        case .kanbanBoard:
            return "/api/kanban/board"
        case .kanbanStats:
            return "/api/kanban/stats"
        case .kanbanAssignees:
            return "/api/kanban/assignees"
        case .kanbanEvents:
            return "/api/kanban/events"
        case .kanbanEventsStream:
            return "/api/kanban/events/stream"
        case let .kanbanCardDetail(request):
            return "/api/kanban/tasks/\(request.cardID)"
        case let .kanbanWorkerLog(request):
            return "/api/kanban/tasks/\(request.cardID)/log"
        case let .kanbanAddComment(request):
            return "/api/kanban/tasks/\(request.cardID)/comments"
        case .kanbanCreateCard:
            return "/api/kanban/tasks"
        case let .kanbanEditCard(request):
            return "/api/kanban/tasks/\(request.cardID)"
        case let .kanbanCardStatus(request):
            return "/api/kanban/tasks/\(request.cardID)"
        case let .kanbanBlockCard(request):
            return "/api/kanban/tasks/\(request.cardID)/block"
        case let .kanbanUnblockCard(request):
            return "/api/kanban/tasks/\(request.cardID)/unblock"
        case .kanbanAddDependency:
            return "/api/kanban/links"
        case .kanbanRemoveDependency:
            return "/api/kanban/links/delete"
        case .memory:
            return "/api/memory"
        case .memoryWrite:
            return "/api/memory/write"
        case .skills:
            return "/api/skills"
        case .skillContent:
            return "/api/skills/content"
        case .toggleSkill:
            return "/api/skills/toggle"
        case .upload:
            return "/api/upload"
        case .transcribe:
            return "/api/transcribe"
        case .tts:
            return "/api/tts"
        }
    }

    var queryItems: [URLQueryItem] {
        switch self {
        case let .sessions(includeArchived, archivedLimit):
            // Opt-in (issue #17): the server's default response excludes archived
            // rows, so the main list request stays byte-identical when off.
            // `archived_limit` only means something alongside `include_archived=1`
            // (`_query_positive_int` in upstream routes.py), so it is only sent then.
            guard includeArchived else { return [] }

            var items = [URLQueryItem(name: "include_archived", value: "1")]
            if let archivedLimit {
                items.append(URLQueryItem(name: "archived_limit", value: "\(archivedLimit)"))
            }
            return items
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
        case let .exportSession(sessionID, format):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "format", value: format.rawValue)
            ]
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
        case let .media(sessionID, path):
            return [
                URLQueryItem(name: "session_id", value: sessionID),
                URLQueryItem(name: "path", value: path)
            ]
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
        case let .kanbanBoard(request):
            return request.queryItems
        case let .kanbanStats(board), let .kanbanAssignees(board):
            return [URLQueryItem(name: "board", value: board)]
        case let .kanbanEvents(request):
            return request.queryItems
        case let .kanbanEventsStream(request):
            return request.queryItems
        case let .kanbanCardDetail(request):
            return request.queryItems
        case let .kanbanWorkerLog(request):
            return request.queryItems
        case let .kanbanAddComment(request):
            return request.queryItems
        case let .kanbanCreateCard(request):
            return request.queryItems
        case let .kanbanEditCard(request):
            return request.queryItems
        case let .kanbanCardStatus(request):
            return request.queryItems
        case let .kanbanBlockCard(request), let .kanbanUnblockCard(request):
            return request.queryItems
        case let .kanbanAddDependency(request), let .kanbanRemoveDependency(request):
            return request.queryItems
        case let .reasoning(model, provider):
            var items: [URLQueryItem] = []
            if let model, !model.isEmpty {
                items.append(URLQueryItem(name: "model", value: model))
            }
            if let provider, !provider.isEmpty {
                items.append(URLQueryItem(name: "provider", value: provider))
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
        let url: URL
        switch self {
        case let .kanbanCardDetail(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID)
        case let .kanbanWorkerLog(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID, suffix: "/log")
        case let .kanbanAddComment(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID, suffix: "/comments")
        case let .kanbanEditCard(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID)
        case let .kanbanCardStatus(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID)
        case let .kanbanBlockCard(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID, suffix: "/block")
        case let .kanbanUnblockCard(request):
            url = kanbanTaskURL(relativeTo: baseURL, cardID: request.cardID, suffix: "/unblock")
        default:
            url = baseURL.appending(path: path)
        }
        guard !queryItems.isEmpty else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    private func kanbanTaskURL(relativeTo baseURL: URL, cardID: String, suffix: String = "") -> URL {
        let root = baseURL.appending(path: "/api/kanban/tasks")
        guard var components = URLComponents(url: root, resolvingAgainstBaseURL: false),
              let encodedCardID = cardID.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed)
        else {
            return root
        }
        components.percentEncodedPath += "/\(encodedCardID)\(suffix)"
        return components.url ?? root
    }

    /// RFC 3986 unreserved characters minus `.`. Encoding dots as well keeps
    /// the special `.` and `..` path segments inert while preserving the exact
    /// Card identity after the server decodes the segment.
    private static let pathSegmentAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_~"))
}
