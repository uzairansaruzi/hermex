import Foundation
import Testing
@testable import WatchShared

@Suite struct ExtendedRouteTests {
    private struct Fixtures {
        let scope: ServerScope
        let session: SessionKey
        let task: TaskKey
        let skill: SkillKey
        let memory: MemoryKey
        let insight: InsightKey
    }

    private func fixtures(generation: UInt64 = 1) throws -> Fixtures {
        let scope = ServerScope(
            epoch: InstallationEpoch(rawValue: UUID()),
            server: ServerID(rawValue: UUID()),
            generation: try Generation(generation)
        )
        return try Fixtures(
            scope: scope,
            session: SessionKey(scope: scope, sessionID: "session-Ω"),
            task: TaskKey(scope: scope, jobID: "task-Ω"),
            skill: SkillKey(scope: scope, name: "skill-Ω"),
            memory: MemoryKey(scope: scope, remoteID: "memory-Ω"),
            insight: InsightKey(scope: scope, remoteID: "insight-Ω")
        )
    }

    private func roundTripHandoff(
        _ target: WatchRouteTarget,
        scope: ServerScope
    ) throws -> WatchRouteTarget {
        let now = Date()
        let route = try WatchHandoffRoute(
            routeID: UUID(),
            scope: scope,
            target: target,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let encoded = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(WatchHandoffRoute.self, from: encoded)
        #expect(decoded == route)
        return decoded.target
    }

    @Test func semanticCoverage_GitPhoneDestination() throws {
        let destinations: [GitPhoneDestination] = [
            .browse, .checkout, .fetch, .pull, .push, .stage,
            .unstage, .discard, .commit, .merge, .resolveConflicts,
        ]
        #expect(destinations.map(\.rawValue) == [
            "browse", "checkout", "fetch", "pull", "push", "stage",
            "unstage", "discard", "commit", "merge", "resolveConflicts",
        ])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(GitPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GitPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let target: WatchRouteTarget = .git(
            values.session,
            pathHandle: try PathHandle("Sources/Route.swift"),
            diffKind: .staged,
            destination: .resolveConflicts
        )
        let recovered = try roundTripHandoff(target, scope: values.scope)
        guard case .git(let session, let path, let diffKind, let destination) = recovered else {
            Issue.record("Expected a git route")
            return
        }
        let expectedPath = try PathHandle("Sources/Route.swift")
        #expect(session == values.session)
        #expect(path == expectedPath)
        #expect(diffKind == .staged)
        #expect(destination == .resolveConflicts)
    }

    @Test func semanticCoverage_InsightPhoneDestination() throws {
        let destinations: [InsightPhoneDestination] = [.detail, .generate, .configure]
        #expect(destinations.map(\.rawValue) == ["detail", "generate", "configure"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(InsightPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(InsightPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .insight(values.insight, destination: .configure),
            scope: values.scope
        )
        guard case .insight(let key, let destination) = recovered else {
            Issue.record("Expected an insight route")
            return
        }
        #expect(key == values.insight)
        #expect(destination == .configure)
    }

    @Test func semanticCoverage_MemoryPhoneDestination() throws {
        let destinations: [MemoryPhoneDestination] = [.detail, .create, .edit, .delete, .bulk]
        #expect(destinations.map(\.rawValue) == ["detail", "create", "edit", "delete", "bulk"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(MemoryPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MemoryPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .memory(values.memory, destination: .edit),
            scope: values.scope
        )
        guard case .memory(let key, let destination) = recovered else {
            Issue.record("Expected a memory route")
            return
        }
        #expect(key == values.memory)
        #expect(destination == .edit)
    }

    @Test func semanticCoverage_SessionPhoneDestination() throws {
        let destinations: [SessionPhoneDestination] = [.detail, .management, .attachments]
        #expect(destinations.map(\.rawValue) == ["detail", "management", "attachments"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(SessionPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SessionPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .session(values.session, destination: .attachments),
            scope: values.scope
        )
        guard case .session(let key, let destination) = recovered else {
            Issue.record("Expected a session route")
            return
        }
        #expect(key == values.session)
        #expect(destination == .attachments)
    }

    @Test func semanticCoverage_SettingsPhoneDestination() throws {
        let destinations: [SettingsPhoneDestination] = [.watchSharing, .directAccess, .bot]
        #expect(destinations.map(\.rawValue) == ["watchSharing", "directAccess", "bot"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(SettingsPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SettingsPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .settings(values.scope, destination: .directAccess),
            scope: values.scope
        )
        guard case .settings(let scope, let destination) = recovered else {
            Issue.record("Expected a settings route")
            return
        }
        #expect(scope == values.scope)
        #expect(destination == .directAccess)
    }

    @Test func semanticCoverage_SkillPhoneDestination() throws {
        let destinations: [SkillPhoneDestination] = [.detail, .install, .edit, .configure, .enablement]
        #expect(destinations.map(\.rawValue) == ["detail", "install", "edit", "configure", "enablement"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(SkillPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SkillPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .skill(values.skill, destination: .configure),
            scope: values.scope
        )
        guard case .skill(let key, let destination) = recovered else {
            Issue.record("Expected a skill route")
            return
        }
        #expect(key == values.skill)
        #expect(destination == .configure)
    }

    @Test func semanticCoverage_TaskPhoneDestination() throws {
        let destinations: [TaskPhoneDestination] = [
            .detail, .edit, .create, .schedule, .delivery, .profile, .model, .skills,
        ]
        #expect(destinations.map(\.rawValue) == [
            "detail", "edit", "create", "schedule", "delivery", "profile", "model", "skills",
        ])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(TaskPhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TaskPhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let detail = try roundTripHandoff(
            .task(values.task, destination: .detail),
            scope: values.scope
        )
        let create = try roundTripHandoff(
            .task(nil, destination: .create),
            scope: values.scope
        )
        #expect(detail == .task(values.task, destination: .detail))
        #expect(create == .task(nil, destination: .create))

        for invalid in [
            WatchRouteTarget.task(nil, destination: .detail),
            WatchRouteTarget.task(values.task, destination: .create),
        ] {
            let encoded = try JSONEncoder().encode(invalid)
            #expect(throws: RouteValidationError.incompatibleDestination) {
                try JSONDecoder().decode(WatchRouteTarget.self, from: encoded)
            }
        }
    }

    @Test func semanticCoverage_WorkspacePhoneDestination() throws {
        let destinations: [WorkspacePhoneDestination] = [.browse, .write, .upload, .download]
        #expect(destinations.map(\.rawValue) == ["browse", "write", "upload", "download"])
        for destination in destinations {
            let encoded = try JSONEncoder().encode(destination)
            #expect(try JSONDecoder().decode(WorkspacePhoneDestination.self, from: encoded) == destination)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WorkspacePhoneDestination.self, from: Data("\"future\"".utf8))
        }

        let values = try fixtures()
        let recovered = try roundTripHandoff(
            .workspace(
                values.session,
                pathHandle: try PathHandle("Workspace/file.txt"),
                destination: .download
            ),
            scope: values.scope
        )
        guard case .workspace(let session, let path, let destination) = recovered else {
            Issue.record("Expected a workspace route")
            return
        }
        let expectedPath = try PathHandle("Workspace/file.txt")
        #expect(session == values.session)
        #expect(path == expectedPath)
        #expect(destination == .download)
    }

    @Test func semanticCoverage_WatchRouteTarget() throws {
        let values = try fixtures()
        let bot = try BotKey(scope: values.scope, connectionID: UUID(), profile: "profile")
        let targets: [WatchRouteTarget] = [
            .home,
            .sessions(collection: .current),
            .newSession(draftHandle: DraftHandle(rawValue: UUID())),
            .session(values.session, destination: .management),
            .run(try RunKey(session: values.session, streamID: "run")),
            .approval(try ApprovalKey(session: values.session, remoteID: "approval")),
            .clarification(
                try ClarificationKey(session: values.session, remoteID: "clarification"),
                draftHandle: DraftHandle(rawValue: UUID())
            ),
            .task(values.task, destination: .schedule),
            .taskRun(values.task, runID: "run-1"),
            .skill(values.skill, destination: .enablement),
            .memory(values.memory, destination: .bulk),
            .insight(values.insight, destination: .detail),
            .workspace(values.session, pathHandle: try PathHandle("file"), destination: .browse),
            .git(values.session, pathHandle: nil, diffKind: .workingTree, destination: .stage),
            .diagnostics(values.scope),
            .settings(values.scope, destination: .bot),
            .bot(bot, destination: .activity, requestID: "request-1"),
        ]

        for target in targets {
            let encoded = try JSONEncoder().encode(target)
            let decoded = try JSONDecoder().decode(WatchRouteTarget.self, from: encoded)
            #expect(decoded == target)
            #expect(try roundTripHandoff(target, scope: values.scope) == target)
        }

        let invalidTargets: [WatchRouteTarget] = [
            .skill(nil, destination: .detail),
            .skill(values.skill, destination: .install),
            .memory(nil, destination: .edit),
            .memory(values.memory, destination: .create),
            .insight(nil, destination: .detail),
            .insight(values.insight, destination: .generate),
            .taskRun(values.task, runID: " "),
            .bot(bot, destination: .conversation, requestID: "not-allowed"),
        ]
        for target in invalidTargets {
            let encoded = try JSONEncoder().encode(target)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(WatchRouteTarget.self, from: encoded)
            }
        }
    }

    @Test func semanticCoverage_WatchHandoffRoute() throws {
        let values = try fixtures()
        let now = Date()
        let route = try WatchHandoffRoute(
            routeID: UUID(),
            scope: values.scope,
            target: .session(values.session, destination: .detail),
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let encoded = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(WatchHandoffRoute.self, from: encoded)
        #expect(decoded == route)
        #expect(try WatchHandoffRoute.decode(route.canonicalJSONData()) == route)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        let futureSchema = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RouteValidationError.unsupportedSchema(2)) {
            try JSONDecoder().decode(WatchHandoffRoute.self, from: futureSchema)
        }

        let other = try fixtures(generation: 2)
        #expect(throws: RouteValidationError.scopeMismatch) {
            try WatchHandoffRoute(
                routeID: UUID(),
                scope: values.scope,
                target: .session(other.session, destination: .detail),
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            )
        }

        let expired = try WatchHandoffRoute(
            routeID: UUID(),
            scope: values.scope,
            target: .home,
            createdAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-60)
        )
        #expect(throws: RouteValidationError.invalidDates) {
            try JSONDecoder().decode(WatchHandoffRoute.self, from: JSONEncoder().encode(expired))
        }

        var oversized = encoded
        oversized.append(Data(repeating: 0x20, count: ContractLimits.routeJSONBytes + 1))
        #expect(throws: RouteValidationError.tooLarge) {
            try WatchHandoffRoute.decode(oversized)
        }
    }
}
