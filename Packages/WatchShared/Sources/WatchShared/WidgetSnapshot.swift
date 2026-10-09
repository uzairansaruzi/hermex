import Foundation

public enum WidgetValidationError: Error, Equatable, Sendable {
    case invalidDisplayName
    case unsupportedSchema(Int)
    case invalidAttentionCount
    case nonfiniteObservedAt
    case routeScopeMismatch
    case tooLarge
    case routeTooLarge
}

public struct RedactedWidgetSnapshot: Hashable, Codable, Sendable {
    public enum Activity: String, Hashable, Codable, Sendable {
        case idle, running, needsAttention, unknown
    }

    public let schema: Int
    public let scope: ServerScope
    public let displayName: RedactedDisplayName
    public let activity: Activity
    public let attentionCount: Int
    public let observedAt: Date
    public let route: RedactedRoute

    public init(
        schema: Int = 1,
        scope: ServerScope,
        displayName: RedactedDisplayName,
        activity: Activity,
        attentionCount: Int,
        observedAt: Date,
        route: RedactedRoute
    ) throws {
        guard schema == 1 else { throw WidgetValidationError.unsupportedSchema(schema) }
        guard (0...999).contains(attentionCount) else {
            throw WidgetValidationError.invalidAttentionCount
        }
        guard observedAt.timeIntervalSince1970.isFinite else {
            throw WidgetValidationError.nonfiniteObservedAt
        }
        let routeMatches: Bool
        switch route {
        case .servers(let epoch): routeMatches = epoch == scope.epoch
        case .sessions(let routeScope): routeMatches = routeScope == scope
        case .session(let key): routeMatches = key.scope == scope
        case .bot(let key): routeMatches = key.scope == scope
        }
        guard routeMatches else { throw WidgetValidationError.routeScopeMismatch }
        self.schema = schema
        self.scope = scope
        self.displayName = displayName
        self.activity = activity
        self.attentionCount = attentionCount
        self.observedAt = observedAt
        self.route = route
    }

    private enum CodingKeys: String, CodingKey {
        case schema, scope, displayName, activity, attentionCount, observedAt, route
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(Int.self, forKey: .schema),
            scope: container.decode(ServerScope.self, forKey: .scope),
            displayName: container.decode(RedactedDisplayName.self, forKey: .displayName),
            activity: container.decode(Activity.self, forKey: .activity),
            attentionCount: container.decode(Int.self, forKey: .attentionCount),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            route: container.decode(RedactedRoute.self, forKey: .route)
        )
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try WatchRedactor.validateNonSecretProjection(data, context: .widget)
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ContractLimits.widgetJSONBytes else {
            throw WidgetValidationError.tooLarge
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any], let route = dictionary["route"] {
            let routeData = try JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
            guard routeData.count <= ContractLimits.routeJSONBytes else {
                throw WidgetValidationError.routeTooLarge
            }
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct RedactedDisplayName: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.allSatisfy(\.isWhitespace),
              rawValue.utf8.count <= ContractLimits.displayNameUTF8Bytes,
              rawValue.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !rawValue.contains("://"),
              !rawValue.contains("@"),
              !rawValue.lowercased().contains("u01c_secret_canary") else {
            throw WidgetValidationError.invalidDisplayName
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
