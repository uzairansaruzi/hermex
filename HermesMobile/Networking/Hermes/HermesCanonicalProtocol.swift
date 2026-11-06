import Foundation

// The canonical session protocol a gateway's own listener speaks (#1341): a socket whose
// `gateway.ready` says `session_authority`, such as the Webapp's. Desktop reaches it through one
// adapter (`apps/desktop/src/api/canonical-protocol.ts` upstream); Hermex's is here, at the one
// place a `HermesCall` becomes a frame (`HermesGateway.send`). It translates the wire shape and
// keeps each session's subscription. Calls it doesn't name go out as they would to the dashboard.

extension HermesCall {
    /// `legacy`, the params `params(hostVersion:)` shaped for the dashboard, as a canonical host
    /// takes them. Its methods take a closed set of keys, so one it doesn't know is refused with
    /// 4001 and the key named in `fields`.
    func canonicalParams(_ legacy: [String: BotJSON]) -> [String: BotJSON] {
        var params = legacy
        switch self {
        // A canonical session outlives every socket; a subscription ends with `session.detach`.
        case .sessionResume, .sessionDraft: params["close_on_disconnect"] = nil
        // Replay is per session: the host answers `snapshot_required` with no events for any
        // epoch but the session's own, from its last snapshot.
        case .sessionEventsSince(let profile, _, _, let replayEpoch):
            params["profile"] = .string(profile)
            if let replayEpoch { params["replay_epoch"] = .string(replayEpoch) }
        // The host admits identified input only; each send is one deliberate send, never resent.
        case .promptSubmit(_, _, let fence):
            params["submission_id"] = .string(UUID().uuidString)
            if let fence { params["profile"] = .string(fence.profile) }
        case .sessionSteer(_, _, let fence?), .sessionRedirect(_, _, let fence?), .sessionInterrupt(_, let fence?):
            params.merge(fence.params) { $1 }
        // An approval is answered by its prompt: the generation replaces the queue's request id.
        case .approvalRespond(_, let promptID, _, let fence?):
            params["request_id"] = nil
            params["prompt_id"] = .string(promptID)
            params.merge(fence.params) { $1 }
        // A session-scoped bypass and Fast are the canonical default, and the host refuses
        // `scope: session` for either (#1602, #1604).
        case .configSet(_, _, .yolo), .configSet(_, _, .fast): params["scope"] = nil
        default: break
        }
        return params
    }

    /// What this call subscribes the socket to: a resume's Profile and the session it asks for,
    /// or a create's Profile and nil, since only its reply names the session. Nil for any other call.
    var attachment: (profile: String, requested: HermesCanonicalSubscriptions.Session?)? {
        switch self {
        case .sessionResume(let profile, let sessionID, _): return (profile, .init(profile: profile, id: sessionID))
        case .sessionCreate(let profile), .sessionNew(let profile, _, _), .sessionDraft(let profile): return (profile, nil)
        default: return nil
        }
    }
}

/// A canonical host refused a call because a fence it carried moved on: the session's execution
/// generation (`stale_generation`, a newer turn started first) or its revision (`revision_conflict`,
/// an edit landed first, #1603). Nothing took effect, and nothing is resent; the user acts again.
/// `revision` and `generation` are the host's current ones when the refusal names them.
struct HermesFenceRefusal: Error, Equatable {
    enum Reason: Equatable { case generation, revision }
    let reason: Reason
    var revision: Int?
    var generation: Int?
}

/// The sessions one canonical socket is subscribed to, and which screens hold each. The host
/// keeps one subscription per socket and session, so every screen attached to a session on the
/// shared socket shares it: a second `session.resume` answers the same `subscription_id`. A
/// screen that leaves releases its hold, and only the last one's leaving detaches the session
/// (`session.detach {session_id, subscription_id}`), so two chats on one session never detach
/// each other. A screen holds a session from the moment its resume is sent, because the host
/// answers frames in order: a detach sent while another screen's resume is in flight would
/// end the subscription that resume just shared. A screen that leaves before its attach is
/// answered still gets the reply's subscription detached when nobody else holds the session.
/// Ids repeat across Profiles, so each session is keyed by its Profile too. A new socket starts
/// with none (`HermesGateway.end`).
struct HermesCanonicalSubscriptions {
    struct Session: Hashable {
        let profile: String
        let id: String
    }

    private struct Entry {
        /// The host's last `subscription_id` for this session; nil until a reply named one.
        var subscription: String?
        var holders: Set<Int> = []
    }

    /// An attach the host has not answered: who sent it, and whether that screen has left since.
    private struct Attach {
        let profile: String
        let requested: Session?
        let consumer: Int
        var left = false
    }

    private var entries: [Session: Entry] = [:]
    /// By JSON-RPC request id.
    private var attaching: [Int: Attach] = [:]

    /// `consumer` sent request `id`, a resume of `requested` or a create under `profile`. A
    /// resume holds its session from now.
    mutating func willAttach(_ id: Int, profile: String, requested: Session?, consumer: Int) {
        if let requested { entries[requested, default: Entry()].holders.insert(consumer) }
        attaching[id] = Attach(profile: profile, requested: requested, consumer: consumer)
    }

    /// The host answered request `id` with `result`: for an attach, a snapshot naming the session
    /// it reached (a resume can resolve to a newer compression tip than it asked for) and the
    /// subscription. Returns the detach to send when the screen that asked has left and no other
    /// holds that session; nil otherwise, and for an error or any other call.
    mutating func didAnswer(_ id: Int, with result: BotJSON) -> HermesCall? {
        guard let attach = attaching.removeValue(forKey: id), let session = result["session_id"].text, !session.isEmpty,
              let subscription = result["subscription_id"].text, !subscription.isEmpty else { return nil }
        let reached = Session(profile: attach.profile, id: session)
        entries[reached, default: Entry()].subscription = subscription
        if attach.left {
            guard entries[reached]?.holders.isEmpty == true else { return nil }
            entries[reached] = nil
            return .sessionDetach(profile: reached.profile, sessionID: reached.id, subscriptionID: subscription)
        }
        if let requested = attach.requested, requested != reached { release(attach.consumer, from: requested) }
        entries[reached]?.holders.insert(attach.consumer)
        return nil
    }

    /// `consumer` left: the detaches to send for the sessions no screen holds any more.
    mutating func release(_ consumer: Int) -> [HermesCall] {
        for (id, attach) in attaching where attach.consumer == consumer { attaching[id]?.left = true }
        return Array(entries.keys).compactMap { release(consumer, from: $0) }
    }

    /// Drops every session, for a socket that ended: the host ended its subscriptions with it.
    mutating func removeAll() { entries = [:]; attaching = [:] }

    /// The detach for `session` once `consumer` was its last holder; nil while another holds it
    /// or no reply named its subscription.
    @discardableResult
    private mutating func release(_ consumer: Int, from session: Session) -> HermesCall? {
        guard var entry = entries[session], entry.holders.remove(consumer) != nil else { return nil }
        guard entry.holders.isEmpty else { entries[session] = entry; return nil }
        entries[session] = nil
        return entry.subscription.map { .sessionDetach(profile: session.profile, sessionID: session.id, subscriptionID: $0) }
    }
}

/// A canonical host's approval and clarify prompts (#1602) as the server-request envelopes the
/// chat's request cards read, as Desktop projects them (`canonicalPromptParams`). They arrive as
/// `approval.request` and `clarify.request` events and the snapshot's `prompts`, each with a
/// `prompt_id` and the execution generation its answer carries; a `.settled` event retires one.
/// Sudo, secret and a batch clarify stay ordinary server requests.
enum HermesCanonicalPrompts {
    /// The envelope for one prompt of `sessionID`: its `prompt_id` as the envelope id (and an
    /// approval's `request_id`), its generation in `execution_generation`. Nil for anything else.
    static func envelope(_ prompt: BotJSON, sessionID: String) -> BotJSON? {
        guard let id = prompt["prompt_id"].text, !id.isEmpty, let kind = prompt["kind"].text,
              ["approval", "clarify"].contains(kind), prompt["execution_generation"].integer != nil,
              var params = prompt.fields else { return nil }
        params["kind"] = nil; params["prompt_id"] = nil
        params["session_id"] = .string(sessionID)
        if kind == "approval" { params["request_id"] = .string(id) }
        return .object(["id": .string(id), "method": .string(kind), "params": .object(params)])
    }

    /// `snapshot` with its `prompts` added to its `open_requests`, which a canonical snapshot
    /// keeps for server requests only; unchanged when it holds no prompt.
    static func projecting(_ snapshot: BotJSON, sessionID: String) -> BotJSON {
        let prompts = (snapshot["prompts"].list ?? []).compactMap { envelope($0, sessionID: sessionID) }
        guard !prompts.isEmpty, var fields = snapshot.fields else { return snapshot }
        fields["open_requests"] = .array((snapshot["open_requests"].list ?? []) + prompts)
        return .object(fields)
    }
}

extension BotTransport {
    /// One fenced edit of a stored session no chat holds attached here, such as a delete or a
    /// folder move from the Sessions list (#1603): an identity `session.resume` reads its fences,
    /// then the edit goes out once under them. A refusal throws as `HermesCall.sessionMutate` says.
    func mutateStoredSession(profile: String, key: String,
                             _ operation: HermesCall.SessionMutation.Operation) async throws -> BotJSON {
        let snapshot = try await call(.sessionResume(profile: profile, sessionID: key, omitMessages: true), validateDispatch: nil)
        guard let session = snapshot["session_id"].text, !session.isEmpty, let revision = snapshot["revision"].integer
        else { throw BotFailure.unsupported }
        return try await call(.sessionMutate(.init(profile: profile, sessionID: session, requestID: UUID().uuidString,
                                                   revision: revision, generation: snapshot["execution_generation"].integer,
                                                   operation: operation)), validateDispatch: nil)
    }
}
