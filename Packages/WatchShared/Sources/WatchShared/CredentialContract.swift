import Foundation

public enum CredentialValidationError: Error, Equatable, Sendable { case blank, tooLarge, insecure, invalidOrigin, invalidPort, invalidCookie, forbiddenHeader, duplicateHeader, invalidDate, scopeMismatch, unsupportedSchema }

private func credentialField(_ value: String, max: Int) throws -> String {
    guard !value.allSatisfy(\.isWhitespace) else { throw CredentialValidationError.blank }
    guard value.utf8.count <= max, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw CredentialValidationError.tooLarge }
    return value
}

public struct HTTPCookiePropertyRecord: Hashable, Codable, Sendable {
    public let name: String; public let value: String; public let domain: String; public let path: String; public let secure: Bool; public let expiresAt: Date?
    public init(name: String, value: String, domain: String, path: String, secure: Bool, expiresAt: Date?) throws {
        guard secure, path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !domain.contains("://"), !domain.contains("/"), !domain.contains(":"), domain == domain.lowercased() else { throw CredentialValidationError.invalidCookie }
        if let expiresAt, !expiresAt.timeIntervalSinceReferenceDate.isFinite { throw CredentialValidationError.invalidDate }
        self.name = try credentialField(name, max: 256); self.value = try credentialField(value, max: 4096); self.domain = try credentialField(domain, max: 255); self.path = try credentialField(path, max: 1024); self.secure = secure; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case name, value, domain, path, secure, expiresAt }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(name: c.decode(String.self, forKey: .name), value: c.decode(String.self, forKey: .value), domain: c.decode(String.self, forKey: .domain), path: c.decode(String.self, forKey: .path), secure: c.decode(Bool.self, forKey: .secure), expiresAt: c.decodeIfPresent(Date.self, forKey: .expiresAt)) }
}

public struct HeaderCredentialRecord: Hashable, Codable, Sendable {
    public let name: String; public let value: String
    private static let allowed: Set<String> = ["x-hermes-proxy", "x-forwarded-user", "authorization"]
    private static let forbidden: Set<String> = ["host", "cookie", "set-cookie", "content-length", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"]
    public init(name: String, value: String) throws {
        let checkedName = try credentialField(name, max: 128), lower = checkedName.lowercased()
        guard Self.allowed.contains(lower), !Self.forbidden.contains(lower) else { throw CredentialValidationError.forbiddenHeader }
        self.name = checkedName; self.value = try credentialField(value, max: 4096)
    }
    private enum CodingKeys: String, CodingKey { case name, value }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(name: c.decode(String.self, forKey: .name), value: c.decode(String.self, forKey: .value)) }
}

public struct WatchCredentialRecord: Hashable, Codable, Sendable {
    public let scope: ServerScope; public let origin: URL; public let cookie: HTTPCookiePropertyRecord; public let approvedHeaders: [HeaderCredentialRecord]; public let expiresAt: Date?
    public init(scope: ServerScope, origin: URL, cookie: HTTPCookiePropertyRecord, approvedHeaders: [HeaderCredentialRecord], expiresAt: Date?) throws {
        try self.init(scope: scope, origin: origin, cookie: cookie, approvedHeaders: approvedHeaders, expiresAt: expiresAt, trustedNow: Date())
    }
    init(scope: ServerScope, origin: URL, cookie: HTTPCookiePropertyRecord, approvedHeaders: [HeaderCredentialRecord], expiresAt: Date?, trustedNow: Date) throws {
        guard trustedNow.timeIntervalSinceReferenceDate.isFinite else { throw CredentialValidationError.invalidDate }
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false), components.scheme == "https", let host = components.host, !host.isEmpty, host == host.lowercased(), !host.hasSuffix("."), components.user == nil, components.password == nil, components.query == nil, components.fragment == nil, components.path.isEmpty else { throw CredentialValidationError.invalidOrigin }
        let canonicalOrigin = "https://\(host)" + (components.port.map { ":\($0)" } ?? "")
        guard origin.absoluteString == canonicalOrigin else { throw CredentialValidationError.invalidOrigin }
        guard (1...65535).contains(components.port ?? 443) else { throw CredentialValidationError.invalidPort }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        guard host == domain || host.hasSuffix("." + domain), cookie.path == "/" else { throw CredentialValidationError.invalidCookie }
        let effectiveExpiry = [expiresAt, cookie.expiresAt].compactMap { $0 }.min()
        if let expiresAt { guard expiresAt.timeIntervalSinceReferenceDate.isFinite else { throw CredentialValidationError.invalidDate }; if let cookieExpiry = cookie.expiresAt, expiresAt > cookieExpiry { throw CredentialValidationError.invalidDate } }
        guard effectiveExpiry.map({ $0 > trustedNow }) ?? true else { throw CredentialValidationError.invalidDate }
        var names = Set<String>(); for header in approvedHeaders { guard names.insert(header.name.lowercased()).inserted else { throw CredentialValidationError.duplicateHeader } }
        self.scope = scope; self.origin = origin; self.cookie = cookie; self.approvedHeaders = approvedHeaders; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case scope, origin, cookie, approvedHeaders, expiresAt }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); try self.init(scope: c.decode(ServerScope.self, forKey: .scope), origin: c.decode(URL.self, forKey: .origin), cookie: c.decode(HTTPCookiePropertyRecord.self, forKey: .cookie), approvedHeaders: c.decode([HeaderCredentialRecord].self, forKey: .approvedHeaders), expiresAt: c.decodeIfPresent(Date.self, forKey: .expiresAt), trustedNow: Date()) }
}

public struct WatchCredentialTransferEnvelope: Hashable, Codable, Sendable {
    public let schemaVersion: UInt16; public let envelopeID: UUID; public let scope: ServerScope; public let issuedAt: Date; public let expiresAt: Date; public let credential: WatchCredentialRecord
    public init(envelopeID: UUID, scope: ServerScope, issuedAt: Date, expiresAt: Date, credential: WatchCredentialRecord) throws {
        try self.init(envelopeID: envelopeID, scope: scope, issuedAt: issuedAt, expiresAt: expiresAt, credential: credential, trustedNow: Date())
    }
    init(envelopeID: UUID, scope: ServerScope, issuedAt: Date, expiresAt: Date, credential: WatchCredentialRecord, trustedNow: Date) throws {
        guard scope == credential.scope else { throw CredentialValidationError.scopeMismatch }
        let credentialExpiry = [credential.expiresAt, credential.cookie.expiresAt].compactMap { $0 }.min()
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite, expiresAt.timeIntervalSinceReferenceDate.isFinite, trustedNow.timeIntervalSinceReferenceDate.isFinite, issuedAt < expiresAt, expiresAt > trustedNow, expiresAt.timeIntervalSince(issuedAt) <= 300, issuedAt <= trustedNow.addingTimeInterval(30), credentialExpiry.map({ expiresAt <= $0 && $0 > trustedNow }) ?? true else { throw CredentialValidationError.invalidDate }
        schemaVersion = 1; self.envelopeID = envelopeID; self.scope = scope; self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.credential = credential
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, envelopeID, scope, issuedAt, expiresAt, credential }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); guard try c.decode(UInt16.self, forKey: .schemaVersion) == 1 else { throw CredentialValidationError.unsupportedSchema }
        let issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        try self.init(envelopeID: c.decode(UUID.self, forKey: .envelopeID), scope: c.decode(ServerScope.self, forKey: .scope), issuedAt: issuedAt, expiresAt: c.decode(Date.self, forKey: .expiresAt), credential: c.decode(WatchCredentialRecord.self, forKey: .credential), trustedNow: Date())
    }
}
