import XCTest
@testable import HermesMobile

/// Regression matrix for the #285 review: connection-identity binding,
/// stale-probe fencing, and configure ownership in `OnboardingViewModel`.
///
/// Async schedules are driven by a *phase-aware* gate: every network call site
/// (`health`, `authStatus`) registers under its own name, so each test releases
/// exactly the events the real schedule produces — a full accepted `connect()`
/// emits FOUR gated events (the ViewModel's probe pair, then the internal
/// re-probe pair inside `AuthManager.configure`). Waiters are deadline-bounded,
/// so a routing regression fails its assertion instead of hanging the target
/// (PR #294 re-gate at 5b68be65c).
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

    // MARK: - Phase-aware gated client double (drives real async schedules)

    /// Distinct call sites inside `AuthManager`'s probe: `testConnection(client:)`
    /// awaits `health()` and then `authStatus()`, so a parked probe is always in
    /// exactly one known phase.
    private enum GatePhase: String {
        case health
        case authStatus
    }

    @MainActor
    final class OnboardingGateKeeper: @unchecked Sendable {
        private(set) var recordedPhases: [GatePhase] = []
        private var pending: [(phase: GatePhase, continuation: CheckedContinuation<Void, Never>)] = []
        /// When set, further gate entries return immediately — drains the
        /// abandoned tail of a superseded schedule without extra bookkeeping.
        private var autoRelease = false

        /// Deadline-bounded waiter: fails the test instead of hanging when the
        /// production schedule never reaches the expected number of gate events.
        func waitForEvents(_ count: Int, _ comment: String = "", timeout seconds: Double = 5) async {
            let deadline = Date().addingTimeInterval(seconds)
            while recordedPhases.count < count {
                if Date() >= deadline {
                    XCTFail("timed out after \(seconds)s waiting for \(count) gate event(s); saw \(recordedPhases.map(\.rawValue)) \(comment)")
                    return
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        func gate(_ phase: GatePhase) async {
            recordedPhases.append(phase)
            if autoRelease { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pending.append((phase, continuation))
            }
        }

        func releaseNext() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().continuation.resume()
        }

        func releaseAll() {
            while !pending.isEmpty {
                pending.removeFirst().continuation.resume()
            }
        }

        /// Releases everything currently parked AND stops parking new arrivals.
        func drainEverything() {
            autoRelease = true
            releaseAll()
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
            await gatekeeper.gate(.health)
            return HealthResponse(status: "ok", sessions: nil, activeStreams: nil, uptimeSeconds: nil)
        }

        func authStatus() async throws -> AuthStatusResponse {
            await gatekeeper.gate(.authStatus)
            switch outcome {
            case .succeed(let status):
                return status
            case .fail(let message):
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        func login(password: String) async throws -> LoginResponse {
            // Login is deliberately UNGATED: it is the third call of the
            // configure password path and carries no schedule decision.
            configuredPasswords.append(password)
            return LoginResponse(ok: true, message: nil, error: nil)
        }

        func logout() async throws -> LoginResponse {
            LoginResponse(ok: true, message: nil, error: nil)
        }
    }

    // MARK: - Stale probe fencing

    // Stale A success cannot publish over B: A is held, the user retargets to
    // B, then A completes — its result must be discarded and B must still be
    // free to probe.
    func testStaleProbeSuccessForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: true))
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitForEvents(1, "probe should park inside health()")

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.drainEverything()
        await probeTask.value

        XCTAssertNil(viewModel.authStatus, "stale success for old identity must be discarded")
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertFalse(viewModel.isConnectionLocked)
    }

    // Stale A rejection cannot publish its error over B.
    func testStaleProbeFailureForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .fail("old server unreachable")
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitForEvents(1, "probe should park inside health()")

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.drainEverything()
        await probeTask.value

        XCTAssertNil(viewModel.errorMessage, "stale rejection must not surface under new identity")
        XCTAssertNil(viewModel.authStatus)
    }

    // MARK: - Connection lock (inputs frozen across probe AND configure)

    // The production lock deliberately forbids overlapping operations, so the
    // right assertion is REFUSAL: a second entry point while locked must be a
    // no-op that leaves the owning operation's busy state untouched.
    func testOperationWhileLockedIsRefusedAndOwnerKeepsBusyState() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false))
        ))
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"

        let owner = Task { await viewModel.testConnection(authManager: manager) }
        await gatekeeper.waitForEvents(1, "owner probe should park inside health()")
        XCTAssertTrue(viewModel.isWorking)

        // Both entry points refuse while the lock is held.
        await viewModel.connect(authManager: manager)
        await viewModel.testConnection(authManager: manager)

        XCTAssertTrue(viewModel.isWorking, "refused operations must not clear the owner's busy state")
        XCTAssertTrue(viewModel.isConnectionLocked)
        XCTAssertNil(viewModel.errorMessage, "refusal must be a silent no-op")
        XCTAssertNil(viewModel.connectionMessage)
        XCTAssertEqual(gatekeeper.recordedPhases.count, 1, "no network activity may start while locked")

        gatekeeper.drainEverything()
        await owner.value
        XCTAssertFalse(viewModel.isWorking, "only the owning operation clears busy state")
        XCTAssertFalse(viewModel.isConnectionLocked)
    }

    // Edit during connect(): the operation must be refused outright while the
    // form is locked (inputs frozen), so no second connect can interleave.
    // The accepted connect walks its REAL four-phase schedule: the ViewModel's
    // own probe (health, authStatus) followed by configure's internal re-probe
    // (health, authStatus).
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
        await gatekeeper.waitForEvents(1, "accepted connect should park in its probe's health()")

        XCTAssertTrue(viewModel.isConnectionLocked, "inputs frozen for the whole connect")
        XCTAssertTrue(viewModel.isWorking)
        XCTAssertNil(viewModel.authStatus, "probe still in flight — capability-derived UI must not be asserted yet")

        let loginsBefore = client.configuredPasswords.count

        // Return-key during lock must be refused by the guard.
        await viewModel.connect(authManager: manager)
        XCTAssertEqual(gatekeeper.recordedPhases.count, 1, "refused connect starts no network work")

        // Settle the accepted connect through all four phases: release each
        // gate only after its successor has parked, keeping the schedule
        // deterministic.
        for expected in 2...4 {
            gatekeeper.releaseNext()
            await gatekeeper.waitForEvents(expected, "connect schedule phase \(expected)")
        }
        gatekeeper.releaseNext()

        await connectTask.value

        XCTAssertEqual(client.configuredPasswords.count, loginsBefore, "passwordless configure must not attempt login")
        XCTAssertFalse(viewModel.isConnectionLocked, "lock released after settle")
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertNotNil(viewModel.authStatus, "accepted connect settles to a probed status")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isPasswordRequired, "trusted-header status hides the password field AFTER settle")
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://example.com")))
    }

    // Configure reaches AuthManager exactly once per accepted connect: one
    // keychain persist, one registry activation, zero login attempts on a
    // passwordless server.
    func testConfigureRunsOncePerAcceptedConnect() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: false))
        )
        let keychain = InMemoryKeychainStore()
        let manager = makeGatedManager(client, keychain: keychain)
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"

        await runConnectToCompletion(viewModel, authManager: manager, gatekeeper: gatekeeper)

        XCTAssertEqual(keychain.saveCounts[.serverURL], 1, "exactly one persist per accepted connect")
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://example.com")
        XCTAssertEqual(manager.servers.count, 1, "exactly one registry activation")
        // authEnabled=false → configure skips login entirely (no password path).
        XCTAssertEqual(client.configuredPasswords.count, 0, "passwordless configure must not attempt login")
        XCTAssertFalse(viewModel.isConnectionLocked)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://example.com")))
    }

    // Full password path: probe demands auth, configure logs in with the typed
    // password and persists the session.
    func testConfigurePasswordPathLogsInWithTypedPassword() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false))
        )
        let keychain = InMemoryKeychainStore()
        let manager = makeGatedManager(client, keychain: keychain)
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"
        viewModel.password = "typed-secret"

        // Probe pair + configure's probe pair; login itself is ungated.
        await runConnectToCompletion(viewModel, authManager: manager, gatekeeper: gatekeeper)

        XCTAssertEqual(client.configuredPasswords, ["typed-secret"], "configure must log in with the typed password")
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://example.com")
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://example.com")))
        XCTAssertFalse(viewModel.isConnectionLocked)
        XCTAssertFalse(viewModel.isWorking)
    }

    // MARK: - Schedule helpers

    /// Drives the canonical accepted-connect schedule: probe pair (health,
    /// authStatus), then configure's internal re-probe pair, releasing each
    /// phase in order so every await settles before its successor is released.
    @MainActor
    final class AcceptedConnectDriver {
        let gatekeeper: OnboardingGateKeeper

        init(gatekeeper: OnboardingGateKeeper) {
            self.gatekeeper = gatekeeper
        }

        /// Runs connect() as a task and settles it through all four phases,
        /// releasing each gate only after its successor has parked.
        func runAndSettle(
            _ operation: @escaping @MainActor () async -> Void
        ) async {
            let task = Task { await operation() }
            await gatekeeper.waitForEvents(1, "accepted connect should park in its probe's health()")
            // Events 2…4 only fire AFTER the preceding phase is released, so
            // waiting for them up front would deadlock — release one phase,
            // then wait for exactly the next event.
            for expected in 2...4 {
                gatekeeper.releaseNext()
                await gatekeeper.waitForEvents(expected, "connect schedule phase \(expected)")
            }
            gatekeeper.releaseNext()
            await task.value
        }
    }

    /// Convenience wrapper for inline connect() drives.
    private func runConnectToCompletion(
        _ viewModel: OnboardingViewModel,
        authManager: AuthManager,
        gatekeeper: OnboardingGateKeeper
    ) async {
        await AcceptedConnectDriver(gatekeeper: gatekeeper)
            .runAndSettle { await viewModel.connect(authManager: authManager) }
    }
}

extension OnboardingViewModelIdentityTests {
    @MainActor
    func makeGatedManager(_ client: GatedAuthAPIClient, keychain: InMemoryKeychainStore = InMemoryKeychainStore()) -> AuthManager {
        AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )
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
