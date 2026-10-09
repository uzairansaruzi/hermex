import Foundation
import Testing
@testable import WatchShared

@Suite struct CredentialContractTests {
    private let epochUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let serverUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let envelopeUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func scope(generation: UInt64 = 1) throws -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(rawValue: epochUUID),
            server: ServerID(rawValue: serverUUID),
            generation: try Generation(generation)
        )
    }

    private func fixture(
        scope: ServerScope? = nil,
        explicitPort: Bool = true,
        issuedAt: Date = Date(),
        lifetime: TimeInterval = 300,
        cookieLifetime: TimeInterval = 600,
        credentialHasExpiry: Bool = true
    ) throws -> WatchCredentialTransferEnvelope {
        let scope = try scope ?? self.scope()
        let cookieExpiry = issuedAt.addingTimeInterval(cookieLifetime)
        let cookie = try HTTPCookiePropertyRecord(
            name: "hermes_session", value: "credential-value", domain: ".example.com",
            path: "/", secure: true, expiresAt: cookieExpiry
        )
        let origin = URL(string: explicitPort ? "https://api.example.com:443" : "https://api.example.com")!
        let credential = try WatchCredentialRecord(
            scope: scope, origin: origin, cookie: cookie,
            approvedHeaders: [try HeaderCredentialRecord(name: "X-Hermes-Proxy", value: "credential-header")],
            expiresAt: credentialHasExpiry ? cookieExpiry : nil
        )
        return try WatchCredentialTransferEnvelope(
            envelopeID: envelopeUUID, scope: scope, issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime), credential: credential,
            trustedNow: issuedAt
        )
    }

    private func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func encodedObject(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @Test func semanticCoverage_HTTPCookiePropertyRecord() throws {
        let value = try HTTPCookiePropertyRecord(
            name: "semantic_cookie", value: "secret", domain: "example.com",
            path: "/", secure: true, expiresAt: Date(timeIntervalSinceReferenceDate: 600)
        )
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(HTTPCookiePropertyRecord.self, from: encoded)
        #expect(decoded == value)
        #expect(decoded.name == "semantic_cookie" && decoded.secure)
        #expect(throws: CredentialValidationError.invalidCookie) {
            try HTTPCookiePropertyRecord(name: "semantic_cookie", value: "secret", domain: "example.com", path: "/", secure: false, expiresAt: nil)
        }
    }

    @Test func semanticCoverage_HeaderCredentialRecord() throws {
        let value = try HeaderCredentialRecord(name: "X-Hermes-Proxy", value: "semantic-header")
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(HeaderCredentialRecord.self, from: encoded)
        #expect(decoded == value)
        #expect(decoded.name == "X-Hermes-Proxy")
        #expect(throws: CredentialValidationError.forbiddenHeader) {
            try HeaderCredentialRecord(name: "Cookie", value: "secret")
        }
    }

    @Test func semanticCoverage_WatchCredentialRecord() throws {
        let scope = try scope()
        let cookie = try HTTPCookiePropertyRecord(name: "semantic_cookie", value: "secret", domain: "example.com", path: "/", secure: true, expiresAt: nil)
        let value = try WatchCredentialRecord(
            scope: scope, origin: URL(string: "https://example.com")!, cookie: cookie,
            approvedHeaders: [try HeaderCredentialRecord(name: "authorization", value: "semantic-token")],
            expiresAt: nil
        )
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WatchCredentialRecord.self, from: encoded)
        #expect(decoded == value)
        #expect(decoded.scope == scope && decoded.origin.host == "example.com")
        #expect(throws: CredentialValidationError.invalidOrigin) {
            try WatchCredentialRecord(scope: scope, origin: URL(string: "http://example.com")!, cookie: cookie, approvedHeaders: [], expiresAt: nil)
        }
    }

    @Test func semanticCoverage_WatchCredentialTransferEnvelope() throws {
        let issuedAt = Date().addingTimeInterval(10)
        let value = try fixture(issuedAt: issuedAt)
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encoded)
        #expect(decoded == value)
        #expect(decoded.schemaVersion == 1 && decoded.scope == value.credential.scope)
        var malformed = try object(value)
        malformed["schemaVersion"] = 2
        #expect(throws: CredentialValidationError.unsupportedSchema) {
            try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed))
        }
    }

    @Test func independentPhoneAndWatchCanonicalFixturesAreByteCompatible() throws {
        let issuedAt = Date(timeIntervalSinceReferenceDate: floor(Date().timeIntervalSinceReferenceDate) + 10)
        let phoneFixture = try fixture(explicitPort: true, issuedAt: issuedAt)
        let watchFixture = try fixture(explicitPort: false, issuedAt: issuedAt)

        let phoneBytes = try canonicalEncoder().encode(phoneFixture)
        let watchBytes = try canonicalEncoder().encode(watchFixture)
        let phoneObject = try #require(JSONSerialization.jsonObject(with: phoneBytes) as? [String: Any])
        let watchObject = try #require(JSONSerialization.jsonObject(with: watchBytes) as? [String: Any])
        let phoneCredential = try #require(phoneObject["credential"] as? [String: Any])
        let watchCredential = try #require(watchObject["credential"] as? [String: Any])
        #expect(phoneCredential["origin"] as? String == "https://api.example.com:443")
        #expect(watchCredential["origin"] as? String == "https://api.example.com")
        #expect(try canonicalEncoder().encode(JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: phoneBytes)) == phoneBytes)
        #expect(try canonicalEncoder().encode(JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: watchBytes)) == watchBytes)
    }

    @Test func envelopeCannotOutliveCookieWhenCredentialExpiryIsOmitted() throws {
        let issuedAt = Date()
        let envelope = try fixture(issuedAt: issuedAt, lifetime: 30, cookieLifetime: 30, credentialHasExpiry: false)
        #expect(envelope.expiresAt == envelope.credential.cookie.expiresAt)
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(
                envelopeID: UUID(), scope: envelope.scope, issuedAt: issuedAt,
                expiresAt: issuedAt.addingTimeInterval(31), credential: envelope.credential,
                trustedNow: issuedAt
            )
        }
    }

    @Test func publicInitializerCannotBypassCurrentClockValidation() throws {
        let scope = try scope()
        let future = Date().addingTimeInterval(86_400)
        let cookie = try HTTPCookiePropertyRecord(
            name: "hermes_session", value: "credential-value", domain: "example.com",
            path: "/", secure: true, expiresAt: future.addingTimeInterval(600)
        )
        let credential = try WatchCredentialRecord(
            scope: scope, origin: URL(string: "https://example.com")!, cookie: cookie,
            approvedHeaders: [], expiresAt: future.addingTimeInterval(600)
        )
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(
                envelopeID: UUID(), scope: scope, issuedAt: future,
                expiresAt: future.addingTimeInterval(60), credential: credential
            )
        }
    }

    @Test func effectiveCredentialAndEnvelopeExpiryUseTrustedClock() throws {
        let scope = try scope()
        let now = Date()
        let expiredCookie = try HTTPCookiePropertyRecord(
            name: "hermes_session", value: "credential-value", domain: "example.com",
            path: "/", secure: true, expiresAt: now.addingTimeInterval(-1)
        )
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialRecord(
                scope: scope, origin: URL(string: "https://example.com")!,
                cookie: expiredCookie, approvedHeaders: [], expiresAt: nil,
                trustedNow: now
            )
        }

        let liveCookie = try HTTPCookiePropertyRecord(
            name: "hermes_session", value: "credential-value", domain: "example.com",
            path: "/", secure: true, expiresAt: now.addingTimeInterval(600)
        )
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialRecord(
                scope: scope, origin: URL(string: "https://example.com")!,
                cookie: liveCookie, approvedHeaders: [], expiresAt: now.addingTimeInterval(-1),
                trustedNow: now
            )
        }
        let credential = try WatchCredentialRecord(
            scope: scope, origin: URL(string: "https://example.com")!,
            cookie: liveCookie, approvedHeaders: [], expiresAt: now.addingTimeInterval(600),
            trustedNow: now
        )
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(
                envelopeID: UUID(), scope: scope,
                issuedAt: now.addingTimeInterval(-120), expiresAt: now.addingTimeInterval(-1),
                credential: credential, trustedNow: now
            )
        }
    }

    @Test func noncanonicalTextualOriginsAreRejected() throws {
        let scope = try scope()
        let cookie = try HTTPCookiePropertyRecord(
            name: "hermes_session", value: "credential-value", domain: "example.com",
            path: "/", secure: true, expiresAt: nil
        )
        for origin in ["HTTPS://example.com", "https://example.com/", "https://example.com:0443", "https://example.com."] {
            #expect(throws: CredentialValidationError.invalidOrigin) {
                try WatchCredentialRecord(
                    scope: scope, origin: URL(string: origin)!, cookie: cookie,
                    approvedHeaders: [], expiresAt: nil
                )
            }
        }
    }

    @Test func decodedScopeSchemaAndRequiredFieldsFailClosed() throws {
        let envelope = try fixture()
        var malformed = try object(envelope)
        malformed["scope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope(generation: 2)))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }

        for key in ["envelopeID", "scope", "issuedAt", "expiresAt", "credential"] {
            malformed = try object(envelope)
            malformed.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
        }
        malformed = try object(envelope)
        malformed["schemaVersion"] = 2
        #expect(throws: CredentialValidationError.unsupportedSchema) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
    }

    @Test func cookieFieldsAndDecodedMalformedFixturesAreBounded() throws {
        let valid = try HTTPCookiePropertyRecord(name: "n", value: "v", domain: "example.com", path: "/", secure: true, expiresAt: nil)
        #expect(valid.name == "n")
        for name in ["", " ", String(repeating: "n", count: 257), "n\n"] {
            #expect(throws: (any Error).self) { try HTTPCookiePropertyRecord(name: name, value: "v", domain: "example.com", path: "/", secure: true, expiresAt: nil) }
        }
        for value in ["", " ", String(repeating: "v", count: 4097), "v\t"] {
            #expect(throws: (any Error).self) { try HTTPCookiePropertyRecord(name: "n", value: value, domain: "example.com", path: "/", secure: true, expiresAt: nil) }
        }
        for domain in ["", " ", String(repeating: "d", count: 256), "Example.com", "https://example.com", "example.com/path", "example.com:443"] {
            #expect(throws: (any Error).self) { try HTTPCookiePropertyRecord(name: "n", value: "v", domain: domain, path: "/", secure: true, expiresAt: nil) }
        }
        for path in ["", "relative", String(repeating: "/", count: 1025), "/?x", "/#x"] {
            #expect(throws: (any Error).self) { try HTTPCookiePropertyRecord(name: "n", value: "v", domain: "example.com", path: path, secure: true, expiresAt: nil) }
        }
        #expect(throws: CredentialValidationError.invalidCookie) { try HTTPCookiePropertyRecord(name: "n", value: "v", domain: "example.com", path: "/", secure: false, expiresAt: nil) }

        var malformed = try object(valid)
        malformed["secure"] = false
        #expect(throws: CredentialValidationError.invalidCookie) { try JSONDecoder().decode(HTTPCookiePropertyRecord.self, from: encodedObject(malformed)) }
        malformed = try object(valid)
        malformed["name"] = ""
        #expect(throws: CredentialValidationError.blank) { try JSONDecoder().decode(HTTPCookiePropertyRecord.self, from: encodedObject(malformed)) }
        malformed = try object(valid)
        malformed["expiresAt"] = "not-a-date"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HTTPCookiePropertyRecord.self, from: encodedObject(malformed)) }
    }

    @Test func cookieDomainBoundaryPathAndEffectivePortsAreExact() throws {
        let scope = try scope()
        let cookie = try HTTPCookiePropertyRecord(name: "n", value: "v", domain: ".example.com", path: "/", secure: true, expiresAt: nil)
        for origin in ["https://example.com", "https://example.com:443", "https://api.example.com", "https://api.example.com:1", "https://api.example.com:65535"] {
            #expect(throws: Never.self) { try WatchCredentialRecord(scope: scope, origin: URL(string: origin)!, cookie: cookie, approvedHeaders: [], expiresAt: nil) }
        }
        for invalid in ["http://example.com", "https://user@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#x", "https://EXAMPLE.com", "https://example.com:0", "https://example.com:65536", "https://notexample.com"] {
            #expect(throws: (any Error).self) { try WatchCredentialRecord(scope: scope, origin: URL(string: invalid)!, cookie: cookie, approvedHeaders: [], expiresAt: nil) }
        }
        let wrongPath = try HTTPCookiePropertyRecord(name: "n", value: "v", domain: "example.com", path: "/api", secure: true, expiresAt: nil)
        #expect(throws: CredentialValidationError.invalidCookie) { try WatchCredentialRecord(scope: scope, origin: URL(string: "https://example.com")!, cookie: wrongPath, approvedHeaders: [], expiresAt: nil) }
    }

    @Test func approvedHeadersAllowlistForbiddenSetValuesAndDuplicatesAreExact() throws {
        for name in ["X-Hermes-Proxy", "x-forwarded-user", "AUTHORIZATION"] {
            #expect(throws: Never.self) { try HeaderCredentialRecord(name: name, value: "v") }
        }
        for name in ["Host", "Cookie", "Set-Cookie", "Content-Length", "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade", "X-Not-Reviewed"] {
            #expect(throws: CredentialValidationError.forbiddenHeader) { try HeaderCredentialRecord(name: name, value: "x") }
        }
        for value in ["", " ", String(repeating: "v", count: 4097), "v\r\nInjected: x"] {
            #expect(throws: (any Error).self) { try HeaderCredentialRecord(name: "authorization", value: value) }
        }
        let decoded = try JSONDecoder().decode(HeaderCredentialRecord.self, from: Data("{\"name\":\"authorization\",\"value\":\"v\"}".utf8))
        #expect(decoded.name == "authorization")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HeaderCredentialRecord.self, from: Data("{\"name\":\"x-not-reviewed\",\"value\":\"v\"}".utf8)) }

        let scope = try scope()
        let cookie = try HTTPCookiePropertyRecord(name: "n", value: "v", domain: "example.com", path: "/", secure: true, expiresAt: nil)
        #expect(throws: CredentialValidationError.duplicateHeader) {
            try WatchCredentialRecord(scope: scope, origin: URL(string: "https://example.com")!, cookie: cookie, approvedHeaders: [
                try HeaderCredentialRecord(name: "X-Hermes-Proxy", value: "a"),
                try HeaderCredentialRecord(name: "x-hermes-proxy", value: "b"),
            ], expiresAt: nil)
        }
    }

    @Test func dateBoundariesAreEnforcedByInitializerAndDecoder() throws {
        let now = Date()
        let envelope = try fixture(issuedAt: now)
        #expect(throws: Never.self) {
            try WatchCredentialTransferEnvelope(envelopeID: UUID(), scope: envelope.scope, issuedAt: now.addingTimeInterval(30), expiresAt: now.addingTimeInterval(330), credential: envelope.credential, trustedNow: now)
        }
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(envelopeID: UUID(), scope: envelope.scope, issuedAt: now.addingTimeInterval(31), expiresAt: now.addingTimeInterval(60), credential: envelope.credential, trustedNow: now)
        }
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(envelopeID: UUID(), scope: envelope.scope, issuedAt: now, expiresAt: now, credential: envelope.credential, trustedNow: now)
        }
        #expect(throws: CredentialValidationError.invalidDate) {
            try WatchCredentialTransferEnvelope(envelopeID: UUID(), scope: envelope.scope, issuedAt: now, expiresAt: now.addingTimeInterval(301), credential: envelope.credential, trustedNow: now)
        }

        var malformed = try object(envelope)
        malformed["issuedAt"] = "not-a-date"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
        malformed = try object(envelope)
        malformed["expiresAt"] = "not-a-date"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
        malformed = try object(envelope)
        malformed["expiresAt"] = envelope.issuedAt.timeIntervalSinceReferenceDate
        #expect(throws: CredentialValidationError.invalidDate) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
        malformed = try object(envelope)
        malformed["expiresAt"] = envelope.issuedAt.addingTimeInterval(301).timeIntervalSinceReferenceDate
        #expect(throws: CredentialValidationError.invalidDate) { try JSONDecoder().decode(WatchCredentialTransferEnvelope.self, from: encodedObject(malformed)) }
    }

    @Test func secretTypesRemainAbsentFromNonCredentialStorageAndPayloadSources() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repositoryRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        let roots = [
            packageRoot.appendingPathComponent("Sources/WatchShared"),
            repositoryRoot.appendingPathComponent("HermesMobile"),
            repositoryRoot.appendingPathComponent("HermexWatch"),
            repositoryRoot.appendingPathComponent("HermexWatchWidget"),
            repositoryRoot.appendingPathComponent("HermesLiveActivityWidget"),
            repositoryRoot.appendingPathComponent("HermesShareExtension"),
        ]
        let forbiddenTypes = ["HTTPCookiePropertyRecord", "HeaderCredentialRecord", "WatchCredentialRecord", "WatchCredentialTransferEnvelope"]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" && file.lastPathComponent != "CredentialContract.swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for type in forbiddenTypes { #expect(!text.contains(type), "\(type) leaked into \(file.path)") }
            }
        }
    }
}
