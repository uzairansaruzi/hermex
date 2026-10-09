import Foundation

public enum FreshnessValidationError: Error, Equatable, Sendable {
    case nonfiniteTimestamp
    case expiryBeforeObservation
    case unsupportedSchema(Int)
}

public struct Freshness: Hashable, Codable, Sendable {
    public enum Source: String, Hashable, Codable, Sendable {
        case directServer
        case phoneProjection
        case cache
    }

    public let observedAt: Date
    public let expiresAt: Date?
    public let source: Source

    public init(observedAt: Date, expiresAt: Date?, source: Source) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw FreshnessValidationError.nonfiniteTimestamp
        }
        guard expiresAt.map({ $0 >= observedAt }) ?? true else {
            throw FreshnessValidationError.expiryBeforeObservation
        }
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case observedAt, expiresAt, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            observedAt: container.decode(Date.self, forKey: .observedAt),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            source: container.decode(Source.self, forKey: .source)
        )
    }

    public func isFresh(at now: Date) -> Bool {
        guard now >= observedAt, let expiresAt else {
            return false
        }
        return now < expiresAt
    }

    public func authorizesMutation(at now: Date) -> Bool {
        isFresh(at: now)
    }
}

public struct RegistryEntry: Hashable, Codable, Sendable {
    public let scope: ServerScope
    public let displayName: RedactedDisplayName
    /// `true` when Message, voice notes, and photos are unavailable for this
    /// server. Older phones omit it; omission means those writes are allowed.
    public let writesUnsupported: Bool?

    public init(
        scope: ServerScope,
        displayName: RedactedDisplayName,
        writesUnsupported: Bool? = nil
    ) {
        self.scope = scope
        self.displayName = displayName
        self.writesUnsupported = writesUnsupported
    }
}

public enum RegistryValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case nonfiniteGeneratedAt
    case tooManyEntries
    case duplicateServer(ServerID)
    case epochMismatch
}

public struct RegistrySnapshot: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let epoch: InstallationEpoch
    public let revision: Revision
    public let generatedAt: Date
    public let entries: [RegistryEntry]

    public init(
        schemaVersion: Int = 1,
        epoch: InstallationEpoch,
        revision: Revision,
        generatedAt: Date,
        entries: [RegistryEntry]
    ) throws {
        guard schemaVersion == 1 else {
            throw RegistryValidationError.unsupportedSchema(schemaVersion)
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RegistryValidationError.nonfiniteGeneratedAt
        }
        guard entries.count <= ContractLimits.registryEntries else {
            throw RegistryValidationError.tooManyEntries
        }
        var servers = Set<ServerID>()
        for entry in entries {
            guard entry.scope.epoch == epoch else {
                throw RegistryValidationError.epochMismatch
            }
            guard servers.insert(entry.scope.server).inserted else {
                throw RegistryValidationError.duplicateServer(entry.scope.server)
            }
        }
        self.schemaVersion = schemaVersion
        self.epoch = epoch
        self.revision = revision
        self.generatedAt = generatedAt
        self.entries = entries
    }

    /// What the watch substitutes when the phone does not answer. A real
    /// registry with no servers uses the phone's epoch and a live revision.
    public static func unavailableWake() -> RegistrySnapshot {
        try! RegistrySnapshot(
            epoch: InstallationEpoch(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))),
            revision: Revision(0),
            generatedAt: Date(timeIntervalSince1970: 1),
            entries: []
        )
    }

    public var isUnavailableWake: Bool {
        self == Self.unavailableWake()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, epoch, revision, generatedAt, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            epoch: container.decode(InstallationEpoch.self, forKey: .epoch),
            revision: container.decode(Revision.self, forKey: .revision),
            generatedAt: container.decode(Date.self, forKey: .generatedAt),
            entries: container.decode([RegistryEntry].self, forKey: .entries)
        )
    }
}

public struct ScopedSnapshot<Value: Codable & Sendable>: Codable, Sendable {
    public let schema: Int
    public let scope: ServerScope
    public let revision: Revision
    public let freshness: Freshness
    public let value: Value

    public init(
        schema: Int,
        scope: ServerScope,
        revision: Revision,
        freshness: Freshness,
        value: Value
    ) throws {
        guard schema == 1 else {
            throw FreshnessValidationError.unsupportedSchema(schema)
        }
        self.schema = schema
        self.scope = scope
        self.revision = revision
        self.freshness = freshness
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case schema, scope, revision, freshness, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(Int.self, forKey: .schema),
            scope: container.decode(ServerScope.self, forKey: .scope),
            revision: container.decode(Revision.self, forKey: .revision),
            freshness: container.decode(Freshness.self, forKey: .freshness),
            value: container.decode(Value.self, forKey: .value)
        )
    }
}
