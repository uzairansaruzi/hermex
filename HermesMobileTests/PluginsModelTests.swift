import Observation
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

    func testTheInstallFieldReadsEverythingPeoplePaste() {
        let cases: [(String, PluginInstallInput)] = [
            ("  ", .empty),
            ("owner/repo", .repo("owner/repo")),
            ("git@github.com:owner/repo.git", .repo("git@github.com:owner/repo.git")),
            ("apify", .catalogName("apify")),
            (" hermes plugins install apify\n", .catalogName("apify")),
            ("hermes plugins install --force owner/repo", .repo("owner/repo")),
            ("hermes://plugin/install?catalog=apify", .catalogName("apify")),
            ("hermes://plugin/install?repo=owner/repo&force=1", .repo("owner/repo")),
            ("hermes://plugin/install?catalog=owner/repo", .invalid),
            ("hermes://connections/done", .invalid),
            ("two words", .invalid),
            ("Apify", .invalid)
        ]
        for (raw, expected) in cases { XCTAssertEqual(PluginInstallInput(raw), expected, raw) }
    }

    func testACatalogInstallNamesOnlyTheEntryOnTheProfileAsked() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let model = model(on: host)
        await model.load()
        await model.select("dev")

        host.next("plugins.manage", .init(result: installed("apify")))
        let result = await model.install(.catalog(name: "apify", pin: "4d492b1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), profile: "dev", replace: false, enable: true)

        XCTAssertEqual(result, .finished)
        let params = try XCTUnwrap(host.requests.last { $0["params"]["action"].text == "install" })["params"]
        XCTAssertEqual(params["catalog_name"].text, "apify")
        XCTAssertEqual(params["ref"].text, "4d492b1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "the commit the review showed, not a disabled copy's")
        XCTAssertEqual(params["profile"].text, "dev")
        XCTAssertEqual(params["identifier"], .null, "a catalog install is never turned into a repo install")
        XCTAssertEqual(params["force"], .null)
    }

    func testReplaceIsOfferedOnlyWhenTheHostSaysThePluginExists() async {
        let host = hostWithPlugins([row("disk-cleanup")])
        let model = model(on: host)
        await model.load()

        host.next("plugins.manage", .init(error: 5026, message: "Plugin 'apify' already exists. Use force reinstall or run `hermes plugins update apify`."))
        let exists = await model.install(.catalog(name: "apify", pin: ""), profile: "default", replace: false, enable: true)
        guard case .alreadyExists = exists else { return XCTFail("Expected Replace to be offered, got \(exists)") }
        XCTAssertEqual(host.requests.filter { $0["params"]["force"].flag == true }.count, 0, "nothing replaces on its own")

        host.next("plugins.manage", .init(error: 5026, message: "enable refused: a dependency conflict"))
        let refused = await model.install(.repo("owner/repo"), profile: "default", replace: false, enable: true)
        XCTAssertEqual(refused, .refused("enable refused: a dependency conflict"))

        host.next("plugins.manage", .init(result: installed("apify")))
        _ = await model.install(.catalog(name: "apify", pin: ""), profile: "default", replace: true, enable: true)
        XCTAssertEqual(host.requests.filter { $0["params"]["force"].flag == true }.count, 1)
    }

    func testAnInstallCutOffByADroppedConnectionIsUnconfirmedAndNeverResent() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()

        host.withhold("plugins.manage")
        let sent = expectation(description: "the install reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let install = Task { await model.install(.repo("owner/repo"), profile: "default", replace: false, enable: true) }
        await fulfillment(of: [sent], timeout: 5)
        host.allow("plugins.manage")
        host.next("plugins.manage", .init(result: list([row("disk-cleanup"), row("repo", source: "git")])))
        http.gateway.dropSocket()
        let result = await install.value

        XCTAssertEqual(result, .finished)
        guard case .unconfirmed = model.notice else { return XCTFail("Expected an unconfirmed result, got \(String(describing: model.notice))") }
        XCTAssertEqual(host.requests.filter { $0["params"]["action"].text == "install" }.count, 1)
        XCTAssertEqual(model.plugins.map(\.key), ["disk-cleanup", "repo"], "the list shows what the host reports now")
    }

    func testMissingKeysAreSavedToTheProfileThatInstalledThePlugin() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let model = PluginsModel(client: HermesPluginsClient(http: host.connection(record, rest: { request in
            request.url?.path == "/api/env" ? .json(200, .object(["ok": .bool(true)])) : nil
        })))
        await model.load()
        await model.select("dev")

        host.next("plugins.manage", .init(result: installed("homeassistant", extra: ["missing_env": .array([.string("HASS_TOKEN")])])))
        _ = await model.install(.catalog(name: "homeassistant", pin: ""), profile: "dev", replace: false, enable: true)
        XCTAssertEqual(model.setup, .init(profile: "dev", name: "homeassistant", keys: ["HASS_TOKEN"]))

        host.next("plugins.manage", .init(result: .object(["ok": .bool(true), "name": .string("homeassistant")])))
        try await model.saveKey("HASS_TOKEN", value: "secret")

        XCTAssertEqual(HermesHostFixture.requests.last { $0.url?.path == "/api/env" }?.httpMethod, "PUT")
        XCTAssertNil(model.setup, "the last key finishes it")
        let params = try XCTUnwrap(host.requests.last { $0["params"]["action"].text == "settings" })["params"]
        XCTAssertEqual(params["key"].text, "homeassistant")
        XCTAssertEqual(params["profile"].text, "dev")
        XCTAssertEqual(params["values"], .object([:]), "it tells the host, without the key's value")
    }

    func testAKeySaveEndingAfterASwitchLeavesTheNewProfileAlone() async throws {
        let host = hostWithPlugins([row("disk-cleanup")])
        let model = PluginsModel(client: HermesPluginsClient(http: host.connection(record, rest: { request in
            request.url?.path == "/api/env" ? .park : nil
        })))
        await model.load()
        host.next("plugins.manage", .init(result: installed("homeassistant", extra: ["missing_env": .array([.string("HASS_TOKEN")])])))
        _ = await model.install(.catalog(name: "homeassistant", pin: ""), profile: "default", replace: false, enable: true)

        let parked = expectation(description: "the save is on its way")
        HermesHostFixture.onPark = { parked.fulfill() }
        let save = Task { try await model.saveKey("HASS_TOKEN", value: "secret") }
        await fulfillment(of: [parked], timeout: 5)
        await model.select("dev")
        HermesHostFixture.releaseParked(.json(200, .object(["ok": .bool(true)])))
        try await save.value

        XCTAssertNil(model.notice, "dev never saved anything")
    }

    func testACancelledCallerDoesntTakeTheCatalogReadDownWithIt() async {
        let model = PluginsModel(client: HermesPluginsClient(http: BotSocketHost().connection(record, rest: { request in
            request.url?.path == "/api/dashboard/plugins/catalog" ? .park : nil
        })))
        let parked = expectation(description: "the catalog is on its way")
        HermesHostFixture.onPark = { parked.fulfill() }
        let keystroke = Task { await model.loadCatalog() }
        await fulfillment(of: [parked], timeout: 5)
        keystroke.cancel()
        HermesHostFixture.releaseParked(.json(200, .object(["entries": .array([.object(["name": .string("apify")])])])))
        await model.loadCatalog()

        guard case .catalog = model.review(of: .catalogName("apify")) else { return XCTFail("Expected the entry, got \(model.catalog)") }
    }

    func testConfirmingARemovalSendsItEvenThoughTheAlertClearsThePendingOne() async throws {
        let host = hostWithPlugins([row("apify", source: "user")])
        let model = model(on: host)
        await model.load()
        await model.select("dev")
        model.pendingRemoval = try XCTUnwrap(model.plugins.first)
        XCTAssertFalse(host.requests.contains { $0["params"]["action"].text == "remove" })

        host.next("plugins.manage", .init(result: .object(["ok": .bool(true), "name": .string("apify")])))
        let sent = expectation(description: "the removal reached the host")
        host.expect(sent, onNext: "plugins.manage")
        model.confirmPendingRemoval()
        model.pendingRemoval = nil // what the alert's binding does as it closes
        await fulfillment(of: [sent], timeout: 5)

        let params = try XCTUnwrap(host.requests.last { $0["params"]["action"].text == "remove" })["params"]
        XCTAssertEqual(params["name"].text, "apify")
        XCTAssertEqual(params["profile"].text, "dev")
    }

    func testTheReviewNeverOffersARemovedOrUnlistedNameAndSplitsTheDisclosure() async throws {
        let catalog: BotJSON = .object([
            "entries": .array([
                .object(["name": .string("apify"),
                         "requires_hermes": .string(">=0.23"),
                         "description": .string("Run Actors.\n Disclosure: Runs go to Apify. Apify bills them.")]),
                .object(["description": .string("A row with no name is left out.")])
            ]),
            "removed": .array([.object(["name": .string("or-picker"), "reason": .string("Folded into openrouter-picker.")])])
        ])
        let model = PluginsModel(client: HermesPluginsClient(http: BotSocketHost().connection(record, rest: { request in
            request.url?.path == "/api/dashboard/plugins/catalog" ? .json(200, catalog) : nil
        })))
        await model.loadCatalog()

        XCTAssertEqual(model.review(of: .catalogName("or-picker")), .removed("or-picker", reason: "Folded into openrouter-picker."))
        XCTAssertEqual(model.review(of: .catalogName("nope")), .notInCatalog("nope"))
        guard case .catalog(let entry) = model.review(of: .catalogName("apify")) else { return XCTFail("Expected the entry") }
        XCTAssertEqual(entry.summary, "Run Actors.")
        XCTAssertEqual(entry.disclosure, "Runs go to Apify. Apify bills them.")
        XCTAssertTrue(entry.isTooNew(forHost: "0.22.5"))
        XCTAssertFalse(entry.isTooNew(forHost: "0.23.0"))
        XCTAssertFalse(entry.isTooNew(forHost: nil), "the host checks an unread version itself")
    }

    func testDiscoverOrdersByTierAndKeepsDesktopPluginsOutOfTheMainList() throws {
        let catalog = try HermesPluginCatalog(try JSONEncoder().encode(BotJSON.object(["entries": .array([
            entry("zeta", tier: "community", category: "tools"), entry("meet", tier: "official", category: "tools"),
            entry("palette", tier: "official", category: "desktop"), entry("pay", tier: "verified", category: "web"),
            entry("odd", tier: "brand-new-tier", category: "tools")
        ])])))

        XCTAssertEqual(catalog.groups(query: "", category: nil).map { $0.entries.map(\.name) }, [["meet"], ["pay"], ["zeta", "odd"]])
        XCTAssertEqual(catalog.groups(query: "", category: "desktop").flatMap(\.entries).map(\.name), ["palette"])
        XCTAssertEqual(catalog.groups(query: " PALETTE ", category: nil).flatMap(\.entries).map(\.name), ["palette"], "search finds them")
        XCTAssertEqual(catalog.groups(query: "meet", category: "web"), [], "search stays inside a category")
    }

    func testOnlyGitHubHTTPSImagesAreFetchedAndSVGsAreSkipped() {
        let allowed = ["https://raw.githubusercontent.com/o/r/abc/banner.png", "https://github.com/o/r/raw/main/a.jpg",
                       "https://gist.githubusercontent.com/o/1/raw/a.gif"]
        let refused = ["http://raw.githubusercontent.com/o/r/a.png", "https://example.com/a.png",
                       "https://githubusercontent.com.evil.example/a.png", "https://raw.githubusercontent.com/o/r/a.SVG", ""]
        for url in allowed { XCTAssertNotNil(PluginCatalogImageRule.url(url), url) }
        for url in refused { XCTAssertNil(PluginCatalogImageRule.url(url), url) }
    }

    func testInstalledAndRemovedAreReadForTheShownProfile() async throws {
        let host = hostWithPlugins([row("hermex-push", source: "user")])
        let catalog: BotJSON = .object([
            "entries": .array([.object(["name": .string("apify"), "installed": .bool(true)])]),
            "removed": .array([.object(["name": .string("or-picker"), "reason": .string("Folded into openrouter-picker.")])])
        ])
        let model = PluginsModel(client: HermesPluginsClient(http: host.connection(record, rest: { request in
            request.url?.path == "/api/dashboard/plugins/catalog" ? .json(200, catalog) : nil
        })))
        host.next("plugins.manage", .init(result: list([
            .object(["key": .string("or_picker"), "name": .string("or_picker"), "source": .string("user"), "status": .string("enabled"),
                     "catalog_name": .string("or-picker")])
        ])))
        await model.load()
        await model.loadCatalog()

        let removed = try XCTUnwrap(model.plugins.first)
        XCTAssertEqual(model.removalReason(for: removed), "Folded into openrouter-picker.")
        XCTAssertEqual(model.installedCatalogNames, ["or-picker"], "the catalog's own `installed` reads another Profile")

        await model.select("dev")
        XCTAssertEqual(model.installedCatalogNames, ["hermex-push"])

        host.next("plugins.manage", .init(error: 4064, message: "profile 'gone' not found"))
        await model.select("gone")
        XCTAssertNil(model.installedCatalogNames, "a Profile whose list failed offers no installs")
    }

    func testAWideningUpdateThenACautionScanEachWaitForTheirOwnAnswer() async throws {
        let host = hostWithPlugins([row("spotify", source: "user")])
        let model = model(on: host)
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        host.next("plugins.manage", .init(result: .object(["ok": .bool(false), "consent_required": .bool(true),
                                                           "delta_lines": .array([.string("tools: spotify_library")])])))
        await model.update(plugin)
        XCTAssertEqual(model.updateReview?.reason, .newAbilities(["tools: spotify_library"]))
        XCTAssertEqual(updates(on: host).last?["accept_capabilities"], .null, "the first ask accepts nothing")

        host.next("plugins.manage", .init(result: scan("caution")))
        await accepting(try XCTUnwrap(model.updateReview), on: model, host: host)
        XCTAssertEqual(updates(on: host).last?["accept_capabilities"], .bool(true))
        XCTAssertEqual(updates(on: host).last?["force"], .null, "consent isn't an answer to a scan")
        await waitForReview(on: model)
        guard case .scan(true, let findings) = model.updateReview?.reason else { return XCTFail("Expected findings to read") }
        XCTAssertEqual(findings.first?.location, "a.py:3")

        host.next("plugins.manage", .init(result: .object(["ok": .bool(true), "unchanged": .bool(false)])))
        await accepting(try XCTUnwrap(model.updateReview), on: model, host: host)
        XCTAssertEqual(updates(on: host).last?["force"], .bool(true))
        XCTAssertEqual(updates(on: host).last?["accept_capabilities"], .bool(true), "the earlier answer holds")
    }

    func testADangerousScanOrAFutureVerdictCanNeverBeAccepted() async throws {
        for verdict in ["dangerous", "a-future-verdict"] {
            let host = hostWithPlugins([row("spotify", source: "user")])
            let model = model(on: host)
            await model.load()
            host.next("plugins.manage", .init(result: scan(verdict)))
            await model.update(try XCTUnwrap(model.plugins.first))
            let review = try XCTUnwrap(model.updateReview)
            let sent = updates(on: host).count

            model.accept(review)
            await model.load() // a round trip, so anything accepting queued has gone out by now

            XCTAssertEqual(model.updateReview, review, verdict)
            XCTAssertEqual(updates(on: host).count, sent, verdict)
        }
    }

    func testAcceptingAReviewThatsNoLongerShownSendsNothing() async throws {
        let host = hostWithPlugins([row("spotify", source: "user")])
        let model = model(on: host)
        await model.load()
        host.next("plugins.manage", .init(result: scan("caution")))
        await model.update(try XCTUnwrap(model.plugins.first))
        let shown = try XCTUnwrap(model.updateReview)
        let sent = updates(on: host).count

        await model.select("dev")
        model.accept(shown)
        await model.load() // a round trip, so anything accepting queued has gone out by now

        XCTAssertNil(model.updateReview)
        XCTAssertEqual(updates(on: host).count, sent, "a switch ended it, and an answer can't reach another Profile")
    }

    func testAnUpdateCutOffByADroppedConnectionIsUnconfirmedAndNeverResent() async throws {
        let host = hostWithPlugins([row("spotify", source: "user")])
        let http = host.connection(record)
        let model = PluginsModel(client: HermesPluginsClient(http: http))
        await model.load()
        let plugin = try XCTUnwrap(model.plugins.first)

        host.withhold("plugins.manage")
        let sent = expectation(description: "the update reached the host")
        host.expect(sent, onNext: "plugins.manage")
        let update = Task { await model.update(plugin) }
        await fulfillment(of: [sent], timeout: 5)
        host.allow("plugins.manage")
        http.gateway.dropSocket()
        await update.value

        guard case .unconfirmed = model.notice else { return XCTFail("Expected an unconfirmed result, got \(String(describing: model.notice))") }
        XCTAssertEqual(updates(on: host).count, 1)
    }

    func testEachFieldTypeReadsItsTextAsTheHostNeedsIt() throws {
        func field(_ type: String, value: BotJSON = .null) throws -> HermesPluginSetting {
            try XCTUnwrap(HermesPluginSetting(.object(["key": .string("k"), "type": .string(type), "value": value])))
        }
        XCTAssertEqual(try field("string").parse(""), .unset, "an empty field with no value isn't a change")
        XCTAssertEqual(try field("number").parse("5"), .value(.number(5)))
        XCTAssertEqual(try field("number", value: .number(3)).text, "3")
        guard case .invalid = try field("number").parse("five") else { return XCTFail("Expected a problem") }
        XCTAssertEqual(try field("boolean").parse(""), .unset, "an untouched switch with no value isn't a change")
        XCTAssertEqual(try field("json").parse("[\"a\"]"), .value(.array([.string("a")])))
        guard case .invalid = try field("json").parse("5") else { return XCTFail("The host takes only a list or object") }
        XCTAssertEqual(try field("json", value: .object(["k": .number(1)])).text, "{\"k\":1}")
        XCTAssertNil(HermesPluginSetting(.object(["key": .string("k"), "type": .string("a-future-type")])), "an unknown type isn't shown or sent")
        XCTAssertNil(HermesPluginSetting(.object(["key": .string("k"), "type": .string("secret")])), "a secret needs somewhere to go")
    }

    func testSettingsGoToTheShownProfileAndShowTheHostsRefusal() async throws {
        let schema: BotJSON = .array([.object(["key": .string("retries"), "type": .string("number"), "value": .number(3)])])
        let rowWithForm: BotJSON = .object(["key": .string("form"), "name": .string("form"), "source": .string("user"),
                                            "status": .string("enabled"), "settings_schema": schema])
        let host = hostWithPlugins([rowWithForm])
        let model = model(on: host)
        await model.load()
        await model.select("dev")
        host.next("plugins.manage", .init(error: 4021, message: "'retries' should be number (got str)"))
        let plugin = try XCTUnwrap(model.plugins.first)

        let refusal = await model.saveSettings(plugin, values: ["retries": .number(5)])

        XCTAssertEqual(refusal, "'retries' should be number (got str)")
        let params = try XCTUnwrap(host.requests.last { $0["params"]["action"].text == "settings" })["params"]
        XCTAssertEqual(params["profile"].text, "dev")
        XCTAssertEqual(params["key"].text, "form")
    }

    func testASecretGoesToTheEnvAndOnlyAnEmptySettingsCallFollows() async throws {
        let host = hostWithPlugins([row("form", source: "user")])
        let model = PluginsModel(client: HermesPluginsClient(http: host.connection(record, rest: { request in
            request.url?.path == "/api/env" ? .json(200, .object(["ok": .bool(true)])) : nil
        })))
        await model.load()
        await model.select("dev")
        host.next("plugins.manage", .init(result: .object(["ok": .bool(true), "name": .string("form")])))

        try await model.setSecret("FORM_TOKEN", value: "secret", of: try XCTUnwrap(model.plugins.first))

        XCTAssertEqual(HermesHostFixture.requests.last { $0.url?.path == "/api/env" }?.httpMethod, "PUT")
        let params = try XCTUnwrap(host.requests.last { $0["params"]["action"].text == "settings" })["params"]
        XCTAssertEqual(params["profile"].text, "dev")
        XCTAssertEqual(params["values"], .object([:]), "a secret's value never reaches plugins.manage")
    }

    func testHermexManagedPluginsNeverOfferAnUpdateHere() throws {
        let row: BotJSON = .object(["key": .string("hermex-screen"), "update_available": .bool(true)])
        XCTAssertFalse(try XCTUnwrap(HermesPlugin(row)).hasUpdate, "its own page and the app's pin update it")
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

    /// Lets the accepted update's reply land, which opens the next review.
    private func waitForReview(on model: PluginsModel) async {
        let reviewed = expectation(description: "the next review opened")
        reviewed.assertForOverFulfill = false
        func observe() {
            withObservationTracking { if model.updateReview != nil { reviewed.fulfill() } } onChange: {
                Task { @MainActor in observe() }
            }
        }
        observe()
        await fulfillment(of: [reviewed], timeout: 5)
    }

    private func scan(_ verdict: String) -> BotJSON {
        .object(["ok": .bool(false), "scan_blocked": .bool(true), "scan_verdict": .string(verdict),
                 "scan_findings": .array([.object(["severity": .string("high"), "description": .string("Runs curl"),
                                                   "file": .string("a.py"), "line": .number(3)])])])
    }

    /// Accepts `review` and waits for what that sends to reach the host.
    private func accepting(_ review: PluginsModel.UpdateReview, on model: PluginsModel, host: BotSocketHost) async {
        let sent = expectation(description: "the accepted update reached the host")
        host.expect(sent, onNext: "plugins.manage")
        model.accept(review)
        await fulfillment(of: [sent], timeout: 5)
    }

    private func updates(on host: BotSocketHost) -> [BotJSON] {
        host.requests.filter { $0["params"]["action"].text == "update" }.map { $0["params"] }
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

    private func entry(_ name: String, tier: String, category: String) -> BotJSON {
        .object(["name": .string(name), "tier": .string(tier), "category": .string(category)])
    }

    private func installed(_ name: String, extra: [String: BotJSON] = [:]) -> BotJSON {
        .object(["ok": .bool(true), "plugin_name": .string(name), "enabled": .bool(true), "missing_env": .array([]),
                 "restart_required": .bool(false), "gateway_reloaded": .bool(true)].merging(extra) { $1 })
    }

    private func row(_ key: String, name: String? = nil, status: String = "enabled", source: String = "bundled") -> BotJSON {
        .object(["key": .string(key), "name": .string(name ?? key), "source": .string(source), "status": .string(status)])
    }
}
