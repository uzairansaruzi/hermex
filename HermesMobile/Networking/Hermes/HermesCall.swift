import Foundation

/// Every JSON-RPC request Hermex sends to a direct Hermes gateway: one case per
/// operation the app uses, and deliberately none for any other upstream method.
/// A case carries only what its callers vary. Values the contract fixes for
/// Hermex (the canonical Bot Chat title, `queued`, the avatar asset, the room
/// page size) are written here, so no caller can widen a request.
///
/// `params()` is the only way to the wire. It runs admission first, for the
/// value rules the types cannot express (a non-empty session, a bare skill
/// name, a valid room id), so `BotClient` never sends a refused request.
enum HermesCall: Equatable, Sendable {
    /// The exact title of a bot's one canonical chat, as Desktop names it.
    static let botChatTitle = "Bot Chat"
    /// Room lists are read in the host's largest page.
    static let roomPageSize = 500

    // Profiles
    case profilesList(includeSessions: Bool)
    case profilesDescribe(name: String)
    /// The Profile's avatar, the only asset Hermex reads.
    case profilesGetAsset(name: String)
    case profilesSetAsset(name: String, avatar: AvatarChange)
    case profilesConfigure(ProfileChanges)
    case profilesCreate(NewProfile)

    // The canonical Bot Chat
    /// Finds the Profile's Bot Chat by its exact title, hidden rows included.
    case sessionList(profile: String)
    /// Mints the Profile's hidden Bot Chat under its configuration.
    case sessionCreate(profile: String)
    /// Persists a freshly minted Bot Chat under its canonical title.
    case sessionTitle(sessionID: String)
    /// Attaches to a session without closing it when this socket drops.
    case sessionResume(profile: String, sessionID: String, omitMessages: Bool)
    case sessionEventsSince(sessionID: String, lastSeen: Int)
    /// The inbox's live-status read. `current_session_id` only marks a TUI's
    /// focused row, which Hermex never has.
    case sessionActiveList
    /// The Sessions list's one Profile-scoped read after it connects (#1046): naming the
    /// Profile makes the host watch its store for `sessions.changed`, which it does only once
    /// some call names it. A Profile the host no longer has answers 4064.
    case sessionMostRecent(profile: String)

    // Sessions
    /// Mints a plain session under the Profile: no title, not hidden. The host writes no
    /// row until its first prompt (`ConversationTarget.new`). `/clear` (#1050) starts it in
    /// the old chat's working folder and on its model; otherwise the Profile's defaults.
    case sessionNew(profile: String, cwd: String? = nil, model: Model? = nil)
    /// `/title` in an open chat (#1048): renames the session `runtime` runs and emits
    /// `session.info`. A title in use or over 100 characters is 4022 with the host's message.
    case sessionRename(runtime: String, title: String)
    /// Ends one runtime, for every client attached to it. Only a delete sends it, and only
    /// for an idle runtime this phone attached (#1048).
    case sessionClose(runtime: String)
    /// Deletes that exact stored session and its messages under `profile` (#1048). The host
    /// refuses with 4023 while a runtime in its process holds the session; REST `DELETE` has
    /// no such check, so it is never used.
    case sessionDelete(profile: String, storedKey: String)
    /// Fork From Here, `/branch` and `/fork` (#1051): copies the session `runtime` runs into a
    /// new session whose `parent_session_id` is this one, and answers `{session_id, stored_session_id,
    /// title, parent, message_count, messages, info}`, its `session_id` the branch's own runtime.
    /// `count` keeps the first rows of the host's visible history (`HermesBranchCount`); without
    /// it every row is copied. Tool rows never are. `name` titles the branch, else the host takes
    /// the parent's next title in its lineage. Nothing to copy is 4008; a name in use is 5008.
    case sessionBranch(runtime: String, name: String?, count: Int?)
    /// Move to Project (#1052): sets that exact stored session's working folder to `cwd` and
    /// answers `{cwd, branch, git_repo_root}`. A runtime on it follows, even mid-turn. A folder
    /// the host lacks is 4017.
    case sessionWorkspaceMove(profile: String, storedKey: String, cwd: String)

    // Projects (#1052): folder-based and per Profile. A session belongs to the project whose
    // folder it works in, so membership is read, never written.
    /// The Profile's project lanes: `{projects, active_id, scoped_session_ids}`. `active_id` is
    /// Desktop's own pick and is never read.
    case projectsTree(profile: String)
    /// A project on one folder, its primary. A folder another project has as its primary is 5063.
    case projectsCreate(profile: String, name: String, folder: String, color: String?)
    /// Renames a project; a nil color leaves its color as it is.
    case projectsUpdate(profile: String, id: String, name: String, color: String?)
    /// Removes the project only: the sessions in its folders stay.
    case projectsDelete(profile: String, id: String)

    // Turns
    /// Always `queued`: even an idle Send can race Desktop, so a fresh send never
    /// inherits a host setting that converts it into a redirect or steer.
    case promptSubmit(sessionID: String, text: String)
    /// Cuts the transcript at one durable prompt row and starts the turn again with
    /// `text`, in one call under the host's history lock. Never `queued`: the host
    /// refuses a cut while busy (4009) instead of queueing or steering it. Bot Chat's
    /// retry of a failed turn (#878) uses it, and so do a Hermes session's Edit,
    /// Regenerate and `/retry` (#1049).
    case promptRewind(sessionID: String, text: String, beforeRowID: Int)
    /// `/undo` in a Hermes session (#1049): rewinds the last real user turn on `runtime`
    /// and answers `{removed}`. Refused while a turn runs (4009).
    case sessionUndo(runtime: String)
    /// `/compress` and `/compact` in a Hermes session (#1050): compacts `runtime`'s history,
    /// steered by `focus`, and answers `{status, removed, summary, info}`; another compressor
    /// holding the lock answers `{lock_held, message}`. Refused while a turn runs (4009).
    case sessionCompress(runtime: String, focus: String?, profile: String)
    case sessionSteer(sessionID: String, text: String)
    case sessionRedirect(sessionID: String, text: String)
    case sessionInterrupt(sessionID: String)
    case fileAttach(sessionID: String, name: String, dataURL: String)

    // Side work (#1013): each runs beside the session's turn, even mid-turn, and answers
    // `{task_id}`; its result arrives later on the session's runtime.
    /// A side question over a snapshot of the conversation, tools off: `btw.complete`.
    case promptBtw(sessionID: String, text: String)
    /// A side agent in its own `bg_<id>` session under the Profile: `background.complete`.
    case promptBackground(sessionID: String, text: String)

    // Answers to the host's requests
    case approvalRespond(sessionID: String, requestID: String, choice: BotApprovalRequest.Choice)
    case requestAnswer(id: String, result: RequestAnswer)
    case clarifyLock(requestID: String, questionID: String, answer: String)
    case connectionRespond(sessionID: String, opID: String, answer: BotConnectionOperation.Answer)
    /// Your own Tapback on one persisted row; nil clears it.
    case messageReact(sessionID: String, rowID: Int, emoji: String?)

    // Runtime-scoped session settings
    case modelOptions(sessionID: String, profile: String)
    /// The configured-provider inventory the Profile editors pick from.
    case configuredModelOptions
    /// One Profile's models, outside any session: the Task editor's picker (#1040).
    case profileModelOptions(profile: String)
    case configSet(sessionID: String, profile: String, setting: SessionSetting)
    case sessionCwdSet(sessionID: String, profile: String, cwd: String)
    case sessionControlRead(sessionID: String, profile: String)
    case sessionControl(sessionID: String, profile: String, action: String)

    // Composer panels
    case commandsCatalog(sessionID: String)
    case commandDispatch(name: String, argument: String, sessionID: String)
    /// `timesOutLocally`: the Hermes chat's `@` lookups (#1113) fail only themselves when the
    /// host never answers. Bot Chat's keep the required-call policy, ending its screen's
    /// connection.
    case completePath(word: String, sessionID: String, profile: String, timesOutLocally: Bool = false)
    /// `complete.path` for a host folder outside any session (#1052): `word` is a path from the
    /// host's root or home (`HermesFolderCompletion.completes`), so no session's folder resolves it.
    case completeFolder(word: String, profile: String)
    /// `complete.slash` at a command's argument stage (#1036): `text` is one `/name …` line
    /// with a space. The command stage is ranked on the phone from `commands.catalog`.
    case completeSlash(text: String, sessionID: String)
    /// Runs one typed `/name …` line on the session (#1036): the host's built-ins, the user's
    /// quick commands (which can run shell) and plugin commands, as Desktop runs them.
    case slashExec(sessionID: String, command: String)

    // Git (#1115)
    /// A commit message for `diff`, from `llm.oneshot`'s `commit_message` template at Desktop's
    /// temperature: one stateless model call outside the conversation, on the model of the
    /// runtime `sessionID` names when there is one, else the Profile's task backend. `avoid` is the
    /// last suggestion, which the host is told not to repeat. Answers `{text}`.
    case commitMessage(diff: String, recentCommits: String, avoid: String?, sessionID: String?, profile: String)

    // Usage
    /// The Profile's visible sessions started in the last `days` (1-365) and their messages, over
    /// at most its newest 500 sessions: `{days, sessions, messages}`, or 5017 for a store the host
    /// can't open (#1074).
    case insightsGet(days: Int, profile: String)

    // Delegated work
    case subagentList(sessionID: String)
    case subagentTail(sessionID: String, subagentID: String)
    case subagentInterrupt(sessionID: String, subagentID: String)

    // Rooms: reads, participation and lifecycle; never peer administration.
    case groupsCapabilities
    case groupsList(offset: Int)
    case groupsState(roomID: String)
    case groupsLog(roomID: String, sinceSeq: Int, limit: Int)
    case groupsSend(roomID: String, eventID: String, text: String, threadID: String)
    case groupsStop(roomID: String, cancelID: String)
    case groupsApprove(roomID: String, memberID: String, taskID: String, executionGeneration: Int,
                       requestID: String, choice: BotApprovalRequest.Choice)
    case groupsRetry(roomID: String, taskID: String)
    case groupsCreate(RoomCreation)
    case groupsRename(roomID: String, eventID: String, name: String)
    case groupsDisband(roomID: String)

    /// The socket handshake's opt-in to server→client requests. `BotClient` sends it itself.
    case clientCapabilities

    /// A new avatar as a base64 data URL, or its removal.
    enum AvatarChange: Equatable, Sendable {
        case replace(String)
        case clear
    }

    /// A model the host resolves under one provider.
    struct Model: Hashable, Sendable {
        var id: String
        var provider: String
    }

    /// Desktop's `hermes-bots` look object, sent whole under the revision it was read at.
    struct Look: Equatable, Sendable {
        var fields: [String: BotJSON]
        var revision: Int
    }

    /// One `profiles.configure` write. Only the fields that are set are sent.
    struct ProfileChanges: Equatable, Sendable {
        var name: String
        var description: String?
        var soul: String?
        var model: Model?
        /// Resends a model change the host asked to confirm. Only with `model`.
        var confirmExpensiveModel = false
        var disabledSkills: [String]?
        var enabledToolsets: [String]?
        var enabledMCPServers: [String]?
        var look: Look?
    }

    /// One `profiles.create`. A clone copies its source's skills, so it cannot skip them.
    struct NewProfile: Equatable, Sendable {
        var name: String
        var description: String?
        var cloneFrom: String?
        var soul: String?
        var model: Model?
        var skipsBundledSkills = false
        /// True shares the default Profile's credentials; false keeps its own, unmirrored.
        var sharesCredentials: Bool
    }

    /// `request.answer`'s result: a `value` for sudo, secret and Desktop prompts,
    /// an `answer` for an unkeyed clarify.
    enum RequestAnswer: Equatable, Sendable {
        case value(String)
        case answer(String)
    }

    /// The writes `config.set` may carry. All are runtime-scoped except `personality`. The
    /// host still has a missing-runtime fallback for effort/fast; never send global or display writes.
    enum SessionSetting: Equatable, Sendable {
        /// `value` must end in `--session` so the host never writes the Profile's default.
        case model(value: String, confirmExpensive: Bool)
        case reasoning(String)
        case fast(Bool)
        /// The session's approval bypass: on auto-approves its dangerous commands, off asks again.
        case yolo(Bool)
        /// The one write that reaches the Profile, deliberately (#1016): the host has no
        /// session-only personality, so it always writes the Profile's default and switches
        /// this session too. `none` clears it. Sent without a scope, which the host ignores here.
        case personality(String)
    }

    /// One immutable room creation. A deliberate retry resends the same value.
    struct RoomCreation: Equatable, Sendable {
        var roomID: String
        var name: String
        var members: [RoomMember]
    }

    struct RoomMember: Equatable, Sendable {
        var memberID: String
        var profile: String
        var handle: String
        var displayName: String?

        var json: BotJSON {
            var fields: [String: BotJSON] = ["member_id": .string(memberID), "profile": .string(profile), "handle": .string(handle)]
            if let displayName { fields["display_name"] = .string(displayName) }
            return .object(fields)
        }
    }

    var method: String {
        switch self {
        case .profilesList: return "profiles.list"
        case .profilesDescribe: return "profiles.describe"
        case .profilesGetAsset: return "profiles.get_asset"
        case .profilesSetAsset: return "profiles.set_asset"
        case .profilesConfigure: return "profiles.configure"
        case .profilesCreate: return "profiles.create"
        case .sessionList: return "session.list"
        case .sessionCreate, .sessionNew: return "session.create"
        case .sessionTitle, .sessionRename: return "session.title"
        case .sessionClose: return "session.close"
        case .sessionDelete: return "session.delete"
        case .sessionBranch: return "session.branch"
        case .sessionWorkspaceMove: return "session.workspace.move"
        case .projectsTree: return "projects.tree"
        case .projectsCreate: return "projects.create"
        case .projectsUpdate: return "projects.update"
        case .projectsDelete: return "projects.delete"
        case .sessionResume: return "session.resume"
        case .sessionEventsSince: return "session.events.since"
        case .sessionActiveList: return "session.active_list"
        case .sessionMostRecent: return "session.most_recent"
        case .promptSubmit, .promptRewind: return "prompt.submit"
        case .sessionSteer: return "session.steer"
        case .sessionRedirect: return "session.redirect"
        case .sessionInterrupt: return "session.interrupt"
        case .sessionUndo: return "session.undo"
        case .sessionCompress: return "session.compress"
        case .fileAttach: return "file.attach"
        case .promptBtw: return "prompt.btw"
        case .promptBackground: return "prompt.background"
        case .approvalRespond: return "approval.respond"
        case .requestAnswer: return "request.answer"
        case .clarifyLock: return "clarify.lock"
        case .connectionRespond: return "connection.respond"
        case .messageReact: return "message.react"
        case .modelOptions, .configuredModelOptions, .profileModelOptions: return "model.options"
        case .configSet: return "config.set"
        case .sessionCwdSet: return "session.cwd.set"
        case .sessionControlRead: return "session.control.read"
        case .sessionControl: return "session.control"
        case .commandsCatalog: return "commands.catalog"
        case .commandDispatch: return "command.dispatch"
        case .completePath, .completeFolder: return "complete.path"
        case .completeSlash: return "complete.slash"
        case .slashExec: return "slash.exec"
        case .insightsGet: return "insights.get"
        case .commitMessage: return "llm.oneshot"
        case .subagentList: return "subagent.list"
        case .subagentTail: return "subagent.tail"
        case .subagentInterrupt: return "subagent.interrupt"
        case .groupsCapabilities: return "groups.capabilities"
        case .groupsList: return "groups.list"
        case .groupsState: return "groups.state"
        case .groupsLog: return "groups.log"
        case .groupsSend: return "groups.send"
        case .groupsStop: return "groups.stop"
        case .groupsApprove: return "groups.approve"
        case .groupsRetry: return "groups.retry"
        case .groupsCreate: return "groups.create"
        case .groupsRename: return "groups.rename"
        case .groupsDisband: return "groups.disband"
        case .clientCapabilities: return "client.capabilities"
        }
    }

    /// The JSON-RPC `params`, after admission, in the shape the host's release takes.
    /// `hostVersion` is the `version` `/api/status` reported; nil reads as the pin.
    /// Throws `BotFailure.unsupported` for a value the host must never receive from this app.
    func params(hostVersion: String? = nil) throws -> [String: BotJSON] {
        try admit()
        switch self {
        case .profilesList(let includeSessions): return ["include_sessions": .bool(includeSessions)]
        case .profilesDescribe(let name): return ["name": .string(name)]
        case .profilesGetAsset(let name): return ["name": .string(name), "asset": .string("avatar")]
        case .profilesSetAsset(let name, .replace(let data)):
            return ["name": .string(name), "asset": .string("avatar"), "data": .string(data)]
        case .profilesSetAsset(let name, .clear):
            return ["name": .string(name), "asset": .string("avatar"), "clear": .bool(true)]
        case .profilesConfigure(let changes): return changes.params
        case .profilesCreate(let profile): return profile.params
        case .sessionList(let profile):
            return ["profile": .string(profile), "title": .string(Self.botChatTitle), "include_hidden": .bool(true)]
        case .sessionCreate(let profile):
            return ["profile": .string(profile), "title": .string(Self.botChatTitle),
                    "hidden": .bool(true), "follow_profile_config": .bool(true)]
        case .sessionNew(let profile, let cwd, let model):
            var params: [String: BotJSON] = ["profile": .string(profile)]
            if let cwd { params["cwd"] = .string(cwd) }
            if let model { params["model"] = .string(model.id); params["provider"] = .string(model.provider) }
            return params
        case .sessionMostRecent(let profile): return ["profile": .string(profile)]
        case .sessionTitle(let sessionID): return ["session_id": .string(sessionID), "title": .string(Self.botChatTitle)]
        case .sessionRename(let runtime, let title): return ["session_id": .string(runtime), "title": .string(title)]
        case .sessionClose(let runtime), .sessionUndo(let runtime): return ["session_id": .string(runtime)]
        case .sessionDelete(let profile, let storedKey): return ["session_id": .string(storedKey), "profile": .string(profile)]
        case .sessionBranch(let runtime, let name, let count):
            var params: [String: BotJSON] = ["session_id": .string(runtime)]
            if let name { params["name"] = .string(name) }
            if let count { params["count"] = .number(Double(count)) }
            return params
        case .sessionWorkspaceMove(let profile, let storedKey, let cwd):
            return ["session_key": .string(storedKey), "cwd": .string(cwd), "profile": .string(profile)]
        case .projectsTree(let profile): return ["profile": .string(profile)]
        case .projectsCreate(let profile, let name, let folder, let color):
            var params: [String: BotJSON] = ["profile": .string(profile), "name": .string(name),
                                             "folders": .array([.string(folder)]), "primary_path": .string(folder)]
            if let color { params["color"] = .string(color) }
            return params
        case .projectsUpdate(let profile, let id, let name, let color):
            var params: [String: BotJSON] = ["profile": .string(profile), "id": .string(id), "name": .string(name)]
            if let color { params["color"] = .string(color) }
            return params
        case .projectsDelete(let profile, let id): return ["profile": .string(profile), "id": .string(id)]
        case .sessionCompress(let runtime, let focus, let profile):
            var params: [String: BotJSON] = ["session_id": .string(runtime), "profile": .string(profile)]
            if let focus { params["focus_topic"] = .string(focus) }
            return params
        case .sessionResume(let profile, let sessionID, let omitMessages):
            var params: [String: BotJSON] = ["profile": .string(profile), "session_id": .string(sessionID),
                                             "close_on_disconnect": .bool(false)]
            if omitMessages { params["omit_messages"] = .bool(true) }
            return params
        case .sessionEventsSince(let sessionID, let lastSeen):
            return ["session_id": .string(sessionID), "last_seen": .number(Double(lastSeen))]
        case .sessionActiveList, .groupsCapabilities: return [:]
        case .promptSubmit(let sessionID, let text):
            return ["session_id": .string(sessionID), "text": .string(text), "queued": .bool(true)]
        case .promptRewind(let sessionID, let text, let rowID):
            // `confirm_empty_truncate` too, as Desktop sends whenever it names a row:
            // cutting at the first prompt legitimately empties the transcript.
            return ["session_id": .string(sessionID), "text": .string(text), "truncate_before_row_id": .number(Double(rowID)),
                    "confirm_truncate": .bool(true), "confirm_empty_truncate": .bool(true)]
        case .sessionSteer(let sessionID, let text), .sessionRedirect(let sessionID, let text),
             .promptBtw(let sessionID, let text), .promptBackground(let sessionID, let text):
            return ["session_id": .string(sessionID), "text": .string(text)]
        case .sessionInterrupt(let sessionID), .commandsCatalog(let sessionID), .subagentList(let sessionID):
            return ["session_id": .string(sessionID)]
        case .fileAttach(let sessionID, let name, let dataURL):
            return ["session_id": .string(sessionID), "name": .string(name), "data_url": .string(dataURL)]
        case .approvalRespond(let sessionID, let requestID, let choice):
            return ["session_id": .string(sessionID), "request_id": .string(requestID), "choice": .string(choice.rawValue)]
        case .requestAnswer(let id, .value(let value)):
            return ["id": .string(id), "result": .object(["value": .string(value)])]
        case .requestAnswer(let id, .answer(let answer)):
            return ["id": .string(id), "result": .object(["answer": .string(answer)])]
        case .clarifyLock(let requestID, let questionID, let answer):
            return ["request_id": .string(requestID), "question_id": .string(questionID), "answer": .string(answer)]
        case .connectionRespond(let sessionID, let opID, let answer):
            // 0.21.5 names the session as an `owner`; 0.21.4 took a bare `session_id`.
            // Each refuses the other's key, so send the one the host's release expects.
            var params: [String: BotJSON] = ["op_id": .string(opID), "result": answer.result]
            if Self.predatesSessionOwner(hostVersion) { params["session_id"] = .string(sessionID) }
            else { params["owner"] = .object(["type": .string("session"), "session_id": .string(sessionID)]) }
            return params
        case .messageReact(let sessionID, let rowID, let emoji):
            return ["session_id": .string(sessionID), "row_id": .number(Double(rowID)), "emoji": emoji.map(BotJSON.string) ?? .null]
        case .modelOptions(let sessionID, let profile), .sessionControlRead(let sessionID, let profile):
            return ["session_id": .string(sessionID), "profile": .string(profile)]
        case .configuredModelOptions: return ["include_unconfigured": .bool(false)]
        case .profileModelOptions(let profile): return ["profile": .string(profile)]
        case .configSet(let sessionID, let profile, let setting):
            var params: [String: BotJSON] = ["session_id": .string(sessionID), "profile": .string(profile)]
            if case .personality = setting {} else { params["scope"] = .string("session") }
            switch setting {
            case .model(let value, let confirmExpensive):
                params["key"] = .string("model"); params["value"] = .string(value)
                params["confirm_expensive_model"] = .bool(confirmExpensive)
            case .reasoning(let value):
                params["key"] = .string("reasoning"); params["value"] = .string(value)
            case .fast(let enabled):
                params["key"] = .string("fast"); params["value"] = .string(enabled ? "fast" : "normal")
            case .yolo(let enabled):
                params["key"] = .string("yolo"); params["value"] = .string(enabled ? "on" : "off")
            case .personality(let name):
                params["key"] = .string("personality"); params["value"] = .string(name)
            }
            return params
        case .sessionCwdSet(let sessionID, let profile, let cwd):
            return ["session_id": .string(sessionID), "profile": .string(profile), "cwd": .string(cwd)]
        case .sessionControl(let sessionID, let profile, let action):
            return ["session_id": .string(sessionID), "profile": .string(profile), "action": .string(action)]
        case .commandDispatch(let name, let argument, let sessionID):
            return ["name": .string(name), "arg": .string(argument), "session_id": .string(sessionID)]
        case .completePath(let word, let sessionID, let profile, _):
            return ["word": .string(word), "session_id": .string(sessionID), "profile": .string(profile)]
        case .completeFolder(let word, let profile): return ["word": .string(word), "profile": .string(profile)]
        case .completeSlash(let text, let sessionID): return ["text": .string(text), "session_id": .string(sessionID)]
        case .slashExec(let sessionID, let command): return ["session_id": .string(sessionID), "command": .string(command)]
        case .insightsGet(let days, let profile): return ["days": .number(Double(days)), "profile": .string(profile)]
        case .commitMessage(let diff, let recentCommits, let avoid, let sessionID, let profile):
            var variables: [String: BotJSON] = ["diff": .string(diff), "recent_commits": .string(recentCommits)]
            if let avoid { variables["avoid"] = .string(avoid) }
            var params: [String: BotJSON] = ["template": .string("commit_message"), "variables": .object(variables),
                                             "temperature": .number(0.8), "profile": .string(profile)]
            if let sessionID { params["session_id"] = .string(sessionID) }
            return params
        case .subagentTail(let sessionID, let subagentID), .subagentInterrupt(let sessionID, let subagentID):
            return ["session_id": .string(sessionID), "subagent_id": .string(subagentID)]
        case .groupsList(let offset):
            return ["limit": .number(Double(Self.roomPageSize)), "offset": .number(Double(offset))]
        case .groupsState(let roomID), .groupsDisband(let roomID): return ["room_id": .string(roomID)]
        case .groupsLog(let roomID, let sinceSeq, let limit):
            return ["room_id": .string(roomID), "since_seq": .number(Double(sinceSeq)), "limit": .number(Double(limit))]
        case .groupsSend(let roomID, let eventID, let text, let threadID):
            return ["room_id": .string(roomID), "event_id": .string(eventID),
                    "payload": .object(["text": .string(text), "thread_id": .string(threadID)])]
        case .groupsStop(let roomID, let cancelID): return ["room_id": .string(roomID), "cancel_id": .string(cancelID)]
        case .groupsApprove(let roomID, let memberID, let taskID, let executionGeneration, let requestID, let choice):
            return ["room_id": .string(roomID), "member_id": .string(memberID), "task_id": .string(taskID),
                    "execution_generation": .number(Double(executionGeneration)),
                    "request_id": .string(requestID), "choice": .string(choice.rawValue)]
        case .groupsRetry(let roomID, let taskID): return ["room_id": .string(roomID), "task_id": .string(taskID)]
        case .groupsCreate(let room):
            return ["room_id": .string(room.roomID), "name": .string(room.name), "members": .array(room.members.map(\.json))]
        case .groupsRename(let roomID, let eventID, let name):
            return ["room_id": .string(roomID), "event_id": .string(eventID), "name": .string(name)]
        case .clientCapabilities: return ["server_requests": .bool(true)]
        }
    }

    /// Whether `version` is a release before 0.21.5, which moved `connection.respond`'s
    /// `session_id` into `owner`. A canary reads as its base release; a missing, partial
    /// or unreadable one reads as the pin (`HermesCompatibility.release`).
    private static func predatesSessionOwner(_ version: String?) -> Bool {
        HermesCompatibility.release(version)?.lexicographicallyPrecedes([0, 21, 5]) ?? false
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One line that opens with `/` and names something after it.
    private static func isSlashLine(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("/") && !text.contains(where: \.isNewline)
    }

    /// The value rules each case's types cannot express. A case with none is `true`.
    private func admit() throws {
        let valid: Bool
        switch self {
        case .profilesDescribe(let name): valid = !name.isEmpty
        case .profilesSetAsset(let name, let avatar):
            // Base64 for the server's 2 MB decoded cap, with small data-URL headroom.
            if case .replace(let data) = avatar { valid = !name.isEmpty && !data.isEmpty && data.utf8.count <= 3_000_000 }
            else { valid = !name.isEmpty }
        case .profilesConfigure(let changes): valid = changes.isAdmissible
        case .profilesCreate(let profile): valid = profile.isAdmissible
        case .sessionCreate(let profile), .sessionMostRecent(let profile): valid = !profile.isEmpty
        case .sessionNew(let profile, let cwd, let model):
            valid = !profile.isEmpty && cwd?.isEmpty != true && model?.isAdmissible != false
        case .sessionCompress(let runtime, let focus, let profile):
            valid = !runtime.isEmpty && !profile.isEmpty && focus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        case .sessionTitle(let sessionID), .commandsCatalog(let sessionID), .subagentList(let sessionID),
             .sessionClose(let sessionID), .sessionUndo(let sessionID):
            valid = !sessionID.isEmpty
        case .sessionRename(let runtime, let title):
            valid = !runtime.isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sessionDelete(let profile, let storedKey): valid = !profile.isEmpty && !storedKey.isEmpty
        case .sessionBranch(let runtime, let name, let count):
            valid = !runtime.isEmpty && name.map(Self.isBlank) != true && (count ?? 1) > 0
        case .sessionWorkspaceMove(let profile, let storedKey, let cwd):
            valid = !profile.isEmpty && !storedKey.isEmpty && !Self.isBlank(cwd)
        case .projectsTree(let profile): valid = !profile.isEmpty
        case .projectsCreate(let profile, let name, let folder, let color):
            valid = !profile.isEmpty && !Self.isBlank(name) && !Self.isBlank(folder) && color?.isEmpty != true
        case .projectsUpdate(let profile, let id, let name, let color):
            valid = !profile.isEmpty && !id.isEmpty && !Self.isBlank(name) && color?.isEmpty != true
        case .projectsDelete(let profile, let id): valid = !profile.isEmpty && !id.isEmpty
        case .completeFolder(let word, let profile): valid = HermesFolderCompletion.completes(word) && !profile.isEmpty
        case .configSet(let sessionID, _, let setting):
            switch setting {
            case .model(let value, _): valid = !sessionID.isEmpty && value.hasSuffix(" --session")
            case .reasoning(let value): valid = !sessionID.isEmpty && HermesModelCatalog.effortLevels.contains(value)
            case .fast, .yolo: valid = !sessionID.isEmpty
            case .personality(let name):
                valid = !sessionID.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .commandDispatch(let name, _, let sessionID):
            // One bare name, so this never widens into the general slash runner:
            // the gateway resolves quick commands, which can run shell, ahead of skills.
            valid = !name.isEmpty && !name.hasPrefix("/") && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && !sessionID.isEmpty
        case .completeSlash(let text, let sessionID):
            // The argument stage only: a named command, then a space.
            valid = !sessionID.isEmpty && Self.isSlashLine(text) && text.dropFirst().first?.isWhitespace == false
                && text.contains(" ")
        case .slashExec(let sessionID, let command):
            valid = !sessionID.isEmpty && Self.isSlashLine(command) && command.dropFirst().first?.isWhitespace == false
        case .completePath(let word, let sessionID, let profile, _):
            valid = !word.isEmpty && !word.contains(where: \.isWhitespace) && !sessionID.isEmpty && !profile.isEmpty
        case .subagentTail(let sessionID, let subagentID), .subagentInterrupt(let sessionID, let subagentID):
            valid = !sessionID.isEmpty && !subagentID.isEmpty
        case .connectionRespond(let sessionID, let opID, let answer):
            let answerIsValid: Bool
            switch answer {
            case .continueWithout: answerIsValid = true
            case .skip(let target): answerIsValid = !target.isEmpty
            case .connect(let target, let env):
                answerIsValid = !target.isEmpty && env.allSatisfy { !$0.key.isEmpty && !$0.value.isEmpty }
            }
            valid = !sessionID.isEmpty && !opID.isEmpty && answerIsValid
        case .messageReact(let sessionID, _, let emoji):
            valid = !sessionID.isEmpty && emoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        case .promptRewind(let sessionID, let text, let rowID):
            valid = !sessionID.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rowID > 0
        case .promptBtw(let sessionID, let text), .promptBackground(let sessionID, let text):
            // The host refuses empty text (4012).
            valid = !sessionID.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .groupsList(let offset): valid = offset >= 0
        case .profileModelOptions(let profile): valid = !profile.isEmpty
        case .insightsGet(let days, let profile): valid = (1...365).contains(days) && !profile.isEmpty
        case .commitMessage(let diff, _, let avoid, let sessionID, let profile):
            valid = !Self.isBlank(diff) && avoid.map(Self.isBlank) != true && sessionID?.isEmpty != true && !profile.isEmpty
        case .groupsState(let roomID), .groupsDisband(let roomID): valid = BotRoomRPC.validID(roomID)
        case .groupsLog(let roomID, let sinceSeq, let limit):
            valid = BotRoomRPC.validID(roomID) && sinceSeq >= 0 && (1...Self.roomPageSize).contains(limit)
        case .groupsSend(let roomID, let eventID, let text, let threadID):
            valid = [roomID, eventID, threadID].allSatisfy(BotRoomRPC.validID) && BotRoomRPC.validText(text)
        case .groupsStop(let roomID, let cancelID): valid = BotRoomRPC.validID(roomID) && BotRoomRPC.validID(cancelID)
        case .groupsApprove(let roomID, let memberID, let taskID, let executionGeneration, let requestID, let choice):
            valid = [roomID, memberID, taskID, requestID].allSatisfy(BotRoomRPC.validID) && executionGeneration > 0
                && [.once, .deny].contains(choice)
        case .groupsRetry(let roomID, let taskID): valid = BotRoomRPC.validID(roomID) && BotRoomRPC.validID(taskID)
        case .groupsCreate(let room): valid = room.isAdmissible
        case .groupsRename(let roomID, let eventID, let name):
            valid = BotRoomRPC.validID(roomID) && BotRoomRPC.validID(eventID) && BotRoomRPC.validName(name)
        case .profilesList, .profilesGetAsset, .sessionList, .sessionResume, .sessionEventsSince, .sessionActiveList,
             .promptSubmit, .sessionSteer, .sessionRedirect, .sessionInterrupt, .fileAttach, .approvalRespond,
             .requestAnswer, .clarifyLock, .modelOptions, .configuredModelOptions, .sessionCwdSet, .sessionControlRead,
             .sessionControl, .groupsCapabilities, .clientCapabilities:
            valid = true
        }
        guard valid else { throw BotFailure.unsupported }
    }
}

private extension HermesCall.ProfileChanges {
    var isAdmissible: Bool {
        let changesSomething = description != nil || soul != nil || model != nil || disabledSkills != nil
            || enabledToolsets != nil || enabledMCPServers != nil || look != nil
        let lists = [disabledSkills, enabledToolsets, enabledMCPServers].compactMap { $0 }
        return !name.isEmpty && changesSomething && model?.isAdmissible != false
            && (!confirmExpensiveModel || model != nil)
            && lists.allSatisfy { $0.allSatisfy { !$0.isEmpty } } && (look?.revision ?? 0) >= 0
    }

    var params: [String: BotJSON] {
        var params: [String: BotJSON] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let model {
            params["model"] = .string(model.id); params["provider"] = .string(model.provider)
            if confirmExpensiveModel { params["confirm_expensive_model"] = .bool(true) }
        }
        if let disabledSkills { params["disabled_skills"] = .array(disabledSkills.map(BotJSON.string)) }
        if let enabledToolsets { params["enabled_toolsets"] = .array(enabledToolsets.map(BotJSON.string)) }
        if let enabledMCPServers { params["enabled_mcp_servers"] = .array(enabledMCPServers.map(BotJSON.string)) }
        if let look {
            params["ui_meta"] = .object(["hermes-bots": .object(look.fields)])
            params["ui_meta_expected_revisions"] = .object(["hermes-bots": .number(Double(look.revision))])
        }
        return params
    }
}

private extension HermesCall.NewProfile {
    var isAdmissible: Bool {
        BotProfileName.isValid(name) && [description, cloneFrom, soul].allSatisfy { $0?.isEmpty != true }
            && model?.isAdmissible != false && !(skipsBundledSkills && cloneFrom != nil)
    }

    var params: [String: BotJSON] {
        var params: [String: BotJSON] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let cloneFrom { params["clone_from"] = .string(cloneFrom) }
        if let soul { params["soul"] = .string(soul) }
        if let model { params["model"] = .string(model.id); params["provider"] = .string(model.provider) }
        if skipsBundledSkills { params["no_skills"] = .bool(true) }
        if sharesCredentials { params["share_auth"] = .bool(true) } else { params["mirror_credentials"] = .bool(false) }
        return params
    }
}

private extension HermesCall.Model {
    var isAdmissible: Bool { !id.isEmpty && !provider.isEmpty }
}

private extension HermesCall.RoomCreation {
    /// Two to six members, each a Profile addressed by its own name (`default` may
    /// answer to `hermes`), with no duplicate id, Profile or handle and no handle
    /// that collides with `all` or `everyone`.
    var isAdmissible: Bool {
        guard BotRoomRPC.validID(roomID), BotRoomRPC.validName(name), (2...6).contains(members.count) else { return false }
        var ids = Set<String>(), profiles = Set<String>(), handles: Set<String> = ["all", "everyone"]
        return members.allSatisfy { member in
            [member.memberID, member.profile, member.handle].allSatisfy(BotRoomRPC.validID)
                && ids.insert(member.memberID.lowercased()).inserted
                && profiles.insert(member.profile.lowercased()).inserted
                && handles.insert(member.handle.lowercased()).inserted
                && member.memberID == member.profile
                && (member.handle == member.profile || (member.profile == "default" && member.handle == "hermes"))
                && (member.displayName?.unicodeScalars.count ?? 0) <= 200
        }
    }
}
