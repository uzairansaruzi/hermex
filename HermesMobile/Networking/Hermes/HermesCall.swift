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

    // Sessions
    /// Mints a plain session under the Profile: no title, not hidden. The host writes no
    /// row until its first prompt (`ConversationTarget.new`).
    case sessionNew(profile: String)

    // Turns
    /// Always `queued`: even an idle Send can race Desktop, so a fresh send never
    /// inherits a host setting that converts it into a redirect or steer.
    case promptSubmit(sessionID: String, text: String)
    /// Cuts the transcript at one durable prompt row and starts the turn again with
    /// `text`, in one call under the host's history lock. Never `queued`: the host
    /// refuses a cut while busy (4009) instead of queueing or steering it. Retry of
    /// a failed turn (#878) uses it; edit and retry-from-here (#745) will too.
    case promptRewind(sessionID: String, text: String, beforeRowID: Int)
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
    case configSet(sessionID: String, profile: String, setting: SessionSetting)
    case sessionCwdSet(sessionID: String, profile: String, cwd: String)
    case sessionControlRead(sessionID: String, profile: String)
    case sessionControl(sessionID: String, profile: String, action: String)

    // Composer panels
    case commandsCatalog(sessionID: String)
    case commandDispatch(name: String, argument: String, sessionID: String)
    case completePath(word: String, sessionID: String, profile: String)

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
    struct Model: Equatable, Sendable {
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

    /// The runtime-scoped writes `config.set` may carry. The host still has a
    /// missing-runtime fallback for effort/fast; never send global or display writes.
    enum SessionSetting: Equatable, Sendable {
        /// `value` must end in `--session` so the host never writes the Profile's default.
        case model(value: String, confirmExpensive: Bool)
        case reasoning(String)
        case fast(Bool)
        /// The session's approval bypass: on auto-approves its dangerous commands, off asks again.
        case yolo(Bool)
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
        case .sessionTitle: return "session.title"
        case .sessionResume: return "session.resume"
        case .sessionEventsSince: return "session.events.since"
        case .sessionActiveList: return "session.active_list"
        case .promptSubmit, .promptRewind: return "prompt.submit"
        case .sessionSteer: return "session.steer"
        case .sessionRedirect: return "session.redirect"
        case .sessionInterrupt: return "session.interrupt"
        case .fileAttach: return "file.attach"
        case .promptBtw: return "prompt.btw"
        case .promptBackground: return "prompt.background"
        case .approvalRespond: return "approval.respond"
        case .requestAnswer: return "request.answer"
        case .clarifyLock: return "clarify.lock"
        case .connectionRespond: return "connection.respond"
        case .messageReact: return "message.react"
        case .modelOptions, .configuredModelOptions: return "model.options"
        case .configSet: return "config.set"
        case .sessionCwdSet: return "session.cwd.set"
        case .sessionControlRead: return "session.control.read"
        case .sessionControl: return "session.control"
        case .commandsCatalog: return "commands.catalog"
        case .commandDispatch: return "command.dispatch"
        case .completePath: return "complete.path"
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
        case .sessionNew(let profile): return ["profile": .string(profile)]
        case .sessionTitle(let sessionID): return ["session_id": .string(sessionID), "title": .string(Self.botChatTitle)]
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
        case .configSet(let sessionID, let profile, let setting):
            var params: [String: BotJSON] = ["session_id": .string(sessionID), "profile": .string(profile), "scope": .string("session")]
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
            }
            return params
        case .sessionCwdSet(let sessionID, let profile, let cwd):
            return ["session_id": .string(sessionID), "profile": .string(profile), "cwd": .string(cwd)]
        case .sessionControl(let sessionID, let profile, let action):
            return ["session_id": .string(sessionID), "profile": .string(profile), "action": .string(action)]
        case .commandDispatch(let name, let argument, let sessionID):
            return ["name": .string(name), "arg": .string(argument), "session_id": .string(sessionID)]
        case .completePath(let word, let sessionID, let profile):
            return ["word": .string(word), "session_id": .string(sessionID), "profile": .string(profile)]
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
        case .sessionCreate(let profile), .sessionNew(let profile): valid = !profile.isEmpty
        case .sessionTitle(let sessionID), .commandsCatalog(let sessionID), .subagentList(let sessionID):
            valid = !sessionID.isEmpty
        case .configSet(let sessionID, _, let setting):
            switch setting {
            case .model(let value, _): valid = !sessionID.isEmpty && value.hasSuffix(" --session")
            case .reasoning(let value): valid = !sessionID.isEmpty && BotModelCatalog.effortLevels.contains(value)
            case .fast, .yolo: valid = !sessionID.isEmpty
            }
        case .commandDispatch(let name, _, let sessionID):
            // One bare name, so this never widens into the general slash runner:
            // the gateway resolves quick commands, which can run shell, ahead of skills.
            valid = !name.isEmpty && !name.hasPrefix("/") && name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && !sessionID.isEmpty
        case .completePath(let word, let sessionID, let profile):
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
