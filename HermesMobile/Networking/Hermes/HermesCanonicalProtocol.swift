import Foundation

extension HermesCall {
    func canonicalParams(_ legacy: [String: BotJSON]) -> [String: BotJSON] {
        var params = legacy
        switch self {
        case .sessionResume, .sessionDraft: params["close_on_disconnect"] = nil
        case .sessionEventsSince(let profile, _, _, let replayEpoch):
            params["profile"] = .string(profile)
            if let replayEpoch { params["replay_epoch"] = .string(replayEpoch) }
        case .promptSubmit(_, _, let fence, _, _):
            params["submission_id"] = .string(UUID().uuidString)
            if let fence { params["profile"] = .string(fence.profile) }
        case .sessionSteer(_, _, let fence?), .sessionRedirect(_, _, let fence?), .sessionInterrupt(_, let fence?):
            params.merge(fence.params) { $1 }
        case .approvalRespond(_, let promptID, _, let fence?):
            params["request_id"] = nil
            params["prompt_id"] = .string(promptID)
            params.merge(fence.params) { $1 }
        case .groupsRetry(_, _, let attempt?): params.merge(attempt.params) { $1 }
        case .configSet(_, _, .yolo), .configSet(_, _, .fast): params["scope"] = nil
        default: break
        }
        return params
    }

    var attachment: (profile: String, requested: HermesCanonicalSubscriptions.Session?)? {
        switch self {
        case .sessionResume(let profile, let sessionID, _): return (profile, .init(profile: profile, id: sessionID))
        case .sessionCreate(let profile), .sessionNew(let profile, _, _), .sessionDraft(let profile): return (profile, nil)
        default: return nil
        }
    }
}

struct HermesFenceRefusal: Error, Equatable {
    enum Reason: Equatable { case generation, revision }
    let reason: Reason
    var revision: Int?
    var generation: Int?
}

struct HermesCanonicalSubscriptions {
    struct Session: Hashable {
        let profile: String
        let id: String
    }

    private struct Entry {
        var subscription: String?
        var holders: Set<Int> = []
    }

    private struct Attach {
        let profile: String
        let requested: Session?
        let consumer: Int
        var left = false
    }

    private var entries: [Session: Entry] = [:]
    private var attaching: [Int: Attach] = [:]

    mutating func willAttach(_ id: Int, profile: String, requested: Session?, consumer: Int) {
        if let requested { entries[requested, default: Entry()].holders.insert(consumer) }
        attaching[id] = Attach(profile: profile, requested: requested, consumer: consumer)
    }

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

    mutating func release(_ consumer: Int) -> [HermesCall] {
        for (id, attach) in attaching where attach.consumer == consumer { attaching[id]?.left = true }
        return Array(entries.keys).compactMap { release(consumer, from: $0) }
    }

    mutating func removeAll() { entries = [:]; attaching = [:] }

    @discardableResult
    mutating func release(_ consumer: Int, from session: Session) -> HermesCall? {
        guard var entry = entries[session], entry.holders.remove(consumer) != nil else { return nil }
        guard entry.holders.isEmpty else { entries[session] = entry; return nil }
        entries[session] = nil
        return entry.subscription.map { .sessionDetach(profile: session.profile, sessionID: session.id, subscriptionID: $0) }
    }
}

enum HermesCanonicalPrompts {
    static func envelope(_ prompt: BotJSON, sessionID: String) -> BotJSON? {
        guard let id = prompt["prompt_id"].text, !id.isEmpty, let kind = prompt["kind"].text,
              ["approval", "clarify"].contains(kind), prompt["execution_generation"].integer != nil,
              var params = prompt.fields else { return nil }
        params["kind"] = nil; params["prompt_id"] = nil
        params["session_id"] = .string(sessionID)
        if kind == "approval" { params["request_id"] = .string(id) }
        return .object(["id": .string(id), "method": .string(kind), "params": .object(params)])
    }

    static func projecting(_ snapshot: BotJSON, sessionID: String) -> BotJSON {
        let prompts = (snapshot["prompts"].list ?? []).compactMap { envelope($0, sessionID: sessionID) }
        guard !prompts.isEmpty, var fields = snapshot.fields else { return snapshot }
        fields["open_requests"] = .array((snapshot["open_requests"].list ?? []) + prompts)
        return .object(fields)
    }
}

extension BotTransport {
    func mutateStoredSession(profile: String, key: String,
                             _ operation: HermesCall.SessionMutation.Operation) async throws -> BotJSON {
        let snapshot = try await call(.sessionResume(profile: profile, sessionID: key, omitMessages: true), validateDispatch: nil)
        guard let session = snapshot["session_id"].text, !session.isEmpty else { throw BotFailure.unsupported }
        defer { release(profile: profile, sessionID: session) }
        guard let revision = snapshot["revision"].integer else { throw BotFailure.unsupported }
        return try await call(.sessionMutate(.init(profile: profile, sessionID: session, requestID: UUID().uuidString,
                                                   revision: revision, generation: snapshot["execution_generation"].integer,
                                                   operation: operation)), validateDispatch: nil)
    }
}
