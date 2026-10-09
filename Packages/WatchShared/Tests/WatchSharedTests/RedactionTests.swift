import Foundation
import Testing
@testable import WatchShared

@Suite struct RedactionTests {
    @Test func semanticCoverage_RedactionContext() throws {
        let values: [RedactionContext] = [.route, .widget, .diagnostics, .receipt, .log]
        for value in values {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(RedactionContext.self, from: encoded)
            #expect(decoded == value)
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RedactionContext.self, from: Data("\"private\"".utf8))
        }
    }

    @Test func semanticCoverage_SourceTextCategory() throws {
        let expected: [(SourceTextCategory, String)] = [
            (.chat, "Private chat content"),
            (.command, "Private command"),
            (.question, "Private question"),
            (.answer, "Private answer"),
            (.path, "Private path"),
            (.backendError, "Private server error"),
        ]
        for (value, placeholder) in expected {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(SourceTextCategory.self, from: encoded)
            #expect(decoded == value)
            #expect(WatchRedactor.fixedPlaceholder(for: value) == placeholder)
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceTextCategory.self, from: Data("\"credential\"".utf8))
        }
    }

    @Test func semanticCoverage_WatchRedactor() throws {
        #expect(WatchRedactor.fixedPlaceholder(for: .backendError) == "Private server error")
        #expect(try WatchRedactor.displayName(aliasIndex: 41).rawValue == "Server42")
        try WatchRedactor.validateNonSecretProjection(Data("attentionExactIDUnavailable".utf8), context: .log)

        #expect(throws: DTOValidationError.invalidCount) {
            try WatchRedactor.displayName(aliasIndex: -1)
        }
        #expect(throws: DTOValidationError.tooLarge) {
            try WatchRedactor.validateNonSecretProjection(Data("authorization: Bearer private".utf8), context: .log)
        }
    }

    @Test func exactPlaceholdersAndAliasesAreStableAndBounded() throws {
        let expected: [(SourceTextCategory, String)] = [(.chat, "Private chat content"), (.command, "Private command"), (.question, "Private question"), (.answer, "Private answer"), (.path, "Private path"), (.backendError, "Private server error")]
        for (category, placeholder) in expected { #expect(WatchRedactor.fixedPlaceholder(for: category) == placeholder); #expect(try JSONDecoder().decode(SourceTextCategory.self, from: JSONEncoder().encode(category)) == category) }
        #expect(try WatchRedactor.displayName(aliasIndex: 0).rawValue == "Server1")
        #expect(try WatchRedactor.displayName(aliasIndex: 999).rawValue == "Server1000")
        #expect(try WatchRedactor.displayName(aliasIndex: Int.max - 1).rawValue == "Server\(Int.max)")
        #expect(throws: (any Error).self) { try WatchRedactor.displayName(aliasIndex: -1) }
        #expect(throws: (any Error).self) { try WatchRedactor.displayName(aliasIndex: Int.max) }
    }

    @Test func safeClientCodeDoesNotBypassForbiddenMaterial() throws {
        for payload in [
            "attentionExactIDUnavailable U01C_SECRET_CANARY",
            "attentionExactIDUnavailable authorization: Bearer token",
            "attentionExactIDUnavailable https://private.example/path",
        ] {
            #expect(throws: (any Error).self) {
                try WatchRedactor.validateNonSecretProjection(Data(payload.utf8), context: .log)
            }
        }
    }

    @Test func escapedAndUnicodeControlsFailClosed() throws {
        for value in ["safe\nforged", "safe\tforged", "safe\u{2028}forged", "safe\u{2029}forged"] {
            let encoded = try JSONEncoder().encode(value)
            #expect(throws: (any Error).self) {
                try WatchRedactor.validateNonSecretProjection(encoded, context: .log)
            }
        }
    }

    @Test func widgetSnapshotRejectsCanaryBeforeEncoding() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let unsafeName = try RedactedDisplayName("Server1")
        let snapshot = try RedactedWidgetSnapshot(
            schema: 1, scope: scope, displayName: unsafeName, activity: .unknown,
            attentionCount: 0, observedAt: Date(), route: .sessions(scope)
        )
        let safeBytes = try snapshot.canonicalJSONData()
        try WatchRedactor.validateNonSecretProjection(safeBytes, context: .widget)
        #expect(!String(decoding: safeBytes, as: UTF8.self).contains("U01C_SECRET_CANARY"))
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try RedactedDisplayName("U01C_SECRET_CANARY")
        }
    }

    @Test func contextByteBoundariesAreExact() throws {
        for (context, limit) in [
            (RedactionContext.route, ContractLimits.routeJSONBytes),
            (.widget, ContractLimits.widgetJSONBytes),
            (.diagnostics, 16_384), (.receipt, 16_384), (.log, 16_384),
        ] {
            try WatchRedactor.validateNonSecretProjection(Data(repeating: 65, count: limit), context: context)
            #expect(throws: (any Error).self) {
                try WatchRedactor.validateNonSecretProjection(Data(repeating: 65, count: limit + 1), context: context)
            }
        }
    }

    @Test func structuredJSONRejectsSensitiveKeysWithoutBenignSubstringFalsePositives() throws {
        let benign = try JSONSerialization.data(withJSONObject: ["role": "secretary", "status": "responsive"])
        try WatchRedactor.validateNonSecretProjection(benign, context: .log)

        for key in [
            "authorization", "cookie", "set-cookie", "password", "token", "api-key", "host", "origin", "url",
            "command", "prompt", "response", "raw-error", "raw-path", "filename", "content-length", "connection",
            "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
        ] {
            let payload = try JSONSerialization.data(withJSONObject: [key: "value"])
            #expect(throws: (any Error).self) {
                try WatchRedactor.validateNonSecretProjection(payload, context: .log)
            }
        }
    }

    @Test func forbiddenValuesCoverCredentialsURLsErrorsAndPaths() {
        let forbidden = [
            "Authorization: Bearer abc", "Cookie: session=abc", "Set-Cookie: x=y",
            "api_key=abc", "token=abc", "password=abc", "prompt=private",
            "response=private", "command=rm", "raw_error=private",
            "https://host/private", "http://host", "/Users/person/private", "C:\\Users\\person\\private",
            "U01C_SECRET_CANARY",
        ]
        for value in forbidden {
            #expect(throws: (any Error).self) {
                try WatchRedactor.validateNonSecretProjection(Data(value.utf8), context: .log)
            }
        }
    }

    @Test func utf8AndControlBoundariesFailClosed() throws {
        let exact = Data(String(repeating: "é", count: 8192).utf8)
        try WatchRedactor.validateNonSecretProjection(exact, context: .log)
        #expect(throws: (any Error).self) { try WatchRedactor.validateNonSecretProjection(Data(String(repeating: "é", count: 8193).utf8), context: .log) }
        for byte in [UInt8(0), 1, 8, 9, 10, 11, 12, 13, 31, 127] { #expect(throws: (any Error).self) { try WatchRedactor.validateNonSecretProjection(Data([65, byte, 66]), context: .log) } }
        #expect(throws: (any Error).self) { try WatchRedactor.validateNonSecretProjection(Data([0xff]), context: .log) }
    }

    @Test func realRouteWidgetDiagnosticReceiptAndLogSafeOutputsContainNoCanary() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let route = try WatchHandoffRoute(routeID: UUID(), scope: scope, target: .diagnostics(scope), createdAt: now, expiresAt: now.addingTimeInterval(60))
        let widget = try RedactedWidgetSnapshot(schema: 1, scope: scope, displayName: RedactedDisplayName("Server1"), activity: .unknown, attentionCount: 0, observedAt: now, route: .sessions(scope))
        let diagnostic = try WatchDiagnosticsProjection(scope: scope, source: .snapshot, observedAt: now, expiresAt: now.addingTimeInterval(60), codes: [.timeout])
        let context = try CommandContext(stableCommandID: CommandID(rawValue: UUID()), scope: scope, expectedRevision: Revision(1), createdAt: now, expiresAt: now.addingTimeInterval(60))
        let receipt = try MutationReceipt(context: context, operationKind: .stop, phase: .rejected, updatedAt: now, nonSecretResultID: "attentionExactIDUnavailable")
        let outputs: [(RedactionContext, Data)] = [(.route, try JSONEncoder().encode(route)), (.widget, try JSONEncoder().encode(widget)), (.diagnostics, try JSONEncoder().encode(diagnostic)), (.receipt, try JSONEncoder().encode(receipt)), (.log, Data("attentionExactIDUnavailable".utf8))]
        for (context, output) in outputs { try WatchRedactor.validateNonSecretProjection(output, context: context); #expect(!String(decoding: output, as: UTF8.self).contains("U01C_SECRET_CANARY")) }
        for context in [RedactionContext.route, .widget, .diagnostics, .receipt, .log] { #expect(throws: (any Error).self) { try WatchRedactor.validateNonSecretProjection(Data("U01C_SECRET_CANARY authorization=https://host/private".utf8), context: context) } }
    }
}
