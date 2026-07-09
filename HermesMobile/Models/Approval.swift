import Foundation

enum ApprovalChoice: String, Codable, CaseIterable, Equatable {
    case once
    case session
    case always
    case deny
}

struct ApprovalPendingResponse: Decodable, Equatable {
    let pending: PendingApproval?
    let pendingCount: Int?

    init(pending: PendingApproval?, pendingCount: Int?) {
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
        pending = try? container.decodeIfPresent(PendingApproval.self, forKey: .pending)
        pendingCount = container.decodeLossyIntIfPresent(forKey: .pendingCount)
            ?? container.decodeLossyIntIfPresent(forKey: .pendingCountSnake)
    }

    static func streamPayload(from data: Data, decoder: JSONDecoder = JSONDecoder()) -> ApprovalPendingResponse {
        if let wrapped = try? decoder.decode(Self.self, from: data),
           wrapped.pending != nil || wrapped.pendingCount != nil {
            return wrapped
        }

        if let direct = try? decoder.decode(PendingApproval.self, from: data),
           !direct.isEmpty {
            return ApprovalPendingResponse(pending: direct, pendingCount: 1)
        }

        return ApprovalPendingResponse(pending: nil, pendingCount: nil)
    }
}

struct PendingApproval: Decodable, Equatable, Identifiable {
    var id: String {
        if let approvalId, !approvalId.isEmpty {
            return approvalId
        }

        return "\(command ?? "")-\(description ?? "")-\(displayPatternKeys.joined(separator: ","))"
    }

    let approvalId: String?
    let command: String?
    let description: String?
    let patternKey: String?
    let patternKeys: [String]?

    var displayPatternKeys: [String] {
        let keys = patternKeys?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        if !keys.isEmpty {
            return keys
        }

        guard let patternKey = patternKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !patternKey.isEmpty
        else {
            return []
        }

        return [patternKey]
    }

    var isEmpty: Bool {
        approvalId == nil
            && command == nil
            && description == nil
            && patternKey == nil
            && (patternKeys?.isEmpty ?? true)
    }

    init(
        approvalId: String? = nil,
        command: String? = nil,
        description: String? = nil,
        patternKey: String? = nil,
        patternKeys: [String]? = nil
    ) {
        self.approvalId = Self.normalizedApprovalId(approvalId)
        self.command = command
        self.description = description
        self.patternKey = patternKey
        self.patternKeys = patternKeys
    }

    enum CodingKeys: String, CodingKey {
        case id
        case approvalId
        case approvalIdSnake = "approval_id"
        case command
        case description
        case patternKey
        case patternKeySnake = "pattern_key"
        case patternKeys
        case patternKeysSnake = "pattern_keys"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = Self.decodeApprovalId(from: container)
        command = container.decodeLossyStringIfPresent(forKey: .command)
        description = container.decodeLossyStringIfPresent(forKey: .description)
        patternKey = container.decodeLossyStringIfPresent(forKey: .patternKey)
            ?? container.decodeLossyStringIfPresent(forKey: .patternKeySnake)
        patternKeys = Self.decodeStringArray(from: container, keys: [.patternKeys, .patternKeysSnake])
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
                return values.compactMap(\.lossyString)
            }

            if let value = container.decodeLossyStringIfPresent(forKey: key) {
                return [value]
            }
        }

        return nil
    }

    private static func decodeApprovalId(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
        for key in [CodingKeys.approvalId, .approvalIdSnake, .id] {
            if let value = normalizedApprovalId(container.decodeLossyStringIfPresent(forKey: key)) {
                return value
            }
        }

        return nil
    }

    private static func normalizedApprovalId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct ApprovalRespondResponse: Decodable, Equatable {
    let ok: Bool?
    let choice: ApprovalChoice?
    /// Server cleared a stale card whose approval already resolved (benign 200; issue #25).
    let staleCleared: Bool?
    /// The respond was relayed to a gateway-managed run rather than resolved locally.
    let relayed: Bool?
    /// The prompt already expired (paired with a 409 on the docs' respond contract).
    let stale: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case choice
        case staleCleared
        case staleClearedSnake = "stale_cleared"
        case relayed
        case stale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        choice = try? container.decodeIfPresent(ApprovalChoice.self, forKey: .choice)
        staleCleared = container.decodeLossyBoolIfPresent(forKey: .staleCleared)
            ?? container.decodeLossyBoolIfPresent(forKey: .staleClearedSnake)
        relayed = container.decodeLossyBoolIfPresent(forKey: .relayed)
        stale = container.decodeLossyBoolIfPresent(forKey: .stale)
    }
}

struct SessionYoloResponse: Decodable, Equatable {
    let ok: Bool?
    let yoloEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case yoloEnabled
        case yoloEnabledSnake = "yolo_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        yoloEnabled = container.decodeLossyBoolIfPresent(forKey: .yoloEnabled)
            ?? container.decodeLossyBoolIfPresent(forKey: .yoloEnabledSnake)
    }
}

private extension JSONValue {
    var lossyString: String? {
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
