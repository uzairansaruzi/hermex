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

    /// An access proxy's refusal, a host with browser sign-in only and a release older than
    /// the minimum stop setup at sign-in with words the user can act on, before the password
    /// goes out.
    func testSignInStopsBeforeThePasswordWithCopyTheUserCanActOn() async throws {
        let rows: [((Int, BotJSON), String)] = [
            // A proxy's 401 page: not the webui's JSON object.
            ((401, .null), "Something in front of Hermes, such as Cloudflare Access, wants its own sign-in first. Add its service token under Connection Headers in the Hermes connection, or use an address that skips it, such as the dashboard's local network address."),
            ((200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("nous")])])),
             "This Hermes host only offers sign-in with a browser, which Hermex doesn't support yet. To connect now, add a dashboard username and password on the host."),
            ((200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]), "version": .string("0.21.2")])),
             "This Hermes host runs 0.21.2. Hermex needs Hermes 0.21.3 or later. Update Hermes on the host, then try again.")
        ]
        for (status, message) in rows {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { request in request.url?.path == "/api/status" ? status : nil }
            let provisioner = makeProvisioner(server: serverA, registrar: FakePushRegistrar())
            await provisioner.enable()
            XCTAssertEqual(provisioner.failure, HermexPushProvisioner.Failure(title: "Sign in to Hermes", message: message))
            XCTAssertEqual(PushHTTPFixture.calls, ["GET https://a.example.com/api/status"])
        }
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
            // The shared sign-in reads a status 404, a JSON 401 or a non-JSON body as another kind of server.
            (BotFailure.notDashboard, "This Hermes host doesn’t offer the password sign-in push setup needs."),
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

    // MARK: - Test notification (#874)

    func testATestNotificationIsOneRequestAndReportsDelivery() async throws {
        let registrar = FakePushRegistrar()
        let pairing = PushPairing(relayURL: URL(string: "https://relay.example")!,
                                  installKey: String(repeating: "a", count: 64), previewKey: "key")
        try await registrar.enable(pairing, for: serverA)
        var sent: [String] = []
        let entered = expectation(description: "test sending")
        var release: CheckedContinuation<Void, Never>?
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, testSender: {
            sent.append($0.installKey)
            await withCheckedContinuation { release = $0; entered.fulfill() }
            return .delivered
        })
        XCTAssertTrue(provisioner.canSendTest)

        let first = Task { await provisioner.sendTestNotification() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(provisioner.isWorking)
        XCTAssertFalse(provisioner.canSendTest)
        await provisioner.sendTestNotification()
        release?.resume()
        await first.value

        XCTAssertEqual(sent, [String(repeating: "a", count: 64)], "A second tap while sending sends nothing")
        XCTAssertTrue(provisioner.testDelivered)
        XCTAssertNil(provisioner.failure)
        XCTAssertFalse(provisioner.isWorking)
        provisioner.leaveSettings()
        XCTAssertFalse(provisioner.testDelivered, "Leaving Settings clears the result")
    }

    func testEachTestOutcomeSaysWhatAnsweredIt() async throws {
        let registrar = FakePushRegistrar()
        try await registrar.enable(PushPairing(relayURL: URL(string: "https://relay.example")!,
                                               installKey: String(repeating: "a", count: 64), previewKey: "key"),
                                   for: serverA)
        let cases: [(PushRelayTestOutcome, String)] = [
            (.unreachable, "Couldn’t reach the relay. Check this iPhone’s internet connection, then try again."),
            (.rejected(statusCode: 503, result: "apns_rejected"),
             "Apple refused the test notification. Turn notifications off and on again for this server."),
            (.rejected(statusCode: 503, result: "delivery_retry"),
             "The relay couldn’t deliver the test right now (HTTP 503). Try again in a few minutes."),
            (.rejected(statusCode: 503, result: "temporarily_unavailable"),
             "The relay couldn’t deliver the test right now (HTTP 503). Try again in a few minutes."),
            (.rejected(statusCode: 429, result: "event_limit"),
             "The relay couldn’t deliver the test right now (HTTP 429). Try again in a few minutes."),
            (.rejected(statusCode: 429, result: nil),
             "The relay’s hosting refused the request (HTTP 429). The relay may be over its daily limit or switched off."),
            (.rejected(statusCode: 400, result: "invalid_request"), "The relay couldn’t deliver (HTTP 400)."),
            (.unusablePairing, "This Hermes host returned pairing keys Hermex cannot use. Update the hermex-push plugin.")
        ]
        for (outcome, message) in cases {
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, testSender: { _ in outcome })
            await provisioner.sendTestNotification()
            // Keys an old plugin sent are the one answer updating the plugin fixes (#851).
            let remedy: HermexPushProvisioner.Failure.Remedy = outcome == .unusablePairing ? .updatePlugin : .none
            XCTAssertEqual(provisioner.failure, HermexPushProvisioner.Failure(title: "Test notification failed", message: message,
                                                                              remedy: remedy),
                           "\(outcome)")
            XCTAssertFalse(provisioner.testDelivered)
            // The next action replaces the result.
            await provisioner.updatePreferences(PushPreferences())
            XCTAssertNil(provisioner.failure)
        }
    }

    func testReplyNotificationsOffOrNotificationsDeniedMakeTheTestUnavailable() async throws {
        let registrar = FakePushRegistrar()
        var pairing = PushPairing(relayURL: URL(string: "https://relay.example")!,
                                  installKey: String(repeating: "a", count: 64), previewKey: "key")
        pairing.preferences = PushPreferences(replies: false)
        try await registrar.enable(pairing, for: serverA)
        var sent = 0
        let permission = FakeNotificationPermission(status: .authorized)
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, notifications: permission,
                                          testSender: { _ in sent += 1; return .delivered })

        // The relay would skip the banner yet still answer accepted.
        XCTAssertFalse(provisioner.canSendTest)
        await provisioner.sendTestNotification()
        XCTAssertEqual(sent, 0)

        await provisioner.updatePreferences(PushPreferences(replies: true))
        XCTAssertTrue(provisioner.canSendTest)
        permission.status = .denied
        await provisioner.recheckNotificationPermission()
        XCTAssertFalse(provisioner.canSendTest)
        await provisioner.sendTestNotification()
        XCTAssertEqual(sent, 0)

        let unpaired = makeProvisioner(server: serverB, registrar: registrar, testSender: { _ in sent += 1; return .delivered })
        XCTAssertFalse(unpaired.canSendTest)
        await unpaired.sendTestNotification()
        XCTAssertEqual(sent, 0)
    }

    // MARK: - Plugin update (#851)

    private let newest = HermexPushPlugin.newestVersion.description

    func testThePairingRouteAndTheHubReportPluginVersionsTolerantly() throws {
        let version = try XCTUnwrap(HermexPushPluginVersion("0.3.0"))
        XCTAssertEqual(HermexPushPlugin.loadedVersion(PushHTTPFixture.pairingBody(version: "0.3.0")), version)
        // A plugin older than 0.2.0 sends no version; nothing unparseable is guessed at.
        for body in [PushHTTPFixture.pairingBody(version: nil), .object(["plugin_version": .number(3)]),
                     PushHTTPFixture.pairingBody(version: "0.3.x"), PushHTTPFixture.pairingBody(version: "")] {
            XCTAssertNil(HermexPushPlugin.loadedVersion(body), "\(body)")
        }
        // The version rides beside the keys, whose decode stays strict.
        XCTAssertEqual(try HermexPushPlugin.pairing(PushHTTPFixture.pairingBody(version: "0.3.0")).installKey,
                       PushHTTPFixture.installKey)

        let hub = BotJSON.object(["plugins": .array([
            .object(["name": .string("other"), "version": .string("9.0.0")]),
            .object(["name": .string("hermex-push"), "version": .string("0.3.0")])
        ])])
        XCTAssertEqual(HermexPushPlugin.installedVersion(hub: hub), version)
        XCTAssertNil(HermexPushPlugin.installedVersion(hub: .object(["plugins": .array([])])))
        XCTAssertNil(HermexPushPlugin.installedVersion(hub: .null))

        // Numeric order, not string order.
        XCTAssertLessThan(try XCTUnwrap(HermexPushPluginVersion("0.9.0")), try XCTUnwrap(HermexPushPluginVersion("0.10.0")))
        XCTAssertEqual(HermexPushPluginVersion("0.3"), version)
    }

    func testSettingsReadsAPairedHostAndOffersAnUpdateForAnOlderPlugin() async throws {
        let registrar = try await pairedRegistrar(serverA)
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: nil))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.1.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.checkPlugin()

        XCTAssertEqual(provisioner.pluginCard, .status(.available(loaded: nil)))
        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "GET https://a.example.com/api/plugins/hermex-push/pairing",
            "GET https://a.example.com/api/dashboard/plugins/hub"
        ], "Only reads: nothing on the host changes without a confirmed tap")
        XCTAssertEqual(registrar.actions, [])
    }

    func testAHostOnTheNewestPluginIsReadOnceAndShowsNoCard() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let newest = newest
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? (200, PushHTTPFixture.pairingBody(version: newest)) : nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.checkPlugin()

        XCTAssertNil(provisioner.pluginCard)
        XCTAssertEqual(PushHTTPFixture.calls.filter { $0.contains("/api/plugins/hermex-push/pairing") }.count, 1)
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/plugins/hub") },
                       "The hub is read only for a plugin that is behind")

        PushHTTPFixture.clearCalls()
        await makeProvisioner(server: serverB, registrar: registrar).checkPlugin()
        XCTAssertEqual(PushHTTPFixture.calls, [], "A server without push is not checked")
    }

    func testUpdatingReinstallsRestartsAndReadsTheNewlyLoadedVersion() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let newest = newest
        var restarted = false
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/gateway/restart": restarted = true; return nil
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: restarted ? newest : "0.2.0"))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.2.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()
        XCTAssertEqual(provisioner.pluginCard, .status(.available(loaded: HermexPushPluginVersion("0.2.0"))))
        PushHTTPFixture.clearCalls()

        await provisioner.updatePlugin()

        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            // Off first: Hermes refuses the dashboard's reinstall of an enabled plugin that
            // declares Python packages; the install turns it back on.
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable",
            "POST https://a.example.com/api/dashboard/agent-plugins/install",
            "POST https://a.example.com/api/gateway/restart",
            "GET https://a.example.com/api/plugins/hermex-push/pairing"
        ])
        let install = PushHTTPFixture.body(of: "POST https://a.example.com/api/dashboard/agent-plugins/install")
        XCTAssertEqual(install["identifier"].text, "https://github.com/uzairansaruzi/hermex-push.git/plugin")
        XCTAssertEqual(install["force"].flag, true, "A reinstall over the loaded copy, cloned again from main")
        XCTAssertEqual(install["enable"].flag, true)
        XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(HermexPushPlugin.newestVersion)))
        XCTAssertFalse(provisioner.isWorking)
        XCTAssertNotNil(provisioner.pairing)
        XCTAssertEqual(registrar.actions, [], "The keys live in plugin-data, so nothing is paired again")

        provisioner.leaveSettings()
        XCTAssertNil(provisioner.pluginCard, "Up to date shows until Settings closes")
    }

    func testAnUpdateTheDashboardHasNotLoadedAsksForARestartUntilTheNewVersionAnswers() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let newest = newest
        var installed = false
        var dashboardRestarted = false
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/dashboard/agent-plugins/install": installed = true; return nil
            // The gateway restart leaves the dashboard process, and the code it loaded, running.
            case "/api/plugins/hermex-push/pairing":
                return (200, PushHTTPFixture.pairingBody(version: dashboardRestarted ? newest : nil))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: installed ? newest : "0.1.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()

        await provisioner.updatePlugin()

        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: nil)))

        // Settings opened again before the host restarts: the host, not this iPhone, says so.
        let reopened = makeProvisioner(server: serverA, registrar: registrar)
        await reopened.checkPlugin()
        XCTAssertEqual(reopened.pluginCard, .status(.restartNeeded(loaded: nil)))

        dashboardRestarted = true
        PushHTTPFixture.clearCalls()
        await reopened.checkPluginAgain()

        XCTAssertEqual(reopened.pluginCard, .status(.upToDate(HermexPushPlugin.newestVersion)))
        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "GET https://a.example.com/api/plugins/hermex-push/pairing"
        ], "Check again is one read")
    }

    func testAFailedReinstallTurnsThePluginBackOnAndInterruptsNothing() async throws {
        let registrar = try await pairedRegistrar(serverA)
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/dashboard/agent-plugins/install": return (400, .null)
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: nil))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()
        PushHTTPFixture.clearCalls()

        await provisioner.updatePlugin()

        XCTAssertEqual(provisioner.pluginCard, .failed(HermexPushProvisioner.Failure(
            title: "Couldn’t reinstall the plugin",
            message: "This Hermes host refused the step (HTTP 400). Check the host’s logs, then try again.",
            remedy: .retryUpdate)))
        XCTAssertEqual(PushHTTPFixture.calls.suffix(3), [
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable",
            "POST https://a.example.com/api/dashboard/agent-plugins/install",
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/enable"
        ], "A refused install turns the plugin back on, so the next restart keeps push, and restarts nothing")
        XCTAssertFalse(provisioner.isWorking)
        XCTAssertNotNil(provisioner.pairing)
        XCTAssertEqual(registrar.actions, [])
    }

    func testAnUpdateThatCannotTurnThePluginBackOnSaysPushStopsAtTheNextRestart() async throws {
        let registrar = try await pairedRegistrar(serverA)
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/dashboard/agent-plugins/install": return (400, .null)
            case "/api/dashboard/agent-plugins/hermex-push/enable": return (502, .null)
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: nil))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()

        await provisioner.updatePlugin()

        XCTAssertEqual(provisioner.pluginCard, .failed(HermexPushProvisioner.Failure(
            title: "Couldn’t reinstall the plugin",
            message: "Hermes still has the plugin turned off, so notifications stop when Hermes restarts. Try again to turn it back on.",
            remedy: .retryUpdate)))
    }

    func testATurnOffThatFailsIsUndoneBeforeAnythingIsInstalled() async throws {
        let registrar = try await pairedRegistrar(serverA)
        var enableFails = false
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            // The host may have applied the change before the answer was lost.
            case "/api/dashboard/agent-plugins/hermex-push/disable": return (504, .null)
            case "/api/dashboard/agent-plugins/hermex-push/enable": return enableFails ? (502, .null) : nil
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: nil))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()
        PushHTTPFixture.clearCalls()

        await provisioner.updatePlugin()

        XCTAssertEqual(PushHTTPFixture.calls.suffix(2), [
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable",
            "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/enable"
        ], "Turned back on, and nothing installed")
        guard case .failed(let failure)? = provisioner.pluginCard else { return XCTFail("Expected the failed card") }
        XCTAssertEqual(failure.title, "Couldn’t reinstall the plugin")
        XCTAssertEqual(failure.remedy, .retryUpdate)

        // Neither call confirmed a change, so the card names the failure, not a plugin left off.
        enableFails = true
        await provisioner.updatePlugin()
        guard case .failed(let unconfirmed)? = provisioner.pluginCard else { return XCTFail("Expected the failed card") }
        XCTAssertNotEqual(unconfirmed.message, HermexPushFailure.pluginLeftOff.errorDescription)
        XCTAssertEqual(unconfirmed.message, failure.message, "The turn-off's own failure")
    }

    func testTheOldPluginPairingFailureOffersTheUpdateWhichDoesNotPairByItself() async throws {
        let registrar = FakePushRegistrar()
        let newest = newest
        var restarted = false
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/gateway/restart": restarted = true; return nil
            // Before the update: a plugin too old for this build, with keys the relay would refuse.
            case "/api/plugins/hermex-push/pairing":
                return (200, restarted ? PushHTTPFixture.pairingBody(version: newest)
                             : .object(["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                        "install_key": .string("abc"), "preview_key": .string(PushHTTPFixture.previewKey)]))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        XCTAssertEqual(provisioner.failure, HermexPushProvisioner.Failure(
            title: HermexPushProvisioner.Step.pair.title,
            message: "This Hermes host returned pairing keys Hermex cannot use. Update the hermex-push plugin.",
            remedy: .updatePlugin))

        await provisioner.updatePlugin()

        XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(HermexPushPlugin.newestVersion)))
        XCTAssertNil(provisioner.failure)
        XCTAssertFalse(provisioner.showsSteps, "The failed setup's steps give way to the update")
        XCTAssertNil(provisioner.pairing, "Pairing stays behind Turn on notifications")
        XCTAssertEqual(registrar.actions, [])
    }

    func testAnUpdateThatStopsAfterThePairingFailureLeavesTheSetupStepsHidden() async throws {
        let registrar = FakePushRegistrar()
        let newest = newest
        var installFails = true
        var pairingFails = false
        PushHTTPFixture.isSetUp = true
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/dashboard/agent-plugins/install": return installFails ? (500, .null) : nil
            // A plugin too old for this build: no version, and keys the relay would refuse.
            case "/api/plugins/hermex-push/pairing":
                return pairingFails ? (500, .null)
                    : (200, .object(["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                     "install_key": .string("abc"), "preview_key": .string(PushHTTPFixture.previewKey)]))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: newest))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.enable()
        XCTAssertEqual(provisioner.failure?.remedy, .updatePlugin)
        XCTAssertTrue(provisioner.showsSteps, "Setup stopped, so its steps stay listed")

        await provisioner.updatePlugin()

        XCTAssertEqual(provisioner.pluginCard, .failed(HermexPushProvisioner.Failure(
            title: "Couldn’t reinstall the plugin",
            message: "This Hermes host refused the step (HTTP 500). Check the host’s logs, then try again.",
            remedy: .retryUpdate)))
        XCTAssertFalse(provisioner.showsSteps, "The update stopped, not setup, and its card says so")

        installFails = false
        await provisioner.updatePlugin()
        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: nil)))
        pairingFails = true
        await provisioner.checkPluginAgain()

        XCTAssertEqual(provisioner.failure?.title, "Couldn’t check the plugin version")
        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: nil)), "A failed read leaves the restart step standing")
        XCTAssertFalse(provisioner.showsSteps)
        XCTAssertNil(provisioner.pairing)
    }

    func testAnUpdateWhoseCheckFailsOffersTheReadAgainRatherThanAnotherRestart() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let newest = newest
        var restarted = false
        var pairingStatus = 200
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            // The host changes, then stops answering the version read.
            case "/api/gateway/restart": restarted = true; pairingStatus = 500; return nil
            case "/api/plugins/hermex-push/pairing":
                return (pairingStatus, PushHTTPFixture.pairingBody(version: restarted ? newest : "0.2.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()

        await provisioner.updatePlugin()

        let checkFailed = { (status: Int) in HermexPushProvisioner.PluginCard.status(.checkFailed(HermexPushProvisioner.Failure(
            title: "Couldn’t check the plugin version",
            message: "This Hermes host refused the step (HTTP \(status)). Check the host’s logs, then try again."))) }
        XCTAssertEqual(provisioner.pluginCard, checkFailed(500))
        XCTAssertNil(provisioner.failure, "The card names it once")

        pairingStatus = 503
        await provisioner.checkPluginAgain()
        XCTAssertEqual(provisioner.pluginCard, checkFailed(503), "A second failed read replaces the first")
        XCTAssertNil(provisioner.failure)

        pairingStatus = 200
        PushHTTPFixture.clearCalls()
        await provisioner.checkPluginAgain()

        XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(HermexPushPlugin.newestVersion)))
        XCTAssertEqual(PushHTTPFixture.calls, [
            "GET https://a.example.com/api/status",
            "POST https://a.example.com/auth/password-login",
            "GET https://a.example.com/api/auth/me",
            "GET https://a.example.com/api/plugins/hermex-push/pairing"
        ], "Only a read: the host already took the reinstall and the restart")
    }

    func testTurningNotificationsOffDropsThePluginUpdate() async throws {
        let registrar = try await pairedRegistrar(serverA)
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? (200, PushHTTPFixture.pairingBody(version: nil)) : nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)
        await provisioner.checkPlugin()
        XCTAssertEqual(provisioner.pluginCard, .status(.available(loaded: nil)))

        await provisioner.disable()

        XCTAssertNil(provisioner.pairing)
        XCTAssertNil(provisioner.pluginCard, "Its install would enable the plugin Disable just turned off")
    }

    // MARK: - Restart (#934)

    /// A newest plugin past the restart route's 0.4.0, so a host can have the route loaded and
    /// still be behind. This build's own constants never pair the two.
    private let future = HermexPushPluginVersion("0.5.0")!

    func testOnlyAPluginWithTheRestartRouteIsOfferedARestart() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let rows: [(loaded: String?, offered: Bool)] = [(nil, false), ("0.3.0", false), ("0.4.0", true), ("0.4.2", true)]
        for (loaded, offered) in rows {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: loaded))
                case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
                default: return nil
                }
            }
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
            await provisioner.checkPlugin()
            let version = loaded.flatMap(HermexPushPluginVersion.init)
            XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: version)))
            XCTAssertEqual(HermexPushPlugin.canRestart(version), offered, loaded ?? "no version")

            PushHTTPFixture.clearCalls()
            await provisioner.restartHermes()

            XCTAssertEqual(PushHTTPFixture.calls.contains("POST https://a.example.com/api/plugins/hermex-push/restart"), offered,
                           "An older plugin has no route to call: \(loaded ?? "no version")")
        }
    }

    func testRestartingAsksTheHostThenWaitsForItToComeBackWithTheNewPlugin() async throws {
        // The route answers 202, or the host goes down before its answer arrives: both are the restart.
        for answer in [(202, BotJSON.object(["ok": .bool(true)])), (PushHTTPFixture.dropped, .null)] {
            PushHTTPFixture.reset()
            let registrar = try await pairedRegistrar(serverA)
            var restarted = false, probes = 0, signInsSinceRestart = 0
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/restart": restarted = true; return answer
                // Down for the first probe, then back with a new session key.
                case "/api/status" where restarted:
                    probes += 1
                    return probes == 1 ? (PushHTTPFixture.dropped, .null) : nil
                case "/auth/password-login": if restarted { signInsSinceRestart += 1 }; return nil
                case "/api/plugins/hermex-push/pairing":
                    guard restarted else { return (200, PushHTTPFixture.pairingBody(version: "0.4.0")) }
                    return signInsSinceRestart > 0 ? (200, PushHTTPFixture.pairingBody(version: "0.5.0")) : (401, .null)
                case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
                default: return nil
                }
            }
            var cardsWhileWaiting: [HermexPushProvisioner.PluginCard?] = []
            var provisioner: HermexPushProvisioner?
            provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future,
                                          onSleep: { cardsWhileWaiting.append(provisioner?.pluginCard) })
            let restarting = try XCTUnwrap(provisioner)
            await restarting.checkPlugin()
            PushHTTPFixture.clearCalls()

            await restarting.restartHermes()

            XCTAssertEqual(PushHTTPFixture.calls, [
                "GET https://a.example.com/api/status",
                "POST https://a.example.com/auth/password-login",
                "GET https://a.example.com/api/auth/me",
                "POST https://a.example.com/api/plugins/hermex-push/restart",
                "GET https://a.example.com/api/status",
                "GET https://a.example.com/api/status",
                // The restart dropped the session, so the read signs in again.
                "GET https://a.example.com/api/plugins/hermex-push/pairing",
                "GET https://a.example.com/api/status",
                "POST https://a.example.com/auth/password-login",
                "GET https://a.example.com/api/auth/me",
                "GET https://a.example.com/api/plugins/hermex-push/pairing"
            ], "\(answer.0): one restart request, never resent")
            XCTAssertEqual(cardsWhileWaiting, [.restarting, .restarting])
            XCTAssertEqual(restarting.pluginCard, .status(.upToDate(future)))
            XCTAssertNil(restarting.failure)
            XCTAssertFalse(restarting.isWorking)
            XCTAssertEqual(registrar.actions, [], "The keys live in plugin-data, so nothing is paired again")
        }
    }

    func testAHostThatDoesNotComeBackEndsOnItsOwnCardWhereCheckAgainReadsOnce() async throws {
        let registrar = try await pairedRegistrar(serverA)
        var restarted = false
        var back: String?
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/restart": restarted = true; return (202, .null)
            case "/api/status" where restarted: return back == nil ? (PushHTTPFixture.dropped, .null) : nil
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: restarted ? back : "0.4.0"))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
        await provisioner.checkPlugin()
        PushHTTPFixture.clearCalls()

        await provisioner.restartHermes()

        XCTAssertEqual(provisioner.pluginCard, .status(.restartTimedOut))
        XCTAssertEqual(PushHTTPFixture.calls.filter { $0 == "GET https://a.example.com/api/status" }.count, 4,
                       "The sign-in's read, then one probe per delay")
        XCTAssertFalse(provisioner.isWorking)

        await provisioner.checkPluginAgain()
        XCTAssertEqual(provisioner.pluginCard, .status(.restartTimedOut), "Still silent")
        XCTAssertNil(provisioner.failure, "The card already says Hermes hasn't answered")

        back = "0.4.0"
        await provisioner.checkPluginAgain()
        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: HermexPushPluginVersion("0.4.0"))),
                       "Back with the old plugin: the restart is offered again")
    }

    func testAHostBackWithoutThePluginsRoutesEndsOnAFailedReadNotOnSilence() async throws {
        // A new plugin that fails to import leaves Hermes up with none of its routes mounted.
        let unmounted = HermexPushProvisioner.PluginUpdate.checkFailed(HermexPushProvisioner.Failure(
            title: "Couldn’t check the plugin version",
            message: "This Hermes host refused the step (HTTP 404). Check the host’s logs, then try again."))
        for backDuringTheWait in [true, false] {
            PushHTTPFixture.reset()
            let registrar = try await pairedRegistrar(serverA)
            var restarted = false, back = backDuringTheWait
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/restart": restarted = true; return (202, .null)
                case "/api/status" where restarted && !back: return (PushHTTPFixture.dropped, .null)
                case "/api/plugins/hermex-push/pairing":
                    return restarted ? (404, .null) : (200, PushHTTPFixture.pairingBody(version: "0.4.0"))
                case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
                default: return nil
                }
            }
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
            await provisioner.checkPlugin()

            await provisioner.restartHermes()

            if backDuringTheWait {
                XCTAssertEqual(provisioner.pluginCard, .status(unmounted), "Hermes answered, so it came back")
            } else {
                XCTAssertEqual(provisioner.pluginCard, .status(.restartTimedOut))
                back = true
                await provisioner.checkPluginAgain()
                XCTAssertEqual(provisioner.pluginCard, .status(unmounted), "Answering now, so no longer silent")
            }
            XCTAssertNil(provisioner.failure, "The card itself says what failed")
            XCTAssertFalse(provisioner.isWorking)
        }
    }

    func testARefusedRestartSaysWhatTheHostAnsweredAndCanBeTriedAgain() async throws {
        let registrar = try await pairedRegistrar(serverA)
        var refused = true
        var restarted = false
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/restart":
                if refused { return (500, .null) }
                restarted = true
                return (202, .null)
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: restarted ? "0.5.0" : "0.4.0"))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
        await provisioner.checkPlugin()

        await provisioner.restartHermes()

        XCTAssertEqual(provisioner.pluginCard, .failed(HermexPushProvisioner.Failure(
            title: "Couldn’t restart Hermes",
            message: "This Hermes host refused the step (HTTP 500). Check the host’s logs, then try again.",
            remedy: .retryRestart)))
        XCTAssertEqual(PushHTTPFixture.calls.last, "POST https://a.example.com/api/plugins/hermex-push/restart",
                       "Nothing waits on a restart that never ran")
        XCTAssertFalse(provisioner.showsSteps)

        // "Try again" asks for the same confirmation, whose Restart runs this again.
        refused = false
        await provisioner.restartHermes()

        XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(future)))
        XCTAssertNil(provisioner.failure)
    }

    /// A server already paired with the fixture host's keys, with its setup call cleared.
    private func pairedRegistrar(_ server: URL) async throws -> FakePushRegistrar {
        let registrar = FakePushRegistrar()
        try await registrar.enable(PushPairing(relayURL: HermexPushPlugin.defaultRelayURL, installKey: PushHTTPFixture.installKey,
                                               previewKey: PushHTTPFixture.previewKey), for: server)
        registrar.clearActions()
        return registrar
    }

    /// `onSleep` runs at each wait between retries or restart probes, where a test can read the card.
    private func makeProvisioner(server: URL, registrar: FakePushRegistrar, installID: String? = nil,
                                 notifications: FakeNotificationPermission = FakeNotificationPermission(status: .authorized),
                                 testSender: @escaping @MainActor (PushPairing) async -> PushRelayTestOutcome = { _ in .delivered },
                                 stillConnected: @escaping @MainActor () -> Bool = { true },
                                 newest: HermexPushPluginVersion = HermexPushPlugin.newestVersion,
                                 onSleep: @escaping @MainActor () -> Void = {}) -> HermexPushProvisioner {
        let connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://a.example.com")!,
                                       username: "user", password: "secret", installID: installID)
        return HermexPushProvisioner(
            server: server, connection: connection,
            registrar: registrar,
            notifications: notifications,
            dashboard: { BotDashboardClient(http: HermesConnection(connection: $0, configuration: PushHTTPFixture.configuration())) },
            connectionID: { stillConnected() ? connection.id : nil },
            testSender: testSender,
            retryDelays: [.zero, .zero, .zero],
            restartDelays: [.zero, .zero, .zero],
            newestPlugin: newest,
            sleep: { _ in await onSleep() }
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
/// default success for that route, so a test only writes the response it is about, and
/// `dropped` as the status to fail the request the way a lost connection does.
private final class PushHTTPFixture: URLProtocol {
    static let dropped = -1
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
        if status == Self.dropped {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONEncoder().encode(value)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The pairing route as a set-up host answers it; `version` is its `plugin_version`,
    /// which plugins older than 0.2.0 leave out.
    static func pairingBody(version: String?) -> BotJSON {
        var body: [String: BotJSON] = ["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                       "install_key": .string(installKey), "preview_key": .string(previewKey),
                                       "platform": .string("hermex"), "payload_version": .number(1)]
        if let version { body["plugin_version"] = .string(version) }
        return .object(body)
    }

    /// `GET /api/dashboard/plugins/hub` with hermex-push on disk at `version`, beside another plugin.
    static func hubBody(version: String) -> BotJSON {
        .object(["plugins": .array([
            .object(["name": .string("hermex-push"), "version": .string(version), "source": .string("git")]),
            .object(["name": .string("disk-cleanup"), "version": .string("9.9.9"), "source": .string("bundled")])
        ])])
    }

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
