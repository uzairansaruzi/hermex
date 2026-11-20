import Foundation

struct BotRoomAction: Equatable, Identifiable {
    struct Identity: Hashable {
        let kind: String
        let member: String?
        let task: String?
        let generation: Int?
        let request: String?
    }
    let id: Identity
    let approval: BotApprovalRequest?
    var isRetry: Bool { id.kind == "retry" && id.task.map(BotRoomRPC.validID) == true }
    var isDiscard: Bool { id.kind == "discard" && id.task.map(BotRoomRPC.validID) == true && attempt != nil }
    var isAnswerable: Bool { approval != nil || isRetry || isDiscard }
    var method: String { isRetry ? "groups.retry" : isDiscard ? "groups.discard" : "groups.approve" }
    private var attempt: HermesCall.RoomAttempt? {
        guard let member = id.member, let generation = id.generation else { return nil }
        let attempt = HermesCall.RoomAttempt(memberID: member, executionGeneration: generation)
        return attempt.isAdmissible ? attempt : nil
    }

    init(_ value: BotJSON) {
        id = Identity(kind: value["kind"].text ?? "", member: value["member_id"].text,
                      task: value["task_id"].text, generation: value["execution_generation"].integer,
                      request: value["request_id"].text)
        if id.kind == "approval", let member = id.member, BotRoomRPC.validID(member),
           let task = id.task, BotRoomRPC.validID(task), let generation = id.generation, generation > 0,
           let request = id.request, BotRoomRPC.validID(request), var body = value["approval"].fields {
            body["request_id"] = .string(request)
            if let present = body["choices"] {
                if let list = present.list { body["choices"] = .array(list.filter { $0 == .string("once") || $0 == .string("deny") }) }
            } else {
                body["choices"] = .array([.string("once"), .string("deny")])
            }
            approval = BotApprovalRequest(.object(body))
        } else { approval = nil }
    }

    func call(roomID: String, choice: BotApprovalRequest.Choice?) -> HermesCall? {
        guard let task = id.task else { return nil }
        if isRetry, choice == nil { return .groupsRetry(roomID: roomID, taskID: task, attempt: attempt) }
        if isDiscard, choice == nil, let attempt { return .groupsDiscard(roomID: roomID, taskID: task, attempt: attempt) }
        guard let approval, let choice, approval.choices.contains(choice),
              let member = id.member, let generation = id.generation, let request = id.request else { return nil }
        return .groupsApprove(roomID: roomID, memberID: member, taskID: task, executionGeneration: generation,
                              requestID: request, choice: choice)
    }
}
