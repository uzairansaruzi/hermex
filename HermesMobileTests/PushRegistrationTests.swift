import XCTest
import UserNotifications
@testable import HermesMobile

@MainActor
final class PushRegistrationTests: XCTestCase {
    private let serverA = URL(string: "https://a.example.com")!
    private let serverB = URL(string: "https://b.example.com")!
    private let relay = URL(string: "https://relay.example.com")!
    private let installA = String(repeating: "a", count: 64)
    private let installB = String(repeating: "b", count: 64)

    // MARK: - Build identity

    /// Branch TestFlight is a production build even though its bundle ID looks
    /// like a dev one, so the environment must follow the signed entitlement.
    func testEnvironmentFollowsTheSignedEntitlementNotTheBundleSuffix() {
        let branchProduction = TestBundle(
            values: ["HermesAPSEnvironment": "production", "CFBundleIdentifier": "com.uzairansar.hermesmobile.branch"]
        )
        XCTAssertEqual(PushEnvironment.current(bundle: branchProduction), .production)

        let branchDevelopment = TestBundle(values: ["HermesAPSEnvironment": "development"])
        XCTAssertEqual(PushEnvironment.current(bundle: branchDevelopment), .sandbox)
    }

    /// An unreadable entitlement mirror must not be guessed at: a token registered
    /// under the wrong environment is rejected by Apple and revoked by the relay.
    func testUnknownEntitlementValueYieldsNoEnvironment() {
        XCTAssertNil(PushEnvironment(entitlementValue: "sandbox"))
        XCTAssertNil(PushEnvironment.current(bundle: TestBundle(values: [:])))
    }

    func testShippingBuildDeclaresBothTheEntitlementMirrorAndTheAccessGroup() {
        let bundle = Bundle(for: PushRegistrationTests.self)
        let appBundle = Bundle(identifier: "com.uzairansar.hermesmobile") ?? bundle
        XCTAssertNotNil(PushEnvironment.current(bundle: appBundle),
                        "HermesAPSEnvironment must mirror the aps-environment entitlement")
        let group = appBundle.object(forInfoDictionaryKey: "HermesKeychainAccessGroup") as? String
        XCTAssertEqual(group?.isEmpty, false,
                       "HermesKeychainAccessGroup must name the group the extension shares")
    }

    // MARK: - Enable

    func testEnableRegistersAtTheRelayAndStoresTheToken() async throws {
        let harness = Harness()
        harness.deliverTokenOnRegister("0A1b")

        try await harness.registrar.enable(harness.pairing(install: installA), for: serverA)

        XCTAssertEqual(harness.relay.registrations.count, 1)
        let registration = try XCTUnwrap(harness.relay.registrations.first)
        XCTAssertEqual(registration.token, "0a1b")
        XCTAssertEqual(registration.installKey, installA)
        XCTAssertEqual(registration.environment, .sandbox)
        XCTAssertEqual(registration.bundleID, "com.uzairansar.hermesmobile")
        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "0a1b")
    }

    /// Permission is asked for at the Enable action, and a refusal must leave the
    /// app exactly as it was: no token minted, nothing stored.
    func testEnableWithoutPermissionNeverAsksForATokenOrStoresAnything() async {
        let harness = Harness()
        harness.authorization.granted = false

        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.enable(harness.pairing(install: installA), for: serverA),
            PushRegistrarError.permissionDenied
        )
        XCTAssertEqual(harness.remoteNotifications.registerCount, 0)
        XCTAssertTrue(harness.store.pairings.isEmpty)
        XCTAssertTrue(harness.relay.registrations.isEmpty)
    }

    /// Never store a pairing the relay did not accept: the Enable action would
    /// report success for notifications that can never arrive.
    func testEnableStoresNothingWhenTheRelayRejectsTheDevice() async {
        let harness = Harness()
        harness.deliverTokenOnRegister("0a1b")
        harness.relay.registerError = PushRelayError.http(statusCode: 409)

        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.enable(harness.pairing(install: installA), for: serverA),
            PushRelayError.http(statusCode: 409)
        )
        XCTAssertTrue(harness.store.pairings.isEmpty)
    }

    func testEnableRejectsAMalformedInstallKeyBeforeTouchingTheRelay() async {
        let harness = Harness()
        harness.deliverTokenOnRegister("0a1b")

        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.enable(harness.pairing(install: "not-hex"), for: serverA),
            PushRegistrarError.malformedPairing
        )
        XCTAssertTrue(harness.relay.registrations.isEmpty)
        XCTAssertEqual(harness.remoteNotifications.registerCount, 0)
    }

    // MARK: - Launch refresh and rotation

    /// An unpaired user is never prompted and never mints a token.
    func testLaunchRefreshAsksForNoTokenWithoutAPairing() {
        let harness = Harness()
        harness.registrar.refreshOnLaunch()
        XCTAssertEqual(harness.remoteNotifications.registerCount, 0)
    }

    /// The relay can revoke a device on its own, so a stored registration is
    /// re-sent on every launch rather than assumed to still hold.
    func testLaunchRefreshReregistersEveryPairedServer() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0a1b")
        harness.store.pairings[serverB] = harness.pairing(install: installB, registeredToken: "0a1b")

        harness.registrar.refreshOnLaunch()
        XCTAssertEqual(harness.remoteNotifications.registerCount, 1)
        await harness.deliverToken("0a1b")

        XCTAssertEqual(Set(harness.relay.registrations.map(\.installKey)), [installA, installB])
        XCTAssertTrue(harness.relay.deletions.isEmpty)
    }

    /// A rotated token has to reach every install, and the dead one has to be
    /// retired there so the relay is not left fanning out to a revoked device.
    func testRotatedTokenIsRegisteredEverywhereAndTheOldOneIsDeleted() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0dd0")
        harness.store.pairings[serverB] = harness.pairing(install: installB, registeredToken: "0dd0")

        await harness.deliverToken("0dd0")
        harness.relay.reset()
        await harness.deliverToken("5ee5")

        XCTAssertEqual(Set(harness.relay.registrations.map(\.token)), ["5ee5"])
        XCTAssertEqual(Set(harness.relay.registrations.map(\.installKey)), [installA, installB])
        XCTAssertEqual(Set(harness.relay.deletions.map(\.token)), ["0dd0"])
        XCTAssertEqual(Set(harness.relay.deletions.map(\.installKey)), [installA, installB])
        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "5ee5")
        XCTAssertEqual(harness.store.pairings[serverB]?.registeredToken, "5ee5")
    }

    /// One server's install key never addresses another's: a rotation reaches each
    /// relay with its own capability and nothing crosses over.
    func testEachServerIsRegisteredUnderItsOwnInstallKey() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0dd0")
        harness.store.pairings[serverB] = harness.pairing(install: installB, registeredToken: "0dd0")

        await harness.deliverToken("0dd0")
        harness.relay.reset()
        await harness.deliverToken("5ee5")

        XCTAssertEqual(harness.relay.registrations.filter { $0.installKey == installA }.count, 1)
        XCTAssertEqual(harness.relay.registrations.filter { $0.installKey == installB }.count, 1)
    }

    /// A relay that is down must not unpair the user; the next launch retries.
    func testAFailedReregistrationLeavesThePairingIntact() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0dd0")
        await harness.deliverToken("0dd0")
        harness.relay.registerError = PushRelayError.transport

        await harness.deliverToken("5ee5")

        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "0dd0")
        XCTAssertNotNil(harness.store.pairings[serverA])
    }

    // MARK: - Disable

    func testDisableRemovesTheDeviceAtTheRelayThenWipesTheKeys() async throws {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0a1b")

        try await harness.registrar.disable(for: serverA)

        XCTAssertEqual(harness.relay.deletions.map(\.installKey), [installA])
        XCTAssertNil(harness.store.pairings[serverA])
        XCTAssertEqual(harness.remoteNotifications.unregisterCount, 1)
    }

    /// Wiping the install key while the relay still holds the device would leave a
    /// phone buzzing with nothing left to address it, so a failure changes nothing.
    func testDisableKeepsTheKeysWhenTheRelayCallFails() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0a1b")
        harness.relay.deleteError = PushRelayError.transport

        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.disable(for: serverA),
            PushRelayError.transport
        )
        XCTAssertNotNil(harness.store.pairings[serverA])
        XCTAssertEqual(harness.remoteNotifications.unregisterCount, 0)
    }

    /// Disabling one of two paired servers leaves the other receiving pushes.
    func testDisablingOneServerKeepsTheOtherRegistered() async throws {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0a1b")
        harness.store.pairings[serverB] = harness.pairing(install: installB, registeredToken: "0a1b")

        try await harness.registrar.disable(for: serverA)

        XCTAssertNil(harness.store.pairings[serverA])
        XCTAssertEqual(harness.store.pairings[serverB]?.installKey, installB)
        XCTAssertEqual(harness.remoteNotifications.unregisterCount, 0)
    }

    /// A disable that lands while a launch refresh is registering must win: the
    /// keys stay gone and the device it just registered is retired again.
    func testDisableDuringALaunchRefreshIsNotUndone() async {
        let harness = Harness()
        harness.store.pairings[serverA] = harness.pairing(install: installA, registeredToken: "0dd0")
        harness.relay.duringRegister = { [registrar = harness.registrar, serverA] in
            try? await registrar.disable(for: serverA)
        }

        harness.registrar.refreshOnLaunch()
        await harness.deliverToken("5ee5")

        XCTAssertNil(harness.store.pairings[serverA])
        XCTAssertEqual(harness.relay.deletions.map(\.token), ["0dd0", "5ee5"])
    }

    /// Without stored keys nothing could ever revoke the device, so a Keychain
    /// write that fails takes the relay registration down with it.
    func testEnableUndoesTheRelayRegistrationWhenTheKeychainWriteFails() async {
        struct KeychainFailure: Error, Equatable {}
        let harness = Harness()
        harness.deliverTokenOnRegister("0a1b")
        harness.store.saveError = KeychainFailure()

        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.enable(harness.pairing(install: installA), for: serverA),
            KeychainFailure()
        )
        XCTAssertTrue(harness.store.pairings.isEmpty)
        XCTAssertEqual(harness.relay.deletions.map(\.token), ["0a1b"])
    }

    // MARK: - Relay wire shape

    func testRelayRegistrationSendsTheStrictBodyToTheInstallsPath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = PushRelayClient(session: URLSession(configuration: configuration))
        let recorded = RecordedRequest()
        MockURLProtocol.requestHandler = { request in
            recorded.store(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let pairing = PushPairing(relayURL: relay, installKey: installA, previewKey: "k")
        try await client.registerDevice(
            token: "0a1b",
            identity: PushBuildIdentity(bundleID: "com.uzairansar.hermesmobile", environment: .sandbox),
            pairing: pairing
        )

        let request = try XCTUnwrap(recorded.request)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/installs/\(installA)/devices")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(recorded.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // The relay rejects unknown fields with a 400, so the body is exactly these.
        XCTAssertEqual(Set(json.keys), ["device_token", "bundle_id", "environment"])
        XCTAssertEqual(json["device_token"] as? String, "0a1b")
        XCTAssertEqual(json["bundle_id"] as? String, "com.uzairansar.hermesmobile")
        XCTAssertEqual(json["environment"] as? String, "sandbox")
    }

    func testRelayDeleteAddressesTheDeviceTokenAndSurfacesTheStatus() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = PushRelayClient(session: URLSession(configuration: configuration))
        let recorded = RecordedRequest()
        MockURLProtocol.requestHandler = { request in
            recorded.store(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }

        let pairing = PushPairing(relayURL: relay, installKey: installA, previewKey: "k")
        await XCTAssertThrowsErrorAsync(
            try await client.deleteDevice(token: "0a1b", pairing: pairing),
            PushRelayError.http(statusCode: 503)
        )
        XCTAssertEqual(recorded.request?.url?.absoluteString,
                       "https://relay.example.com/installs/\(installA)/devices/0a1b")
        XCTAssertEqual(recorded.request?.httpMethod, "DELETE")
    }

    // MARK: - Keychain access group

    /// The real store, in the real shared access group: the pairing round-trips,
    /// stays scoped to its server, and is discoverable by enumeration — which is
    /// how the Notification Service Extension will find a preview key.
    func testPairingsRoundTripPerServerInTheSharedAccessGroup() throws {
        let store = try XCTUnwrap(KeychainPushPairingStore(), "the app build must declare a Keychain access group")
        addTeardownBlock { [serverA, serverB] in
            await MainActor.run {
                try? store.remove(for: serverA)
                try? store.remove(for: serverB)
            }
        }
        do {
            try store.save(PushPairing(relayURL: relay, installKey: installA, previewKey: "keyA"), for: serverA)
        } catch {
            // CI compiles with CODE_SIGNING_ALLOWED=NO, which strips entitlements,
            // so there is no access group to write to. On a signed build this runs.
            // That the group is declared at all is covered above from Info.plist.
            throw XCTSkip("Keychain access groups need a signed build: \(error)")
        }
        try store.save(PushPairing(relayURL: relay, installKey: installB, previewKey: "keyB"), for: serverB)

        XCTAssertEqual(try store.pairing(for: serverA)?.installKey, installA)
        XCTAssertEqual(try store.pairing(for: serverB)?.previewKey, "keyB")
        let all = try store.allPairings()
        XCTAssertEqual(all[serverA]?.installKey, installA)
        XCTAssertEqual(all[serverB]?.installKey, installB)

        try store.remove(for: serverA)
        XCTAssertNil(try store.pairing(for: serverA))
        XCTAssertEqual(try store.pairing(for: serverB)?.installKey, installB)
    }

    func testScopedKeysRoundTripThroughTheServerURL() {
        let key = KeychainPushPairingStore.key(for: serverA)
        XCTAssertEqual(KeychainPushPairingStore.scope(fromKey: key), serverA.absoluteString)
        XCTAssertNil(KeychainPushPairingStore.scope(fromKey: "custom_headers::https://a.example.com"))
    }
}

// MARK: - Harness

@MainActor
private final class Harness {
    let store = InMemoryPushPairingStore()
    let relay = RecordingPushRelay()
    let remoteNotifications = RecordingRemoteNotifications()
    let authorization = StubNotificationAuthorization()
    let registrar: PushRegistrar

    init() {
        registrar = PushRegistrar(
            store: store,
            relay: relay,
            remoteNotifications: remoteNotifications,
            authorization: authorization,
            identity: PushBuildIdentity(bundleID: "com.uzairansar.hermesmobile", environment: .sandbox)
        )
    }

    func pairing(install: String, registeredToken: String? = nil) -> PushPairing {
        PushPairing(
            relayURL: URL(string: "https://relay.example.com")!,
            installKey: install,
            previewKey: "preview",
            registeredToken: registeredToken
        )
    }

    /// Mirrors APNs: the token arrives through the delegate after the app asked,
    /// never synchronously from the call.
    func deliverTokenOnRegister(_ hex: String) {
        remoteNotifications.onRegister = { [weak self] in
            Task { @MainActor in self?.registrar.didRegisterForRemoteNotifications(deviceToken: Data(hex: hex)) }
        }
    }

    /// Delivers a token and lets the registrar's follow-up work finish.
    func deliverToken(_ hex: String) async {
        registrar.didRegisterForRemoteNotifications(deviceToken: Data(hex: hex))
        await relay.settled()
    }
}

@MainActor
private final class InMemoryPushPairingStore: PushPairingStoring {
    var pairings: [URL: PushPairing] = [:]
    var saveError: (any Error)?

    func pairing(for server: URL) throws -> PushPairing? { pairings[server] }
    func save(_ pairing: PushPairing, for server: URL) throws {
        if let saveError { throw saveError }
        pairings[server] = pairing
    }
    func remove(for server: URL) throws { pairings[server] = nil }
    func allPairings() throws -> [URL: PushPairing] { pairings }
}

@MainActor
private final class RecordingPushRelay: PushRelayRegistering {
    struct Registration: Equatable {
        let token: String
        let installKey: String
        let environment: PushEnvironment
        let bundleID: String
    }

    struct Deletion: Equatable {
        let token: String
        let installKey: String
    }

    private(set) var registrations: [Registration] = []
    private(set) var deletions: [Deletion] = []
    var registerError: (any Error)?
    var deleteError: (any Error)?

    func reset() {
        registrations = []
        deletions = []
    }

    /// Runs while a registration is suspended, so a test can land a concurrent
    /// disable the way a user tapping the button would.
    var duringRegister: (() async -> Void)?

    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws {
        if let duringRegister {
            self.duringRegister = nil
            await duringRegister()
        }
        if let registerError { throw registerError }
        registrations.append(Registration(token: token, installKey: pairing.installKey,
                                          environment: identity.environment, bundleID: identity.bundleID))
    }

    func deleteDevice(token: String, pairing: PushPairing) async throws {
        if let deleteError { throw deleteError }
        deletions.append(Deletion(token: token, installKey: pairing.installKey))
    }

    /// Lets the registrar's detached refresh run to completion. Each yield drains
    /// one hop of the main-actor queue; the refresh is a bounded chain of awaits,
    /// never a timed wait.
    func settled() async {
        for _ in 0..<12 { await Task.yield() }
    }
}

@MainActor
private final class RecordingRemoteNotifications: RemoteNotificationRegistering {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var onRegister: (() -> Void)?

    func registerForRemoteNotifications() {
        registerCount += 1
        onRegister?()
    }

    func unregisterForRemoteNotifications() {
        unregisterCount += 1
    }
}

private struct StubNotificationAuthorization: ResponseCompletionNotificationScheduling {
    final class Box: @unchecked Sendable { var granted = true }
    private let box = Box()
    var granted: Bool {
        get { box.granted }
        nonmutating set { box.granted = newValue }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { granted ? .authorized : .denied }
    func requestAuthorization() async -> Bool { granted }
    func schedule(_ request: ResponseCompletionNotificationRequest) async {}
}

private final class TestBundle: Bundle, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    override var bundleIdentifier: String? { values["CFBundleIdentifier"] ?? "com.uzairansar.hermesmobile" }
}

private final class RecordedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: URLRequest?
    private var recordedBody: Data?

    func store(_ request: URLRequest) {
        let body = apiTestBodyData(from: request)
        lock.withLock {
            recorded = request
            recordedBody = body
        }
    }

    var request: URLRequest? { lock.withLock { recorded } }
    var body: Data? { lock.withLock { recordedBody } }
}

private extension Data {
    /// The registrar hexes the token back out, so a test token that is not valid
    /// hex would quietly compare equal to every other invalid one.
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2), "device token fixtures are whole bytes")
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("device token fixtures are hex")
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private func XCTAssertThrowsErrorAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
