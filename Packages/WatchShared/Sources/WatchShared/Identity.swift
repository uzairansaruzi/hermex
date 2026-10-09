import Foundation

public struct InstallationEpoch: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum IdentityValidationError: Error, Equatable, Sendable {
    case generationMustBePositive
    case blankIdentifier
    case identifierTooLong(maxUTF8Bytes: Int)
}

public struct Generation: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else {
            throw IdentityValidationError.generationMustBePositive
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ServerID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct ServerScope: Hashable, Codable, Sendable {
    public let epoch: InstallationEpoch
    public let server: ServerID
    public let generation: Generation

    public init(epoch: InstallationEpoch, server: ServerID, generation: Generation) {
        self.epoch = epoch
        self.server = server
        self.generation = generation
    }
}

public struct Revision: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SessionKey: Hashable, Codable, Sendable {
    public let scope: ServerScope
    public let sessionID: String

    public init(scope: ServerScope, sessionID: String) throws {
        guard !sessionID.allSatisfy(\.isWhitespace) else {
            throw IdentityValidationError.blankIdentifier
        }
        guard sessionID.utf8.count <= ContractLimits.identifierUTF8Bytes else {
            throw IdentityValidationError.identifierTooLong(maxUTF8Bytes: ContractLimits.identifierUTF8Bytes)
        }
        self.scope = scope
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case scope, sessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(ServerScope.self, forKey: .scope),
            sessionID: container.decode(String.self, forKey: .sessionID)
        )
    }
}

public struct BotKey: Hashable, Codable, Sendable {
    public let scope: ServerScope
    public let connectionID: UUID
    public let profile: String

    public init(scope: ServerScope, connectionID: UUID, profile: String) throws {
        guard !profile.allSatisfy(\.isWhitespace) else {
            throw IdentityValidationError.blankIdentifier
        }
        guard profile.utf8.count <= ContractLimits.profileUTF8Bytes else {
            throw IdentityValidationError.identifierTooLong(maxUTF8Bytes: ContractLimits.profileUTF8Bytes)
        }
        self.scope = scope
        self.connectionID = connectionID
        self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case scope, connectionID, profile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(ServerScope.self, forKey: .scope),
            connectionID: container.decode(UUID.self, forKey: .connectionID),
            profile: container.decode(String.self, forKey: .profile)
        )
    }
}

private func validateIdentityString(_ value: String, maxUTF8Bytes: Int = ContractLimits.identifierUTF8Bytes) throws {
    guard !value.allSatisfy(\.isWhitespace) else { throw IdentityValidationError.blankIdentifier }
    guard value.utf8.count <= maxUTF8Bytes else {
        throw IdentityValidationError.identifierTooLong(maxUTF8Bytes: maxUTF8Bytes)
    }
}

public struct RunKey: Hashable, Codable, Sendable {
    public let session: SessionKey
    public let streamID: String
    public init(session: SessionKey, streamID: String) throws { try validateIdentityString(streamID); self.session = session; self.streamID = streamID }
    private enum CodingKeys: String, CodingKey { case session, streamID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(session: c.decode(SessionKey.self, forKey: .session), streamID: c.decode(String.self, forKey: .streamID)) }
}

public struct TaskKey: Hashable, Codable, Sendable {
    public let scope: ServerScope; public let jobID: String
    public init(scope: ServerScope, jobID: String) throws { try validateIdentityString(jobID); self.scope = scope; self.jobID = jobID }
    private enum CodingKeys: String, CodingKey { case scope, jobID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(scope: c.decode(ServerScope.self, forKey: .scope), jobID: c.decode(String.self, forKey: .jobID)) }
}

public struct ApprovalKey: Hashable, Codable, Sendable {
    public let session: SessionKey; public let remoteID: String
    public init(session: SessionKey, remoteID: String) throws { try validateIdentityString(remoteID); self.session = session; self.remoteID = remoteID }
    private enum CodingKeys: String, CodingKey { case session, remoteID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(session: c.decode(SessionKey.self, forKey: .session), remoteID: c.decode(String.self, forKey: .remoteID)) }
}

public struct ClarificationKey: Hashable, Codable, Sendable {
    public let session: SessionKey; public let remoteID: String
    public init(session: SessionKey, remoteID: String) throws { try validateIdentityString(remoteID); self.session = session; self.remoteID = remoteID }
    private enum CodingKeys: String, CodingKey { case session, remoteID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(session: c.decode(SessionKey.self, forKey: .session), remoteID: c.decode(String.self, forKey: .remoteID)) }
}

public struct ProfileID: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { try validateIdentityString(rawValue); self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct WorkspaceHandle: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { try validateIdentityString(rawValue); self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct PathHandle: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { try validateIdentityString(rawValue); self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct MediaHandle: Hashable, Codable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) throws { try validateIdentityString(rawValue); self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct DraftHandle: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct OriginBinding: Hashable, Codable, Sendable {
    public let digest: String
    public init(digest: String) throws { try validateIdentityString(digest); self.digest = digest }
    private enum CodingKeys: String, CodingKey { case digest }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(digest: c.decode(String.self, forKey: .digest)) }
}

public struct SkillKey: Hashable, Codable, Sendable {
    public let scope: ServerScope; public let name: String
    public init(scope: ServerScope, name: String) throws { try validateIdentityString(name); self.scope = scope; self.name = name }
    private enum CodingKeys: String, CodingKey { case scope, name }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(scope: c.decode(ServerScope.self, forKey: .scope), name: c.decode(String.self, forKey: .name)) }
}

public struct MemoryKey: Hashable, Codable, Sendable {
    public let scope: ServerScope; public let remoteID: String
    public init(scope: ServerScope, remoteID: String) throws { try validateIdentityString(remoteID); self.scope = scope; self.remoteID = remoteID }
    private enum CodingKeys: String, CodingKey { case scope, remoteID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(scope: c.decode(ServerScope.self, forKey: .scope), remoteID: c.decode(String.self, forKey: .remoteID)) }
}

public struct InsightKey: Hashable, Codable, Sendable {
    public let scope: ServerScope; public let remoteID: String
    public init(scope: ServerScope, remoteID: String) throws { try validateIdentityString(remoteID); self.scope = scope; self.remoteID = remoteID }
    private enum CodingKeys: String, CodingKey { case scope, remoteID }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(scope: c.decode(ServerScope.self, forKey: .scope), remoteID: c.decode(String.self, forKey: .remoteID)) }
}
