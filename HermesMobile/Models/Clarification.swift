import Foundation

struct ClarificationPendingResponse: Decodable, Equatable {
    let pending: PendingClarification?
    let pendingCount: Int?

    init(pending: PendingClarification?, pendingCount: Int?) {
        self.pending = pending
        self.pendingCount = pendingCount
    }

    enum CodingKeys: String, CodingKey {
        case pending
        case pendingCount
        case pendingCountSnake = "pending_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = try? container.decodeIfPresent(PendingClarification.self, forKey: .pending)
        pendingCount = container.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? container.decodeLossyIntIfPresent(forKey: .pendingCountSnake)
    }

    static func streamPayload(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> ClarificationPendingResponse {
        if let wrapped = try? decoder.decode(Self.self, from: data),
           wrapped.pending != nil || wrapped.pendingCount != nil {
            return wrapped
        }

        if let direct = try? decoder.decode(PendingClarification.self, from: data),
           !direct.isEmpty {
            return ClarificationPendingResponse(pending: direct, pendingCount: 1)
        }

        return ClarificationPendingResponse(pending: nil, pendingCount: nil)
    }

    static func containsClarificationMarkers(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let candidate = object["pending"] as? [String: Any] ?? object
        return candidate["question"] != nil
            || candidate["choices_offered"] != nil
            || candidate["choicesOffered"] != nil
    }
}

struct PendingClarification: Decodable, Equatable, Identifiable {
    var id: String {
        if let clarifyId, !clarifyId.isEmpty {
            return clarifyId
        }

        return "\(sessionId ?? "")-\(question ?? "")-\(requestedAt ?? 0)"
    }

    let clarifyId: String?
    let question: String?
    let choicesOffered: [String]?
    let sessionId: String?
    let kind: String?
    let requestedAt: Double?
    let timeoutSeconds: Int?
    let expiresAt: Double?

    var displayChoices: [String] {
        choicesOffered?.compactMap { choice in
            let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? []
    }

    var displayQuestion: String {
        let trimmed = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "The agent needs more information before continuing." : trimmed
    }

    var isEmpty: Bool {
        clarifyId == nil
            && question == nil
            && (choicesOffered?.isEmpty ?? true)
            && sessionId == nil
            && kind == nil
            && requestedAt == nil
            && timeoutSeconds == nil
            && expiresAt == nil
    }

    init(
        clarifyId: String? = nil,
        question: String? = nil,
        choicesOffered: [String]? = nil,
        sessionId: String? = nil,
        kind: String? = nil,
        requestedAt: Double? = nil,
        timeoutSeconds: Int? = nil,
        expiresAt: Double? = nil
    ) {
        self.clarifyId = clarifyId
        self.question = question
        self.choicesOffered = choicesOffered
        self.sessionId = sessionId
        self.kind = kind
        self.requestedAt = requestedAt
        self.timeoutSeconds = timeoutSeconds
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case clarifyId
        case clarifyIdSnake = "clarify_id"
        case question
        case choicesOffered
        case choicesOfferedSnake = "choices_offered"
        case sessionId
        case sessionIdSnake = "session_id"
        case kind
        case requestedAt
        case requestedAtSnake = "requested_at"
        case timeoutSeconds
        case timeoutSecondsSnake = "timeout_seconds"
        case expiresAt
        case expiresAtSnake = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clarifyId = container.decodeLossyStringIfPresent(forKey: .clarifyId)
            ?? container.decodeLossyStringIfPresent(forKey: .clarifyIdSnake)
        question = container.decodeLossyStringIfPresent(forKey: .question)
        choicesOffered = Self.decodeStringArray(from: container, keys: [.choicesOffered, .choicesOfferedSnake])
        sessionId = container.decodeLossyStringIfPresent(forKey: .sessionId)
            ?? container.decodeLossyStringIfPresent(forKey: .sessionIdSnake)
        kind = container.decodeLossyStringIfPresent(forKey: .kind)
        requestedAt = container.decodeLossyDoubleIfPresent(forKey: .requestedAt)
            ?? container.decodeLossyDoubleIfPresent(forKey: .requestedAtSnake)
        timeoutSeconds = container.decodeLossyIntIfPresent(forKey: .timeoutSeconds)
            ?? container.decodeLossyIntIfPresent(forKey: .timeoutSecondsSnake)
        expiresAt = container.decodeLossyDoubleIfPresent(forKey: .expiresAt)
            ?? container.decodeLossyDoubleIfPresent(forKey: .expiresAtSnake)
    }

    private static func decodeStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> [String]? {
        for key in keys {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                return values
            }

            if let values = try? container.decodeIfPresent([JSONValue].self, forKey: key) {
                return values.compactMap(\.clarificationLossyString)
            }

            if let value = container.decodeLossyStringIfPresent(forKey: key) {
                return [value]
            }
        }

        return nil
    }
}

struct ClarificationRespondResponse: Decodable, Equatable {
    let ok: Bool?
    let response: String?
    /// The prompt already expired or was resolved (paired with a 409; issue #25).
    let stale: Bool?
    /// Server cleared a stale card whose prompt already resolved (mirrors approvals).
    let staleCleared: Bool?
    /// The respond was relayed to a gateway-managed run rather than resolved locally.
    let relayed: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case response
        case stale
        case staleCleared
        case staleClearedSnake = "stale_cleared"
        case relayed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        response = container.decodeLossyStringIfPresent(forKey: .response)
        stale = container.decodeLossyBoolIfPresent(forKey: .stale)
        staleCleared = container.decodeLossyBoolIfPresent(forKey: .staleCleared)
            ?? container.decodeLossyBoolIfPresent(forKey: .staleClearedSnake)
        relayed = container.decodeLossyBoolIfPresent(forKey: .relayed)
    }
}

private extension JSONValue {
    var clarificationLossyString: String? {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            "\(value)"
        case .bool(let value):
            value ? "true" : "false"
        case .object, .array, .null:
            nil
        }
    }
}
