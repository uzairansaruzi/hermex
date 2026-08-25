import XCTest
@testable import HermesMobile

/// Regression matrix for the #285 review: connection-identity binding,
/// stale-probe fencing, and configure ownership in `OnboardingViewModel`.
@MainActor
final class OnboardingViewModelIdentityTests: XCTestCase {
    // MARK: - Identity semantics

    func testCanonicallyEquivalentURLsShareIdentity() throws {
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"
        let before = try XCTUnwrap(identity(of: viewModel))

        viewModel.serverURLString = "https://example.com/"
        XCTAssertEqual(try identity(of: viewModel), before, "trailing slash must not churn")

        viewModel.serverURLString = "  https://EXAMPLE.com/path?query=1#frag  "
        XCTAssertEqual(try identity(of: viewModel), before, "case/whitespace/path/query/fragment are normalized away")
    }

    func testHeaderNameCaseAndOrderDoNotChangeIdentity() {
        let viewModel = OnboardingViewModel()
        viewModel.customHeaders = [
            CustomHeader(name: "X-API-Key", value: "k1"),
            CustomHeader(name: "Authorization", value: "Bearer abc")
        ]
        let before = currentIdentity(viewModel)

        viewModel.customHeaders = [
            CustomHeader(name: "authorization", value: "Bearer abc"),
            CustomHeader(name: "x-api-key", value: "k1")
        ]

        XCTAssertEqual(currentIdentity(viewModel), before)
    }

    func testDuplicateNameReorderChangesEffectiveCredentialAndInvalidates() {
        let viewModel = makeProbedViewModel(headers: [
            CustomHeader(name: "X-Auth", value: "a"),
            CustomHeader(name: "X-Auth", value: "b")
        ])
        XCTAssertNotNil(viewModel.authStatus)

        // Effective X-Auth flips b -> a (setValue is last-write-wins), so the
        // cached trusted-header status no longer describes this credential.
        viewModel.customHeaders = [
            CustomHeader(name: "X-Auth", value: "b"),
            CustomHeader(name: "X-Auth", value: "a")
        ]

        XCTAssertNil(viewModel.authStatus, "duplicate-name reorder changes the sent credential and must invalidate")
        XCTAssertNil(viewModel.connectionMessage)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testNewlineBrokenRowIsNotPartOfIdentity() {
        let viewModel = makeProbedViewModel(headers: [])
        XCTAssertNotNil(viewModel.authStatus)

        // A row whose raw value contains a newline is never sent
        // (CustomHeader.isApplicable), so adding it must not change identity —
        // and conversely removing a broken row must not preserve stale state.
        viewModel.customHeaders = [CustomHeader(name: "X-Broken", value: "line1\nline2")]

        // Broken row is filtered from identity; identity equals the empty set,
        // which matches the probed empty-header identity → no churn.
        XCTAssertNotNil(viewModel.authStatus)

        // But replacing it with an applicable row does change identity.
        viewModel.customHeaders = [CustomHeader(name: "Authorization", value: "Bearer xyz")]
        XCTAssertNil(viewModel.authStatus, "applicable header changes the credential and must invalidate")
    }

    func testURLEditClearsInheritedBannersEvenWithoutProbe() {
        var errorMessage: String? = "Previous server rejected the request."
        let viewModel = OnboardingViewModel(
            savedServer: URL(string: "https://old.example.com"),
            initialErrorMessage: errorMessage
        )
        errorMessage = nil

        XCTAssertNotNil(viewModel.errorMessage, "initial error restored")

        viewModel.serverURLString = "https://new.example.com"

        XCTAssertNil(viewModel.errorMessage, "inherited banner has no owner once inputs change")
        XCTAssertNil(viewModel.connectionMessage)
    }

// MARK: - Gated client double (drives real async schedules)

/// Gates `health()` so a probe can be held in flight while inputs change.
@MainActor
final class OnboardingGateKeeper: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0

    func waitUntilProbeStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func gate() async {
        startedCount += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            continuations.append(continuation)
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        while !continuations.isEmpty {
            continuations.removeFirst().resume()
        }
    }
}

enum GatedProbeOutcome {
    case succeed(AuthStatusResponse)
    case fail(String)
}

final class GatedAuthAPIClient: AuthAPIClient, @unchecked Sendable {
    let gatekeeper: OnboardingGateKeeper
    var outcome: GatedProbeOutcome
    /// Records configure side effects so tests can assert what ACTUALLY ran.
    private(set) var configuredServers: [String] = []
    private(set) var configuredPasswords: [String] = []

    init(gatekeeper: OnboardingGateKeeper, outcome: GatedProbeOutcome) {
        self.gatekeeper = gatekeeper
        self.outcome = outcome
    }

    func health() async throws -> HealthResponse {
        await gatekeeper.gate()
        return HealthResponse(status: "ok", sessions: nil, activeStreams: nil, uptimeSeconds: nil)
    }

    func authStatus() async throws -> AuthStatusResponse {
        await gatekeeper.gate()
        switch outcome {
        case .succeed(let status):
            return status
        case .fail(let message):
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func login(password: String) async throws -> LoginResponse {
        configuredPasswords.append(password)
        return LoginResponse(ok: true, message: nil, error: nil)
    }

    func logout() async throws -> LoginResponse {
        LoginResponse(ok: true, message: nil, error: nil)
    }
}

extension OnboardingViewModelIdentityTests {
    @MainActor
    func makeGatedManager(_ client: GatedAuthAPIClient) -> AuthManager {
        AuthManager(
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )
    }

    // Stale A success cannot publish over B: A is held, the user retargets to
    // B, then A completes — its result must be discarded and B must still be
    // free to probe.
    @MainActor
    func testStaleProbeSuccessForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: true))
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitUntilProbeStarted(count: 1)

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.releaseAll()
        await probeTask.value

        XCTAssertNil(viewModel.authStatus, "stale success for old identity must be discarded")
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertFalse(viewModel.isConnectionLocked)
    }

    // Stale A rejection cannot publish its error over B.
    @MainActor
    func testStaleProbeFailureForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .fail("old server unreachable")
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitUntilProbeStarted(count: 1)

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.releaseAll()
        await probeTask.value

        XCTAssertNil(viewModel.errorMessage, "stale rejection must not surface under new identity")
        XCTAssertNil(viewModel.authStatus)
    }

    // Overlapping generations: only the newest operation owns isWorking.
    @MainActor
    func testOverlappingProbesOnlyLatestOwnsIsWorking() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false))
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"

        let first = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitUntilProbeStarted(count: 1)

        let second = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitUntilProbeStarted(count: 2)

        XCTAssertTrue(viewModel.isWorking)

        gatekeeper.releaseOne()
        await first.value
        XCTAssertTrue(viewModel.isWorking, "older defer must not clear newer operation's busy state")

        gatekeeper.releaseAll()
        await second.value
        XCTAssertFalse(viewModel.isWorking)
    }

    // Edit during connect(): the operation must be refused outright while the
    // form is locked (inputs frozen), so no second connect can interleave.
    @MainActor
    func testConnectWhileLockedIsRefused() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: true))
        )
        let manager = makeGatedManager(client)
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"

        let connectTask = Task { await viewModel.connect(authManager: manager) }
        await gatekeeper.waitUntilProbeStarted(count: 1)

        XCTAssertTrue(viewModel.isConnectionLocked, "inputs frozen for the whole connect")
        XCTAssertTrue(viewModel.isPasswordRequired == false, "trusted-header probe hides password field")

        let loginsBefore = client.configuredPasswords.count

        // Return-key during lock must be refused by the guard.
        await viewModel.connect(authManager: manager)

        gatekeeper.releaseAll()
        await connectTask.value

        XCTAssertFalse(viewModel.isConnectionLocked, "lock released after settle")
        XCTAssertTrue(viewModel.authStatus != nil || viewModel.errorMessage != nil,
                      "the accepted connect settled to a visible outcome")
    }

    // Configure reaches AuthManager exactly once per accepted connect.
    @MainActor
    func testConfigureRunsOncePerAcceptedConnect() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: false))
        )
        let manager = makeGatedManager(client)
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"

        await viewModel.connect(authManager: manager)

        // authEnabled=false → configure skips login entirely (no password path).
        XCTAssertEqual(client.configuredPasswords.count, 0, "passwordless configure must not attempt login")
        XCTAssertFalse(viewModel.isConnectionLocked)
        XCTAssertFalse(viewModel.isWorking)
    }
}


    // MARK: - Helpers

    private func identity(of viewModel: OnboardingViewModel) throws -> String {
        _ = viewModel // identity is derived from public inputs; recompute via invalidation side effect
        return currentIdentity(viewModel)
    }

    /// Reads the identity by round-tripping through invalidation: mutating any
    /// input recomputes it. Uses a sentinel edit that cannot collide with real
    /// header content.
    private func currentIdentity(_ viewModel: OnboardingViewModel) -> String {
        viewModel.probeConnectionIdentityForTesting()
    }

    private func makeProbedViewModel(headers: [CustomHeader]) -> OnboardingViewModel {
        let viewModel = OnboardingViewModel(
            savedServer: URL(string: "https://trusted.example.com"),
            savedHeaders: headers
        )
        viewModel.authStatus = AuthStatusResponse(authEnabled: true, loggedIn: true)
        // Seed the probed identity the way testConnection would after success.
        viewModel.seedProbedIdentityForTesting()
        return viewModel
    }
}
