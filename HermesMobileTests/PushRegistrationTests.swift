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

    func testLocalCompletionSuppressionFollowsServerPairingAndDisable() async throws {
        let harness = Harness()
        harness.deliverTokenOnRegister("ab12")
        try await harness.registrar.enable(harness.pairing(install: installA), for: serverA)
        let scheduler = CompletionScheduler()
        func schedule(_ server: URL) async -> Bool {
            await ResponseCompletionNotificationService.scheduleResponseCompletedIfAllowed(
                sessionID: "same-id", preferenceEnabled: true, completedNormally: true,
                sceneIsActive: false, server: server,
                isPushPaired: { harness.registrar.pairing(for: $0) != nil }, scheduler: scheduler)
        }
        let paired = await schedule(serverA)
        let unpaired = await schedule(serverB)
        XCTAssertFalse(paired)
        XCTAssertTrue(unpaired)
        try await harness.registrar.disable(for: serverA)
        let disabled = await schedule(serverA)
        XCTAssertTrue(disabled)
        XCTAssertEqual(scheduler.count, 2)
    }

    func testForgetWipesTheKeysEvenWhenTheRelayCannotBeReached() async throws {
        let harness = Harness()
        harness.deliverTokenOnRegister(String(repeating: "ab", count: 32))
        try await harness.registrar.enable(harness.pairing(install: installA), for: serverA)
        harness.relay.deleteError = PushRelayError.transport

        await harness.registrar.forget(for: serverA)

        XCTAssertNil(try harness.store.pairing(for: serverA),
                     "A removed connection may not leave credentials behind")
        XCTAssertEqual(harness.remoteNotifications.unregisterCount, 1,
                       "The last pairing gone means this phone stops minting tokens")
    }

    func testOlderPairingsAndPartialPreferencesKeepRelayDefaults() throws {
        let original = Harness().pairing(install: installA, registeredToken: "abcd")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PushPairing.self, from: encoded)
        XCTAssertNil(decoded.preferences)
        XCTAssertEqual(decoded.effectivePreferences, PushPreferences())
        let partial = try JSONDecoder().decode(PushPreferences.self, from: Data(#"{"previews":false,"future":true}"#.utf8))
        XCTAssertEqual(partial, PushPreferences(previews: false))
        XCTAssertTrue(partial.presenceSuppression, "Only the app enforces it, so it defaults on unlike the relay")
    }

    func testPreferencesPersistForOnlyTheirServerAndSurviveRefreshAndRotation() async throws {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        harness.store.pairings[serverB] = harness.pairing(install: installB, registeredToken: "abcd")
        let choices = PushPreferences(replies: false, muteSubagents: false, previews: false)
        try await harness.registrar.updatePreferences(choices, for: serverA, expectedPairing: original)
        let stored = try XCTUnwrap(harness.store.pairings[serverA])
        XCTAssertEqual(try JSONDecoder().decode(PushPairing.self, from: JSONEncoder().encode(stored)).effectivePreferences, choices)
        XCTAssertEqual(harness.store.pairings[serverB]?.effectivePreferences, PushPreferences())
        harness.registrar.refreshOnLaunch()
        await harness.deliverToken("abcd")
        await harness.deliverToken("1234")
        XCTAssertTrue(harness.relay.registrations.filter { $0.installKey == installA }.allSatisfy { $0.preferences == choices })
        XCTAssertTrue(harness.relay.registrations.filter { $0.installKey == installB }.allSatisfy { $0.preferences == PushPreferences() })
        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "1234")
    }

    func testPreferenceFailureKeepsTheConfirmedValuesAndCanRetry() async throws {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        harness.relay.registerError = PushRelayError.transport
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original),
            PushRegistrarError.preferencesUnconfirmed)
        XCTAssertEqual(harness.store.pairings[serverA]?.effectivePreferences, original.effectivePreferences)
        XCTAssertEqual(harness.store.pairings[serverA]?.preferencesNeedSync, true)
        harness.relay.registerError = nil
        try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original)
        XCTAssertEqual(harness.store.pairings[serverA]?.effectivePreferences.previews, false)
    }

    func testPreferenceKeychainFailureRestoresRelayChoices() async {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        harness.store.failedSaveAttempts = [2]
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original),
            PushRelayError.transport)
        XCTAssertEqual(harness.store.pairings[serverA], original)
        XCTAssertEqual(harness.relay.registrations.map(\.preferences), [PushPreferences(previews: false), PushPreferences()])
    }

    func testUnavailableKeychainStopsPreferencesBeforeChangingTheRelay() async {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        harness.store.saveError = PushRelayError.transport
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original),
            PushRelayError.transport)
        XCTAssertTrue(harness.relay.registrations.isEmpty)
        XCTAssertEqual(harness.store.pairings[serverA], original)
    }

    func testFailedCommitAndRollbackStayUnconfirmedAcrossRelaunchUntilRefresh() async throws {
        let harness = Harness()
        var original = harness.pairing(install: installA, registeredToken: "abcd")
        original.preferences = PushPreferences(previews: false)
        harness.store.pairings[serverA] = original
        harness.store.failedSaveAttempts = [2]
        harness.relay.failedRegisterAttempts = [2]
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: true), for: serverA, expectedPairing: original),
            PushRegistrarError.preferencesUnconfirmed)
        let pending = try XCTUnwrap(harness.store.pairings[serverA])
        XCTAssertEqual(pending.effectivePreferences.previews, false)
        XCTAssertEqual(pending.preferencesNeedSync, true)
        XCTAssertEqual(harness.relay.registrations.map(\.preferences.previews), [true])
        // Persisted uncertainty survives a new process, including when the token
        // is unchanged. A failed launch refresh must not clear it either.
        harness.store.pairings[serverA] = try JSONDecoder().decode(PushPairing.self, from: JSONEncoder().encode(pending))
        let relaunched = PushRegistrar(store: harness.store, relay: harness.relay,
            remoteNotifications: harness.remoteNotifications, authorization: harness.authorization,
            identity: PushBuildIdentity(bundleID: "com.uzairansar.hermesmobile", environment: .sandbox))
        harness.relay.registerError = PushRelayError.transport
        relaunched.refreshOnLaunch()
        relaunched.didRegisterForRemoteNotifications(deviceToken: Data(hex: "abcd"))
        await relaunched.finishPendingRegistrations()
        XCTAssertEqual(harness.store.pairings[serverA]?.preferencesNeedSync, true)
        harness.relay.registerError = nil
        relaunched.refreshOnLaunch()
        relaunched.didRegisterForRemoteNotifications(deviceToken: Data(hex: "abcd"))
        await relaunched.finishPendingRegistrations()
        XCTAssertNil(harness.store.pairings[serverA]?.preferencesNeedSync)
        XCTAssertEqual(harness.store.pairings[serverA]?.effectivePreferences.previews, false)
        XCTAssertEqual(harness.relay.registrations.last?.preferences.previews, false)
    }

    func testDisableWhilePreferencesSaveCannotRestoreThePairing() async {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        harness.relay.duringRegister = { [serverA] in try? await harness.registrar.disable(for: serverA) }
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original),
            PushRegistrarError.pairingChanged)
        XCTAssertNil(harness.store.pairings[serverA])
        XCTAssertEqual(harness.relay.deletions.map(\.token), ["abcd", "abcd"])
    }

    func testOldSettingsCannotChangeAReplacementPairing() async {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = harness.pairing(install: installB, registeredToken: "abcd")
        await XCTAssertThrowsErrorAsync(
            try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original),
            PushRegistrarError.pairingChanged)
        XCTAssertTrue(harness.relay.registrations.isEmpty)
    }

    func testRefreshQueuedDuringPreferenceSaveUsesConfirmedChoices() async throws {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        let entered = expectation(description: "preference request entered")
        var release: CheckedContinuation<Void, Never>?
        harness.relay.duringRegister = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let saving = Task { try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(harness.store.pairings[serverA]?.effectivePreferences, original.effectivePreferences,
                       "Never claim success before the relay accepts")
        XCTAssertEqual(harness.store.pairings[serverA]?.preferencesNeedSync, true)
        harness.registrar.refreshOnLaunch()
        harness.registrar.didRegisterForRemoteNotifications(deviceToken: Data(hex: "1234"))
        release?.resume()
        try await saving.value
        await harness.registrar.finishPendingRegistrations()
        XCTAssertEqual(harness.relay.registrations.map(\.preferences.previews), [false, false])
        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "1234")
        XCTAssertEqual(harness.store.pairings[serverA]?.effectivePreferences.previews, false)
    }

    func testPreferenceSaveQueuedDuringRefreshUsesRotatedToken() async throws {
        let harness = Harness()
        let original = harness.pairing(install: installA, registeredToken: "abcd")
        harness.store.pairings[serverA] = original
        let entered = expectation(description: "refresh request entered")
        var release: CheckedContinuation<Void, Never>?
        harness.relay.duringRegister = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        harness.registrar.refreshOnLaunch()
        harness.registrar.didRegisterForRemoteNotifications(deviceToken: Data(hex: "1234"))
        await fulfillment(of: [entered], timeout: 2)
        let saving = Task { try await harness.registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original) }
        release?.resume()
        try await saving.value
        XCTAssertEqual(harness.relay.registrations.map(\.token), ["1234", "1234"])
        XCTAssertEqual(harness.relay.registrations.map(\.preferences.previews), [true, false])
        XCTAssertEqual(harness.store.pairings[serverA]?.registeredToken, "1234")
    }

    func testPreferenceChangeDoesNotRetireALiveActivity() async {
        let wire = ActivityRelaySpy()
        var keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "activity")
        keys.preferences = PushPreferences(previews: false)
        XCTAssertTrue(registrar.isRegistered("a"))
        await registrar.refresh()
        XCTAssertEqual(wire.calls.map(\.action), ["put:activity"])
    }

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

    func testBuiltAppDeclaresBothTheEntitlementMirrorAndTheAccessGroup() {
        // Hosted XCTest runs inside the signed app, including contributor builds
        // that use a local bundle identifier instead of the shipping identity.
        let appBundle = Bundle.main
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

        var pairing = PushPairing(relayURL: relay, installKey: installA, previewKey: "k")
        pairing.preferences = PushPreferences(replies: false, muteSubagents: false, previews: false)
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
        XCTAssertEqual(Set(json.keys), ["device_token", "bundle_id", "environment", "prefs"])
        XCTAssertEqual(json["device_token"] as? String, "0a1b")
        XCTAssertEqual(json["bundle_id"] as? String, "com.uzairansar.hermesmobile")
        XCTAssertEqual(json["environment"] as? String, "sandbox")
        XCTAssertEqual(json["prefs"] as? [String: Bool],
                       ["replies": false, "mute_subagents": false, "previews": false, "presence_suppression": true])
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

    func testActivityRelayUsesOneEncodedSessionSegmentAndExactBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = PushRelayClient(session: URLSession(configuration: configuration))
        let recorded = RecordedRequest()
        MockURLProtocol.requestHandler = { request in
            recorded.store(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }
        let pairing = PushPairing(relayURL: relay, installKey: installA, previewKey: "k")
        try await client.registerActivity(token: "aabb", sessionID: "session/a%? #", deviceToken: "ccdd", pairing: pairing)
        XCTAssertEqual(recorded.request?.httpMethod, "PUT")
        XCTAssertTrue(recorded.request?.url?.absoluteString.hasSuffix("/activities/session%2Fa%25%3F%20%23") == true)
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(recorded.body))
        XCTAssertEqual(body, ["activity_token": "aabb"])
        let url = recorded.request?.url
        try await client.deleteActivity(sessionID: "session/a%? #", deviceToken: "ccdd", pairing: pairing)
        XCTAssertEqual(recorded.request?.httpMethod, "DELETE")
        XCTAssertEqual(recorded.request?.url, url)
    }

    func testActivityTokenRotationAndServersStayScoped() async {
        let wire = ActivityRelaySpy()
        let a = PushPairing(relayURL: relay, installKey: installA, previewKey: "a", registeredToken: "device-a")
        let b = PushPairing(relayURL: relay, installKey: installB, previewKey: "b", registeredToken: "device-b")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { [serverA] in $0 == serverA ? a : b })
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "first")
        await registrar.register(owner: "b", server: serverB, sessionID: "runtime", token: "other")
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "rotated")
        await registrar.retire(owner: "a")
        XCTAssertEqual(wire.calls.map(\.action), ["put:first", "put:other", "delete", "put:rotated", "delete"])
        XCTAssertEqual(wire.calls.map(\.install), [installA, installB, installA, installA, installA])
        XCTAssertFalse(registrar.isRegistered("a"))
        XCTAssertTrue(registrar.isRegistered("b"))
    }

    func testUnpairedAndFailedRegistrationNeverClaimBackgroundFreshness() async {
        let wire = ActivityRelaySpy()
        var keys: PushPairing?
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "token")
        XCTAssertTrue(wire.calls.isEmpty)
        XCTAssertFalse(registrar.isRegistered("a"))
        keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        wire.failure = true
        await registrar.refresh()
        XCTAssertFalse(registrar.isRegistered("a"))
        wire.failure = false
        await registrar.refresh()
        XCTAssertTrue(registrar.isRegistered("a"))
        keys = nil
        XCTAssertFalse(registrar.isRegistered("a"))
        await registrar.refresh()
        XCTAssertEqual(wire.calls.last?.action, "delete")
    }

    func testHandoffWaitsForAnActivityTokenThatArrivesLater() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "token")
        let registered = await handoff.value
        XCTAssertTrue(registered)
    }

    func testHandoffReportsARegistrationTheRelayRejected() async {
        let wire = ActivityRelaySpy()
        wire.failure = true
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "token")
        let registered = await handoff.value
        XCTAssertFalse(registered)
    }

    func testHandoffWaitsForAPutAlreadyInFlight() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let entered = expectation(description: "PUT entered")
        var release: CheckedContinuation<Void, Never>?
        wire.hold = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let register = Task { await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "token") }
        await fulfillment(of: [entered], timeout: 2)
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        release?.resume()
        await register.value
        let registered = await handoff.value
        XCTAssertTrue(registered)
    }

    func testHandoffFollowsATokenRotatedDuringThePut() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let entered = expectation(description: "first PUT entered")
        var release: CheckedContinuation<Void, Never>?
        wire.hold = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let first = Task { await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "old") }
        await fulfillment(of: [entered], timeout: 2)
        wire.hold = nil
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        let rotated = Task { await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "new") }
        await Task.yield()
        release?.resume()
        await first.value
        await rotated.value
        let registered = await handoff.value
        XCTAssertTrue(registered)
        XCTAssertEqual(wire.calls.last?.action, "put:new")
    }

    func testCancellingAHandoffEndsItsWaitAtOnce() async {
        let registrar = PushActivityRegistrar(relay: ActivityRelaySpy(), pairing: { _ in nil })
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        handoff.cancel()
        let registered = await handoff.value
        XCTAssertFalse(registered)
    }

    func testHandoffGivesUpWhenNoActivityTokenArrives() async {
        let registrar = PushActivityRegistrar(relay: ActivityRelaySpy(), pairing: { _ in nil })
        let registered = await registrar.awaitRegistration("a", limit: .zero)
        XCTAssertFalse(registered)
    }

    func testRetiringAnActivityEndsItsHandoffWait() async {
        let registrar = PushActivityRegistrar(relay: ActivityRelaySpy(), pairing: { _ in nil })
        let handoff = Task { await registrar.awaitRegistration("a", limit: .seconds(30)) }
        await Task.yield()
        await registrar.retire(owner: "a")
        let registered = await handoff.value
        XCTAssertFalse(registered)
    }

    func testRetiringDuringPutDeletesBeforeTheReplacementRegisters() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let entered = expectation(description: "first PUT entered")
        var release: CheckedContinuation<Void, Never>?
        wire.hold = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let first = Task { await registrar.register(owner: "old", server: serverA, sessionID: "runtime", token: "old") }
        await fulfillment(of: [entered], timeout: 2)
        let retiring = expectation(description: "retirement queued")
        let retire = Task {
            retiring.fulfill()
            await registrar.retire(owner: "old")
        }
        await fulfillment(of: [retiring], timeout: 2)
        wire.hold = nil
        let replacement = Task { await registrar.register(owner: "new", server: serverA, sessionID: "runtime", token: "new") }
        release?.resume()
        await first.value
        await retire.value
        await replacement.value
        XCTAssertEqual(wire.calls.map(\.action), ["put:old", "delete", "put:new"])
        XCTAssertFalse(registrar.isRegistered("old"))
        XCTAssertTrue(registrar.isRegistered("new"))
    }

    func testDeviceRefreshRepublishesActivitiesAndForgetCannotReviveThem() async {
        let wire = ActivityRelaySpy()
        var keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "old-device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        await registrar.register(owner: "a", server: serverA, sessionID: "runtime", token: "activity")
        keys.registeredToken = "new-device"
        await registrar.refresh(republish: true)
        XCTAssertEqual(wire.calls.map(\.action), ["put:activity", "delete", "put:activity"])
        wire.failure = true
        await registrar.refresh(republish: true)
        XCTAssertFalse(registrar.isRegistered("a"))
        wire.failure = false
        await registrar.refresh()
        XCTAssertTrue(registrar.isRegistered("a"))
        await registrar.forget(server: serverA)
        let count = wire.calls.count
        await registrar.refresh(republish: true)
        XCTAssertEqual(wire.calls.count, count)
        XCTAssertFalse(registrar.isRegistered("a"))
    }

    func testFailedRetirementBlocksReplacementUntilCleanupSucceeds() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        await registrar.register(owner: "old", server: serverA, sessionID: "runtime", token: "old")
        wire.failure = true
        await registrar.retire(owner: "old")
        await registrar.register(owner: "new", server: serverA, sessionID: "runtime", token: "new")
        XCTAssertFalse(wire.calls.contains { $0.action == "put:new" })
        wire.failure = false
        await registrar.refresh()
        XCTAssertEqual(wire.calls.last?.action, "put:new")
        XCTAssertTrue(registrar.isRegistered("new"))
    }

    func testRelaunchedActivityCanDeleteItsRegistrationWithoutSeeingAToken() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        await registrar.retire(owner: "persisted", server: serverA, sessionID: "runtime")
        XCTAssertEqual(wire.calls.map(\.action), ["delete"])
    }

    /// A finished activity's cleanup (cold launch or an orphaned webui run, #566) must
    /// not delete the route a new run in the same session is still registering.
    func testRelaunchedActivityCleanupSparesARegistrationInFlightForTheSameSession() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let entered = expectation(description: "PUT entered")
        var release: CheckedContinuation<Void, Never>?
        wire.hold = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let register = Task { await registrar.register(owner: "new", server: serverA, sessionID: "runtime", token: "token") }
        await fulfillment(of: [entered], timeout: 2)
        let retire = Task { await registrar.retire(owner: "persisted", server: serverA, sessionID: "runtime") }
        await Task.yield()
        release?.resume()
        await register.value
        await retire.value
        XCTAssertEqual(wire.calls.map(\.action), ["put:token"])
        XCTAssertTrue(registrar.isRegistered("new"))
    }

    /// If that replacement's PUT fails, nothing holds the route any more, so the
    /// finished activity's cleanup still deletes it.
    func testRelaunchedActivityCleanupDeletesTheRouteWhenTheReplacementFails() async {
        let wire = ActivityRelaySpy()
        let keys = PushPairing(relayURL: relay, installKey: installA, previewKey: "k", registeredToken: "device")
        let registrar = PushActivityRegistrar(relay: wire, pairing: { _ in keys })
        let entered = expectation(description: "PUT entered")
        var release: CheckedContinuation<Void, Never>?
        wire.hold = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        wire.failure = true
        let register = Task { await registrar.register(owner: "new", server: serverA, sessionID: "runtime", token: "token") }
        await fulfillment(of: [entered], timeout: 2)
        let retire = Task { await registrar.retire(owner: "persisted", server: serverA, sessionID: "runtime") }
        await Task.yield()
        release?.resume()
        await register.value
        await retire.value
        XCTAssertEqual(wire.calls.map(\.action), ["put:token", "delete"])
        XCTAssertFalse(registrar.isRegistered("new"))
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
        await registrar.finishPendingRegistrations()
    }
}

@MainActor
private final class InMemoryPushPairingStore: PushPairingStoring {
    var pairings: [URL: PushPairing] = [:]
    var saveError: (any Error)?
    var failedSaveAttempts: Set<Int> = []
    private var saveAttempts = 0

    func pairing(for server: URL) throws -> PushPairing? { pairings[server] }
    func save(_ pairing: PushPairing, for server: URL) throws {
        saveAttempts += 1
        if failedSaveAttempts.contains(saveAttempts) { throw PushRelayError.transport }
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
        let preferences: PushPreferences
    }

    struct Deletion: Equatable {
        let token: String
        let installKey: String
    }

    private(set) var registrations: [Registration] = []
    private(set) var deletions: [Deletion] = []
    var registerError: (any Error)?
    var failedRegisterAttempts: Set<Int> = []
    private var registerAttempts = 0
    var deleteError: (any Error)?

    func reset() {
        registrations = []
        deletions = []
    }

    /// Runs while a registration is suspended, so a test can land a concurrent
    /// disable the way a user tapping the button would.
    var duringRegister: (() async -> Void)?

    func registerDevice(token: String, identity: PushBuildIdentity, pairing: PushPairing) async throws {
        registerAttempts += 1
        if failedRegisterAttempts.contains(registerAttempts) { throw PushRelayError.transport }
        if let duringRegister {
            self.duringRegister = nil
            await duringRegister()
        }
        if let registerError { throw registerError }
        registrations.append(Registration(token: token, installKey: pairing.installKey,
                                          environment: identity.environment, bundleID: identity.bundleID,
                                          preferences: pairing.effectivePreferences))
    }

    func deleteDevice(token: String, pairing: PushPairing) async throws {
        if let deleteError { throw deleteError }
        deletions.append(Deletion(token: token, installKey: pairing.installKey))
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

@MainActor private final class ActivityRelaySpy: PushActivityRelaying {
    struct Call { let action: String; let install: String; let session: String }
    var calls: [Call] = []
    var hold: (() async -> Void)?
    var failure = false
    func registerActivity(token: String, sessionID: String, deviceToken: String, pairing: PushPairing) async throws {
        calls.append(Call(action: "put:" + token, install: pairing.installKey, session: sessionID))
        await hold?()
        if failure { throw PushRelayError.transport }
    }
    func deleteActivity(sessionID: String, deviceToken: String, pairing: PushPairing) async throws {
        calls.append(Call(action: "delete", install: pairing.installKey, session: sessionID))
        if failure { throw PushRelayError.transport }
    }
}

private final class CompletionScheduler: ResponseCompletionNotificationScheduling {
    var count = 0
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> Bool { true }
    func schedule(_ request: ResponseCompletionNotificationRequest) async { count += 1 }
}
