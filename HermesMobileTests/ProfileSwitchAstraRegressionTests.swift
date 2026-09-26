import XCTest
@testable import HermesMobile

/// Astra (gpt-6-astra) regression probes for PR #638 profile-switch perf path.
final class ProfileSwitchAstraRegressionTests: APIClientTestCase {
    override func setUp() {
        super.setUp()
        RecentProfileSwitchSeed.resetForTests()
    }

    override func tearDown() {
        RecentProfileSwitchSeed.resetForTests()
        super.tearDown()
    }

    private let server = URL(string: "https://example.test")!

    private func summary(_ profile: String, id: String = "original") throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data("{\"session_id\":\"\(id)\",\"profile\":\"\(profile)\"}".utf8)
        )
    }

    private func profile(_ name: String, provider: String? = nil) -> ProfileSummary {
        ProfileSummary(
            name: name,
            path: nil,
            isDefault: nil,
            isActive: nil,
            gatewayRunning: nil,
            model: nil,
            provider: provider,
            hasEnv: nil,
            skillCount: nil
        )
    }

    private func errorResponse(_ status: Int, request: URLRequest) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data("{}".utf8)
        )
    }

    func testParallelComposerPrefersUnauthorizedOverOtherWaveFailures() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"active":"work","profiles":[{"name":"work","model":"work-model","provider":"openai"}]}"#,
                    for: request
                )
            case "/api/models":
                return self.errorResponse(500, request: request)
            case "/api/workspaces":
                return self.errorResponse(401, request: request)
            case "/api/reasoning", "/api/commands":
                return apiTestJSONResponse("{}", for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: .init(currentProfile: "work")
        )
        guard let error = result.configurationError, case APIError.unauthorized = error else {
            return XCTFail(
                "A wave 401 must win over models 500 so AuthManager still signs out: \(String(describing: result.configurationError))"
            )
        }
    }

    /// Provider unknown until /api/models; early /api/reasoning 401 must still
    /// win when the replacement reasoning call returns 500.
    func testEarlyReasoningUnauthorizedSurvivesProviderDiscoveryRefetch() async throws {
        var reasoningCalls = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                // Model known, provider omitted → early reasoning runs without provider.
                return apiTestJSONResponse(
                    #"{"active":"work","profiles":[{"name":"work","model":"work-model"}]}"#,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    #"{"default_model":"work-model","groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"work-model","name":"Work"}]}]}"#,
                    for: request
                )
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[],"last":null}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            case "/api/reasoning":
                reasoningCalls += 1
                if reasoningCalls == 1 {
                    return self.errorResponse(401, request: request)
                }
                return self.errorResponse(500, request: request)
            default:
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: .init(currentProfile: "work")
        )
        XCTAssertGreaterThanOrEqual(reasoningCalls, 2, "Provider discovery should re-query reasoning")
        guard let error = result.configurationError, case APIError.unauthorized = error else {
            return XCTFail(
                "Early reasoning 401 must survive a 500 replacement: \(String(describing: result.configurationError))"
            )
        }
    }

    func testForeignTakeDoesNotEvictUnconsumedOtherServers() {
        let a = URL(string: "https://example.test:443")!
        let b = URL(string: "https://example.test:8443")!
        RecentProfileSwitchSeed.store(.init(profiles: [], active: "a"), for: a, sessionID: "s-a")
        RecentProfileSwitchSeed.store(.init(profiles: [], active: "b"), for: b, sessionID: "s-b")
        XCTAssertNil(RecentProfileSwitchSeed.take(for: URL(string: "https://foreign.test")!, sessionID: "s-a"))
        XCTAssertNil(RecentProfileSwitchSeed.take(for: a, sessionID: "other"))
        XCTAssertEqual(RecentProfileSwitchSeed.take(for: a, sessionID: "s-a")?.active, "a")
        XCTAssertEqual(RecentProfileSwitchSeed.take(for: b, sessionID: "s-b")?.active, "b")
    }

    func testExpiredSeedsAreSweptOnStoreAndDoNotAccumulate() {
        let server = URL(string: "https://example.test")!
        RecentProfileSwitchSeed.storeExpiredForTests(.init(profiles: [], active: "old"), for: server, sessionID: "abandoned-1")
        RecentProfileSwitchSeed.storeExpiredForTests(.init(profiles: [], active: "old"), for: server, sessionID: "abandoned-2")
        XCTAssertEqual(RecentProfileSwitchSeed.liveEntryCountForTests(), 0, "Expired entries must not linger after sweep")

        RecentProfileSwitchSeed.store(.init(profiles: [], active: "live"), for: server, sessionID: "live-1")
        // store() sweeps before insert; expired ghosts from abandoned navigations stay gone.
        RecentProfileSwitchSeed.storeExpiredForTests(.init(profiles: [], active: "ghost"), for: server, sessionID: "ghost")
        RecentProfileSwitchSeed.store(.init(profiles: [], active: "live2"), for: server, sessionID: "live-2")
        XCTAssertEqual(RecentProfileSwitchSeed.liveEntryCountForTests(), 2)
        XCTAssertEqual(RecentProfileSwitchSeed.take(for: server, sessionID: "live-1")?.active, "live")
        XCTAssertEqual(RecentProfileSwitchSeed.take(for: server, sessionID: "live-2")?.active, "live2")
        XCTAssertEqual(RecentProfileSwitchSeed.liveEntryCountForTests(), 0)
    }

    @MainActor
    func testSeedIsNotStoredUntilCreateSessionSucceeds() async throws {
        let creationStarted = expectation(description: "creation pending")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(
                    #"{"active":"research","default_model":"research-model","default_workspace":"/research","profiles":[{"name":"research","model":"research-model","provider":"openai"}]}"#,
                    for: request
                )
            case "/api/session/new":
                creationStarted.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else {
                    throw URLError(.timedOut)
                }
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.badURL)
            }
        }

        let vm = ChatViewModel(session: try summary("work"), server: server, client: client)
        let switching = Task {
            await vm.switchProfile(self.profile("research"), startNewSession: true)
        }
        await fulfillment(of: [creationStarted], timeout: 3)

        // While create is pending, no replacement seed may exist for another chat to steal.
        XCTAssertNil(
            RecentProfileSwitchSeed.take(for: server, sessionID: "replacement"),
            "Seed must not be published before createSession succeeds"
        )

        release.signal()
        let outcome = await switching.value
        XCTAssertNil(outcome)
        XCTAssertNil(RecentProfileSwitchSeed.take(for: server, sessionID: "replacement"))
    }

    @MainActor
    func testFailedRecoveryFencesSlashModelAsWellAsPicker() async throws {
        var updateCount = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let name = try apiTestJSONBody(from: request)["name"] as? String
                if name == "work" {
                    throw URLError(.notConnectedToInternet)
                }
                return apiTestJSONResponse(#"{"active":"research"}"#, for: request)
            case "/api/session/new":
                throw URLError(.notConnectedToInternet)
            case "/api/session/update":
                updateCount += 1
                return self.errorResponse(400, request: request)
            default:
                throw URLError(.badURL)
            }
        }

        let vm = ChatViewModel(session: try summary("work"), server: server, client: client)
        let outcome = await vm.switchProfile(profile("research"), startNewSession: true)
        XCTAssertNil(outcome)
        XCTAssertTrue(vm.canRetryProfileOwnership)

        let pickerResult = await vm.selectComposerModel(
            ModelCatalogOption(id: "new-model", displayName: "New", providerID: "openai")
        )
        XCTAssertFalse(pickerResult)

        let command = try XCTUnwrap(SlashCommandCatalog.command(named: "model"))
        _ = await vm.executeSlashCommand(command, args: "new-model")
        XCTAssertEqual(updateCount, 0, "Typed /model must not mutate session while profile handoff is fenced")
    }

    @MainActor
    func testRollbackUnauthorizedSurvivesCreateFailure() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profile/switch":
                let name = try apiTestJSONBody(from: request)["name"] as? String
                if name == "work" {
                    return self.errorResponse(401, request: request)
                }
                return apiTestJSONResponse(#"{"active":"research"}"#, for: request)
            case "/api/session/new":
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.badURL)
            }
        }

        let vm = ChatViewModel(session: try summary("work"), server: server, client: client)
        _ = await vm.switchProfile(profile("research"), startNewSession: true)
        guard let error = vm.lastError, case APIError.unauthorized = error else {
            return XCTFail("Rollback 401 was lost behind the create failure: \(String(describing: vm.lastError))")
        }
    }

    @MainActor
    func testFreshSwitchProviderWinsOverStalePickerWithDefaultModel() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(
                    #"{"active":"research","default_model":"new-model","profiles":[{"name":"research","model":"new-model","provider":"fresh-provider"}]}"#,
                    for: request
                )
            case "/api/session/new":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["model"] as? String, "new-model")
                XCTAssertEqual(body["model_provider"] as? String, "fresh-provider")
                return apiTestJSONResponse(
                    #"{"session":{"session_id":"replacement","profile":"research","model":"new-model","model_provider":"fresh-provider"}}"#,
                    for: request
                )
            default:
                throw URLError(.badURL)
            }
        }

        let vm = ChatViewModel(session: try summary("work"), server: server, client: client)
        let outcome = await vm.switchProfile(
            profile("research", provider: "stale-provider"),
            startNewSession: true
        )
        XCTAssertEqual(outcome?.session?.sessionId, "replacement")
    }

    /// Early /api/reasoning 500 without a provider must not stick after the
    /// provider-scoped refetch succeeds.
    func testEarlyReasoningNonAuthFailureClearsWhenProviderScopedRequestSucceeds() async throws {
        var reasoningCalls = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"active":"work","profiles":[{"name":"work","model":"work-model"}]}"#,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    #"{"default_model":"work-model","groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"work-model","name":"Work"}]}]}"#,
                    for: request
                )
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[],"last":null}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            case "/api/reasoning":
                reasoningCalls += 1
                if reasoningCalls == 1 {
                    return self.errorResponse(500, request: request)
                }
                return apiTestJSONResponse(#"{"reasoning_effort":"medium"}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: .init(currentProfile: "work")
        )
        XCTAssertGreaterThanOrEqual(reasoningCalls, 2, "Provider discovery should re-query reasoning")
        XCTAssertNil(
            result.configurationError,
            "A speculative early 500 must not surface after the provider-scoped request succeeds: \(String(describing: result.configurationError))"
        )
        XCTAssertEqual(result.state.selectedReasoningEffort, "medium")
    }

    /// Early 401 is only preserved when the replacement also fails. A successful
    /// provider-scoped refetch means the composer loaded; do not keep the banner.
    func testEarlyReasoningUnauthorizedDoesNotStickWhenReplacementSucceeds() async throws {
        var reasoningCalls = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"active":"work","profiles":[{"name":"work","model":"work-model"}]}"#,
                    for: request
                )
            case "/api/models":
                return apiTestJSONResponse(
                    #"{"default_model":"work-model","groups":[{"name":"OpenAI","provider_id":"openai","models":[{"id":"work-model","name":"Work"}]}]}"#,
                    for: request
                )
            case "/api/workspaces":
                return apiTestJSONResponse(#"{"workspaces":[],"last":null}"#, for: request)
            case "/api/commands":
                return apiTestJSONResponse(#"{"commands":[]}"#, for: request)
            case "/api/reasoning":
                reasoningCalls += 1
                if reasoningCalls == 1 {
                    return self.errorResponse(401, request: request)
                }
                return apiTestJSONResponse(#"{"reasoning_effort":"low"}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let result = await ChatComposerConfigLoader(client: client).loadConfiguration(
            from: .init(currentProfile: "work")
        )
        XCTAssertGreaterThanOrEqual(reasoningCalls, 2)
        XCTAssertNil(
            result.configurationError,
            "Successful replacement must clear an early 401: \(String(describing: result.configurationError))"
        )
        XCTAssertEqual(result.state.selectedReasoningEffort, "low")
    }

    @MainActor
    func testSiblingChatCannotStealReplacementProfileSeed() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profile/switch":
                return apiTestJSONResponse(
                    #"{"active":"research","default_model":"research-model","profiles":[{"name":"research","model":"research-model","provider":"openai"}]}"#,
                    for: request
                )
            case "/api/session/new":
                return apiTestJSONResponse(
                    #"{"session":{"session_id":"replacement","profile":"research"}}"#,
                    for: request
                )
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"active":"work","profiles":[{"name":"work","model":"work-model","provider":"openai"}]}"#,
                    for: request
                )
            case "/api/models", "/api/workspaces", "/api/commands", "/api/reasoning":
                return apiTestJSONResponse("{}", for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let original = ChatViewModel(session: try summary("work", id: "original"), server: server, client: client)
        let outcome = await original.switchProfile(profile("research"), startNewSession: true)
        XCTAssertEqual(outcome?.session?.sessionId, "replacement")

        let sibling = ChatViewModel(session: try summary("work", id: "sibling"), server: server, client: client)
        await sibling.loadComposerConfiguration()

        XCTAssertEqual(
            RecentProfileSwitchSeed.take(for: server, sessionID: "replacement")?.active,
            "research",
            "Sibling composer load on the same server must leave the replacement seed in place"
        )
    }
}
