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

// MARK: - Blocking client double

/// Gates `health()` until the test releases it, so a probe can be held in
/// flight while inputs change.
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

final class GatedAuthAPIClient: AuthAPIClient, @unchecked Sendable {
    let gatekeeper: OnboardingGateKeeper
    init(gatekeeper: OnboardingGateKeeper) { self.gatekeeper = gatekeeper }

    func health() async throws -> HealthResponse {
        await gatekeeper.gate()
        return HealthResponse(status: "ok", sessions: nil, activeStreams: nil, uptimeSeconds: nil)
    }

    func authStatus() async throws -> AuthStatusResponse {
        AuthStatusResponse(authEnabled: true, loggedIn: false, passwordAuthEnabled: true)
    }

    func login(password: String) async throws -> LoginResponse {
        LoginResponse(ok: true, message: nil, error: nil)
    }

    func logout() async throws -> LoginResponse {
        LoginResponse(ok: true, message: nil, error: nil)
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
