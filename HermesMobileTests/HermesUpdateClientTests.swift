import XCTest
@testable import HermesMobile

/// Updating a Hermes host from Settings (#1075): `HermesUpdateClient`'s routes against a scripted
/// host, in the shapes `scripts/local-hermes` answered at the pin (0.21.5, ca678285) and the live
/// host's check, and `HermesUpdateModel` following one update through the dashboard's restart.
@MainActor final class HermesUpdateClientTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    private func connection(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesConnection {
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "user", password: "secret")
        return HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script))
    }

    private func client(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesUpdateClient {
        HermesUpdateClient(http: connection(script))
    }

    private static func json(_ text: String) -> BotJSON {
        (try? JSONDecoder().decode(BotJSON.self, from: Data(text.utf8))) ?? .null
    }

    func testTheCheckIsPassiveUnlessForcedAndReadsAnUnknownCount() async throws {
        let client = client { request in
            request.url?.path == "/api/hermes/update/check" ? .json(200, Self.json(#"""
            {"install_method": "git", "current_version": "0.21.5+6146.g46904a3.dirty", "behind": -1,
             "update_available": true, "can_apply": true, "update_command": "hermes update", "message": null,
             "commits": [], "future_field": {"x": 1}}
            """#)) : nil
        }

        let passive = try await client.check(force: false)
        let forced = try await client.check(force: true)

        XCTAssertEqual(passive, HermesUpdateCheck(installMethod: "git", currentVersion: "0.21.5+6146.g46904a3.dirty", behind: -1,
                                                  updateAvailable: true, canApply: true, updateCommand: "hermes update"))
        XCTAssertEqual(forced, passive)
        let checks = HermesHostFixture.requests.filter { $0.url?.path == "/api/hermes/update/check" }
        XCTAssertEqual(checks.map { $0.url?.query }, [nil, "force=true"], "The host's 24-hour cache unless forced")
        XCTAssertEqual(checks.map(\.httpMethod), ["GET", "GET"])
    }

    func testAnInstallThatUpdatesOnTheHostCarriesItsCommandUnlessItIsManagedElsewhere() async throws {
        var reply = #"{"install_method": "docker", "current_version": "0.21.5", "behind": null, "update_available": false, "can_apply": false, "update_command": "docker compose pull && docker compose up -d", "message": "Pull the new image."}"#
        let client = client { request in request.url?.path == "/api/hermes/update/check" ? .json(200, Self.json(reply)) : nil }

        let docker = try await client.check(force: false)
        XCTAssertEqual(docker.hostCommand, "docker compose pull && docker compose up -d")
        XCTAssertEqual(docker.message, "Pull the new image.")

        reply = #"{"install_method": "managed-runtime", "current_version": "0.21.5", "behind": null, "update_available": false, "can_apply": false, "update_command": "managed outside dashboard", "message": "Hermes updates are managed outside this dashboard in containerized environments."}"#
        let managed = try await client.check(force: false)
        XCTAssertNil(managed.hostCommand, "A sentence, not a command to copy")
    }

    func testStartingSendsOnePostWithoutABodyAndReadsEachAnswer() async throws {
        var reply = #"{"ok": true, "pid": 4242, "name": "hermes-update", "action_id": "0123456789abcdef0123456789abcdef"}"#
        let client = client { request in request.url?.path == "/api/hermes/update" ? .json(200, Self.json(reply)) : nil }

        let started = try await client.start()
        reply = #"{"ok": true, "pid": 4242, "name": "hermes-update", "already_running": true}"#
        let joined = try await client.start()
        reply = #"{"ok": false, "pid": null, "name": "hermes-update", "error": "apt_update_required", "message": "Hermes is managed by Termux APT; run `pkg upgrade hermes-agent`.", "update_command": "pkg upgrade hermes-agent"}"#
        let refused = try await client.start()
        reply = #"{"ok": false, "error": "dashboard_update_managed_externally", "message": "Managed elsewhere.", "update_command": "managed outside dashboard"}"#
        let managed = try await client.start()

        XCTAssertEqual(started, .started(pid: 4242))
        XCTAssertEqual(joined, .started(pid: 4242), "An update already running is followed, not started again")
        XCTAssertEqual(refused, .refused(error: "apt_update_required", message: "Hermes is managed by Termux APT; run `pkg upgrade hermes-agent`.",
                                         command: "pkg upgrade hermes-agent"))
        XCTAssertEqual(refused.hostCommand, "pkg upgrade hermes-agent")
        XCTAssertNil(managed.hostCommand)
        let posts = HermesHostFixture.requests.filter { $0.url?.path == "/api/hermes/update" }
        XCTAssertEqual(posts.map(\.httpMethod), ["POST", "POST", "POST", "POST"])
        XCTAssertTrue(posts.allSatisfy { $0.httpBody == nil && $0.httpBodyStream == nil }, "The route takes no body")
    }

    func testStatusReadsTheActionAndTheLatestReceiptsSummary() async throws {
        var missing = false
        let client = client { request in
            guard request.url?.path == "/api/actions/hermes-update/status" else { return nil }
            if missing { return .json(404, .object(["detail": .string("Unknown action: hermes-update")])) }
            return .json(200, Self.json(#"""
            {"name": "hermes-update", "running": false, "exit_code": 0, "pid": null,
             "lines": ["=== hermes update started 2026-10-06 18:00:00 ===", "✓ Update complete! (v0.22.0)"],
             "action_id": "0123456789abcdef0123456789abcdef",
             "receipt": {"outcome": "success", "started_at": "2026-10-06T18:00:00+00:00", "finished_at": "2026-10-06T18:03:00+00:00",
                         "pre_sha": "aaa", "post_sha": "bbb", "post_version": "0.22.0", "fleet_states": ["current"]}}
            """#))
        }

        let status = try await client.status()

        XCTAssertEqual(status, HermesUpdateStatus(
            running: false, exitCode: 0, pid: nil,
            lines: ["=== hermes update started 2026-10-06 18:00:00 ===", "✓ Update complete! (v0.22.0)"],
            receipt: HermesUpdateReceipt(outcome: .success, startedAt: "2026-10-06T18:00:00+00:00", postVersion: "0.22.0")))
        XCTAssertEqual(HermesHostFixture.requests.last?.url?.query, "lines=40")

        missing = true
        do { _ = try await client.status(); XCTFail("Expected the 404") }
        catch { XCTAssertEqual(error as? BotFailure, .rejected(404)) }
    }

    func testTheReceiptIsItsSummaryOrNilWhenNoUpdateHasRun() async throws {
        var reply: HermesHostFixture.Reply = .json(200, Self.json(#"""
        {"receipt": {"schema": 1, "outcome": "partial", "started_at": "2026-10-06T18:00:00+00:00",
                     "pre_update": {"sha": "aaa", "version": "0.21.5"}, "post_update": {"sha": "bbb", "version": "0.22.0"}, "steps": []},
         "summary": {"outcome": "partial", "started_at": "2026-10-06T18:00:00+00:00", "post_version": "0.22.0"}}
        """#))
        let client = client { request in request.url?.path == "/api/hermes/update/receipt" ? reply : nil }

        let partial = try await client.receipt()
        reply = .json(200, Self.json(#"{"receipt": {"outcome": "failed", "started_at": "2026-10-06T19:00:00+00:00", "post_update": {"version": "0.21.5"}}, "summary": null}"#))
        let fromTheFullReceipt = try await client.receipt()
        reply = .json(404, .object(["detail": .string("No update receipt found (no `hermes update` run recorded).")]))
        let none = try await client.receipt()

        XCTAssertEqual(partial, HermesUpdateReceipt(outcome: .partial, startedAt: "2026-10-06T18:00:00+00:00", postVersion: "0.22.0"))
        XCTAssertEqual(fromTheFullReceipt, HermesUpdateReceipt(outcome: .failed, startedAt: "2026-10-06T19:00:00+00:00", postVersion: "0.21.5"))
        XCTAssertNil(none)
    }

    func testHealthIsReadWithoutSigningIn() async throws {
        let client = client { request in
            request.url?.path == "/api/health"
                ? .json(200, .object(["ok": .bool(true), "version": .string("0.22.0"), "auth_required": .bool(true)])) : nil
        }

        let version = try await client.health()

        XCTAssertEqual(version, "0.22.0")
        XCTAssertEqual(HermesHostFixture.requests.map { $0.url?.path }, ["/api/health"], "No sign-in for a public route")
    }

    func testARestartedDashboardsNewSessionKeySignsInAgainOnceAndResendsTheRead() async throws {
        var restarted = false
        let client = client { request in
            guard request.url?.path == "/api/actions/hermes-update/status" else { return nil }
            if !restarted { restarted = true; return .json(401, .object(["error": .string("unauthenticated")])) }
            return .json(200, .object(["name": .string("hermes-update"), "running": .bool(true), "exit_code": .null,
                                       "pid": .number(4242), "lines": .array([])]))
        }

        // Signed in before the restart; the restarted dashboard's key no longer accepts the cookie.
        let status = try await client.status()

        XCTAssertEqual(status, HermesUpdateStatus(running: true, pid: 4242))
        XCTAssertEqual(HermesHostFixture.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /api/status", "POST /auth/password-login", "GET /api/auth/me",
            "GET /api/actions/hermes-update/status",
            "GET /api/status", "POST /auth/password-login", "GET /api/auth/me",
            "GET /api/actions/hermes-update/status"
        ])
    }

    func testAnUpdateSendsOnePostAndIsFollowedThroughTheRestartToItsRelease() async throws {
        var applied = false, reads = 0
        let earlier = #"{"outcome": "success", "started_at": "2026-10-01T09:00:00+00:00", "post_version": "0.21.5"}"#
        let http = connection { request in
            switch request.url?.path {
            case "/api/hermes/update/check":
                return .json(200, Self.json(#"{"install_method": "git", "behind": 12, "update_available": true, "can_apply": true}"#))
            case "/api/hermes/update":
                applied = true
                return .json(200, Self.json(#"{"ok": true, "pid": 4242, "name": "hermes-update", "action_id": "0123456789abcdef0123456789abcdef"}"#))
            case "/api/actions/hermes-update/status":
                guard applied else {
                    return .json(200, Self.json(#"{"running": false, "exit_code": 0, "pid": null, "lines": [], "receipt": \#(earlier)}"#))
                }
                reads += 1
                switch reads {
                case 1, 2: return .json(200, Self.json(#"{"running": true, "exit_code": null, "pid": 4242, "lines": [], "receipt": \#(earlier)}"#))
                case 3: return .fail(URLError(.networkConnectionLost))
                case 4: return .json(502, .string("Bad Gateway"))
                default:
                    // The restarted dashboard no longer tracks the process; the receipt is this run's.
                    return .json(200, Self.json(#"{"running": false, "exit_code": 0, "pid": null, "lines": [], "receipt": {"outcome": "success", "started_at": "2026-10-06T18:00:00+00:00", "post_version": "0.22.0"}}"#))
                }
            case "/api/health":
                return .json(200, .object(["ok": .bool(true), "version": .string("0.22.0"), "auth_required": .bool(true)]))
            default: return nil
            }
        }
        var seen: [HermesUpdateMachine.State?] = []
        var model: HermesUpdateModel?
        let onSleep: @MainActor () -> Void = {
            if case .following(let machine)? = model?.run { seen.append(machine.state) } else { seen.append(nil) }
        }
        model = HermesUpdateModel(server: server, makeClient: { HermesUpdateClient(http: http) }, cadence: .zero,
                                  sleep: { _ in await onSleep() })
        let updating = try XCTUnwrap(model)
        let finished = expectation(description: "updated")
        var installed: [String] = []
        updating.onUpdated = { installed.append($0); finished.fulfill() }
        await updating.appear()
        guard case .answered(let check, _)? = updating.check else { return XCTFail("Expected the passive check") }
        XCTAssertEqual(check.behind, 12)

        updating.apply()
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertEqual(HermesHostFixture.count("/api/hermes/update"), 1, "One update, never resent")
        XCTAssertEqual(seen, [.applying, .applying, .applying, .recovering, .recovering, .applying],
                       "Updating, Restarting while the dashboard is away, then the release check")
        guard case .following(let machine)? = updating.run else { return XCTFail("Expected the run") }
        XCTAssertEqual(machine.state, .done(version: "0.22.0"))
        XCTAssertEqual(installed, ["0.22.0"], "The saved version follows the update")
        XCTAssertFalse(updating.isWorking)
    }

    func testALostReplyToTheUpdateFollowsTheRunTheHostReports() async throws {
        var applied = false, reads = 0
        let earlier = #"{"outcome": "success", "started_at": "2026-10-01T09:00:00+00:00", "post_version": "0.21.5"}"#
        let http = connection { request in
            switch request.url?.path {
            case "/api/hermes/update":
                // The host started the update, but its reply never arrived.
                applied = true
                return .fail(URLError(.networkConnectionLost))
            case "/api/actions/hermes-update/status":
                guard applied else {
                    return .json(200, Self.json(#"{"running": false, "exit_code": 0, "pid": null, "lines": [], "receipt": \#(earlier)}"#))
                }
                reads += 1
                if reads == 1 {
                    return .json(200, Self.json(#"{"running": true, "exit_code": null, "pid": 4242, "lines": [], "receipt": \#(earlier)}"#))
                }
                return .json(200, Self.json(#"{"running": false, "exit_code": 0, "pid": null, "lines": [], "receipt": {"outcome": "success", "started_at": "2026-10-06T18:00:00+00:00", "post_version": "0.22.0"}}"#))
            case "/api/health":
                return .json(200, .object(["ok": .bool(true), "version": .string("0.22.0"), "auth_required": .bool(true)]))
            default: return nil
            }
        }
        let model = HermesUpdateModel(server: server, makeClient: { HermesUpdateClient(http: http) }, cadence: .zero, sleep: { _ in })
        let finished = expectation(description: "updated")
        model.onUpdated = { _ in finished.fulfill() }

        model.apply()
        await fulfillment(of: [finished], timeout: 5)

        XCTAssertEqual(HermesHostFixture.count("/api/hermes/update"), 1, "The run is followed, not offered again")
        guard case .following(let machine)? = model.run else { return XCTFail("Expected the run") }
        XCTAssertEqual(machine.pid, 4242, "The process the host reported")
        XCTAssertEqual(machine.state, .done(version: "0.22.0"))
    }
}
