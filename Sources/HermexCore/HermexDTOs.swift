import Foundation

public struct HermexSessionsResponse: Codable, Equatable, Sendable {
    public var sessions: [HermexSessionDTO]?
    public var projects: [HermexProjectDTO]?
    public var error: String?

    public init(sessions: [HermexSessionDTO]? = nil, projects: [HermexProjectDTO]? = nil, error: String? = nil) {
        self.sessions = sessions
        self.projects = projects
        self.error = error
    }
}

public struct HermexSessionResponse: Codable, Equatable, Sendable {
    public var session: HermexSessionDTO?
    public var messages: [HermexChatMessageDTO]?
    public var error: String?

    public init(session: HermexSessionDTO? = nil, messages: [HermexChatMessageDTO]? = nil, error: String? = nil) {
        self.session = session
        self.messages = messages
        self.error = error
    }
}

public struct HermexSessionDTO: Codable, Identifiable, Equatable, Sendable {
    public var sessionId: String?
    public var title: String?
    public var updatedAt: Double?
    public var createdAt: Double?
    public var lastMessageAt: Double?
    public var messageCount: Int?
    public var workspace: String?
    public var projectId: String?
    public var pinned: Bool?
    public var archived: Bool?
    public var branch: String?
    public var model: String?
    public var modelProvider: String?

    public var id: String { sessionId ?? title ?? "session" }

    public init(
        sessionId: String? = nil,
        title: String? = nil,
        updatedAt: Double? = nil,
        createdAt: Double? = nil,
        lastMessageAt: Double? = nil,
        messageCount: Int? = nil,
        workspace: String? = nil,
        projectId: String? = nil,
        pinned: Bool? = nil,
        archived: Bool? = nil,
        branch: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.workspace = workspace
        self.projectId = projectId
        self.pinned = pinned
        self.archived = archived
        self.branch = branch
        self.model = model
        self.modelProvider = modelProvider
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case title
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case messageCount = "message_count"
        case workspace
        case projectId = "project_id"
        case pinned
        case archived
        case branch
        case model
        case modelProvider = "model_provider"
    }
}

public struct HermexProjectDTO: Codable, Identifiable, Equatable, Sendable {
    public var projectId: String?
    public var name: String?
    public var color: String?
    public var createdAt: Double?

    public var id: String { projectId ?? name ?? "project" }

    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case name
        case color
        case createdAt = "created_at"
    }
}

public struct HermexModelOption: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var provider: String?
    public var label: String?

    public var displayName: String { label ?? name ?? id }

    public init(id: String, name: String? = nil, provider: String? = nil, label: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.label = label
    }
}

public struct HermexProfileOption: Codable, Identifiable, Equatable, Sendable {
    public var name: String
    public var displayName: String?
    public var path: String?
    public var isDefault: Bool?
    public var isActive: Bool?
    public var model: String?
    public var provider: String?

    public var id: String { name }
    public var title: String { displayName ?? name }

    public init(
        name: String,
        displayName: String? = nil,
        path: String? = nil,
        isDefault: Bool? = nil,
        isActive: Bool? = nil,
        model: String? = nil,
        provider: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.path = path
        self.isDefault = isDefault
        self.isActive = isActive
        self.model = model
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case path
        case isDefault = "is_default"
        case isActive = "is_active"
        case model
        case provider
    }
}

public struct HermexChatMessageDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String?
    public var messageId: String?
    public var role: String?
    public var content: String?
    public var text: String?
    public var timestamp: Double?
    public var reasoning: String?
    public var toolCalls: [HermexJSONValue]?
    public var attachments: [HermexAttachmentDTO]?

    public var stableId: String { messageId ?? id ?? "\(role ?? "message"):\(timestamp ?? 0)" }

    public init(
        id: String? = nil,
        messageId: String? = nil,
        role: String? = nil,
        content: String? = nil,
        text: String? = nil,
        timestamp: Double? = nil,
        reasoning: String? = nil,
        toolCalls: [HermexJSONValue]? = nil,
        attachments: [HermexAttachmentDTO]? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.role = role
        self.content = content
        self.text = text
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case role
        case content
        case text
        case timestamp
        case reasoning
        case toolCalls = "tool_calls"
        case attachments
    }
}

public struct HermexAttachmentDTO: Codable, Identifiable, Equatable, Sendable {
    public var id: String { path ?? name ?? "attachment" }
    public var name: String?
    public var path: String?
    public var mime: String?
    public var size: Int?
    public var isImage: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case mime
        case size
        case isImage = "is_image"
    }
}

public struct HermexModelsResponse: Codable, Equatable, Sendable {
    public var groups: [HermexJSONValue]?
    public var models: [HermexJSONValue]?
    public var defaultModel: String?
    public var activeProvider: String?

    public init(
        groups: [HermexJSONValue]? = nil,
        models: [HermexJSONValue]? = nil,
        defaultModel: String? = nil,
        activeProvider: String? = nil
    ) {
        self.groups = groups
        self.models = models
        self.defaultModel = defaultModel
        self.activeProvider = activeProvider
    }

    enum CodingKeys: String, CodingKey {
        case groups
        case models
        case defaultModel = "default_model"
        case activeProvider = "active_provider"
    }

    public var normalizedModels: [HermexModelOption] {
        let direct = (models ?? []).flatMap { $0.modelOptions(inheritedProvider: activeProvider) }
        let grouped = (groups ?? []).flatMap { $0.modelOptions(inheritedProvider: activeProvider) }
        return (direct + grouped).uniqueModels()
    }
}

public struct HermexProfilesResponse: Codable, Equatable, Sendable {
    public var profiles: [HermexProfileOption]?
    public var active: String?
    public var singleProfileMode: Bool?
    public var error: String?

    public init(
        profiles: [HermexProfileOption]? = nil,
        active: String? = nil,
        singleProfileMode: Bool? = nil,
        error: String? = nil
    ) {
        self.profiles = profiles
        self.active = active
        self.singleProfileMode = singleProfileMode
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case profiles
        case active
        case singleProfileMode = "single_profile_mode"
        case error
    }
}

public struct HermexWorkspaceRootDTO: Codable, Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String?
    public var exists: Bool?
    public var id: String { path }

    public init(path: String, name: String? = nil, exists: Bool? = nil) {
        self.path = path
        self.name = name
        self.exists = exists
    }

    public init(from decoder: Decoder) throws {
        if let stringValue = try? decoder.singleValueContainer().decode(String.self) {
            path = stringValue
            name = nil
            exists = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        exists = try container.decodeIfPresent(Bool.self, forKey: .exists)
    }

    enum CodingKeys: String, CodingKey {
        case path
        case name
        case exists
    }
}

public struct HermexWorkspacesResponse: Codable, Equatable, Sendable {
    public var workspaces: [HermexWorkspaceRootDTO]?
    public var roots: [HermexWorkspaceRootDTO]?
    public var last: String?
    public var error: String?

    public init(
        workspaces: [HermexWorkspaceRootDTO]? = nil,
        roots: [HermexWorkspaceRootDTO]? = nil,
        last: String? = nil,
        error: String? = nil
    ) {
        self.workspaces = workspaces
        self.roots = roots
        self.last = last
        self.error = error
    }

    public var normalizedRoots: [HermexWorkspaceRootDTO] {
        (workspaces ?? roots ?? []).filter { !$0.path.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
    }
}

public struct HermexReasoningResponse: Codable, Equatable, Sendable {
    public var effort: String?
    public var supportedEfforts: [String]?
    public var supportsReasoningEffort: Bool?
    public var error: String?

    public init(
        effort: String? = nil,
        supportedEfforts: [String]? = nil,
        supportsReasoningEffort: Bool? = nil,
        error: String? = nil
    ) {
        self.effort = effort
        self.supportedEfforts = supportedEfforts
        self.supportsReasoningEffort = supportsReasoningEffort
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case effort
        case supportedEfforts = "supported_efforts"
        case supportsReasoningEffort = "supports_reasoning_effort"
        case error
    }
}

public struct HermexUploadResponse: Codable, Equatable, Sendable {
    public var filename: String?
    public var path: String?
    public var mime: String?
    public var size: Int?
    public var isImage: Bool?
    public var error: String?

    public init(filename: String? = nil, path: String? = nil, mime: String? = nil, size: Int? = nil, isImage: Bool? = nil, error: String? = nil) {
        self.filename = filename
        self.path = path
        self.mime = mime
        self.size = size
        self.isImage = isImage
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case filename
        case path
        case mime
        case size
        case isImage = "is_image"
        case error
    }
}

public struct HermexTranscribeResponse: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var transcript: String?
    public var error: String?

    public init(ok: Bool? = nil, transcript: String? = nil, error: String? = nil) {
        self.ok = ok
        self.transcript = transcript
        self.error = error
    }
}

private extension HermexJSONValue {
    func modelOptions(inheritedProvider: String?) -> [HermexModelOption] {
        switch self {
        case .array(let values):
            return values.flatMap { $0.modelOptions(inheritedProvider: inheritedProvider) }
        case .object(let object):
            let provider = object.stringValue("provider") ?? object.stringValue("provider_id") ?? inheritedProvider
            let nestedKeys = ["models", "items", "slash_autocomplete_models"]
            let nested = nestedKeys.flatMap { key in
                object[key]?.modelOptions(inheritedProvider: provider) ?? []
            }
            if let id = object.stringValue("id") ?? object.stringValue("model") ?? object.stringValue("name") {
                return [HermexModelOption(
                    id: id,
                    name: object.stringValue("name"),
                    provider: provider,
                    label: object.stringValue("label") ?? object.stringValue("display_name")
                )] + nested
            }
            return nested
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [HermexModelOption(id: trimmed, provider: inheritedProvider)]
        default:
            return []
        }
    }
}

private extension Array where Element == HermexModelOption {
    func uniqueModels() -> [HermexModelOption] {
        var seen: Set<String> = []
        return filter { option in
            let key = [option.provider, option.id].compactMap { $0 }.joined(separator: ":")
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
