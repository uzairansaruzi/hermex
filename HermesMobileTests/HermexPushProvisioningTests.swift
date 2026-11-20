import UserNotifications
import XCTest
@testable import HermesMobile

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
            switch attempts {
            case 1: return PushHTTPFixture.pluginNotFound
            case 2: return (404, .null)
            case 3: return (409, .null)
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(attempts, 4)
        XCTAssertNotNil(registrar.pairing(for: serverA))
    }

    func testAHostThatNeverAnswersFailsThePairingStepInsteadOfWaitingForever() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? PushHTTPFixture.pluginNotFound : nil
        }
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

    func testAFreshHostAsksForADashboardRestartAndCheckAgainPairs() async throws {
        let registrar = FakePushRegistrar()
        var enabled = false
        var dashboardRestarted = false
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/dashboard/agent-plugins/hermex-push/enable": enabled = true; return nil
            case "/api/plugins/hermex-push/pairing":
                if dashboardRestarted { return nil }
                return enabled ? PushHTTPFixture.notMounted : PushHTTPFixture.pluginNotFound
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure, "A host that needs its dashboard restarted has not failed")
        XCTAssertEqual(provisioner.pluginCard, .status(.setupNeedsRestart))
        XCTAssertNil(provisioner.pairing)
        XCTAssertEqual(registrar.actions, [])
        XCTAssertEqual(PushHTTPFixture.calls.filter { $0.hasSuffix("/api/plugins/hermex-push/pairing") }.count, 2,
                       "An unmounted route is not retried: only a dashboard restart mounts it")
        XCTAssertTrue(PushHTTPFixture.calls.contains("POST https://a.example.com/api/gateway/restart"))

        dashboardRestarted = true
        PushHTTPFixture.clearCalls()
        await provisioner.checkPluginAgain()

        XCTAssertNil(provisioner.failure)
        XCTAssertNil(provisioner.pluginCard)
        XCTAssertEqual(provisioner.pairing?.installKey, PushHTTPFixture.installKey)
        XCTAssertEqual(registrar.actions, ["enable a.example.com"])
        XCTAssertEqual(PushHTTPFixture.calls.filter { $0.hasPrefix("POST") || $0.hasPrefix("PUT") },
                       ["POST https://a.example.com/auth/password-login"], "Check again changes nothing on the host")
    }

    func testAPluginOnDiskButNotMountedAsksForARestartWithoutReinstalling() async throws {
        for answer in [PushHTTPFixture.notMounted, PushHTTPFixture.headless] {
            PushHTTPFixture.reset()
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/pairing": return answer
                case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.4.0"))
                default: return nil
                }
            }
            let registrar = FakePushRegistrar()
            let provisioner = makeProvisioner(server: serverA, registrar: registrar)

            await provisioner.enable()

            XCTAssertNil(provisioner.failure)
            XCTAssertEqual(provisioner.pluginCard, .status(.setupNeedsRestart))
            XCTAssertEqual(PushHTTPFixture.calls, [
                "GET https://a.example.com/api/status",
                "POST https://a.example.com/auth/password-login",
                "GET https://a.example.com/api/auth/me",
                "GET https://a.example.com/api/plugins/hermex-push/pairing",
                "GET https://a.example.com/api/dashboard/plugins/hub"
            ])
            XCTAssertEqual(registrar.actions, [])
        }
    }

    func testSetupOnAWebappThatNeedsARestartKnowsItIsAWebapp() async throws {
        var statuses = 0
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/status":
                statuses += 1
                return (200, .object(statuses == 1 ? ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
                                     : ["auth_required": .bool(true), "install_id": .string("fixture-install")]))
            case "/api/plugins/hermex-push/pairing": return PushHTTPFixture.notMounted
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.4.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: FakePushRegistrar())

        await provisioner.enable()

        XCTAssertEqual(provisioner.pluginCard, .status(.setupNeedsRestart))
        XCTAssertTrue(provisioner.servesWebapp)
    }

    func testAnUnmountedRouteWithNoPluginOnDiskInstallsIt() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/pairing": return PushHTTPFixture.notMounted
            case "/api/dashboard/plugins/hub":
                return (200, .object(["plugins": .array([.object(["name": .string("disk-cleanup"), "version": .string("1.0")])])]))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertNil(provisioner.failure)
        XCTAssertEqual(provisioner.pluginCard, .status(.setupNeedsRestart))
        XCTAssertTrue(PushHTTPFixture.calls.contains("POST https://a.example.com/api/dashboard/agent-plugins/install"))
        XCTAssertTrue(PushHTTPFixture.calls.contains("POST https://a.example.com/api/gateway/restart"))
    }

    func testAnUnreadableHubReplyIsReportedInsteadOfReinstalling() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/pairing": return PushHTTPFixture.notMounted
            case "/api/dashboard/plugins/hub": return (200, .object(["error": .string("hub unavailable")]))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertEqual(provisioner.failure?.message, "This Hermes host refused the step (HTTP 404). Check the host’s logs, then try again.")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") || $0.contains("agent-plugins") || $0.contains("/api/gateway/restart") })
        XCTAssertNil(provisioner.pluginCard)
        XCTAssertEqual(registrar.actions, [])
    }

    func testAnUnknownMissingRouteIsReportedInsteadOfReconfiguringTheHost() async throws {
        let registrar = FakePushRegistrar()
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/pairing" ? (404, .object(["detail": .string("Not Found")])) : nil
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.enable()

        XCTAssertEqual(provisioner.failure?.title, HermexPushProvisioner.Step.pair.title)
        XCTAssertEqual(provisioner.failure?.message, "This Hermes host refused the step (HTTP 404). Check the host’s logs, then try again.")
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/env") || $0.contains("agent-plugins") || $0.contains("/api/gateway/restart") })
        XCTAssertNil(provisioner.pluginCard)
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
            request.url?.path == "/api/status" ? (200, .object(["version": .string("0.21.5")])) : nil
        }
        let unknown = makeProvisioner(server: serverA, registrar: FakePushRegistrar())
        await unknown.enable()
        XCTAssertEqual(unknown.failure, HermexPushProvisioner.Failure(
            title: "Sign in to Hermes",
            message: "This Hermes host doesn’t offer the password sign-in push setup needs."))
        XCTAssertEqual(PushHTTPFixture.calls, ["GET https://a.example.com/api/status"])
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

    func testDisableLeavesTheHostPluginOnWhileAnotherEntryForTheHostIsPaired() async throws {
        let registrar = try await pairedRegistrar(serverA)
        try await registrar.enable(try XCTUnwrap(registrar.pairing(for: serverA)), for: serverB)
        registrar.clearActions()
        PushHTTPFixture.handler = { _ in nil }
        PushHTTPFixture.clearCalls()
        let first = makeProvisioner(server: serverA, registrar: registrar)

        await first.disable()

        XCTAssertNil(first.failure)
        XCTAssertEqual(PushHTTPFixture.calls, [])
        XCTAssertEqual(registrar.actions, ["disable a.example.com"])
        XCTAssertNil(first.pairing)
        XCTAssertNotNil(registrar.pairing(for: serverB))

        let last = makeProvisioner(server: serverB, registrar: registrar)
        await last.disable()

        XCTAssertNil(last.failure)
        XCTAssertEqual(PushHTTPFixture.calls.last, "POST https://a.example.com/api/dashboard/agent-plugins/hermex-push/disable")
        XCTAssertEqual(registrar.actions, ["disable a.example.com", "disable b.example.com"])
    }

    func testDisableLeavesTheHostPluginOnWhenAnotherEntryPairsDuringSignIn() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let shared = try XCTUnwrap(registrar.pairing(for: serverA))
        PushHTTPFixture.handler = { _ in nil }
        let held = expectation(description: "Sign-in held")
        var pending: PushHTTPFixture?
        PushHTTPFixture.holdResponse = { fixture in
            guard fixture.request.url?.path == "/auth/password-login" else { return false }
            pending = fixture
            held.fulfill()
            return true
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        let disabling = Task { await provisioner.disable() }
        await fulfillment(of: [held], timeout: 5)
        PushHTTPFixture.holdResponse = nil
        try await registrar.enable(shared, for: serverB)
        registrar.clearActions()
        try XCTUnwrap(pending).respond(status: 200, value: .object(["result": .string("ok")]))
        await disabling.value

        XCTAssertNil(provisioner.failure)
        XCTAssertFalse(PushHTTPFixture.calls.contains { $0.contains("/api/dashboard/agent-plugins/") },
                       "The plugin now serves the other entry and stays on")
        XCTAssertEqual(registrar.actions, ["disable a.example.com"])
        XCTAssertNil(provisioner.pairing)
        XCTAssertEqual(registrar.pairing(for: serverB)?.installKey, PushHTTPFixture.installKey)
    }

    func testDisableChangesNothingWhenTheKeychainCantListTheOtherEntries() async throws {
        struct KeychainFailure: Error {}
        let registrar = try await pairedRegistrar(serverA)
        registrar.sharesError = KeychainFailure()
        PushHTTPFixture.handler = { _ in nil }
        PushHTTPFixture.clearCalls()
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.disable()

        XCTAssertEqual(provisioner.failure?.title, "Disable the plugin")
        XCTAssertEqual(PushHTTPFixture.calls, [])
        XCTAssertEqual(registrar.actions, [])
        XCTAssertNotNil(provisioner.pairing)
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

    private let newest = HermexPushPlugin.newestVersion.description

    func testThePairingRouteAndTheHubReportPluginVersionsTolerantly() throws {
        let version = try XCTUnwrap(HermexPushPluginVersion("0.3.0"))
        XCTAssertEqual(HermexPushPlugin.loadedVersion(PushHTTPFixture.pairingBody(version: "0.3.0")), version)
        for body in [PushHTTPFixture.pairingBody(version: nil), .object(["plugin_version": .number(3)]),
                     PushHTTPFixture.pairingBody(version: "0.3.x"), PushHTTPFixture.pairingBody(version: "")] {
            XCTAssertNil(HermexPushPlugin.loadedVersion(body), "\(body)")
        }
        XCTAssertEqual(try HermexPushPlugin.pairing(PushHTTPFixture.pairingBody(version: "0.3.0")).installKey,
                       PushHTTPFixture.installKey)

        let hub = BotJSON.object(["plugins": .array([
            .object(["name": .string("other"), "version": .string("9.0.0")]),
            .object(["name": .string("hermex-push"), "version": .string("0.3.0")])
        ])])
        XCTAssertEqual(HermexPushPlugin.installedVersion(hub: hub), version)
        XCTAssertNil(HermexPushPlugin.installedVersion(hub: .object(["plugins": .array([])])))
        XCTAssertNil(HermexPushPlugin.installedVersion(hub: .null))

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

    func testAPairedHostWhosePluginIsOnDiskButNotLoadedAsksForARestart() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let newest = newest
        var pairing = PushHTTPFixture.notMounted
        var onDisk = newest
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/pairing": return pairing
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: onDisk))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar)

        await provisioner.checkPlugin()
        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: nil)))

        await provisioner.checkPluginAgain()
        XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: nil)))
        XCTAssertNil(provisioner.failure, "Not \"refused the step (HTTP 404)\"")
        XCTAssertEqual(registrar.actions, [], "Check again on a paired host only reads")

        pairing = (200, PushHTTPFixture.pairingBody(version: "0.4.0"))
        onDisk = "0.4.0"
        await provisioner.checkPluginAgain()
        XCTAssertEqual(provisioner.pluginCard, .status(.available(loaded: HermexPushPluginVersion("0.4.0"))))
    }

    func testCompanionRoutesListWhatTheDashboardMountedAndA404ClosesTheGate() async throws {
        var answer: (Int, BotJSON) = (200, .object([
            "plugin_version": .string("0.5.0"),
            "routes": .array([.string("GET /capabilities"), .string("GET /pairing"), .string("POST /restart"), .number(7)]),
            "added_later": .bool(true)
        ]))
        PushHTTPFixture.handler = { request in
            request.url?.path == "/api/plugins/hermex-push/capabilities" ? answer : nil
        }
        let connection = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://a.example.com")!,
                                       username: "user", password: "secret")
        let client = BotDashboardClient(http: HermesConnection(connection: connection, configuration: PushHTTPFixture.configuration()))

        let routes = try await client.companionRoutes()
        XCTAssertEqual(routes.pluginVersion, HermexPushPluginVersion("0.5.0"))
        XCTAssertTrue(routes.supports("POST /restart"))
        XCTAssertFalse(routes.supports("POST /git/pull"))
        XCTAssertEqual(routes.routes.count, 3, "An entry that isn't a string is skipped")

        for missing in [PushHTTPFixture.notMounted, PushHTTPFixture.pluginNotFound, PushHTTPFixture.headless, (404, .null)] {
            answer = missing
            let closed = try await client.companionRoutes()
            XCTAssertEqual(closed, .closed, "\(missing)")
        }

        answer = (500, .null)
        do { _ = try await client.companionRoutes(); XCTFail("A server error is not a closed gate") } catch {
            XCTAssertEqual(error as? BotFailure, .rejected(500))
        }
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

    private let future = HermexPushPluginVersion("0.5.0")!

    func testARestartIsNeverResentToAHostThatTurnedOutToBeAWebapp() async throws {
        let registrar = try await pairedRegistrar(serverA)
        var restarts = 0, webappStatuses = 0
        PushHTTPFixture.handler = { request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/restart":
                restarts += 1
                return (401, .null)
            case "/api/status" where restarts > 0:
                webappStatuses += 1
                return (200, .object(webappStatuses == 1 ? ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
                                     : ["auth_required": .bool(true), "install_id": .string("fixture-install")]))
            case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: "0.4.0"))
            case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
            default: return nil
            }
        }
        let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
        await provisioner.checkPlugin()

        await provisioner.restartHermes()

        XCTAssertEqual(restarts, 1)
        XCTAssertTrue(provisioner.servesWebapp)
        XCTAssertEqual(provisioner.phase, .idle)
    }

    func testOnlyAPluginWithTheRestartRouteIsOfferedARestart() async throws {
        let registrar = try await pairedRegistrar(serverA)
        let rows: [(loaded: String?, webapp: Bool, offered: Bool)] = [
            (nil, false, false), ("0.3.0", false, false), ("0.4.0", false, true), ("0.4.2", false, true), ("0.4.2", true, false)
        ]
        for (loaded, webapp, offered) in rows {
            PushHTTPFixture.reset()
            var statuses = 0
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/status" where webapp:
                    statuses += 1
                    return (200, .object(statuses == 1 ? ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
                                         : ["auth_required": .bool(true), "install_id": .string("fixture-install")]))
                case "/api/plugins/hermex-push/pairing": return (200, PushHTTPFixture.pairingBody(version: loaded))
                case "/api/dashboard/plugins/hub": return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
                default: return nil
                }
            }
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
            await provisioner.checkPlugin()
            let version = loaded.flatMap(HermexPushPluginVersion.init)
            XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: version)))
            XCTAssertEqual(provisioner.canRestart(version), offered, loaded ?? "no version")

            PushHTTPFixture.clearCalls()
            await provisioner.restartHermes()

            XCTAssertEqual(PushHTTPFixture.calls.contains("POST https://a.example.com/api/plugins/hermex-push/restart"), offered,
                           "An older plugin has no route to call: \(loaded ?? "no version")")
        }
    }

    func testRestartingAsksTheHostThenWaitsForItToComeBackWithTheNewPlugin() async throws {
        for answer in [(202, BotJSON.object(["ok": .bool(true)])), (PushHTTPFixture.dropped, .null)] {
            PushHTTPFixture.reset()
            let registrar = try await pairedRegistrar(serverA)
            var restarted = false, probes = 0, signInsSinceRestart = 0
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/restart": restarted = true; return answer
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

        refused = false
        await provisioner.restartHermes()

        XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(future)))
        XCTAssertNil(provisioner.failure)
    }

    func testPassiveReadCannotReplaceAFinishedUpdate() async throws {
        try await assertPassiveReadCannotReplaceResult { await $0.updatePlugin() }
    }

    func testPassiveReadCannotReplaceAFinishedRecheck() async throws {
        try await assertPassiveReadCannotReplaceResult { await $0.checkPluginAgain() }
    }

    func testPassiveReadCannotReplaceAFinishedRestart() async throws {
        try await assertPassiveReadCannotReplaceResult { await $0.restartHermes() }
    }

    private func assertPassiveReadCannotReplaceResult(
        action: (HermexPushProvisioner) async -> Void
    ) async throws {
        for staleVersion in ["0.4.0", "0.5.0", nil] as [String?] {
            PushHTTPFixture.reset()
            let registrar = try await pairedRegistrar(serverA)
            var loaded = "0.4.0"
            PushHTTPFixture.handler = { request in
                switch request.url?.path {
                case "/api/plugins/hermex-push/pairing":
                    return (200, PushHTTPFixture.pairingBody(version: loaded))
                case "/api/dashboard/plugins/hub":
                    return (200, PushHTTPFixture.hubBody(version: "0.5.0"))
                default: return nil
                }
            }
            let provisioner = makeProvisioner(server: serverA, registrar: registrar, newest: future)
            await provisioner.checkPlugin()
            XCTAssertEqual(provisioner.pluginCard, .status(.restartNeeded(loaded: HermexPushPluginVersion("0.4.0"))))
            let originalPairing = provisioner.pairing
            let held = expectation(description: "Passive pairing read held")
            var pending: PushHTTPFixture?
            PushHTTPFixture.holdResponse = { fixture in
                guard fixture.request.url?.path == "/api/plugins/hermex-push/pairing" else { return false }
                pending = fixture
                held.fulfill()
                return true
            }
            let passive = Task { await provisioner.checkPlugin() }
            await fulfillment(of: [held], timeout: 5)
            PushHTTPFixture.holdResponse = nil
            let response = try XCTUnwrap(pending)
            loaded = "0.5.0"

            await action(provisioner)

            XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(future)))
            XCTAssertFalse(provisioner.isWorking)
            if let staleVersion {
                response.respond(status: 200, value: PushHTTPFixture.pairingBody(version: staleVersion))
            } else {
                response.respond(status: 500, value: .null)
            }
            await passive.value

            XCTAssertEqual(provisioner.pluginCard, .status(.upToDate(future)),
                           "A stale passive completion must preserve the deliberate action's result (\(staleVersion ?? "failure"))")
            XCTAssertNil(provisioner.failure)
            XCTAssertEqual(provisioner.pairing, originalPairing)
            XCTAssertEqual(registrar.actions, [])
        }
    }

    private func pairedRegistrar(_ server: URL) async throws -> FakePushRegistrar {
        let registrar = FakePushRegistrar()
        try await registrar.enable(PushPairing(relayURL: HermexPushPlugin.defaultRelayURL, installKey: PushHTTPFixture.installKey,
                                               previewKey: PushHTTPFixture.previewKey), for: server)
        registrar.clearActions()
        return registrar
    }

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

    var sharesError: (any Error)?
    func sharesRegistration(for server: URL) throws -> Bool {
        if let sharesError { throw sharesError }
        guard let pairing = pairings[server] else { return false }
        return pairings.contains { $0.key != server && $0.value.installKey == pairing.installKey && $0.value.relayURL == pairing.relayURL }
    }

    func clearActions() { actions = [] }
}

private final class FakeNotificationPermission: ResponseCompletionNotificationScheduling, @unchecked Sendable {
    var status: UNAuthorizationStatus
    let grants: Bool
    private(set) var hostCallsBeforeRequest: [Int] = []
    var requests: Int { hostCallsBeforeRequest.count }
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

private final class PushHTTPFixture: URLProtocol {
    static let dropped = -1
    static let installKey = String(repeating: "0123456789abcdef", count: 4)
    static let previewKey = Data(repeating: 7, count: 32).base64EncodedString()
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, BotJSON)?)?
    nonisolated(unsafe) static var holdResponse: ((PushHTTPFixture) -> Bool)?
    nonisolated(unsafe) static var isSetUp = false
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
    static func reset() { handler = nil; holdResponse = nil; isSetUp = false; isUnreachable = false; clearCalls() }

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
        if Self.holdResponse?(self) == true { return }
        respond(status: status, value: value)
    }

    func respond(status: Int, value: BotJSON) {
        let url = request.url!
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

    static let pluginNotFound: (Int, BotJSON) = (404, .object(["detail": .string("Plugin not found")]))
    static let notMounted: (Int, BotJSON) = (404, .object(["detail": .string("No such API endpoint: /api/plugins/hermex-push/pairing")]))
    static let headless: (Int, BotJSON) = (404, .object(["error": .string(
        "Headless backend (hermes serve): web UI disabled — use `hermes dashboard` for the browser UI.")]))

    static func pairingBody(version: String?) -> BotJSON {
        var body: [String: BotJSON] = ["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                       "install_key": .string(installKey), "preview_key": .string(previewKey),
                                       "platform": .string("hermex"), "payload_version": .number(1)]
        if let version { body["plugin_version"] = .string(version) }
        return .object(body)
    }

    static func hubBody(version: String) -> BotJSON {
        .object(["plugins": .array([
            .object(["name": .string("hermex-push"), "version": .string(version), "source": .string("git")]),
            .object(["name": .string("disk-cleanup"), "version": .string("9.9.9"), "source": .string("bundled")])
        ])])
    }

    private static func success(for url: URL) -> (Int, BotJSON) {
        switch url.path {
        case "/api/status":
            return (200, .object(["auth_required": .bool(true), "auth_providers": .array([.string("basic")]),
                                  "version": .string("0.21.3"), "install_id": .string("fixture-install")]))
        case "/api/auth/me": return (200, .object(["provider": .string("basic")]))
        case "/api/plugins/hermex-push/pairing":
            guard isSetUp else { return pluginNotFound }
            return (200, .object(["relay_url": .string(HermexPushPlugin.defaultRelayURL.absoluteString),
                                  "install_key": .string(installKey), "preview_key": .string(previewKey),
                                  "platform": .string("hermex"), "payload_version": .number(1)]))
        default: return (200, .object(["result": .string("ok")]))
        }
    }
}
