import Foundation
import Testing
@testable import WatchShared

@Suite struct DiagnosticsTests {
    private func scope() throws -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(
                rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            server: ServerID(
                rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            generation: try Generation(5)
        )
    }

    @Test func semanticCoverage_DiagnosticsSource() throws {
        let sources: [DiagnosticsSource] = [.direct, .phoneBroker, .snapshot]
        #expect(sources.map(\.rawValue) == ["direct", "phoneBroker", "snapshot"])

        for source in sources {
            let encoded = try JSONEncoder().encode(source)
            #expect(
                try JSONDecoder().decode(DiagnosticsSource.self, from: encoded) == source
            )
        }

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                DiagnosticsSource.self,
                from: Data(#""relay""#.utf8)
            )
        }
    }

    @Test func semanticCoverage_SanitizedDiagnosticCode() throws {
        let codes: [SanitizedDiagnosticCode] = [
            .authRequired,
            .permissionDenied,
            .tls,
            .dns,
            .timeout,
            .phoneUnavailable,
            .routeUnavailable,
            .invalidResponse,
            .unknown,
        ]
        #expect(codes.map(\.rawValue) == [
            "authRequired",
            "permissionDenied",
            "tls",
            "dns",
            "timeout",
            "phoneUnavailable",
            "routeUnavailable",
            "invalidResponse",
            "unknown",
        ])

        for code in codes {
            let encoded = try JSONEncoder().encode(code)
            #expect(
                try JSONDecoder().decode(SanitizedDiagnosticCode.self, from: encoded)
                    == code
            )
        }

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                SanitizedDiagnosticCode.self,
                from: Data(#""rawServerError""#.utf8)
            )
        }
    }

    @Test func semanticCoverage_WatchDiagnosticsProjection() throws {
        let observedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        let projection = try WatchDiagnosticsProjection(
            scope: scope(),
            source: .phoneBroker,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(60),
            codes: [.authRequired, .tls, .routeUnavailable]
        )
        let encoded = try JSONEncoder().encode(projection)
        let decoded = try JSONDecoder().decode(
            WatchDiagnosticsProjection.self,
            from: encoded
        )
        #expect(decoded == projection)
        #expect(decoded.source == .phoneBroker)
        #expect(decoded.codes == [.authRequired, .tls, .routeUnavailable])

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["codes"] = Array(
            repeating: SanitizedDiagnosticCode.timeout.rawValue,
            count: 17
        )
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WatchDiagnosticsProjection.self, from: invalid)
        }
    }
}
