import Foundation

extension APIClient {
    func startChat(
        sessionID: String,
        message: String,
        workspace: String?,
        model: String?,
        modelProvider: String? = nil,
        profile: String? = nil,
        explicitModelPick: Bool = false,
        attachments: [JSONValue]? = nil
    ) async throws -> ChatStartResponse {
        try await send(
            endpoint: .chatStart,
            method: "POST",
            body: ChatStartRequest(
                sessionId: sessionID,
                message: message,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile,
                explicitModelPick: explicitModelPick ? true : nil,
                attachments: attachments
            )
        )
    }

    nonisolated func chatStreamURL(streamID: String, replayAfterSeq: Int? = nil) -> URL {
        Endpoint.chatStream(streamID: streamID, replayAfterSeq: replayAfterSeq).url(relativeTo: baseURL)
    }

    func cancelChat(streamID: String) async throws -> ChatCancelResponse {
        try await send(endpoint: .chatCancel(streamID: streamID), method: "GET")
    }

    /// Status probes run inside the reconnect retry budget (#537), so they use a
    /// short explicit timeout instead of the 60s session default.
    private static let chatStreamStatusTimeout: TimeInterval = 10

    func chatStreamStatus(streamID: String) async throws -> ChatStreamStatusResponse {
        try await send(
            endpoint: .chatStreamStatus(streamID: streamID),
            method: "GET",
            timeout: Self.chatStreamStatusTimeout
        )
    }

    func approvalPending(sessionID: String) async throws -> ApprovalPendingResponse {
        try await send(endpoint: .approvalPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func approvalStreamURL(sessionID: String) -> URL {
        Endpoint.approvalStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondApproval(
        sessionID: String,
        choice: ApprovalChoice,
        approvalID: String?
    ) async throws -> ApprovalRespondResponse {
        try await send(
            endpoint: .approvalRespond,
            method: "POST",
            body: ApprovalRespondRequest(
                sessionId: sessionID,
                choice: choice,
                approvalId: approvalID
            )
        )
    }

    func clarifyPending(sessionID: String) async throws -> ClarificationPendingResponse {
        try await send(endpoint: .clarifyPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func clarifyStreamURL(sessionID: String) -> URL {
        Endpoint.clarifyStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondClarification(
        sessionID: String,
        response: String,
        clarifyID: String?
    ) async throws -> ClarificationRespondResponse {
        try await send(
            endpoint: .clarifyRespond,
            method: "POST",
            body: ClarificationRespondRequest(
                sessionId: sessionID,
                response: response,
                clarifyId: clarifyID
            )
        )
    }

    func steerChat(sessionID: String, text: String) async throws -> ChatSteerResponse {
        try await send(
            endpoint: .chatSteer,
            method: "POST",
            body: ChatSteerRequest(sessionId: sessionID, text: text)
        )
    }

    func submitGoal(
        sessionID: String,
        args: String,
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?
    ) async throws -> GoalSubmissionResponse {
        try await send(
            endpoint: .submitGoal,
            method: "POST",
            body: GoalSubmissionRequest(
                sessionId: sessionID,
                args: args,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile
            )
        )
    }

    func startBtw(sessionID: String, question: String) async throws -> BtwStartResponse {
        try await send(
            endpoint: .btw,
            method: "POST",
            body: BtwRequest(sessionId: sessionID, question: question)
        )
    }

    func startBackground(sessionID: String, prompt: String) async throws -> BackgroundStartResponse {
        try await send(
            endpoint: .background,
            method: "POST",
            body: BackgroundRequest(sessionId: sessionID, prompt: prompt)
        )
    }

    func backgroundStatus(sessionID: String) async throws -> BackgroundStatusResponse {
        try await send(endpoint: .backgroundStatus(sessionID: sessionID), method: "GET")
    }
}

private struct ChatStartRequest: Encodable {
    let sessionId: String
    let message: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
    let explicitModelPick: Bool?
    let attachments: [JSONValue]?
}

private struct ChatSteerRequest: Encodable {
    let sessionId: String
    let text: String
}

private struct GoalSubmissionRequest: Encodable {
    let sessionId: String
    let args: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}

private struct ApprovalRespondRequest: Encodable {
    let sessionId: String
    let choice: ApprovalChoice
    let approvalId: String?
}

private struct ClarificationRespondRequest: Encodable {
    let sessionId: String
    let response: String
    let clarifyId: String?
}

private struct BtwRequest: Encodable {
    let sessionId: String
    let question: String
}

private struct BackgroundRequest: Encodable {
    let sessionId: String
    let prompt: String
}
