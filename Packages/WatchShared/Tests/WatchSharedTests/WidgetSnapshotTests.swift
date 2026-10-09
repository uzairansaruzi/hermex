import Foundation
import Testing
@testable import WatchShared

@Suite struct WidgetSnapshotTests {
    @Test func semanticCoverage_RedactedDisplayName() throws {
        let value = try RedactedDisplayName(String(repeating: "é", count: 31) + "ab")
        #expect(value.rawValue.utf8.count == ContractLimits.displayNameUTF8Bytes)

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RedactedDisplayName.self, from: encoded)
        #expect(decoded == value)

        let oversized = try JSONEncoder().encode(String(repeating: "é", count: 33))
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try JSONDecoder().decode(RedactedDisplayName.self, from: oversized)
        }
    }

    @Test func semanticCoverage_RedactedWidgetSnapshot() throws {
        let epoch = InstallationEpoch(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
        let scope = ServerScope(
            epoch: epoch,
            server: ServerID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!),
            generation: try Generation(7)
        )
        let value = try RedactedWidgetSnapshot(
            schema: 1,
            scope: scope,
            displayName: RedactedDisplayName("Server42"),
            activity: .needsAttention,
            attentionCount: 999,
            observedAt: Date(timeIntervalSince1970: 1_234_567),
            route: .sessions(scope)
        )

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(RedactedWidgetSnapshot.self, from: encoded)
        #expect(decoded == value)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["attentionCount"] = -1
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: WidgetValidationError.invalidAttentionCount) {
            try JSONDecoder().decode(RedactedWidgetSnapshot.self, from: invalid)
        }
    }

    @Test func semanticCoverage_WidgetValidationError() throws {
        let epoch = InstallationEpoch(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!)
        let scope = ServerScope(
            epoch: epoch,
            server: ServerID(rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!),
            generation: try Generation(1)
        )
        let name = try RedactedDisplayName("Server1")

        #expect(throws: WidgetValidationError.invalidDisplayName) { try RedactedDisplayName("   ") }
        #expect(throws: WidgetValidationError.unsupportedSchema(9)) {
            try RedactedWidgetSnapshot(schema: 9, scope: scope, displayName: name, activity: .idle, attentionCount: 0, observedAt: Date(), route: .sessions(scope))
        }
        #expect(throws: WidgetValidationError.invalidAttentionCount) {
            try RedactedWidgetSnapshot(scope: scope, displayName: name, activity: .idle, attentionCount: -1, observedAt: Date(), route: .sessions(scope))
        }
        #expect(throws: WidgetValidationError.nonfiniteObservedAt) {
            try RedactedWidgetSnapshot(scope: scope, displayName: name, activity: .idle, attentionCount: 0, observedAt: Date(timeIntervalSince1970: .infinity), route: .sessions(scope))
        }

        let otherScope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID()), generation: try Generation(1))
        #expect(throws: WidgetValidationError.routeScopeMismatch) {
            try RedactedWidgetSnapshot(scope: scope, displayName: name, activity: .idle, attentionCount: 0, observedAt: Date(), route: .sessions(otherScope))
        }
        #expect(throws: WidgetValidationError.tooLarge) {
            try RedactedWidgetSnapshot.decode(Data(repeating: 0x20, count: ContractLimits.widgetJSONBytes + 1))
        }

        let snapshot = try RedactedWidgetSnapshot(scope: scope, displayName: name, activity: .idle, attentionCount: 0, observedAt: Date(), route: .sessions(scope))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var route = try #require(object["route"] as? [String: Any])
        route["padding"] = String(repeating: "x", count: ContractLimits.routeJSONBytes)
        object["route"] = route
        let routeOversized = try JSONSerialization.data(withJSONObject: object)
        #expect(routeOversized.count <= ContractLimits.widgetJSONBytes)
        #expect(throws: WidgetValidationError.routeTooLarge) {
            try RedactedWidgetSnapshot.decode(routeOversized)
        }
    }

    @Test func displayNamePreservesAcceptedBytes() throws {
        let original = "  Server Ω  "
        let name = try RedactedDisplayName(original)
        #expect(name.rawValue == original)
    }

    @Test func displayNameRejectsBlankValue() {
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try RedactedDisplayName(" \t\n")
        }
    }

    @Test func displayNameEnforces64UTF8ByteLimit() throws {
        #expect(try RedactedDisplayName(String(repeating: "a", count: 64)).rawValue.utf8.count == 64)
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try RedactedDisplayName(String(repeating: "é", count: 33))
        }
    }

    @Test func displayNameRejectsControlAndAddressMarkers() {
        for invalid in ["line\nbreak", "https://host", "user@example"] {
            #expect(throws: WidgetValidationError.invalidDisplayName) {
                try RedactedDisplayName(invalid)
            }
        }
    }

    @Test func displayNameDecodingRevalidates() throws {
        let valid = try RedactedDisplayName("Server")
        #expect(try JSONDecoder().decode(RedactedDisplayName.self, from: JSONEncoder().encode(valid)) == valid)
        #expect(throws: WidgetValidationError.invalidDisplayName) {
            try JSONDecoder().decode(RedactedDisplayName.self, from: Data("\"user@example\"".utf8))
        }
    }

    @Test func widgetSnapshotCarriesOnlyRedactedSchemaFields() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let observedAt = Date(timeIntervalSince1970: 42)
        let snapshot = try RedactedWidgetSnapshot(
            schema: 1,
            scope: scope,
            displayName: RedactedDisplayName("Server"),
            activity: .running,
            attentionCount: 7,
            observedAt: observedAt,
            route: .sessions(scope)
        )
        #expect(snapshot.schema == 1)
        #expect(snapshot.scope == scope)
        #expect(snapshot.displayName.rawValue == "Server")
        #expect(snapshot.activity == .running)
        #expect(snapshot.attentionCount == 7)
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.route == .sessions(scope))
    }

    @Test func widgetSnapshotValidatesSchemaCountAndTime() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        func make(schema: Int = 1, count: Int = 0, time: Date = Date()) throws -> RedactedWidgetSnapshot {
            try RedactedWidgetSnapshot(schema: schema, scope: scope, displayName: RedactedDisplayName("Server"), activity: .idle, attentionCount: count, observedAt: time, route: .sessions(scope))
        }
        #expect(throws: WidgetValidationError.unsupportedSchema(2)) { try make(schema: 2) }
        #expect(throws: WidgetValidationError.invalidAttentionCount) { try make(count: -1) }
        #expect(throws: WidgetValidationError.invalidAttentionCount) { try make(count: 1000) }
        #expect(throws: WidgetValidationError.nonfiniteObservedAt) { try make(time: Date(timeIntervalSince1970: .infinity)) }
        #expect(try make(count: 999).attentionCount == 999)
    }

    @Test func widgetRouteMustMatchScopeOrServersEpoch() throws {
        let epoch = InstallationEpoch(rawValue: UUID())
        let scope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let otherScope = ServerScope(epoch: epoch, server: ServerID(rawValue: UUID()), generation: try Generation(1))
        func make(route: RedactedRoute) throws -> RedactedWidgetSnapshot {
            try RedactedWidgetSnapshot(scope: scope, displayName: RedactedDisplayName("Server"), activity: .unknown, attentionCount: 0, observedAt: Date(), route: route)
        }
        #expect(try make(route: .servers(epoch)).route == .servers(epoch))
        #expect(try make(route: .sessions(scope)).route == .sessions(scope))
        #expect(throws: WidgetValidationError.routeScopeMismatch) { try make(route: .sessions(otherScope)) }
        #expect(throws: WidgetValidationError.routeScopeMismatch) { try make(route: .servers(InstallationEpoch(rawValue: UUID()))) }
    }

    @Test func widgetSnapshotDecodingRevalidatesNestedContract() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let snapshot = try RedactedWidgetSnapshot(scope: scope, displayName: RedactedDisplayName("Server"), activity: .needsAttention, attentionCount: 1, observedAt: Date(), route: .sessions(scope))
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(RedactedWidgetSnapshot.self, from: encoded) == snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["attentionCount"] = 1000
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: WidgetValidationError.invalidAttentionCount) {
            try JSONDecoder().decode(RedactedWidgetSnapshot.self, from: invalid)
        }
    }

    @Test func widgetBoundedDecodeChecks4KiBBeforeParsing() {
        let oversized = Data(repeating: 0x20, count: 4097)
        #expect(throws: WidgetValidationError.tooLarge) {
            try RedactedWidgetSnapshot.decode(oversized)
        }
    }

    @Test func widgetDecodeEnforcesNestedRouteBound() throws {
        let scope = ServerScope(epoch: InstallationEpoch(rawValue: UUID()), server: ServerID(rawValue: UUID()), generation: try Generation(1))
        let snapshot = try RedactedWidgetSnapshot(scope: scope, displayName: RedactedDisplayName("Server"), activity: .idle, attentionCount: 0, observedAt: Date(), route: .sessions(scope))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var route = try #require(object["route"] as? [String: Any])
        route["padding"] = String(repeating: "x", count: 1200)
        object["route"] = route
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(data.count < 4096)
        #expect(throws: WidgetValidationError.routeTooLarge) {
            try RedactedWidgetSnapshot.decode(data)
        }
    }

}
