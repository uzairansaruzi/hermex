import XCTest
@testable import HermesMobile

/// The pin file is the maintainer-facing record; `BotConnection.testedHermesVersion`
/// is the runtime mirror. Reading the file via `#filePath` keeps it out of the bundle.
final class BotConnectionVersionTests: XCTestCase {
    private var pinFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HermesMobileTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("HERMES_AGENT_TESTED_SHA")
    }

    func testPinFileMatchesRuntimeConstant() throws {
        guard let contents = try? String(contentsOf: pinFile, encoding: .utf8) else {
            throw XCTSkip("Could not read \(pinFile.path); the source tree is not present (physical device or remote runner).")
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3, "commit, release, trailing newline")
        XCTAssertNotNil(lines[0].wholeMatch(of: /[0-9a-f]{40}/), "line 1 is the hermes-agent commit")
        XCTAssertEqual(lines[1], BotConnection.testedHermesVersion, "line 2 is the release /api/status reports")
    }

    func testRecordsSavedBeforeThePinDecodeWithoutAVersion() throws {
        let stored = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Host","address":"http://hermes.local","username":"user","password":"secret"}"#
        let connection = try JSONDecoder().decode(BotConnection.self, from: Data(stored.utf8))
        XCTAssertNil(connection.hermesVersion)
        XCTAssertNil(connection.installID)
    }
}

@MainActor final class BotConnectionSetupTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!

    func testLocalAddressDefaultsHaveNarrowTransportExceptions() throws {
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        // .local and single-label names, which scheme inference sends over HTTP.
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertEqual(Set(domains.keys), Set(["10.0.0.0/8", "127.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                               "169.254.0.0/16", "100.64.0.0/10", "::1", "fc00::/7", "fe80::/10",
                                               "ts.net"]))
        for (range, policy) in domains {
            XCTAssertEqual(policy["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true, range)
        }
        // Tailscale MagicDNS names sit below the tailnet: host.tailnet.ts.net.
        XCTAssertEqual(domains["ts.net"]?["NSIncludesSubdomains"] as? Bool, true)
    }

    func testDismissalDuringCommittedCleanupKeepsSuccessfulResult() async throws {
        for removing in [false, true] {
            let store = BotConnectionStore(keychain: InMemoryKeychainStore())
            let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!, username: "me", password: "old")
            try store.save(old, server: server)
            let parked = expectation(description: "Committed cleanup in flight")
            var release: CheckedContinuation<Void, Never>?
            var cleaned = false
            let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in ConnectionSetupWire() }, discard: { value in
                XCTAssertEqual(value.id, old.id)
                await withCheckedContinuation { release = $0; parked.fulfill() }
                XCTAssertFalse(Task.isCancelled, "Committed cleanup outlives the presenting task")
                cleaned = true
            })
            model.load(); model.username = "replacement"
            let task = Task { removing ? await model.remove() : await model.connect() }
            await fulfillment(of: [parked], timeout: 3)
            XCTAssertEqual(try store.load(server: server), model.saved, "State and persistence commit before cleanup suspends")
            if removing { XCTAssertNil(model.saved) } else { XCTAssertEqual(model.saved?.username, "replacement") }
            model.cancel(); task.cancel()
            release?.resume()
            let result = await task.value
            XCTAssertTrue(result, "Dismissal after commit cannot report the persisted operation as cancelled")
            XCTAssertTrue(cleaned)
            XCTAssertEqual(try store.load(server: server), model.saved)
        }
    }

    func testAddressDefaultsHonorLocalNetworksAndExplicitSchemes() throws {
        let cases = [
            "hermes.example.com": "https://hermes.example.com",
            "machine.tail123.ts.net:443": "https://machine.tail123.ts.net:443",
            "8.8.8.8:9119": "https://8.8.8.8:9119",
            "localhost:9119": "http://localhost:9119",
            "hermes.local:9119": "http://hermes.local:9119",
            "hermes:9119": "http://hermes:9119",
            "10.1.2.3:9119": "http://10.1.2.3:9119",
            "172.16.0.1": "http://172.16.0.1",
            "172.32.0.1": "https://172.32.0.1",
            "192.168.1.4": "http://192.168.1.4",
            "169.254.1.4": "http://169.254.1.4",
            "127.0.0.2": "http://127.0.0.2",
            "100.64.0.1": "http://100.64.0.1",
            "100.128.0.1": "https://100.128.0.1",
            "[::1]:9119": "http://[::1]:9119",
            "fd7a:115c:a1e0::1": "http://[fd7a:115c:a1e0::1]",
            "[fe80::1]:9119": "http://[fe80::1]:9119",
            "[2001:4860::1]:9119": "https://[2001:4860::1]:9119",
            " HTTPS://HERMES.LOCAL:9119/ ": "https://hermes.local:9119",
            "http://public.example": "http://public.example"
        ]
        for (input, expected) in cases {
            XCTAssertEqual(try BotConnection.address(input).absoluteString, expected, input)
        }
        for invalid in ["", " ", "https://", "bad host", "192.168.1.999", "host/path", "host?key=x",
                        "user:pass@host", "host:0", "host:65536", "ftp://host", "host#fragment"] {
            XCTAssertThrowsError(try BotConnection.address(invalid), invalid)
        }
    }

    func testAddressFailureIsVisibleBeforeAClientExists() async {
        let model = BotConnectionSetup(server: server, store: BotConnectionStore(keychain: InMemoryKeychainStore()),
            makeWire: { _ in XCTFail("Invalid input must not create a client"); return ConnectionSetupWire() }, discard: { _ in })
        model.address = "host/not-supported"
        let succeeded = await model.connect()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.errorMessage, BotFailure.invalidAddress.localizedDescription)
        XCTAssertFalse(model.isConnecting)
    }

    func testSuccessOnAnUnknownVersionKeepsSameAccountIdentityAndAllowsDismissal() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!, username: "me", password: "old")
        try store.save(old, server: server)
        let wire = ConnectionSetupWire(); wire.serverVersion = "999.0"
        let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in wire },
                                       discard: { _ in XCTFail("Same account must retain drafts and pairing") })
        model.load(); model.address = "hermes.example"; model.password = "new"
        let succeeded = await model.connect()
        XCTAssertTrue(succeeded, "Every verified successful login can dismiss, irrespective of release")
        XCTAssertNil(model.errorMessage)
        let stored = try XCTUnwrap(store.load(server: server))
        XCTAssertEqual(stored.id, old.id)
        XCTAssertEqual(stored.password, "new")
        XCTAssertEqual(stored.hermesVersion, "999.0")
        XCTAssertGreaterThan(wire.closeCount, 0)
    }

    func testReplacingAnAccountClearsOnlyTheOldConnection() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!, username: "me", password: "old")
        let other = URL(string: "https://other-webui.example")!
        try store.save(old, server: server); try store.save(old, server: other)
        var discarded: [UUID] = []
        let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in ConnectionSetupWire() },
                                       discard: { discarded.append($0.id) })
        model.load(); model.username = "someone-else"
        let succeeded = await model.connect()
        XCTAssertTrue(succeeded)
        XCTAssertNotEqual(model.saved?.id, old.id)
        XCTAssertEqual(discarded, [old.id])
        XCTAssertEqual(try store.load(server: other), old)
    }

    func testFailedLoginAndSaveNeverReportSuccess() async throws {
        let wire = ConnectionSetupWire(); wire.failure = BotFailure.rejected(401)
        let model = BotConnectionSetup(server: server, store: BotConnectionStore(keychain: InMemoryKeychainStore()),
                                       makeWire: { _ in wire }, discard: { _ in XCTFail("Failed login must not discard") })
        model.address = "hermes.example"; model.username = "me"; model.password = "password"
        let loggedIn = await model.connect()
        XCTAssertFalse(loggedIn)
        XCTAssertNil(model.saved)
        XCTAssertEqual(model.errorMessage, BotFailure.rejected(401).localizedDescription)

        let failing = BotConnectionSetup(server: server, store: BotConnectionStore(keychain: ConnectionSetupFailingKeychain()),
            makeWire: { _ in ConnectionSetupWire() }, discard: { _ in XCTFail("Failed save must not discard") })
        failing.address = "hermes.example"; failing.username = "me"; failing.password = "password"
        let saved = await failing.connect()
        XCTAssertFalse(saved)
        XCTAssertEqual(failing.errorMessage, "Could not save sign-in details on this iPhone.")
        XCTAssertNil(failing.saved)
    }

    func testAFailedSignInNamesWhatToCheckAndSavesNothing() async throws {
        let rows: [(Error, String)] = [
            (URLError(.cannotFindHost), "Couldn't find hermes.example. Check the address. For a Tailscale or VPN name, make sure this iPhone is connected to it."),
            (BotFailure.rejected(530), "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host.")
        ]
        for (failure, expected) in rows {
            let store = BotConnectionStore(keychain: InMemoryKeychainStore())
            let wire = ConnectionSetupWire(); wire.failure = failure
            let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in wire },
                                           discard: { _ in XCTFail("A failed sign-in must not discard") })
            model.address = "hermes.example"; model.username = "me"; model.password = "password"
            let succeeded = await model.connect()
            XCTAssertFalse(succeeded)
            XCTAssertEqual(model.errorMessage, expected)
            XCTAssertNil(try store.load(server: server))
        }
    }

    func testANewAddressAndUsernameOnTheSameInstallKeepTheConnection() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let install = String(repeating: "a", count: 32)
        let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "http://192.168.1.4:9119")!,
                                username: "me", password: "old", installID: install)
        try store.save(old, server: server)
        let wire = ConnectionSetupWire(); wire.serverInstallID = install
        let model = BotConnectionSetup(server: server, store: store, makeWire: { wire.connection = $0; return wire },
                                       discard: { _ in XCTFail("The same install keeps drafts, cache and pairing") })
        model.load(); model.address = "hermes.example.com"; model.username = "renamed"
        let succeeded = await model.connect()
        XCTAssertTrue(succeeded)
        XCTAssertNil(wire.connection?.installID, "A new address carries no expectation into the probe")
        let stored = try XCTUnwrap(store.load(server: server))
        XCTAssertEqual(stored.id, old.id)
        XCTAssertEqual(stored.address.absoluteString, "https://hermes.example.com")
        XCTAssertEqual(stored.username, "renamed")
        XCTAssertEqual(stored.installID, install)
    }

    func testAHostOmittingItsInstallIDKeepsTheStoredOne() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let install = String(repeating: "a", count: 32)
        let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!,
                                username: "me", password: "old", installID: install)
        try store.save(old, server: server)
        let wire = ConnectionSetupWire(); wire.serverInstallID = nil
        let model = BotConnectionSetup(server: server, store: store, makeWire: { wire.connection = $0; return wire },
                                       discard: { _ in XCTFail("An omitted id is not another host") })
        model.load(); model.password = "new"
        let succeeded = await model.connect()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(wire.connection?.installID, install, "The saved address must prove the saved install")
        let stored = try XCTUnwrap(store.load(server: server))
        XCTAssertEqual(stored.id, old.id)
        XCTAssertEqual(stored.password, "new")
        XCTAssertEqual(stored.installID, install)
    }

    func testASavedAddressReachingAnotherInstallIsRefusedUntilTheUserReplacesIt() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let old = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!,
                                username: "me", password: "old", installID: String(repeating: "a", count: 32))
        try store.save(old, server: server)
        let other = String(repeating: "b", count: 32)
        let wire = ConnectionSetupWire(); wire.serverInstallID = other
        var discarded: [UUID] = []
        let model = BotConnectionSetup(server: server, store: store, makeWire: { wire.connection = $0; return wire },
                                       discard: { discarded.append($0.id) })
        model.load()
        let refused = await model.connect()
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, BotFailure.differentHost.localizedDescription)
        XCTAssertTrue(model.offersHostReplacement)
        XCTAssertEqual(wire.calls, 0)
        XCTAssertEqual(try store.load(server: server), old, "Nothing is written under the old connection")
        XCTAssertEqual(discarded, [])

        model.address = "elsewhere.example"
        XCTAssertFalse(model.offersHostReplacement, "Editing the address withdraws the data-clearing action")
        model.address = "hermes.example"

        let replaced = await model.connect(replacingHost: true)
        XCTAssertTrue(replaced)
        XCTAssertNil(wire.connection?.installID, "Replacing drops the expectation")
        let stored = try XCTUnwrap(store.load(server: server))
        XCTAssertNotEqual(stored.id, old.id)
        XCTAssertEqual(stored.installID, other)
        XCTAssertEqual(discarded, [old.id])
        XCTAssertFalse(model.offersHostReplacement)
    }

    func testDismissalDropsALateSuccessfulLogin() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let wire = ConnectionSetupWire()
        let parked = expectation(description: "Login in flight")
        wire.park = { parked.fulfill() }
        let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in wire }, discard: { _ in })
        model.address = "hermes.example"; model.username = "me"; model.password = "password"
        let task = Task { await model.connect() }
        await fulfillment(of: [parked], timeout: 3)
        model.cancel()
        wire.continuation?.resume(); wire.continuation = nil
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertNil(try store.load(server: server))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isConnecting)
        XCTAssertEqual(wire.calls, 0, "A dismissed attempt cannot load the roster or save credentials")
    }

    func testStatusCheckReadsOnlyThisServersSavedHost() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        var probed: [URL] = []
        var relayServers: [URL] = []
        let reply = BotHostStatus(.object(["version": .string("0.21.5")]))
        let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in ConnectionSetupWire() }, discard: { _ in },
                                       probe: { probed.append($0); return .success(reply) },
                                       relay: { relayServers.append($0); return URL(string: "https://push.example")! })
        model.load(); await model.checkStatus()
        XCTAssertTrue(probed.isEmpty, "No saved connection means no probe")
        XCTAssertNil(model.hostStatus)

        let saved = BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!, username: "me", password: "pw")
        try store.save(saved, server: server)
        model.load(); await model.checkStatus()
        XCTAssertEqual(probed, [saved.address])
        XCTAssertEqual(model.hostStatus, .reachable(reply))
        XCTAssertEqual(relayServers, [server, server], "Notification state is read for this server only")
        XCTAssertEqual(model.notificationRelay?.host, "push.example")
    }

    func testCancelAndNewerChecksDropALateStatusReply() async throws {
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(BotConnection(id: UUID(), name: "Home", address: URL(string: "https://hermes.example")!,
                                     username: "me", password: "pw"), server: server)
        var pending: [CheckedContinuation<Result<BotHostStatus, BotHostProbeFailure>, Never>] = []
        var parked = expectation(description: "First probe in flight")
        let model = BotConnectionSetup(server: server, store: store, makeWire: { _ in ConnectionSetupWire() }, discard: { _ in },
                                       probe: { _ in await withCheckedContinuation { pending.append($0); parked.fulfill() } },
                                       relay: { _ in nil })
        model.load()
        let first = Task { await model.checkStatus() }
        await fulfillment(of: [parked], timeout: 3)
        XCTAssertEqual(model.hostStatus, .checking)
        model.cancel()
        pending[0].resume(returning: .success(BotHostStatus(.object([:]))))
        await first.value
        XCTAssertEqual(model.hostStatus, .checking, "A reply after cancel() never writes state")

        parked = expectation(description: "Older probe in flight")
        let older = Task { await model.checkStatus() }
        await fulfillment(of: [parked], timeout: 3)
        parked = expectation(description: "Newer probe in flight")
        let newer = Task { await model.checkStatus() }
        await fulfillment(of: [parked], timeout: 3)
        pending[2].resume(returning: .failure(.answered(502)))
        await newer.value
        pending[1].resume(returning: .success(BotHostStatus(.object([:]))))
        await older.value
        XCTAssertEqual(model.hostStatus, .unreachable(.answered(502)), "Only the newest check writes")
    }
}

@MainActor private final class ConnectionSetupWire: BotTransport {
    var replayEpoch: String? = "fixture"
    var serverVersion: String? = "999.0"
    var serverInstallID: String?
    /// The record the setup probed with; `connect()` applies its `install_id` check.
    var connection: BotConnection?
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var failure: Error?
    var park: (() -> Void)?
    var continuation: CheckedContinuation<Void, Never>?
    var closeCount = 0
    var calls = 0
    func connect() async throws {
        if let park { await withCheckedContinuation { continuation = $0; park() } }
        if let failure { throw failure }
        try connection?.requireSameInstall(serverInstallID)
    }
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?(); calls += 1
        XCTAssertEqual(method, "profiles.list")
        return .object(["profiles": .array([])])
    }
    func close() { closeCount += 1 }
}

private struct ConnectionSetupFailingKeychain: KeychainStoring {
    func save(_ value: String, forKey key: KeychainStore.Key) throws { throw CocoaError(.fileWriteNoPermission) }
    func load(_ key: KeychainStore.Key) throws -> String? { nil }
    func delete(_ key: KeychainStore.Key) throws {}
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func load(_ key: KeychainStore.Key, scope: String) throws -> String? { nil }
    func delete(_ key: KeychainStore.Key, scope: String) throws {}
}

/// One assertion per row of #751's copy table. Tests run in English, so the copy is literal.
final class BotConnectionAdviceTests: XCTestCase {
    func testEachConnectionFailureNamesWhatToCheck() {
        let address = URL(string: "https://hermes.example:8443")!
        let find = "Couldn't find hermes.example. Check the address. For a Tailscale or VPN name, make sure this iPhone is connected to it."
        let secure = "Couldn't make a secure connection to hermes.example. Check its certificate. A dashboard on your local network without HTTPS needs http://."
        let proxy = "Your proxy answered, but Hermes didn't. Check that the dashboard is running on the host."
        let tunnel = "Cloudflare can't reach your tunnel. Check that cloudflared and the dashboard are running on the host."
        let rows: [(Error, String)] = [
            (URLError(.cannotFindHost), find),
            (URLError(.dnsLookupFailed), find),
            (URLError(.cannotConnectToHost), "hermes.example refused the connection. Check the port and that the Hermes dashboard is running."),
            (URLError(.timedOut), "hermes.example didn't answer. Check that this iPhone can reach it on this network, or use your tunnel address."),
            (URLError(.notConnectedToInternet), "This iPhone is offline."),
            (URLError(.dataNotAllowed), "This iPhone is offline."),
            (URLError(.secureConnectionFailed), secure),
            (URLError(.serverCertificateUntrusted), secure),
            (URLError(.appTransportSecurityRequiresSecureConnection),
             "iOS blocked this insecure HTTP connection. Use HTTPS, a local network address, or a Tailscale name or IP."),
            (BotFailure.rejected(400), "Hermes doesn't accept hermes.example as its address. On the host, set dashboard.public_url to https://hermes.example:8443, then restart the dashboard."),
            (BotFailure.rejected(403), "Something in front of Hermes, such as Cloudflare Access, blocked the request."),
            (BotFailure.notDashboard, "hermes.example isn't a Hermes dashboard. Use the dashboard address, not the Hermes Web UI."),
            (BotFailure.rejected(429), "Too many sign-in attempts. Wait a minute, then try again."),
            (BotFailure.rejected(502), proxy),
            (BotFailure.rejected(504), proxy),
            (BotFailure.rejected(520), tunnel),
            (BotFailure.rejected(530), tunnel),
            (BotFailure.rejected(401), "Sign in again. Check your Bot connection username and password."),
            (URLError(.networkConnectionLost), "Couldn't reach hermes.example. Check the address and network.")
        ]
        for (error, expected) in rows {
            XCTAssertEqual(BotConnectionAdvice.message(for: error, address: address), expected, "\(error)")
        }
    }
}

/// The public status probe: one credential-free GET whose replies map to screen
/// states. Transport faults use a raw-body fixture so non-JSON replies are testable.
@MainActor final class BotHostStatusTests: XCTestCase {
    private let host = URL(string: "https://hermes.example")!

    override func tearDown() {
        BotStatusHTTPFixture.handler = nil
        super.tearDown()
    }

    private func check(_ status: Int = 200, _ body: String,
                       configuration: URLSessionConfiguration = .ephemeral) async -> Result<BotHostStatus, BotHostProbeFailure> {
        BotStatusHTTPFixture.handler = { _ in (status, Data(body.utf8)) }
        configuration.protocolClasses = [BotStatusHTTPFixture.self]
        return await BotHostStatusProbe(configuration: configuration).check(host)
    }

    func testDecodesTheLiveShapedPayload() async throws {
        let body = #"{"version":"0.21.5","release_date":"2026.9.20","gateway_running":true,"gateway_state":"running","#
            + #""gateway_exit_reason":null,"gateway_heartbeat_stale_s":null,"overall":"ok","gateway_platforms":{"#
            + #""hermex":{"state":"connected","error_code":null,"error_message":null,"updated_at":"2026-09-24T15:56:13Z","#
            + #""needs_attention":false,"retrying_since":null}},"components":{"gateway":{"status":"ok","state":"running"},"#
            + #""platforms":{"status":"degraded","configured":5,"connected":4}},"auth_required":true}"#
        let status = try await check(200, body).get()
        XCTAssertEqual(status.version, "0.21.5")
        XCTAssertEqual(status.gatewayRunning, true)
        XCTAssertEqual(status.gatewayState, "running")
        XCTAssertNil(status.gatewayExitReason)
        XCTAssertNil(status.heartbeatStale)
        XCTAssertEqual(status.platformsConnected, 4)
        XCTAssertEqual(status.platformsConfigured, 5)
        XCTAssertEqual(status.gatewayTitle, String(localized: "Running"))
        XCTAssertNil(status.gatewayNote)
    }

    func testMinimalAndUnknownStatesDecodeTolerantly() async throws {
        let empty = try await check(200, "{}").get()
        XCTAssertEqual(empty, BotHostStatus(.object([:])))
        XCTAssertNil(empty.version)
        XCTAssertEqual(empty.gatewayTitle, String(localized: "Unknown"))
        XCTAssertNil(empty.gatewayNote)

        let unknown = BotHostStatus(.object(["gateway_running": .bool(true), "gateway_state": .string("hibernating")]))
        XCTAssertEqual(unknown.gatewayTitle, String(localized: "Unknown"))
        XCTAssertNil(unknown.gatewayNote)

        let wedged = BotHostStatus(.object(["gateway_running": .bool(true), "gateway_state": .string("running"),
                                            "gateway_heartbeat_stale_s": .number(240)]))
        XCTAssertEqual(wedged.gatewayTitle, String(localized: "Not responding"))
        XCTAssertEqual(wedged.gatewayNote, String(localized: "Scheduled Tasks may not run until it responds."))
    }

    func testStartupFailureShowsItsReasonAndOnlyTheTaskConsequence() async throws {
        let failed = try await check(200, #"{"gateway_running":false,"gateway_state":"startup_failed","#
            + #""gateway_exit_reason":"telegram: Unauthorized"}"#).get()
        XCTAssertEqual(failed.gatewayTitle, String(localized: "Startup failed"))
        let note = try XCTUnwrap(failed.gatewayNote)
        XCTAssertTrue(note.hasPrefix("telegram: Unauthorized"))
        XCTAssertTrue(note.hasSuffix(String(localized: "Scheduled Tasks won’t run until it starts.")))
        XCTAssertFalse(note.localizedCaseInsensitiveContains("notification"), "Chat notifications do not depend on the gateway")

        let stopped = BotHostStatus(.object(["gateway_running": .bool(false), "gateway_state": .string("stopped")]))
        XCTAssertEqual(stopped.gatewayTitle, String(localized: "Stopped"))
        XCTAssertEqual(stopped.gatewayNote, String(localized: "Scheduled Tasks won’t run until it starts."))
    }

    func testProbeSendsNoCredentialsOrCookies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        var seen: URLRequest?
        BotStatusHTTPFixture.handler = { request in seen = request; return (200, Data("{}".utf8)) }
        configuration.protocolClasses = [BotStatusHTTPFixture.self]
        let probe = BotHostStatusProbe(configuration: configuration)
        XCTAssertNil(probe.configuration.httpCookieStorage, "The session can neither send nor keep cookies")
        XCTAssertFalse(probe.configuration.httpShouldSetCookies)
        XCTAssertNil(probe.configuration.urlCredentialStorage)
        XCTAssertEqual(probe.configuration.timeoutIntervalForRequest, 15)
        _ = try await probe.check(host).get()
        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://hermes.example/api/status")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
    }

    func testFailuresMapToScreenStatesWithoutChatCopy() async {
        let html = await check(200, "<html>Sign in</html>")
        let array = await check(200, "[1, 2]")
        let badGateway = await check(502, "Bad gateway")
        let blocked = await check(403, "error code: 1010")
        XCTAssertEqual(html, .failure(.notHermes))
        XCTAssertEqual(array, .failure(.notHermes))
        XCTAssertEqual(badGateway, .failure(.answered(502)))
        XCTAssertEqual(blocked, .failure(.blocked))
        BotStatusHTTPFixture.handler = { _ in throw URLError(.timedOut) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotStatusHTTPFixture.self]
        guard case .failure(.unreachable(let reason)) = await BotHostStatusProbe(configuration: configuration).check(host) else {
            return XCTFail("A transport error reads as unreachable")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}

private final class BotStatusHTTPFixture: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
