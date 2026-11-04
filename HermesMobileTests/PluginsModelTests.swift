import XCTest
@testable import HermesMobile

/// The Plugins screen on a Hermes host (#1582): `PluginsModel` and the real client over a scripted
/// socket, with replies in the shapes `scripts/local-hermes` and a live host answered at the pin
/// (bf0203a7, 0.22.5).
@MainActor final class PluginsModelTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testTwoPluginsWithOneNameAreToggledByKeyOnTheSelectedProfile() async throws {
        let host = hostWithPlugins([row("image_gen/fal", name: "fal"), row("video_gen/fal", name: "fal")])
        let model = model(on: host)
        await model.load()
        await model.select("dev")

        host.next("plugins.manage", .init(result: toggled(row("video_gen/fal", name: "fal", status: "disabled"))))
        await model.apply(try XCTUnwrap(model.plugins.last), turningOn: false)

        let params = try XCTUnwrap(host.requests.last)["params"]
        XCTAssertEqual(params["action"].text, "toggle")
        XCTAssertEqual(params["key"].text, "video_gen/fal")
        XCTAssertEqual(params["profile"].text, "dev")
        XCTAssertEqual(params["enable"].flag, false)
        XCTAssertEqual(model.plugins.map(\.isEnabled), [true, false], "only the row the host named changes")
        XCTAssertFalse(model.needsRestart, "the host didn't ask for one")
    }

    func testAReadForAnEarlierProfileNeverReplacesTheOneShown() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()

        host.withhold("plugins.manage")
        let sent = expectation(description: "dev's read reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let earlier = Task { await model.select("dev") }
        await fulfillment(of: [sent], timeout: 5)
        host.allow("plugins.manage")
        host.next("plugins.manage", .init(result: list([row("google_meet")])))
        await model.select("default")
        XCTAssertEqual(model.plugins.map(\.key), ["google_meet"])

        http.gateway.dropSocket() // dev's read fails only now, after the switch
        await earlier.value
        XCTAssertEqual(model.state, .loaded(model.plugins))
        XCTAssertEqual(model.plugins.map(\.key), ["google_meet"])
    }

    func testAToggleEndingAfterASwitchLeavesTheNewProfileAlone() async throws {
        let host = hostWithPlugins([row("disk-cleanup", status: "not enabled")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        host.withhold("plugins.manage")
        let sent = expectation(description: "the toggle reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let toggle = Task { await model.apply(plugin, turningOn: true) }
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertTrue(model.isToggling(plugin))
        XCTAssertTrue(model.isOn(plugin))

        host.allow("plugins.manage")
        await model.select("dev")
        XCTAssertFalse(model.isToggling(plugin), "the other Profile's same key isn't busy")
        http.gateway.dropSocket()
        await toggle.value

        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isOn(try XCTUnwrap(model.plugins.first)))
    }

    func testAScreenLeftOverFromASwitchedServerSendsNothingMore() async throws {
        let host = hostWithPlugins([row("disk-cleanup", status: "not enabled")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        http.retire()
        await model.apply(plugin, turningOn: true)

        XCTAssertEqual(toggles(on: host), 0)
    }

    func testARelyOnPluginAsksFirstAndAnyOtherAppliesAtOnce() async throws {
        let basic = row("dashboard_auth/basic", name: "basic")
        let host = hostWithPlugins([basic, row("disk-cleanup")])
        let model = model(on: host)
        await model.load()
        let before = toggles(on: host)

        model.requestToggle(try XCTUnwrap(model.plugins.first), to: false)
        XCTAssertEqual(model.pendingToggle?.plugin.key, "dashboard_auth/basic")
        XCTAssertEqual(toggles(on: host), before, "nothing goes out before the answer")

        host.always("plugins.manage", .init(result: toggled(row("dashboard_auth/basic", name: "basic", status: "disabled"))))
        let sent = expectation(description: "the toggle reached the host")
        host.expect(sent, onNext: "plugins.manage")
        model.confirmPendingToggle()
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(toggles(on: host), before + 1)
    }

    func testOnlyAConnectedPlatformOrTheActiveMemoryProviderNeedsAWarning() throws {
        let telegram = try XCTUnwrap(HermesPlugin(row("platforms/telegram", name: "telegram-platform")))
        let signal = try XCTUnwrap(HermesPlugin(row("platforms/signal", name: "signal-platform")))
        let honcho = try XCTUnwrap(HermesPlugin(row("honcho", source: "user")))
        let known = HermesPluginStakes(connectedPlatforms: ["telegram": "Telegram"], memoryProvider: "honcho")

        XCTAssertNotNil(known.warning(for: telegram, turningOn: false))
        XCTAssertNil(known.warning(for: signal, turningOn: false))
        XCTAssertNotNil(known.warning(for: honcho, turningOn: false))
        XCTAssertNil(HermesPluginStakes(connectedPlatforms: [:], memoryProvider: "").warning(for: honcho, turningOn: false))
        XCTAssertNotNil(HermesPluginStakes().warning(for: signal, turningOn: false), "an unread state errs toward asking")
        XCTAssertNotNil(HermesPluginStakes().warning(for: honcho, turningOn: false), "an unread provider could be any user install")
    }

    func testOnlyAnEnableReadsWhatWaitsForTheNextSession() {
        let reply = toggled(row("disk-cleanup"), extra: [
            "activation": .object(["deferred": .object(["tools": .array([.string("cleanup")])])])
        ])
        XCTAssertTrue(HermesPluginChange(reply, enabling: true).waitsForNextSession)
        XCTAssertFalse(HermesPluginChange(reply, enabling: false).waitsForNextSession,
                       "a disable's activation is an earlier load's summary")
    }

    func testAReadThatLeftBeforeAToggleGoesOutAgain() async throws {
        let host = hostWithPlugins([row("disk-cleanup", status: "not enabled"), row("google_meet", status: "not enabled")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        host.withhold("plugins.manage")
        let sent = expectation(description: "the refresh reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let refresh = Task { await model.load() }
        await fulfillment(of: [sent], timeout: 5)
        host.allow("plugins.manage")
        host.next("plugins.manage", .init(result: toggled(row("disk-cleanup"))))
        host.next("plugins.manage", .init(result: list([row("disk-cleanup"), row("google_meet")])))
        await model.apply(plugin, turningOn: true)

        http.gateway.dropSocket() // the refresh ends only now, after the toggle
        await refresh.value
        XCTAssertEqual(model.plugins.map(\.isEnabled), [true, true], "the toggle holds, and the refresh still lands")
    }

    func testARefusalShowsTheHostsReasonAndKeepsTheRow() async throws {
        let host = hostWithPlugins([row("disk-cleanup", status: "not enabled")])
        let model = model(on: host)
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        host.next("plugins.manage", .init(error: 5026, message: "venv: uv sync exited 2"))
        await model.apply(plugin, turningOn: true)

        XCTAssertEqual(model.notice, .refused("venv: uv sync exited 2"))
        XCTAssertFalse(model.isOn(plugin))
        XCTAssertFalse(model.isToggling(plugin))
    }

    func testAToggleCutOffByADroppedConnectionIsUnconfirmedAndNeverResent() async throws {
        let host = hostWithPlugins([row("disk-cleanup", status: "not enabled")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)
        let sends = toggles(on: host)

        host.withhold("plugins.manage")
        let sent = expectation(description: "the toggle reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let toggle = Task { await model.apply(plugin, turningOn: true) }
        await fulfillment(of: [sent], timeout: 5)
        host.allow("plugins.manage")
        host.next("plugins.manage", .init(result: list([row("disk-cleanup")])))
        http.gateway.dropSocket()
        await toggle.value

        guard case .unconfirmed = model.notice else { return XCTFail("Expected an unconfirmed result, got \(String(describing: model.notice))") }
        XCTAssertEqual(toggles(on: host), sends + 1, "an unconfirmed toggle is never resent")
        XCTAssertTrue(try XCTUnwrap(model.plugins.first).isEnabled, "the row shows what the host reports now")
    }

    func testAHostWithoutTheMethodSaysSo() async {
        let host = BotSocketHost()
        host.always("profiles.list", .init(result: profiles))
        let model = model(on: host)
        await model.load()
        guard case .failed(let message) = model.state else { return XCTFail("Expected a failed state") }
        XCTAssertNotEqual(message, BotFailure.rejected(-32601).localizedDescription, "not the connection's generic refusal")
    }

    func testRestartNamesTheProfileAndOnlyGoesOutWhenAsked() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let model = PluginsModel(client: HermesPluginsClient(http: host.connection(record, rest: { request in
            request.url?.path == "/api/gateway/restart" ? .json(200, .object(["ok": .bool(true)])) : nil
        })))
        await model.load()
        await model.select("dev")
        host.next("plugins.manage", .init(result: toggled(row("disk-cleanup", status: "disabled"), extra: ["restart_required": .bool(true)])))
        await model.apply(try XCTUnwrap(model.plugins.first), turningOn: false)
        XCTAssertTrue(model.needsRestart)
        XCTAssertEqual(HermesHostFixture.count("/api/gateway/restart"), 0, "a change never restarts on the user's behalf")

        await model.restartGateway()

        let restart = try XCTUnwrap(HermesHostFixture.requests.last { $0.url?.path == "/api/gateway/restart" })
        XCTAssertEqual(restart.httpMethod, "POST")
        XCTAssertEqual(restart.url?.query, "profile=dev")
        XCTAssertFalse(model.needsRestart)
    }

    func testUndoingAChangeClearsOnlyItsOwnRestart() async throws {
        let host = hostWithPlugins([row("disk-cleanup"), row("google_meet")])
        let model = model(on: host)
        await model.load()
        let cleanup = try XCTUnwrap(model.plugins.first), meet = try XCTUnwrap(model.plugins.last)
        let off: [String: BotJSON] = ["restart_required": .bool(true)]

        host.next("plugins.manage", .init(result: toggled(row("disk-cleanup", status: "disabled"), extra: off)))
        await model.apply(cleanup, turningOn: false)
        host.next("plugins.manage", .init(result: toggled(row("google_meet", status: "disabled"), extra: off)))
        await model.apply(meet, turningOn: false)
        host.next("plugins.manage", .init(result: toggled(row("disk-cleanup"))))
        await model.apply(cleanup, turningOn: true)
        XCTAssertTrue(model.needsRestart, "google_meet still waits for one")

        host.next("plugins.manage", .init(result: toggled(row("google_meet"))))
        await model.apply(meet, turningOn: true)
        XCTAssertFalse(model.needsRestart)
    }

    // MARK: Fixtures

    private var profiles: BotJSON {
        .object(["profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]), .object(["name": .string("dev")])
        ])])
    }

    private func hostWithPlugins(_ rows: [BotJSON]) -> BotSocketHost {
        let host = BotSocketHost()
        host.always("profiles.list", .init(result: profiles))
        host.always("plugins.manage", .init(result: list(rows)))
        return host
    }

    private func model(on host: BotSocketHost) -> PluginsModel {
        PluginsModel(client: HermesPluginsClient(http: host.connection(record)))
    }

    private func toggles(on host: BotSocketHost) -> Int {
        host.requests.filter { $0["params"]["action"].text == "toggle" }.count
    }

    private func list(_ rows: [BotJSON]) -> BotJSON {
        .object(["plugins": .array(rows), "user_count": .number(0), "bundled_count": .number(Double(rows.count))])
    }

    private func toggled(_ plugin: BotJSON, extra: [String: BotJSON] = [:]) -> BotJSON {
        .object(["ok": .bool(true), "unchanged": .bool(false), "restart_required": .bool(false),
                 "gateway_reloaded": .bool(false), "name": plugin["key"], "plugin": plugin].merging(extra) { $1 })
    }

    private func row(_ key: String, name: String? = nil, status: String = "enabled", source: String = "bundled") -> BotJSON {
        .object(["key": .string(key), "name": .string(name ?? key), "source": .string(source), "status": .string(status)])
    }
}
