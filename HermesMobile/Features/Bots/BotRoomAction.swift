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

    /// A retry without a choice, or an approval answered with a choice the host offered.
    func call(roomID: String, choice: BotApprovalRequest.Choice?) -> HermesCall? {
        guard let task = id.task else { return nil }
        if isRetry, choice == nil { return .groupsRetry(roomID: roomID, taskID: task) }
        guard let approval, let choice, approval.choices.contains(choice),
              let member = id.member, let generation = id.generation, let request = id.request else { return nil }
        return .groupsApprove(roomID: roomID, memberID: member, taskID: task, executionGeneration: generation,
                              requestID: request, choice: choice)
    }
}
