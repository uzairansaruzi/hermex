import Foundation

public enum RouteValidationError: Error, Equatable, Sendable {
    case tooLarge
    case unsupportedSchema(Int)
    case invalidDates
    case scopeMismatch
    case incompatibleDestination
    case invalidRequestID
}

public enum RedactedRoute: Hashable, Sendable {
    case servers(InstallationEpoch)
    case sessions(ServerScope)
    case session(SessionKey)
    case bot(BotKey)

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RedactedRoute {
        guard data.count <= ContractLimits.routeJSONBytes else {
            throw RouteValidationError.tooLarge
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

extension RedactedRoute: Codable {
    private enum EnvelopeKeys: String, CodingKey { case schema, route }
    private enum RouteKeys: String, CodingKey { case kind, epoch, scope, session, bot }
    private enum Kind: String, Codable { case servers, sessions, session, bot }

    public init(from decoder: Decoder) throws {
        let envelope = try decoder.container(keyedBy: EnvelopeKeys.self)
        let schema = try envelope.decode(Int.self, forKey: .schema)
        guard schema == 1 else { throw RouteValidationError.unsupportedSchema(schema) }
        let container = try envelope.nestedContainer(keyedBy: RouteKeys.self, forKey: .route)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .servers: self = .servers(try container.decode(InstallationEpoch.self, forKey: .epoch))
        case .sessions: self = .sessions(try container.decode(ServerScope.self, forKey: .scope))
        case .session: self = .session(try container.decode(SessionKey.self, forKey: .session))
        case .bot: self = .bot(try container.decode(BotKey.self, forKey: .bot))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var envelope = encoder.container(keyedBy: EnvelopeKeys.self)
        try envelope.encode(1, forKey: .schema)
        var container = envelope.nestedContainer(keyedBy: RouteKeys.self, forKey: .route)
        switch self {
        case .servers(let epoch):
            try container.encode(Kind.servers, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
        case .sessions(let scope):
            try container.encode(Kind.sessions, forKey: .kind)
            try container.encode(scope, forKey: .scope)
        case .session(let key):
            try container.encode(Kind.session, forKey: .kind)
            try container.encode(key, forKey: .session)
        case .bot(let key):
            try container.encode(Kind.bot, forKey: .kind)
            try container.encode(key, forKey: .bot)
        }
    }
}

public struct CacheKey: Hashable, Sendable {
    public let rawValue: String

    private init(encoded data: Data) {
        self.rawValue = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func scope(_ scope: ServerScope) throws -> Self {
        try encoded(scope)
    }

    public static func session(_ key: SessionKey) throws -> Self {
        try encoded(key)
    }

    public static func bot(_ key: BotKey) throws -> Self {
        try encoded(key)
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self(encoded: try encoder.encode(value))
    }
}

public enum SessionPhoneDestination:String,Hashable,Codable,Sendable{case detail,management,attachments}
public enum TaskPhoneDestination:String,Hashable,Codable,Sendable{case detail,edit,create,schedule,delivery,profile,model,skills}
public enum SkillPhoneDestination:String,Hashable,Codable,Sendable{case detail,install,edit,configure,enablement}
public enum MemoryPhoneDestination:String,Hashable,Codable,Sendable{case detail,create,edit,delete,bulk}
public enum InsightPhoneDestination:String,Hashable,Codable,Sendable{case detail,generate,configure}
public enum WorkspacePhoneDestination:String,Hashable,Codable,Sendable{case browse,write,upload,download}
public enum GitPhoneDestination:String,Hashable,Codable,Sendable{case browse,checkout,fetch,pull,push,stage,unstage,discard,commit,merge,resolveConflicts}
public enum SettingsPhoneDestination:String,Hashable,Codable,Sendable{case watchSharing,directAccess,bot}
public enum WatchRouteTarget:Hashable,Codable,Sendable{
 case home;case sessions(collection:SessionCollection);case newSession(draftHandle:DraftHandle?);case session(SessionKey,destination:SessionPhoneDestination);case run(RunKey);case approval(ApprovalKey);case clarification(ClarificationKey,draftHandle:DraftHandle?);case task(TaskKey?,destination:TaskPhoneDestination);case taskRun(TaskKey,runID:String);case skill(SkillKey?,destination:SkillPhoneDestination);case memory(MemoryKey?,destination:MemoryPhoneDestination);case insight(InsightKey?,destination:InsightPhoneDestination);case workspace(SessionKey,pathHandle:PathHandle?,destination:WorkspacePhoneDestination);case git(SessionKey,pathHandle:PathHandle?,diffKind:GitDiffKind?,destination:GitPhoneDestination);case diagnostics(ServerScope);case settings(ServerScope,destination:SettingsPhoneDestination);case bot(BotKey,destination:BotPhoneDestination,requestID:String?)
 fileprivate var nestedScope:ServerScope?{switch self{case .home,.sessions,.newSession:return nil;case .session(let k,_),.workspace(let k,_,_),.git(let k,_,_,_):return k.scope;case .run(let k):return k.session.scope;case .approval(let k):return k.session.scope;case .clarification(let k,_):return k.session.scope;case .task(let k,_):return k?.scope;case .taskRun(let k,_):return k.scope;case .skill(let k,_):return k?.scope;case .memory(let k,_):return k?.scope;case .insight(let k,_):return k?.scope;case .diagnostics(let s),.settings(let s,_):return s;case .bot(let k,_,_):return k.scope}}
 fileprivate func validate()throws{switch self{case .bot(_,let destination,let requestID):if destination != .activity,requestID != nil{throw RouteValidationError.incompatibleDestination};if let requestID{guard !requestID.allSatisfy(\.isWhitespace),requestID.utf8.count<=256 else{throw RouteValidationError.invalidRequestID}};case .task(let key,let destination):guard (destination == .create) == (key == nil) else{throw RouteValidationError.incompatibleDestination};case .skill(let key,let destination):guard (destination == .install) == (key == nil) else{throw RouteValidationError.incompatibleDestination};case .memory(let key,let destination):guard (destination == .create) == (key == nil) else{throw RouteValidationError.incompatibleDestination};case .insight(let key,let destination):guard (destination == .generate) == (key == nil) else{throw RouteValidationError.incompatibleDestination};case .taskRun(_,let runID):guard !runID.allSatisfy(\.isWhitespace),runID.utf8.count<=256 else{throw RouteValidationError.invalidRequestID};default:break}}
 public init(from decoder:Decoder)throws{let value=try WatchRouteTargetWire(from:decoder).value;try value.validate();self=value}
}
private enum WatchRouteTargetWire:Codable{case home;case sessions(collection:SessionCollection);case newSession(draftHandle:DraftHandle?);case session(SessionKey,destination:SessionPhoneDestination);case run(RunKey);case approval(ApprovalKey);case clarification(ClarificationKey,draftHandle:DraftHandle?);case task(TaskKey?,destination:TaskPhoneDestination);case taskRun(TaskKey,runID:String);case skill(SkillKey?,destination:SkillPhoneDestination);case memory(MemoryKey?,destination:MemoryPhoneDestination);case insight(InsightKey?,destination:InsightPhoneDestination);case workspace(SessionKey,pathHandle:PathHandle?,destination:WorkspacePhoneDestination);case git(SessionKey,pathHandle:PathHandle?,diffKind:GitDiffKind?,destination:GitPhoneDestination);case diagnostics(ServerScope);case settings(ServerScope,destination:SettingsPhoneDestination);case bot(BotKey,destination:BotPhoneDestination,requestID:String?);var value:WatchRouteTarget{switch self{case .home:return.home;case .sessions(let a):return.sessions(collection:a);case .newSession(let a):return.newSession(draftHandle:a);case .session(let a,let b):return.session(a,destination:b);case .run(let a):return.run(a);case .approval(let a):return.approval(a);case .clarification(let a,let b):return.clarification(a,draftHandle:b);case .task(let a,let b):return.task(a,destination:b);case .taskRun(let a,let b):return.taskRun(a,runID:b);case .skill(let a,let b):return.skill(a,destination:b);case .memory(let a,let b):return.memory(a,destination:b);case .insight(let a,let b):return.insight(a,destination:b);case .workspace(let a,let b,let c):return.workspace(a,pathHandle:b,destination:c);case .git(let a,let b,let c,let d):return.git(a,pathHandle:b,diffKind:c,destination:d);case .diagnostics(let a):return.diagnostics(a);case .settings(let a,let b):return.settings(a,destination:b);case .bot(let a,let b,let c):return.bot(a,destination:b,requestID:c)}}}
public struct WatchHandoffRoute:Hashable,Codable,Sendable{public let schemaVersion:UInt16;public let routeID:UUID;public let scope:ServerScope;public let target:WatchRouteTarget;public let createdAt:Date;public let expiresAt:Date;public init(routeID:UUID,scope:ServerScope,target:WatchRouteTarget,createdAt:Date,expiresAt:Date)throws{guard createdAt.timeIntervalSinceReferenceDate.isFinite,expiresAt.timeIntervalSinceReferenceDate.isFinite,createdAt<expiresAt,expiresAt.timeIntervalSince(createdAt)<=300 else{throw RouteValidationError.invalidDates};if let nested=target.nestedScope, nested != scope{throw RouteValidationError.scopeMismatch};try target.validate();self.schemaVersion=1;self.routeID=routeID;self.scope=scope;self.target=target;self.createdAt=createdAt;self.expiresAt=expiresAt};private enum CodingKeys:String,CodingKey{case schemaVersion,routeID,scope,target,createdAt,expiresAt};public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);let schema=try c.decode(UInt16.self,forKey:.schemaVersion);guard schema==1 else{throw RouteValidationError.unsupportedSchema(Int(schema))};try self.init(routeID:c.decode(UUID.self,forKey:.routeID),scope:c.decode(ServerScope.self,forKey:.scope),target:c.decode(WatchRouteTarget.self,forKey:.target),createdAt:c.decode(Date.self,forKey:.createdAt),expiresAt:c.decode(Date.self,forKey:.expiresAt));let now=Date();guard createdAt<=now.addingTimeInterval(30),expiresAt>=now else{throw RouteValidationError.invalidDates}};public func canonicalJSONData()throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys];let data=try e.encode(self);guard data.count<=ContractLimits.routeJSONBytes else{throw RouteValidationError.tooLarge};return data};public static func decode(_ data:Data)throws->Self{guard data.count<=ContractLimits.routeJSONBytes else{throw RouteValidationError.tooLarge};return try JSONDecoder().decode(Self.self,from:data)}}
