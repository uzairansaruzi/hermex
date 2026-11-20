import XCTest
import SwiftUI
@testable import HermesMobile

@MainActor
final class OnboardingViewModelIdentityTests: XCTestCase {
    func testCanonicallyEquivalentURLsShareIdentity() {
        let viewModel = OnboardingViewModel()
        viewModel.serverURLString = "https://example.com"
        let before = viewModel.probeConnectionIdentityForTesting()

        viewModel.serverURLString = "https://example.com/"
        XCTAssertEqual(viewModel.probeConnectionIdentityForTesting(), before, "trailing slash must not churn")

        viewModel.serverURLString = "  https://EXAMPLE.com/path?query=1#frag  "
        XCTAssertEqual(viewModel.probeConnectionIdentityForTesting(), before, "case/whitespace/path/query/fragment are normalized away")
    }

    func testHeaderNameCaseAndOrderDoNotChangeIdentity() {
        let viewModel = OnboardingViewModel()
        viewModel.customHeaders = [
            CustomHeader(name: "X-API-Key", value: "k1"),
            CustomHeader(name: "Authorization", value: "Bearer abc")
        ]
        let before = viewModel.probeConnectionIdentityForTesting()

        viewModel.customHeaders = [
            CustomHeader(name: "authorization", value: "Bearer abc"),
            CustomHeader(name: "x-api-key", value: "k1")
        ]

        XCTAssertEqual(viewModel.probeConnectionIdentityForTesting(), before)
    }

    func testDuplicateNameReorderChangesEffectiveCredentialAndInvalidates() {
        let viewModel = makeProbedViewModel(headers: [
            CustomHeader(name: "X-Auth", value: "a"),
            CustomHeader(name: "X-Auth", value: "b")
        ])
        XCTAssertNotNil(viewModel.authStatus)

        viewModel.customHeaders = [
            CustomHeader(name: "X-Auth", value: "b"),
            CustomHeader(name: "X-Auth", value: "a")
        ]

        XCTAssertNil(viewModel.authStatus, "duplicate-name reorder changes the sent credential and must invalidate")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testEditingHeaderValueThroughElementBindingInvalidates() {
        let viewModel = makeProbedViewModel(headers: [
            CustomHeader(name: "Authorization", value: "Bearer old")
        ])

        viewModel.customHeaders[0].value = "Bearer new"

        XCTAssertNil(viewModel.authStatus, "element edits from CustomHeadersEditor must invalidate")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testNewlineBrokenRowIsNotPartOfIdentity() {
        let viewModel = makeProbedViewModel(headers: [])
        XCTAssertNotNil(viewModel.authStatus)

        viewModel.customHeaders = [CustomHeader(name: "X-Broken", value: "line1\nline2")]

        XCTAssertNotNil(viewModel.authStatus)

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
    }

    enum GatePhase: String {
        case health
        case authStatus
    }

    @MainActor
    final class OnboardingGateKeeper: @unchecked Sendable {
        private(set) var recordedPhases: [GatePhase] = []
        private var pending: [(phase: GatePhase, continuation: CheckedContinuation<Void, Never>)] = []
        private var eventWaiters: [(count: Int, expectation: XCTestExpectation)] = []
        private var autoRelease = false

        func waitForEvents(_ count: Int, _ comment: String = "", timeout seconds: Double = 5) async {
            guard recordedPhases.count < count else { return }

            let expectation = XCTestExpectation(description: "wait for \(count) gate event(s) \(comment)")
            eventWaiters.append((count, expectation))

            let result = await XCTWaiter.fulfillment(of: [expectation], timeout: seconds)
            guard result == .completed else {
                eventWaiters.removeAll { $0.expectation === expectation }
                XCTFail("timed out after \(seconds)s waiting for \(count) gate event(s); saw \(recordedPhases.map(\.rawValue)) \(comment)")
                drainEverything()
                return
            }
        }

        func gate(_ phase: GatePhase) async {
            recordedPhases.append(phase)
            let readyWaiters = eventWaiters.filter { $0.count <= recordedPhases.count }
            eventWaiters.removeAll { $0.count <= recordedPhases.count }
            readyWaiters.forEach { $0.expectation.fulfill() }
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
            configuredPasswords.append(password)
            return LoginResponse(ok: true, message: nil, error: nil)
        }

        func logout() async throws -> LoginResponse {
            LoginResponse(ok: true, message: nil, error: nil)
        }
    }

    func testStaleProbeSuccessForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: true))
        ))
        let viewModel = makeWebuiFormViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { _ = await viewModel.connect(authManager: manager) }
        await gatekeeper.waitForEvents(1, "probe should park inside health()")

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.drainEverything()
        await probeTask.value

        XCTAssertNil(viewModel.authStatus, "stale success for old identity must be discarded")
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertFalse(viewModel.isConnectionLocked)
    }

    func testStaleProbeFailureForChangedIdentityIsDiscarded() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .fail("old server unreachable")
        ))
        let viewModel = makeWebuiFormViewModel()
        viewModel.serverURLString = "https://first.example.com"

        let probeTask = Task { _ = await viewModel.connect(authManager: manager) }
        await gatekeeper.waitForEvents(1, "probe should park inside health()")

        viewModel.serverURLString = "https://second.example.com"
        gatekeeper.drainEverything()
        await probeTask.value

        XCTAssertNil(viewModel.errorMessage, "stale rejection must not surface under new identity")
        XCTAssertNil(viewModel.authStatus)
    }

    func testOperationWhileLockedIsRefusedAndOwnerKeepsBusyState() async {
        let gatekeeper = OnboardingGateKeeper()
        let manager = makeGatedManager(GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false))
        ))
        let viewModel = makeWebuiFormViewModel()
        viewModel.serverURLString = "https://example.com"

        let owner = Task { _ = await viewModel.connect(authManager: manager) }
        await gatekeeper.waitForEvents(1, "owner probe should park inside health()")
        XCTAssertTrue(viewModel.isWorking)

        await viewModel.connect(authManager: manager)

        XCTAssertTrue(viewModel.isWorking, "refused operations must not clear the owner's busy state")
        XCTAssertTrue(viewModel.isConnectionLocked)
        XCTAssertNil(viewModel.errorMessage, "refusal must be a silent no-op")
        XCTAssertEqual(gatekeeper.recordedPhases.count, 1, "no network activity may start while locked")

        gatekeeper.drainEverything()
        await owner.value
        XCTAssertFalse(viewModel.isWorking, "only the owning operation clears busy state")
        XCTAssertFalse(viewModel.isConnectionLocked)
    }

    func testConfigureRunsOncePerAcceptedConnect() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: false, loggedIn: false))
        )
        let keychain = InMemoryKeychainStore()
        let manager = makeGatedManager(client, keychain: keychain)
        let viewModel = makeWebuiFormViewModel()
        viewModel.serverURLString = "https://example.com"

        await runConnectToCompletion(viewModel, authManager: manager, gatekeeper: gatekeeper)

        XCTAssertEqual(keychain.saveCounts[.serverURL], 1, "exactly one persist per accepted connect")
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://example.com")
        XCTAssertEqual(manager.servers.count, 1, "exactly one registry activation")
        XCTAssertEqual(client.configuredPasswords.count, 0, "passwordless configure must not attempt login")
        XCTAssertFalse(viewModel.isConnectionLocked)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://example.com")!))
    }

    func testConfigurePasswordPathLogsInWithTypedPassword() async {
        let gatekeeper = OnboardingGateKeeper()
        let client = GatedAuthAPIClient(
            gatekeeper: gatekeeper,
            outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false))
        )
        let keychain = InMemoryKeychainStore()
        let manager = makeGatedManager(client, keychain: keychain)
        let viewModel = makeWebuiFormViewModel()
        viewModel.serverURLString = "https://example.com"
        viewModel.password = "typed-secret"

        await runConnectToCompletion(viewModel, authManager: manager, gatekeeper: gatekeeper)

        XCTAssertEqual(client.configuredPasswords, ["typed-secret"], "configure must log in with the typed password")
        XCTAssertEqual(keychain.savedValues[.serverURL], "https://example.com")
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://example.com")!))
        XCTAssertFalse(viewModel.isConnectionLocked)
        XCTAssertFalse(viewModel.isWorking)
    }

    @MainActor
    final class AcceptedConnectDriver {
        let gatekeeper: OnboardingGateKeeper

        init(gatekeeper: OnboardingGateKeeper) {
            self.gatekeeper = gatekeeper
        }

        func runAndSettle(
            _ operation: @escaping @MainActor () async -> Void
        ) async {
            let task = Task { await operation() }
            await gatekeeper.waitForEvents(1, "accepted connect should park in its probe's health()")
            for expected in 2...4 {
                gatekeeper.releaseNext()
                await gatekeeper.waitForEvents(expected, "connect schedule phase \(expected)")
            }
            gatekeeper.releaseNext()
            await task.value
        }
    }

    private func runConnectToCompletion(
        _ viewModel: OnboardingViewModel,
        authManager: AuthManager,
        gatekeeper: OnboardingGateKeeper
    ) async {
        await AcceptedConnectDriver(gatekeeper: gatekeeper)
            .runAndSettle { await viewModel.connect(authManager: authManager) }
    }

    nonisolated override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    private func makeOpenWebui(authEnabled: Bool = true) -> (OnboardingGateKeeper, AuthManager) {
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let client = GatedAuthAPIClient(gatekeeper: gatekeeper,
                                        outcome: .succeed(AuthStatusResponse(authEnabled: authEnabled, loggedIn: false)))
        return (gatekeeper, makeGatedManager(client))
    }

    private func makeHermesForm(
        entry: OnboardingViewModel.Entry = .onboarding,
        _ script: @escaping (URLRequest) -> HermesHostFixture.Reply? = { _ in nil }
    ) -> OnboardingViewModel {
        OnboardingViewModel(entry: entry, hermesConfiguration: { HermesHostFixture.configuration(script) },
                            hermesGateway: .init(socketFactory: { _ in BotScriptedSocket() }))
    }

    func testAHermesStatusRevealsTheDashboardSignInAndNeverReachesTheWebui() async throws {
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let client = GatedAuthAPIClient(gatekeeper: gatekeeper,
                                        outcome: .succeed(AuthStatusResponse(authEnabled: true, loggedIn: false)))
        let manager = makeGatedManager(client)
        let form = makeHermesForm {
            $0.url?.host == "webui.example" ? .json(404, .object(["error": .string("Not found")])) : nil
        }
        form.serverURLString = "hermes.example"
        form.customHeaders = [CustomHeader(name: "CF-Access-Client-Id", value: "id.access"),
                              CustomHeader(name: "CF-Access-Client-Secret", value: " ")]

        await form.connect(authManager: manager)

        XCTAssertEqual(form.detectedKind, .hermes)
        XCTAssertTrue(form.showsHermesSignIn)
        XCTAssertEqual(form.hermesVersion, "0.21.5", "The sheet's status line names the release")
        XCTAssertTrue(gatekeeper.recordedPhases.isEmpty, "A Hermes dashboard never gets the webui probe")
        XCTAssertEqual(manager.state, .unconfigured)
        let status = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/status" })
        XCTAssertEqual(status.url?.absoluteString, "https://hermes.example/api/status")
        XCTAssertEqual(status.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id.access")
        XCTAssertNil(status.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "A header row without a value is never sent")

        form.username = "admin"
        form.password = "dashboard-secret"
        form.customHeaders[0].value = "id.other"
        form.serverURLString = "webui.example"
        await form.connect(authManager: manager)

        XCTAssertEqual(client.configuredPasswords, [], "The dashboard's password never goes to another host")
        XCTAssertTrue(form.showsPasswordField, "The webui asks for its own password")
    }

    func testABrowserHostSignsInThroughThePresenterAndAddsItsServer() async throws {
        let keychain = InMemoryKeychainStore()
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let manager = makeGatedManager(GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: .succeed(
            AuthStatusResponse(authEnabled: true, loggedIn: false))), keychain: keychain)
        let form = makeHermesForm { request in
            switch request.url?.path {
            case "/api/status": return .json(200, HermesBrowserSignInTests.browserStatus)
            case "/auth/native/token": return .json(200, HermesBrowserSignInTests.tokens)
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            default: return nil
            }
        }
        form.serverURLString = "hermes.example"

        await form.connect(authManager: manager)
        XCTAssertTrue(form.showsHermesSignIn)
        XCTAssertEqual(form.signInMethod, .browser)
        XCTAssertFalse(form.showsHermesCredentials)
        XCTAssertFalse(form.showsPasswordField)
        XCTAssertTrue(form.canSubmit, "No username or password to fill in")

        let presenter = HermesBrowserSignIn.Presenter { url in _ = try await HermesBrowserSignInTests.callback(url, code: "code-1") }
        let added = await form.connect(authManager: manager, browser: presenter)

        let server = URL(string: "https://hermes.example")!
        XCTAssertEqual(added, server)
        XCTAssertEqual(manager.state, .loggedIn(server: server))
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: server))
        XCTAssertEqual(saved.oauth, HermesOAuth(provider: "nous", userID: "u1", refreshToken: "refresh-1"))
        XCTAssertEqual(saved.hermesVersion, "0.21.5")
    }

    func testPickingBrowserOnAHostWithBothSignsInThroughThePresenter() async throws {
        let keychain = InMemoryKeychainStore()
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let manager = makeGatedManager(GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: .succeed(
            AuthStatusResponse(authEnabled: true, loggedIn: false))), keychain: keychain)
        let form = makeHermesForm(entry: .addServer) { request in
            switch request.url?.path {
            case "/api/status": return .json(200, HermesBrowserSignInTests.bothStatus)
            case "/auth/native/token": return .json(200, HermesBrowserSignInTests.tokens)
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            default: return nil
            }
        }
        form.serverURLString = "hermes.example"

        await form.connect(authManager: manager)
        XCTAssertTrue(form.offersSignInChoice)
        XCTAssertEqual(form.signInMethod, .password)

        form.signInMethod = .browser
        XCTAssertFalse(form.showsPasswordField)
        let presenter = HermesBrowserSignIn.Presenter { url in _ = try await HermesBrowserSignInTests.callback(url, code: "code-1") }
        let added = await form.connect(authManager: manager, browser: presenter)

        let server = URL(string: "https://hermes.example")!
        XCTAssertEqual(added, server)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: server)?.oauth?.refreshToken, "refresh-1")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
    }

    func testAnOpenHostIsAddedWithoutCredentials() async throws {
        let keychain = InMemoryKeychainStore()
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let manager = makeGatedManager(GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: .succeed(
            AuthStatusResponse(authEnabled: false))), keychain: keychain)
        let form = makeHermesForm(entry: .addServer) { request in
            switch request.url?.path {
            case "/api/status": return .json(200, .object(["auth_required": .bool(false), "version": .string("0.21.6")]))
            case "/": return .body(200, Data(#"<script>window.__HERMES_SESSION_TOKEN__="token-1";</script>"#.utf8))
            default: return nil
            }
        }
        form.serverURLString = "hermes.example"
        form.username = "typed"

        await form.connect(authManager: manager)
        XCTAssertEqual(form.signInMethod, .open)
        XCTAssertFalse(form.showsHermesCredentials)
        XCTAssertFalse(form.showsPasswordField)
        XCTAssertTrue(form.canSubmit, "No username or password to fill in")
        let added = await form.connect(authManager: manager)

        let server = URL(string: "https://hermes.example")!
        XCTAssertEqual(added, server)
        let saved = try XCTUnwrap(BotConnectionStore(keychain: keychain).load(server: server))
        XCTAssertEqual([saved.username, saved.password], ["", ""])
        XCTAssertNil(saved.oauth)
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
    }

    func testABrowserHostSignsInFromAMoveWithoutSwitching() async throws {
        let keychain = InMemoryKeychainStore()
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let manager = makeGatedManager(GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: .succeed(
            AuthStatusResponse(authEnabled: false))), keychain: keychain)
        await manager.configure(serverURLString: "https://webui.example", password: "")
        let form = OnboardingViewModel(entry: .addServer, moveSource: .init(name: "Home", headers: []), hermesConfiguration: {
            HermesHostFixture.configuration { request in
                switch request.url?.path {
                case "/api/status": return .json(200, HermesBrowserSignInTests.browserStatus)
                case "/auth/native/token": return .json(200, HermesBrowserSignInTests.tokens)
                case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
                default: return nil
                }
            }
        }, hermesGateway: .init(socketFactory: { _ in BotScriptedSocket() }))
        form.serverURLString = "hermes.example"
        await form.connect(authManager: manager)
        XCTAssertEqual(form.signInMethod, .browser)

        let presenter = HermesBrowserSignIn.Presenter { url in _ = try await HermesBrowserSignInTests.callback(url, code: "code-1") }
        let added = await form.connect(authManager: manager, browser: presenter)

        let server = URL(string: "https://hermes.example")!
        XCTAssertEqual(added, server)
        XCTAssertNil(form.errorMessage)
        XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://webui.example")!))
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: server)?.oauth?.refreshToken, "refresh-1")
    }

    func testAWebuiAnswerOnTheStatusRouteFallsThroughToHealth() async {
        let replies: [HermesHostFixture.Reply] = [
            .json(401, .object(["error": .string("Authentication required")])),
            .json(404, .object(["error": .string("Not found")])),
            .json(400, .string("The plain HTTP request was sent to HTTPS port"))
        ]
        for reply in replies {
            let (gatekeeper, manager) = makeOpenWebui()
            let form = makeHermesForm { $0.url?.path == "/api/status" ? reply : nil }
            form.serverURLString = "192.168.1.5:8787"
            XCTAssertEqual(form.addressPreview?.absoluteString, "http://192.168.1.5:8787", "Before anything answers")

            await form.connect(authManager: manager)

            XCTAssertEqual(gatekeeper.recordedPhases, [.health, .authStatus], "\(reply)")
            XCTAssertEqual(form.detectedKind, .webui, "\(reply)")
            XCTAssertTrue(form.showsPasswordField, "\(reply)")
            XCTAssertFalse(form.showsHermesSignIn, "\(reply)")
            XCTAssertEqual(form.addressPreview?.absoluteString, "https://192.168.1.5:8787",
                           "Once a webui answers, the line shows the URL the webui path saves")

            form.password = "wrong"
            form.serverURLString = "192.168.1.6:8787"
            XCTAssertFalse(form.showsPasswordField, "\(reply): another address answers first")

            await form.connect(authManager: manager)
            XCTAssertTrue(form.showsPasswordField, "\(reply): the new address asks for its own password, never a hidden one")
        }
    }

    func testAHostHeaderRefusalOrAnAccessSignInShowsItsAdviceWithoutFallingThrough() async {
        let rows: [(HermesHostFixture.Reply, String)] = [
            (.json(400, .object(["detail": .string("Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname.")])),
             "Hermes doesn't accept hermes.example as its address. On the host, set dashboard.public_url to https://hermes.example, then restart the dashboard."),
            (.json(401, .string("Sign in to Access")),
             "Something in front of Hermes, such as Cloudflare Access, wants its own sign-in first. Add its service token under Connection Headers in the Hermes connection, or use an address that skips it, such as the dashboard's local network address.")
        ]
        for (reply, advice) in rows {
            let (gatekeeper, manager) = makeOpenWebui()
            let form = makeHermesForm { $0.url?.path == "/api/status" ? reply : nil }
            form.serverURLString = "hermes.example"

            await form.connect(authManager: manager)

            XCTAssertEqual(form.errorMessage, advice)
            XCTAssertNil(form.detectedKind)
            XCTAssertTrue(gatekeeper.recordedPhases.isEmpty, "\(reply) never falls through to the webui")
        }
    }

    func testHermesSignInFailuresShowTheirCopyAndAreNeverRetried() async {
        let oldStatus = BotJSON.object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                        "version": .string("0.20.0")])
        let browserOnly = BotJSON.object(["auth_required": .bool(true), "auth_providers": .array([.string("nous")]),
                                          "version": .string("0.21.5")])
        let rows: [(String, HermesHostFixture.Reply, String, Int)] = [
            ("/auth/password-login", .json(429, .object([:])), "Too many sign-in attempts. Wait a minute, then try again.", 1),
            ("/auth/password-login", .json(401, .object(["error": .string("invalid_credentials")])),
             "Hermes didn't accept the username or password.", 1),
            ("/api/status", .json(200, oldStatus),
             "This Hermes host runs 0.20.0. Hermex needs Hermes 0.21.3 or later. Update Hermes on the host, then try again.", 0),
            ("/api/status", .json(200, browserOnly),
             "This Hermes host only offers sign-in with a browser, which Hermex doesn't support yet. To connect now, add a dashboard username and password on the host.", 0)
        ]
        for (path, reply, copy, logins) in rows {
            HermesHostFixture.reset()
            let (_, manager) = makeOpenWebui()
            let form = makeHermesForm { $0.url?.path == path ? reply : nil }
            form.serverURLString = "hermes.example"
            await form.connect(authManager: manager)
            XCTAssertEqual(form.detectedKind, .hermes, copy)
            form.username = "me"
            form.password = "secret"

            let added = await form.connect(authManager: manager)

            XCTAssertNil(added, copy)
            XCTAssertEqual(form.errorMessage, copy)
            XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), logins, copy)
            XCTAssertTrue(manager.servers.isEmpty, copy)
        }
    }

    func testEditingTheRefusedPasswordDropsItsDetails() async throws {
        let (_, manager) = makeOpenWebui()
        let form = makeHermesForm(entry: .addServer) {
            $0.url?.path == "/auth/password-login" ? .json(401, .object(["error": .string("invalid_credentials")])) : nil
        }
        form.serverURLString = "hermes.example"
        await form.connect(authManager: manager)
        form.username = "me"
        form.password = "wrong"
        _ = await form.connect(authManager: manager)
        XCTAssertEqual(try XCTUnwrap(form.failedAttempt)[.signIn], .failed(.http(401)))

        form.password = "right"

        XCTAssertNil(form.failedAttempt)
    }

    func testAFailedDetectionKeepsOnlyItsStatusCheckForTheCurrentAddress() async throws {
        let gatekeeper = OnboardingGateKeeper()
        gatekeeper.drainEverything()
        let manager = makeGatedManager(GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: .fail("Could not connect")))
        let form = makeHermesForm { $0.url?.path == "/api/status" ? .fail(URLError(.timedOut)) : nil }
        form.serverURLString = "hermes.example"

        await form.connect(authManager: manager)

        XCTAssertNotNil(form.errorMessage)
        let attempt = try XCTUnwrap(form.failedAttempt)
        XCTAssertEqual(HermesAttemptRecord.Stage.allCases.map { attempt[$0] },
                       [.failed(.timedOut), .notChecked, .notChecked, .notChecked, .notChecked])
        form.serverURLString = "other.example"
        XCTAssertNil(form.failedAttempt)
    }

    func testAddServerDropsTheStatusDetailsOnceAWebuiAnswered() async {
        let rows: [(GatedProbeOutcome, Bool)] = [
            (.succeed(AuthStatusResponse(authEnabled: true, loggedIn: false, passwordAuthEnabled: false)), false),
            (.fail("Could not connect"), true)
        ]
        for (outcome, keepsDetails) in rows {
            let gatekeeper = OnboardingGateKeeper()
            gatekeeper.drainEverything()
            let client = GatedAuthAPIClient(gatekeeper: gatekeeper, outcome: outcome)
            let manager = AuthManager(keychain: InMemoryKeychainStore(), clientFactory: { _ in client },
                                      probeClientFactory: { _, _ in client }, headerStore: CustomHeaderStore(),
                                      serverRegistry: ServerRegistry.inMemory())
            let form = makeHermesForm(entry: .addServer) { $0.url?.path == "/api/status" ? .json(404, .object([:])) : nil }
            form.serverURLString = "b.test"

            let added = await form.connect(authManager: manager)

            XCTAssertNil(added)
            XCTAssertNotNil(form.errorMessage)
            XCTAssertEqual(form.failedAttempt != nil, keepsDetails, "\(outcome)")
        }
    }

    func testCloudflareAccessValuesGoOutOnlyOnceFilledIn() async throws {
        let (_, manager) = makeOpenWebui()
        let form = makeHermesForm(entry: .addServer)
        form.serverURLString = "hermes.example"
        form.customHeaders = [CustomHeader(name: "X-Proxy", value: "1")]
        let identity = form.probeConnectionIdentityForTesting()

        form.accessClientID = ""
        XCTAssertEqual(form.probeConnectionIdentityForTesting(), identity, "An empty field sends nothing")

        form.accessClientID = "id.access"
        form.accessClientSecret = "secret.access"
        XCTAssertNotEqual(form.probeConnectionIdentityForTesting(), identity)
        XCTAssertEqual(form.otherHeaders.map(\.name), ["X-Proxy"], "Access's rows stay out of the header editor")
        await form.connect(authManager: manager)

        let status = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/status" })
        XCTAssertEqual(status.value(forHTTPHeaderField: "CF-Access-Client-Id"), "id.access")
        XCTAssertEqual(status.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret.access")
    }

    func testRenamingAHeaderRowToCloudflareAccessMovesItWithoutCrashing() {
        let form = makeHermesForm(entry: .addServer)
        form.customHeaders = [CustomHeader(name: "CF-Access-Client-I", value: "id.access")]
        let headers = Binding(get: { form.otherHeaders }, set: { form.otherHeaders = $0 })
        let row = headers.row(form.otherHeaders[0])

        row.name.wrappedValue = "CF-Access-Client-Id"

        XCTAssertEqual(row.name.wrappedValue, "CF-Access-Client-I", "A row gone from the editor reads its last snapshot")
        XCTAssertTrue(form.otherHeaders.isEmpty)
        XCTAssertEqual(form.accessClientID, "id.access")

        row.value.wrappedValue = "late"
        XCTAssertEqual(form.accessClientID, "id.access", "A late write from the gone row is dropped")
    }

    func testTheSheetAsksAWebuiForItsPasswordAndThenAddsIt() async {
        for entry in [OnboardingViewModel.Entry.onboarding, .addServer] {
            HermesHostFixture.reset()
            let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
            let manager = AuthManager(keychain: InMemoryKeychainStore(), clientFactory: { _ in client },
                                      probeClientFactory: { _, _ in client }, headerStore: CustomHeaderStore(),
                                      serverRegistry: ServerRegistry.inMemory())
            let form = makeHermesForm(entry: entry) { $0.url?.path == "/api/status" ? .json(404, .object([:])) : nil }
            form.serverURLString = "b.test"
            XCTAssertFalse(form.showsPasswordField, "\(entry): address first")

            let first = await form.connect(authManager: manager)
            XCTAssertNil(first, "\(entry)")
            XCTAssertTrue(form.showsPasswordField, "\(entry)")
            XCTAssertNil(form.errorMessage, "\(entry)")

            form.password = "pw"
            let added = await form.connect(authManager: manager)
            XCTAssertEqual(added, URL(string: "https://b.test"), "\(entry)")
            XCTAssertEqual(manager.state, .loggedIn(server: URL(string: "https://b.test")!), "\(entry)")
            XCTAssertEqual(client.loginPasswords, ["pw"], "\(entry)")
            XCTAssertEqual(HermesHostFixture.count("/api/status"), 1, "\(entry): a webui that answered is not probed again")
        }
    }
}

extension OnboardingViewModelIdentityTests {
    @MainActor
    func makeWebuiFormViewModel() -> OnboardingViewModel {
        OnboardingViewModel(hermesConfiguration: { HermesHostFixture.configuration { _ in .json(404, .object([:])) } })
    }

    @MainActor
    func makeGatedManager(_ client: GatedAuthAPIClient, keychain: InMemoryKeychainStore = InMemoryKeychainStore()) -> AuthManager {
        AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )
    }

    private func makeProbedViewModel(headers: [CustomHeader]) -> OnboardingViewModel {
        let viewModel = OnboardingViewModel(
            savedServer: URL(string: "https://trusted.example.com"),
            savedHeaders: headers
        )
        viewModel.authStatus = AuthStatusResponse(authEnabled: true, loggedIn: true)
        viewModel.seedProbedIdentityForTesting()
        return viewModel
    }
}
