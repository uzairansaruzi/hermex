import Foundation
import Testing
import WatchShared

@Suite struct PrivateExchangeTests {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private struct Fixture {
        let scope: ServerScope
        let otherScope: ServerScope
        let draftHandle: DraftHandle
        let pathHandle: PathHandle
        let session: SessionKey
        let now: Date

        init() throws {
            let epoch = InstallationEpoch(rawValue: UUID())
            scope = ServerScope(
                epoch: epoch,
                server: ServerID(rawValue: UUID()),
                generation: try Generation(1)
            )
            otherScope = ServerScope(
                epoch: epoch,
                server: ServerID(rawValue: UUID()),
                generation: try Generation(1)
            )
            draftHandle = DraftHandle(rawValue: UUID())
            pathHandle = try PathHandle("workspace/Sources/App.swift")
            session = try SessionKey(scope: scope, sessionID: "session-42")
            now = Date().addingTimeInterval(30)
        }

        func request(
            kind: PrivateExchangeKind,
            purpose: PrivateExchangePurpose,
            identity: PrivateExchangeIdentity
        ) throws -> PrivateExchangeRequest {
            try PrivateExchangeRequest(
                requestID: UUID(),
                scope: scope,
                kind: kind,
                purpose: purpose,
                identity: identity,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            )
        }
    }

    @Test func semanticCoverage_PrivateExchangeIdentity() throws {
        let fixture = try Fixture()
        let identities: [PrivateExchangeIdentity] = [
            .draft(scope: fixture.scope, handle: fixture.draftHandle),
            .directPath(session: fixture.session, handle: fixture.pathHandle),
        ]

        for identity in identities {
            let encoded = try JSONEncoder().encode(identity)
            let decoded = try JSONDecoder().decode(PrivateExchangeIdentity.self, from: encoded)
            #expect(decoded == identity)
            #expect(decoded.scope == fixture.scope)
        }

        #expect(throws: PrivateExchangeValidationError.scopeMismatch) {
            try PrivateExchangeRequest(
                requestID: UUID(),
                scope: fixture.otherScope,
                kind: .consumeDraft,
                purpose: .newSessionDraft,
                identity: identities[0],
                createdAt: fixture.now,
                expiresAt: fixture.now.addingTimeInterval(60)
            )
        }
    }

    @Test func semanticCoverage_PrivateExchangeKind() throws {
        let fixture = try Fixture()
        let kinds: [PrivateExchangeKind] = [.consumeDraft, .resolveDirectPath]

        for kind in kinds {
            let encoded = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(PrivateExchangeKind.self, from: encoded)
            #expect(decoded == kind)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PrivateExchangeKind.self, from: Data("\"unknown-kind\"".utf8))
        }

        let draftIdentity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: fixture.draftHandle)
        let pathIdentity = PrivateExchangeIdentity.directPath(session: fixture.session, handle: fixture.pathHandle)
        #expect(throws: PrivateExchangeValidationError.incompatiblePurpose) {
            try fixture.request(kind: .resolveDirectPath, purpose: .newSessionDraft, identity: draftIdentity)
        }
        #expect(throws: PrivateExchangeValidationError.incompatiblePurpose) {
            try fixture.request(kind: .consumeDraft, purpose: .directPathHandoff, identity: pathIdentity)
        }
    }

    @Test func semanticCoverage_PrivateExchangePurpose() throws {
        let fixture = try Fixture()
        let purposes: [PrivateExchangePurpose] = [
            .newSessionDraft,
            .clarificationDraft,
            .directPathHandoff,
        ]

        for purpose in purposes {
            let encoded = try JSONEncoder().encode(purpose)
            let decoded = try JSONDecoder().decode(PrivateExchangePurpose.self, from: encoded)
            #expect(decoded == purpose)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PrivateExchangePurpose.self, from: Data("\"unknown-purpose\"".utf8))
        }

        let draftIdentity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: fixture.draftHandle)
        let pathIdentity = PrivateExchangeIdentity.directPath(session: fixture.session, handle: fixture.pathHandle)
        _ = try fixture.request(kind: .consumeDraft, purpose: .newSessionDraft, identity: draftIdentity)
        _ = try fixture.request(kind: .consumeDraft, purpose: .clarificationDraft, identity: draftIdentity)
        _ = try fixture.request(kind: .resolveDirectPath, purpose: .directPathHandoff, identity: pathIdentity)

        let incompatible: [(PrivateExchangeKind, PrivateExchangePurpose, PrivateExchangeIdentity)] = [
            (.consumeDraft, .newSessionDraft, pathIdentity),
            (.consumeDraft, .clarificationDraft, pathIdentity),
            (.consumeDraft, .directPathHandoff, draftIdentity),
            (.consumeDraft, .directPathHandoff, pathIdentity),
            (.resolveDirectPath, .newSessionDraft, draftIdentity),
            (.resolveDirectPath, .newSessionDraft, pathIdentity),
            (.resolveDirectPath, .clarificationDraft, draftIdentity),
            (.resolveDirectPath, .clarificationDraft, pathIdentity),
            (.resolveDirectPath, .directPathHandoff, draftIdentity),
        ]
        for (kind, purpose, identity) in incompatible {
            #expect(throws: PrivateExchangeValidationError.incompatiblePurpose) {
                try fixture.request(kind: kind, purpose: purpose, identity: identity)
            }
        }
    }

    @Test func semanticCoverage_PrivateExchangePayload() throws {
        let fixture = try Fixture()
        let draftIdentity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: fixture.draftHandle)
        let pathIdentity = PrivateExchangeIdentity.directPath(session: fixture.session, handle: fixture.pathHandle)
        let draftRequest = try fixture.request(
            kind: .consumeDraft,
            purpose: .newSessionDraft,
            identity: draftIdentity
        )
        let pathRequest = try fixture.request(
            kind: .resolveDirectPath,
            purpose: .directPathHandoff,
            identity: pathIdentity
        )
        let payloads: [(PrivateExchangeRequest, PrivateExchangePayload)] = [
            (draftRequest, .draft(handle: fixture.draftHandle, text: "Create a release summary")),
            (pathRequest, .canonicalPath(
                session: fixture.session,
                handle: fixture.pathHandle,
                path: "/workspace/Sources/App.swift"
            )),
            (draftRequest, .failure(identity: draftIdentity, code: "draftUnavailable")),
            (pathRequest, .failure(identity: pathIdentity, code: "pathUnavailable")),
        ]

        for (request, payload) in payloads {
            let payloadData = try JSONEncoder().encode(payload)
            let decodedPayload = try JSONDecoder().decode(PrivateExchangePayload.self, from: payloadData)
            #expect(decodedPayload == payload)

            let result = try PrivateExchangeResult(request: request, payload: payload)
            let resultData = try JSONEncoder().encode(result)
            let decodedResult = try JSONDecoder().decode(PrivateExchangeResult.self, from: resultData)
            #expect(decodedResult.payload == payload)
        }

        #expect(throws: PrivateExchangeValidationError.identityMismatch) {
            try PrivateExchangeResult(
                request: draftRequest,
                payload: .draft(handle: DraftHandle(rawValue: UUID()), text: "wrong handle")
            )
        }
        #expect(throws: PrivateExchangeValidationError.identityMismatch) {
            try PrivateExchangeResult(
                request: pathRequest,
                payload: .canonicalPath(
                    session: fixture.session,
                    handle: try PathHandle("workspace/Other.swift"),
                    path: "/workspace/Other.swift"
                )
            )
        }

        let malformed: [PrivateExchangePayload] = [
            .draft(handle: fixture.draftHandle, text: ""),
            .draft(handle: fixture.draftHandle, text: String(repeating: "x", count: 16_385)),
            .canonicalPath(session: fixture.session, handle: fixture.pathHandle, path: ""),
            .canonicalPath(
                session: fixture.session,
                handle: fixture.pathHandle,
                path: String(repeating: "x", count: 16_385)
            ),
            .failure(identity: draftIdentity, code: "   "),
            .failure(identity: draftIdentity, code: String(repeating: "x", count: 257)),
        ]
        for payload in malformed {
            let encoded = try JSONEncoder().encode(payload)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PrivateExchangePayload.self, from: encoded)
            }
        }
    }

    @Test func semanticCoverage_PrivateExchangeRequest() throws {
        let fixture = try Fixture()
        let draftIdentity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: fixture.draftHandle)
        let pathIdentity = PrivateExchangeIdentity.directPath(session: fixture.session, handle: fixture.pathHandle)
        let requests: [PrivateExchangeRequest] = [
            try fixture.request(kind: .consumeDraft, purpose: .newSessionDraft, identity: draftIdentity),
            try fixture.request(kind: .consumeDraft, purpose: .clarificationDraft, identity: draftIdentity),
            try fixture.request(kind: .resolveDirectPath, purpose: .directPathHandoff, identity: pathIdentity),
        ]

        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(PrivateExchangeRequest.self, from: encoded)
            #expect(decoded == request)
            #expect(decoded.schemaVersion == 1)
            #expect(decoded.scope == decoded.identity.scope)
        }

        #expect(throws: PrivateExchangeValidationError.scopeMismatch) {
            try PrivateExchangeRequest(
                requestID: UUID(),
                scope: fixture.otherScope,
                kind: .consumeDraft,
                purpose: .clarificationDraft,
                identity: draftIdentity,
                createdAt: fixture.now,
                expiresAt: fixture.now.addingTimeInterval(60)
            )
        }
        #expect(throws: PrivateExchangeValidationError.incompatiblePurpose) {
            try fixture.request(kind: .resolveDirectPath, purpose: .newSessionDraft, identity: draftIdentity)
        }
        #expect(throws: PrivateExchangeValidationError.invalidDates) {
            try PrivateExchangeRequest(
                requestID: UUID(),
                scope: fixture.scope,
                kind: .consumeDraft,
                purpose: .newSessionDraft,
                identity: draftIdentity,
                createdAt: fixture.now,
                expiresAt: fixture.now.addingTimeInterval(301)
            )
        }

        let valid = requests[0]
        let otherIdentity = PrivateExchangeIdentity.draft(scope: fixture.otherScope, handle: DraftHandle(rawValue: UUID()))
        var malformedRequests: [[String: Any]] = []
        let replacements: [(String, Any)] = [
            ("schemaVersion", 2),
            ("scope", try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.otherScope))),
            ("kind", "resolveDirectPath"),
            ("purpose", "directPathHandoff"),
            ("identity", try JSONSerialization.jsonObject(with: JSONEncoder().encode(otherIdentity))),
            ("createdAt", valid.expiresAt.timeIntervalSinceReferenceDate),
            ("expiresAt", valid.createdAt.addingTimeInterval(301).timeIntervalSinceReferenceDate),
        ]
        for (key, replacement) in replacements {
            var malformed = try object(valid)
            malformed[key] = replacement
            malformedRequests.append(malformed)
        }
        for key in ["requestID", "scope", "kind", "purpose", "identity", "createdAt", "expiresAt"] {
            var malformed = try object(valid)
            malformed.removeValue(forKey: key)
            malformedRequests.append(malformed)
        }
        for malformed in malformedRequests {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PrivateExchangeRequest.self, from: data(malformed))
            }
        }
    }

    @Test func semanticCoverage_PrivateExchangeResult() throws {
        let fixture = try Fixture()
        let identity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: fixture.draftHandle)
        let request = try fixture.request(
            kind: .consumeDraft,
            purpose: .newSessionDraft,
            identity: identity
        )
        let result = try PrivateExchangeResult(
            request: request,
            payload: .draft(handle: fixture.draftHandle, text: "hello")
        )
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(PrivateExchangeResult.self, from: encoded)

        #expect(decoded == result)
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.scope == request.scope)
        #expect(decoded.requestKind == request.kind)
        #expect(decoded.requestPurpose == request.purpose)
        #expect(decoded.requestIdentity == request.identity)
        try decoded.validate(against: request, receivedAt: fixture.now)

        let differentRequest = try PrivateExchangeRequest(
            requestID: UUID(),
            scope: fixture.scope,
            kind: .consumeDraft,
            purpose: .newSessionDraft,
            identity: identity,
            createdAt: fixture.now,
            expiresAt: fixture.now.addingTimeInterval(60)
        )
        #expect(throws: PrivateExchangeValidationError.requestMismatch) {
            try decoded.validate(against: differentRequest, receivedAt: fixture.now)
        }
        #expect(throws: PrivateExchangeValidationError.expired) {
            try decoded.validate(against: request, receivedAt: request.expiresAt.addingTimeInterval(1))
        }
        #expect(throws: PrivateExchangeValidationError.identityMismatch) {
            try PrivateExchangeResult(
                request: request,
                payload: .failure(
                    identity: .draft(scope: fixture.scope, handle: DraftHandle(rawValue: UUID())),
                    code: "wrongIdentity"
                )
            )
        }

        let otherIdentity = PrivateExchangeIdentity.draft(scope: fixture.scope, handle: DraftHandle(rawValue: UUID()))
        let alternateRequest = try PrivateExchangeRequest(
            requestID: UUID(), scope: fixture.scope, kind: .consumeDraft,
            purpose: .clarificationDraft, identity: otherIdentity,
            createdAt: fixture.now.addingTimeInterval(1),
            expiresAt: fixture.now.addingTimeInterval(59)
        )
        let alternateObject = try object(alternateRequest)
        let replacements: [(String, Any)] = [
            ("schemaVersion", 2),
            ("requestID", alternateRequest.requestID.uuidString),
            ("scope", try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.otherScope))),
            ("requestKind", "resolveDirectPath"),
            ("requestPurpose", "clarificationDraft"),
            ("requestIdentity", alternateObject["identity"] as Any),
            ("requestCreatedAt", alternateRequest.createdAt.timeIntervalSinceReferenceDate),
            ("requestExpiresAt", alternateRequest.expiresAt.timeIntervalSinceReferenceDate),
            ("payload", try JSONSerialization.jsonObject(with: JSONEncoder().encode(PrivateExchangePayload.draft(handle: DraftHandle(rawValue: UUID()), text: "wrong")))),
        ]
        var malformedResults: [[String: Any]] = []
        for (key, replacement) in replacements {
            var malformed = try object(result)
            malformed[key] = replacement
            malformedResults.append(malformed)
        }
        for key in ["requestID", "scope", "requestKind", "requestPurpose", "requestIdentity", "requestCreatedAt", "requestExpiresAt", "payload"] {
            var malformed = try object(result)
            malformed.removeValue(forKey: key)
            malformedResults.append(malformed)
        }
        for malformed in malformedResults {
            #expect(throws: (any Error).self) {
                let decodedMalformed = try JSONDecoder().decode(PrivateExchangeResult.self, from: data(malformed))
                try decodedMalformed.validate(against: request, receivedAt: fixture.now)
            }
        }
    }
}
