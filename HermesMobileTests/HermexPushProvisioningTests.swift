import XCTest
@testable import HermesMobile

/// Push provisioning against scripted dashboard and relay responses: the host is never
/// touched, and neither is a real Keychain. Every test asserts what the user is left with
/// — keys under the right server, or nothing at all.
@MainActor final class HermexPushProvisioningTests: XCTestCase {
    private let serverA = URL(string: "https://a.example.com")!
    private let serverB = URL(string: "https://b.example.com")!
    private let token = String(repeating: "ab", count: 32)

    override func tearDown() {
        PushHTTPFixture.reset()
        super.tearDown()
    }

    func testEnableConfiguresTheHostThenStoresThePairingUnderItsOwnServer() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: token)

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
            "GET https://a.example.com/api/plugins/hermex-push/pairing",
            "POST https://hermex-relay.hermex-relay.workers.dev/installs/\(PushHTTPFixture.installKey)/devices"
        ])
        let env = PushHTTPFixture.body(of: "PUT https://a.example.com/api/env")
        XCTAssertEqual(env["key"].text, "HERMEX_PUSH_RELAY_URL")
        XCTAssertEqual(env["value"].text, HermexPushPairing.defaultRelayURL.absoluteString)
        let install = PushHTTPFixture.body(of: "POST https://a.example.com/api/dashboard/agent-plugins/install")
        XCTAssertEqual(install["identifier"].text, "https://github.com/uzairansaruzi/hermex-push.git/plugin")
        XCTAssertEqual(install["force"].flag, true, "A second run must reinstall rather than refuse")
        let device = PushHTTPFixture.body(of: "POST https://hermex-relay.hermex-relay.workers.dev/installs/\(PushHTTPFixture.installKey)/devices")
        XCTAssertEqual(device["device_token"].text, token)

        let stored = try XCTUnwrap(HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertEqual(stored.installKey, PushHTTPFixture.installKey)
        XCTAssertEqual(stored.previewKey, PushHTTPFixture.previewKey)
        XCTAssertEqual(stored.deviceToken, token)
        XCTAssertEqual(stored.payloadVersion, 1)
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverB),
                     "A pairing belongs to the server it was made on")
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
            PushHTTPFixture.handler = { request in request.url?.path == step.path ? (500, .null) : nil }
            let keychain = InMemoryKeychainStore()
            let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: token)

            await provisioner.enable()

            XCTAssertEqual(provisioner.failure?.title, step.title)
            XCTAssertNil(provisioner.pairing)
            XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA),
                         "\(step.path) must not leave a half-paired phone")
            XCTAssertFalse(PushHTTPFixture.calls.contains { $0.hasSuffix("/devices") })
        }
    }

    func testThePairingRouteIsRetriedWhileTheHostComesBackFromItsRestart() async throws {
        let keychain = InMemoryKeychainStore()
        var attempts = 0
        PushHTTPFixture.handler = { request in
            guard request.url?.path == "/api/plugins/hermex-push/pairing" else { return nil }
            attempts += 1
            // 1 is the probe that finds an unconfigured host; 2 and 3 are the host coming
            // back from its restart with the route missing, then its relay address unread.
            return attempts < 4 ? (attempts < 3 ? 404 : 409, .null) : nil
        }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(attempts, 4)
        XCTAssertNotNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
    }

    func testAHostThatNeverAnswersFailsThePairingStepInsteadOfWaitingForever() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { request in request.url?.path == "/api/plugins/hermex-push/pairing" ? (404, .null) : nil }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertEqual(provisioner.failure?.message, HermexPushFailure.pairingUnavailable.errorDescription)
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
    }

    func testKeysTheRelayCouldNotUseFailInsteadOfPairingAPhoneThatCanNeverBeReached() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { request in
            guard request.url?.path == "/api/plugins/hermex-push/pairing" else { return nil }
            return (200, .object(["relay_url": .string(HermexPushPairing.defaultRelayURL.absoluteString),
                                  "install_key": .string("abc"), "preview_key": .string(PushHTTPFixture.previewKey)]))
        }
        PushHTTPFixture.isSetUp = true
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.message, HermexPushFailure.unusablePairing.errorDescription)
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "Keys this build cannot read are reported, never repaired by a restart")
    }

    func testAHostThatOnlyLacksARelayAddressIsNotReinstalledOrRestarted() async throws {
        let keychain = InMemoryKeychainStore()
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
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertNotNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertTrue(PushHTTPFixture.calls.contains("PUT https://a.example.com/api/env"))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") },
                       "A loaded plugin is not reinstalled to give it an address")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") })
    }

    func testAHostErrorWhileCheckingIsReportedInsteadOfReconfiguringTheHost() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? (500, .null) : nil
        }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertTrue(try XCTUnwrap(provisioner.failure?.message).contains("500"))
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") },
                       "A host error must not replace a self-hosted relay address")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") })
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "A host error must not interrupt work running there")
    }

    func testAHostThatIsAlreadySetUpPairsWithoutInstallingOrRestartingIt() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: nil)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertNotNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") },
                       "A host that names its own relay keeps it")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("agent-plugins") })
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/gateway/restart") },
                       "Nothing is interrupted on a host that is already set up")
    }

    func testAStepTheHostRefusedReportsWhatItAnsweredRatherThanChatWording() async throws {
        PushHTTPFixture.handler = { request in request.url?.path == "/api/env" ? (500, .null) : nil }
        let provisioner = makeProvisioner(server: serverA, keychain: InMemoryKeychainStore(), deviceToken: nil)

        await provisioner.enable()

        let message = try XCTUnwrap(provisioner.failure?.message)
        XCTAssertTrue(message.contains("500"), "The user has to know what the host said: \(message)")
        XCTAssertNotEqual(message, BotFailure.rejected(500).errorDescription,
                          "Provisioning must not borrow the Bot chat's wording")
    }

    func testDisableDropsThePhoneAtTheRelayDisablesThePluginAndWipesTheKeys() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: token)
        await provisioner.enable()
        PushHTTPFixture.clearCalls()

        await provisioner.disable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(PushHTTPFixture.calls, [
            "DELETE https://hermex-relay.hermex-relay.workers.dev/installs/\(PushHTTPFixture.installKey)/devices/\(token)",
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable"
        ])
        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
    }

    func testDisableKeepsTheKeysWhenTheRelayRefusesSoTheUserCanRetry() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: token)
        await provisioner.enable()
        PushHTTPFixture.handler = { request in request.httpMethod == "DELETE" ? (500, .null) : nil }

        await provisioner.disable()

        XCTAssertEqual(provisioner.failure?.message, HermexPushFailure.relayRejected(500).errorDescription)
        XCTAssertNotNil(provisioner.pairing)
        XCTAssertNotNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
    }

    func testRemovingOneServerUnpairsOnlyThatServer() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { _ in nil }
        for server in [serverA, serverB] {
            await makeProvisioner(server: server, keychain: keychain, deviceToken: token)
                .enable()
        }
        PushHTTPFixture.clearCalls()

        await HermexPushPairingStore(keychain: keychain).unpair(server: serverA, relay: relayClient())

        XCTAssertEqual(PushHTTPFixture.calls,
                       ["DELETE https://hermex-relay.hermex-relay.workers.dev/installs/\(PushHTTPFixture.installKey)/devices/\(token)"])
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
        XCTAssertNotNil(try HermexPushPairingStore(keychain: keychain).load(server: serverB))
    }

    func testAnUnreachableRelayStillWipesTheKeysOnRemoval() async throws {
        let keychain = InMemoryKeychainStore()
        PushHTTPFixture.handler = { _ in nil }
        await makeProvisioner(server: serverA, keychain: keychain, deviceToken: token)
            .enable()
        PushHTTPFixture.handler = { _ in (503, .null) }

        await HermexPushPairingStore(keychain: keychain).unpair(server: serverA, relay: relayClient())

        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA))
    }

    func testAConnectionRemovedWhileSettingUpKeepsItsTeardownFinal() async throws {
        let keychain = InMemoryKeychainStore()
        var isConnected = true
        PushHTTPFixture.handler = { request in
            // The user removes the connection while the host is still being set up.
            if request.url?.path == "/api/gateway/restart" { isConnected = false }
            return nil
        }
        let provisioner = makeProvisioner(server: serverA, keychain: keychain, deviceToken: token,
                                          stillConnected: { isConnected })

        await provisioner.enable()

        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(try HermexPushPairingStore(keychain: keychain).load(server: serverA),
                     "A removal during setup must not be undone by the run that outlived it")
        XCTAssertEqual(PushHTTPFixture.calls.last,
                       "DELETE https://hermex-relay.hermex-relay.workers.dev/installs/\(PushHTTPFixture.installKey)/devices/\(token)",
                       "The phone registered mid-teardown comes back off the relay")
    }

    // MARK: - Fixtures

    private func makeProvisioner(server: URL, keychain: InMemoryKeychainStore, deviceToken: String?,
                                 stillConnected: @escaping @MainActor () -> Bool = { true }) -> HermexPushProvisioner {
        let connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://a.example.com")!,
                                       username: "user", password: "secret")
        return HermexPushProvisioner(
            server: server, connection: connection,
            store: HermexPushPairingStore(keychain: keychain),
            relay: relayClient(),
            dashboard: { BotDashboardClient(connection: $0, configuration: PushHTTPFixture.configuration()) },
            deviceToken: { deviceToken },
            connectionID: { stillConnected() ? connection.id : nil },
            retryDelays: [.zero, .zero, .zero],
            sleep: { _ in }
        )
    }

    private func relayClient() -> HermexPushRelayClient {
        HermexPushRelayClient(configuration: PushHTTPFixture.configuration())
    }
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
            return (200, .object(["relay_url": .string(HermexPushPairing.defaultRelayURL.absoluteString),
                                  "install_key": .string(installKey), "preview_key": .string(previewKey),
                                  "platform": .string("hermex"), "payload_version": .number(1)]))
        default: return (200, .object(["result": .string("ok")]))
        }
    }
}
