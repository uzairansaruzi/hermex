import Foundation

public enum EnvelopeValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(UInt16)
    case invalidDates
    case expired
    case scopeMismatch
    case kindMismatch
    case contextMismatch
    case resultMismatch
    case receiptMismatch
}

private func validateEnvelopeDates(_ createdAt: Date, _ expiresAt: Date) throws {
    guard createdAt.timeIntervalSinceReferenceDate.isFinite,
          expiresAt.timeIntervalSinceReferenceDate.isFinite,
          createdAt < expiresAt else { throw EnvelopeValidationError.invalidDates }
}
private func validateLiveExpiry(_ expiresAt:Date,now:Date=Date())throws{guard expiresAt>=now else{throw EnvelopeValidationError.expired}}

public enum WatchRequestEnvelope: Hashable, Codable, Sendable {
    case read(schemaVersion: UInt16, requestID: UUID, scope: ServerScope, operationKind: WatchOperationKind, operation: WatchReadOperation, createdAt: Date, expiresAt: Date)
    case stream(schemaVersion: UInt16, requestID: UUID, scope: ServerScope, operationKind: WatchOperationKind, operation: WatchStreamOperation, createdAt: Date, expiresAt: Date)

    public static func read(requestID: UUID, scope: ServerScope, operation: WatchReadOperation, createdAt: Date, expiresAt: Date) throws -> Self {
        try validate(schema: 1, scope: scope, nested: operation.scope, kind: operation.kind, expected: operation.kind, createdAt: createdAt, expiresAt: expiresAt)
        return .read(schemaVersion: 1, requestID: requestID, scope: scope, operationKind: operation.kind, operation: operation, createdAt: createdAt, expiresAt: expiresAt)
    }

    public static func stream(requestID: UUID, scope: ServerScope, operation: WatchStreamOperation, createdAt: Date, expiresAt: Date) throws -> Self {
        try validate(schema: 1, scope: scope, nested: operation.scope, kind: operation.kind, expected: operation.kind, createdAt: createdAt, expiresAt: expiresAt)
        return .stream(schemaVersion: 1, requestID: requestID, scope: scope, operationKind: operation.kind, operation: operation, createdAt: createdAt, expiresAt: expiresAt)
    }

    public var operationKind: WatchOperationKind {
        switch self { case .read(_, _, _, let kind, _, _, _), .stream(_, _, _, let kind, _, _, _): return kind }
    }

    private static func validate(schema: UInt16, scope: ServerScope, nested: ServerScope, kind: WatchOperationKind, expected: WatchOperationKind, createdAt: Date, expiresAt: Date) throws {
        guard schema == 1 else { throw EnvelopeValidationError.unsupportedSchema(schema) }
        guard scope == nested else { throw EnvelopeValidationError.scopeMismatch }
        guard kind == expected else { throw EnvelopeValidationError.kindMismatch }
        try validateEnvelopeDates(createdAt, expiresAt)
    }
    public init(from decoder:Decoder)throws{let value=try WatchRequestEnvelopeWire(from:decoder).value;switch value{case .read(let schema,_,let scope,let kind,let operation,let created,let expires):try Self.validate(schema:schema,scope:scope,nested:operation.scope,kind:kind,expected:operation.kind,createdAt:created,expiresAt:expires);try validateLiveExpiry(expires);case .stream(let schema,_,let scope,let kind,let operation,let created,let expires):try Self.validate(schema:schema,scope:scope,nested:operation.scope,kind:kind,expected:operation.kind,createdAt:created,expiresAt:expires);try validateLiveExpiry(expires)};self=value}
}
private enum WatchRequestEnvelopeWire:Codable{case read(schemaVersion:UInt16,requestID:UUID,scope:ServerScope,operationKind:WatchOperationKind,operation:WatchReadOperation,createdAt:Date,expiresAt:Date);case stream(schemaVersion:UInt16,requestID:UUID,scope:ServerScope,operationKind:WatchOperationKind,operation:WatchStreamOperation,createdAt:Date,expiresAt:Date);var value:WatchRequestEnvelope{switch self{case .read(let a,let b,let c,let d,let e,let f,let g):return.read(schemaVersion:a,requestID:b,scope:c,operationKind:d,operation:e,createdAt:f,expiresAt:g);case .stream(let a,let b,let c,let d,let e,let f,let g):return.stream(schemaVersion:a,requestID:b,scope:c,operationKind:d,operation:e,createdAt:f,expiresAt:g)}}}

public struct WatchMutationRequest: Hashable, Codable, Sendable {
    public let schemaVersion: UInt16
    public let requestID: UUID
    public let context: CommandContext
    public let operationKind: WatchOperationKind
    public let operation: WatchMutationOperation
    public let createdAt: Date
    public let expiresAt: Date

    public init(requestID: UUID, context: CommandContext, operation: WatchMutationOperation, createdAt: Date, expiresAt: Date) throws {
        try operation.validate()
        guard context.scope == operation.scope else { throw EnvelopeValidationError.scopeMismatch }
        guard createdAt == context.createdAt, expiresAt == context.expiresAt else { throw EnvelopeValidationError.contextMismatch }
        try validateEnvelopeDates(createdAt, expiresAt)
        schemaVersion = 1; self.requestID = requestID; self.context = context; operationKind = operation.kind; self.operation = operation; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, requestID, context, operationKind, operation, createdAt, expiresAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(UInt16.self, forKey: .schemaVersion)
        guard schema == 1 else { throw EnvelopeValidationError.unsupportedSchema(schema) }
        let context = try c.decode(CommandContext.self, forKey: .context)
        let operation = try c.decode(WatchMutationOperation.self, forKey: .operation)
        let kind = try c.decode(WatchOperationKind.self, forKey: .operationKind)
        guard kind == operation.kind else { throw EnvelopeValidationError.kindMismatch }
        try self.init(requestID: c.decode(UUID.self, forKey: .requestID), context: context, operation: operation, createdAt: c.decode(Date.self, forKey: .createdAt), expiresAt: c.decode(Date.self, forKey: .expiresAt))
        try validateLiveExpiry(expiresAt)
    }
    public static func decodeLive(_ data:Data)throws->Self{guard data.count<=16_384 else{throw EnvelopeValidationError.resultMismatch};return try JSONDecoder().decode(Self.self,from:data)}
}

public struct WatchResponseEnvelope: Hashable, Codable, Sendable {
    public let schemaVersion: UInt16
    public let requestID: UUID
    public let scope: ServerScope
    public let requestOperationKind: WatchOperationKind
    public let requestCreatedAt: Date
    public let requestExpiresAt: Date
    public let commandContext: CommandContext?
    public let result: WatchOperationResult

    public init(requestID: UUID, scope: ServerScope, requestOperationKind: WatchOperationKind, requestCreatedAt: Date, requestExpiresAt: Date, commandContext: CommandContext?, result: WatchOperationResult) throws {
        try Self.validate(schemaVersion: 1, scope: scope, requestOperationKind: requestOperationKind, requestCreatedAt: requestCreatedAt, requestExpiresAt: requestExpiresAt, commandContext: commandContext, result: result)
        schemaVersion = 1; self.requestID = requestID; self.scope = scope; self.requestOperationKind = requestOperationKind; self.requestCreatedAt = requestCreatedAt; self.requestExpiresAt = requestExpiresAt; self.commandContext = commandContext; self.result = result
    }

    private static func validate(schemaVersion: UInt16, scope: ServerScope, requestOperationKind: WatchOperationKind, requestCreatedAt: Date, requestExpiresAt: Date, commandContext: CommandContext?, result: WatchOperationResult) throws {
        guard schemaVersion == 1 else { throw EnvelopeValidationError.unsupportedSchema(schemaVersion) }
        try validateEnvelopeDates(requestCreatedAt, requestExpiresAt)
        let mutationKinds: Set<WatchOperationKind> = [.createSession, .send, .stop, .respondApproval, .respondClarification, .controlTask, .sendBot, .interruptBot]
        if mutationKinds.contains(requestOperationKind) {
            guard let commandContext,
                  commandContext.scope == scope,
                  commandContext.createdAt == requestCreatedAt,
                  commandContext.expiresAt == requestExpiresAt else { throw EnvelopeValidationError.contextMismatch }
        } else if commandContext != nil { throw EnvelopeValidationError.contextMismatch }
        try result.validate()
        if let resultKind = result.kind, resultKind != requestOperationKind { throw EnvelopeValidationError.resultMismatch }
        if let resultScope = result.scope, resultScope != scope { throw EnvelopeValidationError.scopeMismatch }
        if let receipt = result.receipt {
            guard let commandContext, receipt.context == commandContext, receipt.operationKind == requestOperationKind else { throw EnvelopeValidationError.receiptMismatch }
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, requestID, scope, requestOperationKind, requestCreatedAt, requestExpiresAt, commandContext, result }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(UInt16.self, forKey: .schemaVersion)
        let scope = try c.decode(ServerScope.self, forKey: .scope)
        let kind = try c.decode(WatchOperationKind.self, forKey: .requestOperationKind)
        let created = try c.decode(Date.self, forKey: .requestCreatedAt)
        let expires = try c.decode(Date.self, forKey: .requestExpiresAt)
        let context = try c.decodeIfPresent(CommandContext.self, forKey: .commandContext)
        let result = try c.decode(WatchOperationResult.self, forKey: .result)
        try Self.validate(schemaVersion: schema, scope: scope, requestOperationKind: kind, requestCreatedAt: created, requestExpiresAt: expires, commandContext: context, result: result)
        try validateLiveExpiry(expires)
        schemaVersion = schema; requestID = try c.decode(UUID.self, forKey: .requestID); self.scope = scope; requestOperationKind = kind; requestCreatedAt = created; requestExpiresAt = expires; commandContext = context; self.result = result
    }
    public static func decodeLive(_ data:Data)throws->Self{guard data.count<=262_144 else{throw EnvelopeValidationError.resultMismatch};return try JSONDecoder().decode(Self.self,from:data)}
    public func validate(against request:WatchRequestEnvelope,receivedAt:Date)throws{
        let expected:(UUID,ServerScope,WatchOperationKind,Date,Date)
        switch request{
        case .read(_,let id,let scope,let kind,_,let created,let expires),.stream(_,let id,let scope,let kind,_,let created,let expires):expected=(id,scope,kind,created,expires)
        }
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite,receivedAt<=expected.4 else{throw EnvelopeValidationError.expired}
        guard requestID==expected.0,scope==expected.1,requestOperationKind==expected.2,requestCreatedAt==expected.3,requestExpiresAt==expected.4,commandContext==nil else{throw EnvelopeValidationError.contextMismatch}
        try Self.validate(schemaVersion:schemaVersion,scope:scope,requestOperationKind:requestOperationKind,requestCreatedAt:requestCreatedAt,requestExpiresAt:requestExpiresAt,commandContext:commandContext,result:result)
        switch request{case .read(_,_,_,_,let operation,_,_):try result.validate(against:operation);case .stream(_,_,_,_,let operation,_,_):try result.validate(against:operation)}
    }
    public func validate(against request:WatchMutationRequest,receivedAt:Date)throws{
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite,receivedAt<=request.expiresAt else{throw EnvelopeValidationError.expired}
        guard requestID==request.requestID,scope==request.context.scope,requestOperationKind==request.operationKind,requestCreatedAt==request.createdAt,requestExpiresAt==request.expiresAt,commandContext==request.context else{throw EnvelopeValidationError.contextMismatch}
        try Self.validate(schemaVersion:schemaVersion,scope:scope,requestOperationKind:requestOperationKind,requestCreatedAt:requestCreatedAt,requestExpiresAt:requestExpiresAt,commandContext:commandContext,result:result)
        try result.validate(against:request.operation)
    }
}
