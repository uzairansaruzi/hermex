import XCTest
@testable import HermesMobile

/// Setting a Hermes host up for push, against scripted dashboard responses and a stand-in
/// for the registrar that owns the relay and the Keychain (`PushRegistrationTests` covers
/// that side). The host is never touched. Every test asserts what the user is left with:
/// a pairing under the right server, or nothing at all.
@MainActor final class HermexPushProvisioningTests: XCTestCase {
    private let serverA = URL(string: "https://a.example.com")!
    private let serverB = URL(string: "https://b.example.com")!

    override func tearDown() {
        PushHTTPFixture.reset()
        super.tearDown()
    }

    func testEnableConfiguresTheHostThenPairsItThroughTheRegistrar() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "GET https://a.example.com/api/plugins/hermex-push/pairing",
            "PUT https://a.example.com/api/env",
            "POST https://a.example.com/api/dashboard/agent-plugins/install",
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/enable",
            "POST https://a.example.com/api/gateway/restart",
            "GET https://a.example.com/api/plugins/hermex-push/pairing"
        ])
        let env = PushHTTPFixture.body(of: "PUT https://a.example.com/api/env")
        XCTAssertEqual(env["key"].text, "HERMEX_PUSH_RELAY_URL")
        XCTAssertEqual(env["value"].text, HermexPushPlugin.defaultRelayURL.absoluteString)
        let install = PushHTTPFixture.body(of: "POST https://a.example.com/api/dashboard/agent-plugins/install")
        XCTAssertEqual(install["identifier"].text, "https://github.com/uzairansaruzi/hermex-push.git/plugin")
        XCTAssertEqual(install["force"].flag, true, "A second run must reinstall rather than refuse")

        let paired = try XCTUnwrap(registrar.pairing(for: serverA))
        XCTAssertEqual(paired.installKey, PushHTTPFixture.installKey)
        XCTAssertEqual(paired.previewKey, PushHTTPFixture.previewKey)
        XCTAssertEqual(paired.relayURL, HermexPushPlugin.defaultRelayURL)
        XCTAssertEqual(registrar.actions, ["enable a.example.com"])
        XCTAssertNil(registrar.pairing(for: serverB), "A pairing belongs to the server it was made on")
    }

    func testEachServerPairsUnderItsOwnServer() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        for server in [serverA, serverB] {
            await makeProvisioner(server: server, registrar: registrar).enable()
        }

        XCTAssertEqual(registrar.actions, ["enable a.example.com", "enable b.example.com"])
        XCTAssertNotNil(registrar.pairing(for: serverA))
        XCTAssertNotNil(registrar.pairing(for: serverB))
    }

    func testAFailedStepIsNamedAndLeavesNothingPaired() async throws {
        let steps: [(path: String, title: String)] = [
            ("/api/env", HermexPushProvisioner.Step.relayURL.title),
            ("/api/dashboard/agent-plugins/install", HermexPushProvisioner.Step.install.title),
            ("/api/gateway/restart", HermexPushProvisioner.Step.restart.title),
            ("/api/plugins/hermex-push/pairing", HermexPushProvisioner.Step.pair.title)
        ]
        for step in steps {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { request in
                // The probe has to find an unconfigured host before the step can fail.
                guard request.url?.path == step.path else { return nil }
                return PushHTTPFixture.isSetUp || step.path != "/api/plugins/hermex-push/pairing" ? (500, .null) : nil
            }
            let registrar = FakePushRegistrar()
            let provisioner = makeProvisioner(server: serverA, registrar: registrar)

            await provisioner.enable()

            XCTAssertEqual(provisioner.failure?.title, step.title)
            XCTAssertNil(provisioner.pairing)
            XCTAssertNil(registrar.pairing(for: serverA), "\(step.path) must not leave a half-paired phone")
            XCTAssertEqual(registrar.actions, [], "Nothing is registered before the host is ready")
        }
    }

    func testThePairingRouteIsRetriedWhileTheHostComesBackFromItsRestart() async throws {
        let registrar = FakePushRegistrar()
        var attempts = 0
        PushHTTPFixture.handler = { request in
            guard request.url?.path == "/api/plugins/hermex-push/pairing" else { return nil }
            attempts += 1
            // 1 is the probe that finds an unconfigured host; 2 and 3 are the host coming
            // back from its restart with the route missing, then its relay address unread.
            return attempts < 4 ? (attempts < 3 ? 404 : 409, .null) : nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(attempts, 4)
        XCTAssertNotNil(registrar.pairing(for: serverA))
    }

    func testAHostThatNeverAnswersFailsThePairingStepInsteadOfWaitingForever() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { request in request.url?.path == "/api/plugins/hermex-push/pairing" ? (404, .null) : nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertEqual(provisioner.failure?.message, HermexPushFailure.pairingUnavailable.errorDescription)
        XCTAssertNil(registrar.pairing(for: serverA))
    }

    func testKeysTheRelayCouldNotUseFailInsteadOfPairingAPhoneThatCanNeverBeReached() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            guard request.url?.path == "/api/plugins/hermex-push/pairing" else { return nil }
            return (200, .object(["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                  "install_key": .string("abc"), "preview_key": .string(PushHTTPFixture.previewKey)]))
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.message, HermexPushFailure.unusablePairing.errorDescription)
        XCTAssertNil(registrar.pairing(for: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "Keys this build cannot read are reported, never repaired by a restart")
    }

    func testAHostThatOnlyLacksARelayAddressIsNotReinstalledOrRestarted() async throws {
        let registrar = FakePushRegistrar()
        var relaySet = false
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/env": relaySet = true; return nil
            // The plugin is loaded but has nowhere to send to until the address is set.
            case "/api/plugins/hermex-push/pairing": return relaySet ? nil : (409, .null)
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertNotNil(registrar.pairing(for: serverA))
        XCTAssertTrue(PushHTTPFixture.calls.contains("PUT https://a.example.com/api/env"))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") },
                       "A loaded plugin is not reinstalled to give it an address")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") })
    }

    func testAHostErrorWhileCheckingIsReportedInsteadOfReconfiguringTheHost() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? (500, .null) : nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertTrue(try XCTUnwrap(provisioner.failure?.message).contains("500"))
        XCTAssertNil(registrar.pairing(for: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") },
                       "A host error must not replace a self-hosted relay address")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") })
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "A host error must not interrupt work running there")
    }

    func testAHostThatIsAlreadySetUpPairsWithoutInstallingOrRestartingIt() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertNotNil(registrar.pairing(for: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") },
                       "A host that names its own relay keeps it")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") })
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "Nothing is interrupted on a host that is already set up")
    }

    func testAStepTheHostRefusedReportsWhatItAnsweredRatherThanChatWording() async throws {
        PushHTTPFixture.handler = { request in request.url?.path == "/api/env" ? (500, .null) : nil }
        let provisioner = makeProvisioner(server: serverA, registrar: FakePushRegistrar())

        await provisioner.enable()

        let message = try XCTUnwrap(provisioner.failure?.message)
        XCTAssertTrue(message.contains("500"), "The user has to know what the host said: \(message)")
        XCTAssertNotEqual(message, BotFailure.rejected(500).errorDescription,
                          "Provisioning must not borrow the Bot chat's wording")
    }

    func testARefusedRegistrationIsNamedAndLeavesNothingPaired() async throws {
        let registrar = FakePushRegistrar()
        registrar.enableError = PushRegistrarError.permissionDenied
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.device.title)
        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(registrar.pairing(for: serverA))
    }

    func testDisableStopsTheHostSendingBeforeDroppingThisPhone() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        PushHTTPFixture.clearCalls()
        registrar.clearActions()

        await provisioner.disable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable"
        ])
        XCTAssertEqual(registrar.actions, ["disable a.example.com"])
        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(registrar.pairing(for: serverA))
    }

    func testDisableKeepsThePairingWhenTheRelayRefusesSoTheUserCanRetry() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        registrar.disableError = PushRelayError.http(statusCode: 503)

        await provisioner.disable()

        XCTAssertNotNil(provisioner.failure)
        XCTAssertNotNil(provisioner.pairing)
        XCTAssertNotNil(registrar.pairing(for: serverA))
    }

    func testAConnectionRemovedWhileSettingUpKeepsItsTeardownFinal() async throws {
        let registrar = FakePushRegistrar()
        var isConnected = true
        PushHTTPFixture.handler = { request in
            // The user removes the connection while the host is still being set up.
            if request.url?.path == "/api/gateway/restart" { isConnected = false }
            return nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, stillConnected: { isConnected })

        await provisioner.enable()

        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(registrar.pairing(for: serverA),
                     "A removal during setup must not be undone by the run that outlived it")
        XCTAssertEqual(registrar.actions, ["enable a.example.com", "forget a.example.com"],
                       "The phone paired mid-teardown comes back off the relay")
    }

    // MARK: - Fixtures

    private func makeProvisioner(server: URL, registrar: FakePushRegistrar,
                                 stillConnected: @escaping @MainActor () -> Bool = { true }) -> HermexPushProvisioner {
        let connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://a.example.com")!,
                                       username: "user", password: "secret")
        return HermexPushProvisioner(
            server: server, connection: connection,
            registrar: registrar,
            dashboard: { BotDashboardClient(connection: $0, configuration: PushHTTPFixture.configuration()) },
            connectionID: { stillConnected() ? connection.id : nil },
            retryDelays: [.zero, .zero, .zero],
            sleep: { _ in }
        )
    }
}

/// Stands in for `PushRegistrar` at the seam provisioning uses. The registrar's own
/// behaviour — permission, device token, relay calls, Keychain group — is covered by
/// `PushRegistrationTests`.
@MainActor private final class FakePushRegistrar: PushPairingEnabling {
    private(set) var actions: [String] = []
    var enableError: (any Error)?
    var disableError: (any Error)?
    private var pairings: [URL: PushPairing] = [:]

    func enable(_ pairing: PushPairing, for server: URL) async throws {
        actions.append("enable \(server.host ?? server.absoluteString)")
        if let enableError { throw enableError }
        var stored = pairing
        stored.registeredToken = String(repeating: "ab", count: 32)
        pairings[server] = stored
    }

    func disable(for server: URL) async throws {
        actions.append("disable \(server.host ?? server.absoluteString)")
        if let disableError { throw disableError }
        pairings[server] = nil
    }

    func forget(for server: URL) async {
        actions.append("forget \(server.host ?? server.absoluteString)")
        pairings[server] = nil
    }

    func pairing(for server: URL) -> PushPairing? { pairings[server] }

    func clearActions() { actions = [] }
}

/// Answers both the Hermes dashboard and the relay. `handler` returns nil to accept the
/// default success for that route, so a test only writes the response it is about.
private final class PushHTTPFixture: URLProtocol {
    static let installKey = String(repeating: "0123456789abcdef", count: 4)
    static let previewKey = Data(repeating: 7, count: 32).base64EncodedString()
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, BotJSON)?)?
    /// Whether the host already has the plugin loaded and a relay address set. A fresh
    /// host only answers the pairing route once a restart has loaded the plugin.
    nonisolated(unsafe) static var isSetUp = false
    private nonisolated(unsafe) static var recorded: [(call: String, body: BotJSON)] = []
    private static let lock = NSLock()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushHTTPFixture.self]
        return configuration
    }

    static var calls: [String] { lock.withLock { recorded.map(\.call) } }
    static func body(of call: String) -> BotJSON { lock.withLock { recorded.first { $0.call == call }?.body ?? .null } }
    static func clearCalls() { lock.withLock { recorded = [] } }
    static func reset() { handler = nil; isSetUp = false; clearCalls() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let call = "\(request.httpMethod ?? "GET") \(url.absoluteString)"
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
            data = body
        }
        let decoded = data.flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
        Self.lock.withLock { Self.recorded.append((call, decoded)) }
        if url.path == "/api/gateway/restart" { Self.isSetUp = true }
        let (status, value) = Self.handler?(request) ?? Self.success(for: url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(value)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The shapes the live 0.21.3 host and the relay return for these routes.
    private static func success(for url: URL) -> (Int, BotJSON) {
        switch url.path {
        case "/api/status":
            return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                  "version": .string("0.21.3")]))
        case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
        case "/api/plugins/hermex-push/pairing":
            guard isSetUp else { return (404, .null) }
            return (200, .object(["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                  "install_key": .string(installKey), "preview_key": .string(previewKey),
                                  "platform": .string("hermex"), "payload_version": .number(1)]))
        default: return (200, .object(["result": .string("ok")]))
        }
    }
}
