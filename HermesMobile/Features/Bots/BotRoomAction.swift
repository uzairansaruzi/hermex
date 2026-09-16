import Foundation

/// Preserve the exact approval identity. Unknown or incomplete actions remain
/// visible as Desktop attention, never as a partially addressable command.
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
    var isAnswerable: Bool { approval != nil || isRetry }

    init(_ value: BotJSON) {
        id = Identity(kind: value["kind"].text ?? "", member: value["member_id"].text,
                      task: value["task_id"].text, generation: value["execution_generation"].integer,
                      request: value["request_id"].text)
        if id.kind == "approval", let member = id.member, BotRoomRPC.validID(member),
           let task = id.task, BotRoomRPC.validID(task), let generation = id.generation, generation > 0,
           let request = id.request, BotRoomRPC.validID(request), var body = value["approval"].fields {
            body["request_id"] = .string(request)
            let choices = body["choices"]?.list?.filter { $0 == .string("once") || $0 == .string("deny") }
            body["choices"] = .array(choices ?? [.string("once"), .string("deny")])
            approval = BotApprovalRequest(.object(body))
        } else { approval = nil }
    }

    func parameters(roomID: String, choice: BotApprovalRequest.Choice?) -> [String: BotJSON]? {
        guard let task = id.task else { return nil }
        var params: [String: BotJSON] = ["room_id": .string(roomID), "task_id": .string(task)]
        if isRetry, choice == nil { return params }
        guard let approval, let choice, approval.choices.contains(choice),
              let member = id.member, let generation = id.generation, let request = id.request else { return nil }
        params["member_id"] = .string(member)
        params["execution_generation"] = .number(Double(generation))
        params["request_id"] = .string(request)
        params["choice"] = .string(choice.rawValue)
        return params
    }
}
