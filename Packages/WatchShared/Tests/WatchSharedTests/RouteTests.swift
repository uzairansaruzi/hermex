import Foundation
import Testing
@testable import WatchShared

@Suite struct RouteTests {
    private func scope(generation: UInt64 = 1) throws -> ServerScope {
        ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(generation)
        )
    }

    @Test func semanticCoverage_CacheKey() throws {
        let scope = try scope()
        let sameScope = try CacheKey.scope(scope)
        let sameScopeAgain = try CacheKey.scope(scope)
        let otherScope = try CacheKey.scope(try self.scope(generation: 2))
        let firstSession = try SessionKey(scope: scope, sessionID: "session/Ω one")
        let secondSession = try SessionKey(scope: scope, sessionID: "session/Ω two")
        let bot = try BotKey(scope: scope, connectionID: UUID(), profile: "profile Ω")
        let keys: [CacheKey] = [
            sameScope,
            try CacheKey.session(firstSession),
            try CacheKey.session(secondSession),
            try CacheKey.bot(bot),
        ]

        #expect(sameScope == sameScopeAgain)
        #expect(sameScope != otherScope)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.rawValue.isEmpty })
        #expect(keys.allSatisfy { key in
            key.rawValue.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }
        })
        #expect(!keys[1].rawValue.contains("session"))
        #expect(!keys[1].rawValue.contains("/"))
        #expect(!keys[1].rawValue.contains("="))
    }

    @Test func semanticCoverage_RedactedRoute() throws {
        let scope = try scope()
        let session = try SessionKey(scope: scope, sessionID: "session/Ω")
        let bot = try BotKey(scope: scope, connectionID: UUID(), profile: "profile Ω")
        let routes: [RedactedRoute] = [
            .servers(scope.epoch),
            .sessions(scope),
            .session(session),
            .bot(bot),
        ]

        for route in routes {
            let encoded = try JSONEncoder().encode(route)
            let decoded = try JSONDecoder().decode(RedactedRoute.self, from: encoded)
            #expect(decoded == route)

            let canonical = try route.canonicalJSONData()
            #expect(try RedactedRoute.decode(canonical) == route)
            let object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
            #expect(object["schema"] as? Int == 1)
        }

        var unknownKind = try #require(
            JSONSerialization.jsonObject(with: routes[0].canonicalJSONData()) as? [String: Any]
        )
        var routeObject = try #require(unknownKind["route"] as? [String: Any])
        routeObject["kind"] = "unknown"
        unknownKind["route"] = routeObject
        let unknownKindData = try JSONSerialization.data(withJSONObject: unknownKind)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RedactedRoute.self, from: unknownKindData)
        }
    }

    @Test func semanticCoverage_RouteValidationError() throws {
        let route = RedactedRoute.servers(InstallationEpoch(rawValue: UUID()))
        var futureSchema = try #require(
            JSONSerialization.jsonObject(with: route.canonicalJSONData()) as? [String: Any]
        )
        futureSchema["schema"] = 2
        let futureSchemaData = try JSONSerialization.data(withJSONObject: futureSchema)

        #expect(throws: RouteValidationError.unsupportedSchema(2)) {
            try RedactedRoute.decode(futureSchemaData)
        }
        #expect(throws: RouteValidationError.unsupportedSchema(2)) {
            try JSONDecoder().decode(RedactedRoute.self, from: futureSchemaData)
        }

        let oversized = Data(repeating: 0x20, count: ContractLimits.routeJSONBytes + 1)
        #expect(throws: RouteValidationError.tooLarge) {
            try RedactedRoute.decode(oversized)
        }

        let scope = try scope()
        let otherScope = try self.scope(generation: 2)
        let otherSession = try SessionKey(scope: otherScope, sessionID: "other")
        let now = Date()
        #expect(throws: RouteValidationError.invalidDates) {
            try WatchHandoffRoute(
                routeID: UUID(), scope: scope, target: .home,
                createdAt: now, expiresAt: now
            )
        }
        #expect(throws: RouteValidationError.scopeMismatch) {
            try WatchHandoffRoute(
                routeID: UUID(), scope: scope, target: .session(otherSession, destination: .detail),
                createdAt: now, expiresAt: now.addingTimeInterval(60)
            )
        }
        #expect(throws: RouteValidationError.incompatibleDestination) {
            try WatchHandoffRoute(
                routeID: UUID(), scope: scope, target: .task(nil, destination: .detail),
                createdAt: now, expiresAt: now.addingTimeInterval(60)
            )
        }
        let task = try TaskKey(scope: scope, jobID: "task")
        #expect(throws: RouteValidationError.invalidRequestID) {
            try WatchHandoffRoute(
                routeID: UUID(), scope: scope, target: .taskRun(task, runID: " "),
                createdAt: now, expiresAt: now.addingTimeInterval(60)
            )
        }
    }
}
