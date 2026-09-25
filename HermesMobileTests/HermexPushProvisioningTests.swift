import UserNotifications
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

    func testPermissionRevokedDuringSetupSaysNotificationsAreOffAndLeavesNothingPaired() async throws {
        let registrar = FakePushRegistrar()
        registrar.enableError = PushRegistrarError.permissionDenied
        PushHTTPFixture.handler = { _ in nil }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertTrue(provisioner.notificationsOff)
        XCTAssertNil(provisioner.failure, "Denied permission is not a host failure")
        XCTAssertFalse(provisioner.isWorking)
        XCTAssertTrue(provisioner.showsSteps, "The host was already changed, so its finished steps stay visible")
        XCTAssertEqual(provisioner.completed, [.relayURL, .install, .restart, .pair])
        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(registrar.pairing(for: serverA))
    }

    func testAHostReportingAnotherInstallIDIsNeverSignedInOrChanged() async throws {
        let saved = String(repeating: "a", count: 32)
        for (live, refused) in [(String(repeating: "b", count: 32), true), (saved, false)] {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { request in
                guard request.url?.path == "/api/status" else { return nil }
                return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                      "install_id": .string(live)]))
            }
            let registrar = FakePushRegistrar()
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, installID: saved)

            await provisioner.enable()

            if refused {
                XCTAssertEqual(provisioner.failure?.message, BotFailure.differentHost.localizedDescription)
                XCTAssertEqual(PushHTTPFixture.calls, ["GET https://a.example.com/api/status"],
                               "No password or change reaches the other host")
                XCTAssertEqual(registrar.actions, [])
            } else {
                XCTAssertNil(provisioner.failure)
                XCTAssertNotNil(registrar.pairing(for: serverA))
            }
        }
    }

    func testDeniedPermissionStopsSetupBeforeAnyHostCall() async throws {
        // A status a future iOS adds counts as not allowed, like a denial.
        let unknown = try XCTUnwrap(UNAuthorizationStatus(rawValue: 99))
        for (status, grants) in [(UNAuthorizationStatus.denied, true), (.notDetermined, false), (unknown, true)] {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { _ in nil }
            let registrar = FakePushRegistrar()
            let permission = FakeNotificationPermission(status: status, grants: grants)
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, notifications: permission)

            await provisioner.enable()

            XCTAssertTrue(provisioner.notificationsOff, "\(status.rawValue)")
            XCTAssertEqual(provisioner.phase, .idle)
            XCTAssertNil(provisioner.failure)
            XCTAssertFalse(provisioner.showsSteps, "Nothing ran, so there are no steps to show")
            XCTAssertEqual(PushHTTPFixture.calls, [], "The host is never touched for a phone that cannot show a push")
            XCTAssertEqual(registrar.actions, [])
            XCTAssertEqual(permission.requests, status == .notDetermined ? 1 : 0,
                           "iOS is asked only when it has never been asked")
        }
    }

    func testAFirstRunAsksForPermissionBeforeAnyHostStep() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let permission = FakeNotificationPermission(status: .notDetermined, grants: true)
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, notifications: permission)
        var phaseDuringPrompt: HermexPushProvisioner.Phase?
        var stepsDuringPrompt: Bool?
        permission.onRequest = {
            phaseDuringPrompt = provisioner.phase
            stepsDuringPrompt = provisioner.showsSteps
        }

        await provisioner.enable()

        XCTAssertEqual(permission.hostCallsBeforeRequest, [0])
        XCTAssertEqual(phaseDuringPrompt, .checkingPermission, "The prompt claims no host step")
        XCTAssertEqual(stepsDuringPrompt, false)
        XCTAssertFalse(provisioner.notificationsOff)
        XCTAssertNil(provisioner.failure)
        XCTAssertNotNil(registrar.pairing(for: serverA))
        XCTAssertTrue(PushHTTPFixture.calls.contains("POST https://a.example.com/api/gateway/restart"))
    }

    func testAllowingNotificationsInSettingsClearsTheNoticeWithoutRerunningSetup() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let permission = FakeNotificationPermission(status: .denied)
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, notifications: permission)
        await provisioner.enable()
        XCTAssertTrue(provisioner.notificationsOff)

        permission.status = .authorized
        await provisioner.recheckNotificationPermission()

        XCTAssertFalse(provisioner.notificationsOff)
        XCTAssertEqual(provisioner.phase, .idle)
        XCTAssertEqual(PushHTTPFixture.calls, [])
        XCTAssertEqual(registrar.actions, [], "Setup stays behind its confirmation")
    }

    func testAPairedServerSaysNotificationsAreOffWhenPermissionIsLaterDenied() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { _ in nil }
        let permission = FakeNotificationPermission(status: .authorized)
        let paired = makeProvisioner(server: serverA, registrar: registrar, notifications: permission)
        await paired.enable()
        let unpaired = makeProvisioner(server: serverB, registrar: registrar, notifications: permission)

        permission.status = .denied
        await paired.recheckNotificationPermission()
        await unpaired.recheckNotificationPermission()

        XCTAssertTrue(paired.notificationsOff)
        XCTAssertFalse(unpaired.notificationsOff, "An unpaired server shows the notice only after a setup attempt")
        permission.status = .authorized
        await paired.recheckNotificationPermission()
        XCTAssertFalse(paired.notificationsOff)
    }

    func testOnlyAnUnreachableHostAtSignInSaysItCouldNotBeReached() async throws {
        PushHTTPFixture.isUnreachable = true
        let unreachable = makeProvisioner(server: serverA, registrar: FakePushRegistrar())
        await unreachable.enable()
        XCTAssertEqual(unreachable.failure, HermexPushProvisioner.Failure(
            title: "Sign in to Hermes",
            message: "Could not reach this Hermes host. Check the connection, then try again."))

        PushHTTPFixture.reset()
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/status" ? (200, .object(["auth_required": .bool(false)])) : nil
        }
        let noPassword = makeProvisioner(server: serverA, registrar: FakePushRegistrar())
        await noPassword.enable()
        XCTAssertEqual(noPassword.failure, HermexPushProvisioner.Failure(
            title: "Sign in to Hermes",
            message: "This Hermes host doesn’t offer the password sign-in push setup needs."))
        XCTAssertEqual(PushHTTPFixture.calls, ["GET https://a.example.com/api/status"])
    }

    func testEachFailureNamesWhatAnsweredIt() {
        let unusable = HermexPushFailure.unusablePairing.errorDescription
        let cases: [(any Error, String?)] = [
            (PushRegistrarError.permissionDenied, "Allow notifications for Hermex in iOS Settings, then turn this on again."),
            (PushRegistrarError.unsupportedBuild, "This build of Hermex can’t receive push notifications."),
            (PushRegistrarError.tokenUnavailable, "iOS gave no notification token. Check this iPhone’s internet connection, then try again."),
            (PushRegistrarError.malformedPairing, unusable),
            (PushRegistrarError.pairingChanged, "This step did not finish. Try again."),
            (PushRegistrarError.preferencesUnconfirmed, "This step did not finish. Try again."),
            (PushRelayError.malformedInstallKey, unusable),
            (PushRelayError.http(statusCode: 409), "The relay refused this phone (409). Check the relay address, then try again."),
            (PushRelayError.transport, "Could not reach the notification relay. Check this iPhone’s internet connection, then try again."),
            (BotFailure.unsupported, "This Hermes host doesn’t offer the password sign-in push setup needs."),
            (BotFailure.wrongIdentity, "This Hermes host doesn’t offer the password sign-in push setup needs."),
            (BotFailure.rejected(401), "This Hermes host rejected the saved sign-in. Update the Hermes connection, then try again."),
            (URLError(.timedOut), "The host did not answer in time. It may still be finishing this step — wait a moment, then try again."),
            (CocoaError(.fileWriteUnknown), "This step did not finish. Try again.")
        ]
        for (error, expected) in cases {
            XCTAssertEqual(HermexPushProvisioner.message(for: error), expected, "\(error)")
        }
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

        XCTAssertEqual(provisioner.failure?.message, "The relay refused this phone (503). Check the relay address, then try again.")
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

    func testSettingsShowsOnlyConfirmedPreferencesAndKeepsFailureRetryable() async throws {
        let registrar = FakePushRegistrar()
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        let original = try XCTUnwrap(provisioner.pairing)
        let entered = expectation(description: "preferences saving")
        var release: CheckedContinuation<Void, Never>?
        registrar.duringPreferenceSave = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let saving = Task { await provisioner.updatePreferences(PushPreferences(previews: false)) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(provisioner.isWorking)
        XCTAssertEqual(provisioner.pairing, original)
        registrar.preferenceError = PushRelayError.transport
        release?.resume()
        await saving.value
        XCTAssertFalse(provisioner.isWorking)
        XCTAssertNotNil(provisioner.failure)
        XCTAssertEqual(provisioner.pairing, original)
        registrar.duringPreferenceSave = nil
        registrar.preferenceError = nil
        await provisioner.updatePreferences(PushPreferences(previews: false))
        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(provisioner.pairing?.effectivePreferences.previews, false)
    }

    func testCancelledSettingsSaveDoesNotPublishBackIntoTheOldScreen() async throws {
        let registrar = FakePushRegistrar()
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        let original = try XCTUnwrap(provisioner.pairing)
        let entered = expectation(description: "preferences saving")
        var release: CheckedContinuation<Void, Never>?
        registrar.duringPreferenceSave = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let saving = Task { await provisioner.updatePreferences(PushPreferences(previews: false)) }
        await fulfillment(of: [entered], timeout: 2)
        saving.cancel()
        provisioner.leaveSettings()
        release?.resume()
        await saving.value
        XCTAssertEqual(provisioner.pairing, original)
        XCTAssertEqual(provisioner.phase, .idle)
        XCTAssertEqual(registrar.pairing(for: serverA)?.effectivePreferences.previews, false)
    }

    func testReopeningSettingsWaitsForThePreviousPreferenceTransaction() async throws {
        let registrar = FakePushRegistrar()
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        let original = try XCTUnwrap(provisioner.pairing)
        let waiting = expectation(description: "return waits for pending registration")
        var release: CheckedContinuation<Void, Never>?
        registrar.pendingRegistrations = {
            await withCheckedContinuation { release = $0; waiting.fulfill() }
        }
        let reloading = Task { await provisioner.reload() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertTrue(provisioner.isWorking)
        XCTAssertEqual(provisioner.pairing, original)
        try await registrar.updatePreferences(PushPreferences(previews: false), for: serverA, expectedPairing: original)
        release?.resume()
        await reloading.value
        XCTAssertFalse(provisioner.isWorking)
        XCTAssertEqual(provisioner.pairing?.effectivePreferences.previews, false)
    }

    func testSettingsReconcilesAnUnconfirmedPairingAndKeepsFailedRetryVisible() async throws {
        let registrar = FakePushRegistrar()
        var pending = PushPairing(relayURL: URL(string: "https://relay.example")!,
                                  installKey: String(repeating: "a", count: 64), previewKey: "key")
        pending.preferencesNeedSync = true
        try await registrar.enable(pending, for: serverA)
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        registrar.preferenceError = PushRegistrarError.preferencesUnconfirmed
        await provisioner.reload()
        XCTAssertEqual(provisioner.pairing?.preferencesNeedSync, true)
        XCTAssertNotNil(provisioner.failure)
        registrar.preferenceError = nil
        await provisioner.reload()
        XCTAssertNil(provisioner.pairing?.preferencesNeedSync)
        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(provisioner.pairing?.effectivePreferences, PushPreferences())
    }

    private func makeProvisioner(server: URL, registrar: FakePushRegistrar, installID: String? = nil,
                                 notifications: FakeNotificationPermission = FakeNotificationPermission(status: .authorized),
                                 stillConnected: @escaping @MainActor () -> Bool = { true }) -> HermexPushProvisioner {
        let connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://a.example.com")!,
                                       username: "user", password: "secret", installID: installID)
        return HermexPushProvisioner(
            server: server, connection: connection,
            registrar: registrar,
            notifications: notifications,
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

    var pendingRegistrations: (() async -> Void)?
    func finishPendingRegistrations() async { await pendingRegistrations?() }

    var preferenceError: (any Error)?
    var duringPreferenceSave: (() async -> Void)?
    func updatePreferences(_ preferences: PushPreferences, for server: URL, expectedPairing: PushPairing) async throws {
        await duringPreferenceSave?()
        if let preferenceError { throw preferenceError }
        pairings[server]?.preferences = preferences
        pairings[server]?.preferencesNeedSync = nil
    }

    func pairing(for server: URL) -> PushPairing? { pairings[server] }

    func clearActions() { actions = [] }
}

/// iOS notification permission. A request answers `grants` and settles the status the way
/// iOS does, and records how many host calls had already gone out when it was asked.
private final class FakeNotificationPermission: ResponseCompletionNotificationScheduling, @unchecked Sendable {
    var status: UNAuthorizationStatus
    let grants: Bool
    private(set) var hostCallsBeforeRequest: [Int] = []
    var requests: Int { hostCallsBeforeRequest.count }
    /// Runs while the prompt is up, so a test can read the provisioner's state behind it.
    var onRequest: (@MainActor () -> Void)?

    init(status: UNAuthorizationStatus, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async -> Bool {
        hostCallsBeforeRequest.append(PushHTTPFixture.calls.count)
        await onRequest?()
        if status == .notDetermined { status = grants ? .authorized : .denied }
        return status == .authorized
    }

    func schedule(_ request: ResponseCompletionNotificationRequest) async {}
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
    /// Every request fails the way an unreachable host does.
    nonisolated(unsafe) static var isUnreachable = false
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
    static func reset() { handler = nil; isSetUp = false; isUnreachable = false; clearCalls() }

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
        if Self.isUnreachable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
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
