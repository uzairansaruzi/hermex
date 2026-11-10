import CoreGraphics
import Observation
import XCTest
@testable import HermesMobile

/// The Screen's states and control rules over a scripted gateway and stream socket.
@MainActor final class ScreenSessionTests: XCTestCase {
    private let host = BotSocketHost()
    private let server = URL(string: "https://hermes.example")!
    private var holds = ScreenHoldStore(keychain: InMemoryKeychainStore(), idleNotification: .off)
    private let opened = OpenedStreams()
    private var sockets: [ScriptedRFBSocket] { opened.sockets }
    private var upgrades: [URLRequest] { opened.upgrades }
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(backoff: [Duration] = [.zero], configure: (inout ScreenSession.Options) -> Void = { _ in }) -> ScreenSession {
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        var options = ScreenSession.Options()
        options.backoff = backoff
        options.holds = holds
        options.now = { [unowned self] in clock }
        options.socketFactory = { [unowned self] upgrade in
            let socket = ScriptedRFBSocket()
            opened.add(socket, upgrade)
            return socket
        }
        configure(&options)
        return ScreenSession(profile: "work", title: "Work", server: server,
                             client: BotClient(http: host.connection(record)), options: options)
    }

    private func lease(holder: String = "agent", viewer: String? = nil) -> BotJSON {
        .object(["holder": .string(holder), "viewer_hash": viewer.map { .string(ScreenLease.hash($0)) } ?? .null])
    }

    private func screen(running: Bool = true, supported: Bool = true, viewer: String = "viewer-1", lease: BotJSON? = nil) -> BotJSON {
        .object([
            "supported": .bool(supported), "running": .bool(running), "ticket": .string("ticket-1"),
            "viewer_id": .string(viewer), "lease": lease ?? self.lease(), "profile_key": .string("/home/work"),
            "some_future_field": .bool(true)
        ])
    }

    /// A host whose screen runs, minting `viewer` and reporting `lease`.
    private func standUp(viewer: String = "viewer-1", lease: BotJSON? = nil) {
        host.always("display.status", .init(result: screen(viewer: viewer, lease: lease)))
        host.always("display.observe", .init(result: screen(viewer: viewer, lease: lease)))
    }

    private func requests(_ method: String) -> [BotJSON] {
        host.requests.filter { $0["method"].text == method }
    }

    private func reach(_ phase: ScreenSession.Phase, on session: ScreenSession) async {
        while session.phase != phase {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = session.phase } onChange: { continuation.resume() }
            }
        }
    }

    private func reach(_ control: ScreenSession.Control, on session: ScreenSession) async {
        while session.control != control {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = session.control } onChange: { continuation.resume() }
            }
        }
    }

    private func socket(_ index: Int) async -> ScriptedRFBSocket {
        await waitUntil("stream \(index) opened") { [opened] in opened.sockets.count > index }
        return sockets[index]
    }

    /// Streams a frame, then takes over as `viewer`.
    private func holding(viewer: String = "viewer-1", configure: (inout ScreenSession.Options) -> Void = { _ in }) async -> ScreenSession {
        standUp(viewer: viewer)
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: viewer)])))
        let session = makeSession(configure: configure)
        session.open()
        await socket(sockets.count).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await reach(.mine, on: session)
        return session
    }

    // MARK: - Watching

    func testARunningScreenStreamsOnATicketAndPutsFramesOnTheStore() async throws {
        standUp()
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        let image = try XCTUnwrap(session.frames.image)
        XCTAssertEqual(image.width, 2)
        let url = try XCTUnwrap(upgrades.first?.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api/display/ws")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "display_ticket" }?.value, "ticket-1")
        XCTAssertEqual(requests("display.observe").first?["params"]["profile"].text, "work")
        session.leave()
    }

    func testAStoppedScreenShowsItsStateWithoutSpendingATicket() async {
        host.always("display.status", .init(result: screen(running: false)))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        XCTAssertTrue(requests("display.observe").isEmpty)
        session.leave()
    }

    func testAHostWithoutTheMethodsSaysSo() async {
        host.always("display.status", .init(error: -32601))
        let lacking = makeSession()
        lacking.open()
        await reach(.unavailable, on: lacking)
        lacking.leave()
    }

    /// 5300 with no `data.code` is a state: the screen stopped between the two calls.
    func testObserveRefusedWithNoCodeReadsAsAStoppedScreen() async {
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(error: 5300))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        session.leave()
    }

    func testASpentTicketOpensAgainOnANewOne() async {
        standUp()
        let session = makeSession(backoff: [.seconds(3600)])
        session.open()
        await socket(0).end(code: 4401)
        // No wait: a backoff of an hour would stall this.
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.leave()
    }

    func testAScreenThatGoesAwayStopsAndABrokenStreamFails() async {
        standUp()
        let gone = makeSession()
        gone.open()
        await socket(0).end(code: 4001)
        await reach(.stopped, on: gone)
        gone.leave()

        let broken = makeSession()
        broken.open()
        await socket(1).serve(Data("not rfb at all".utf8))
        await reach(.failed, on: broken)
        broken.leave()
    }

    /// The last picture stays, dimmed by the view, until the retry's first frame.
    func testADroppedStreamRetriesAndKeepsThePicture() async throws {
        standUp()
        let session = makeSession(backoff: [.milliseconds(1)])
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        await socket(0).end(error: URLError(.networkConnectionLost))
        await reach(.reconnecting, on: session)
        XCTAssertNotNil(session.frames.image)
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.leave()
    }

    /// A proxy that refuses the upgrade won't start accepting it on its own.
    func testARefusedUpgradeStopsRetrying() async {
        standUp()
        let session = makeSession()
        session.open()
        await socket(0).end(error: BotFailure.upgradeRefused(403))
        await reach(.failed, on: session)
        session.leave()
    }

    /// A dead route can leave a read waiting forever, so a ping with no pong must end the stream.
    func testAPingThatFailsEndsAStreamWhoseReadIsParked() async {
        let socket = ScriptedRFBSocket()
        socket.pingFailure = URLError(.networkConnectionLost)
        var options = RFBClient.Options()
        options.keepalive = .milliseconds(1)
        let client = RFBClient(socket: socket, options: options) { _ in }
        do {
            try await client.run()
            XCTFail("run only returns by throwing")
        } catch {
            XCTAssertEqual(error as? RFBStreamEnd, .silent)
        }
    }

    // MARK: - Start and stop

    /// `Start Screen`, then the stream, with the status re-read in between.
    func testStartingAStoppedScreenStreamsIt() async throws {
        host.next("display.status", .init(result: screen(running: false)))
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        host.always("display.start", .init(result: screen()))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        session.start()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertEqual(requests("display.start").first?["params"]["profile"].text, "work")
        session.leave()
    }

    /// Control Center comes back without having interrupted anything, so a Start carries on.
    func testReturningToTheForegroundDoesNotInterruptAStart() async throws {
        host.next("display.status", .init(result: screen(running: false)))
        host.always("display.status", .init(result: screen()))
        host.always("display.observe", .init(result: screen()))
        host.withhold("display.start")
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        let sent = expectation(description: "start sent")
        host.expect(sent, onNext: "display.start")
        session.start()
        await fulfillment(of: [sent], timeout: 5)
        session.returnToForeground()
        XCTAssertEqual(session.phase, .starting)
        XCTAssertEqual(requests("display.status").count, 1)
        session.leave()
    }

    /// A refused start says why in the host's words, in place of Start.
    func testARefusedStartShowsTheHostsReason() async {
        host.always("display.status", .init(result: screen(running: false)))
        host.always("display.start", .init(error: 5300, message: "Not enough free memory for a desktop"))
        let session = makeSession()
        session.open()
        await reach(.stopped, on: session)
        session.start()
        await reach(.blocked("Not enough free memory for a desktop"), on: session)
        session.leave()
    }

    /// A sandbox short of its image reports a blocker as well as missing packages, and installing
    /// on the host wouldn't help, so the blocker wins.
    func testAScreenThatCantStartShowsItsBlockerThenItsMissingPackages() {
        let both = ScreenStatus(.object(["supported": .bool(true), "installed": .bool(false), "running": .bool(false),
                                         "blocker": .string("The sandbox lacks Xvnc"), "install_command": .string("sudo apt-get install")]))
        XCTAssertEqual(both.settledPhase, .blocked("The sandbox lacks Xvnc"))
        let missing = ScreenStatus(.object(["supported": .bool(true), "installed": .bool(false), "running": .bool(false),
                                            "install_command": .string("sudo apt-get install")]))
        XCTAssertEqual(missing.settledPhase, .needsPackages(command: "sudo apt-get install"))
    }

    /// Force only when someone else holds it: the host refuses a plain stop then.
    func testStoppingAScreenAsksForForceOnlyOverAnotherPerson() async throws {
        standUp()
        host.always("display.stop", .init(result: screen(running: false)))
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        host.always("display.status", .init(result: screen(running: false)))
        session.stopScreen(force: false)
        await reach(.stopped, on: session)
        XCTAssertEqual(requests("display.stop").last?["params"]["force"], .null)
        let forced = expectation(description: "forced stop")
        host.expect(forced, onNext: "display.stop")
        session.stopScreen(force: true)
        await fulfillment(of: [forced], timeout: 5)
        XCTAssertEqual(requests("display.stop").last?["params"]["force"].flag, true)
        session.leave()
    }

    /// A stop the host refused says so, and a retry that works clears that.
    func testARefusedStopReportsItAndARetryClearsIt() async {
        standUp()
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        host.next("display.stop", .init(error: 5300))
        session.stopScreen(force: false)
        await waitUntil("a notice") { session.notice != nil }
        XCTAssertEqual(session.notice, .stopFailed)

        host.always("display.stop", .init(result: screen(running: false)))
        host.always("display.status", .init(result: screen(running: false)))
        session.stopScreen(force: false)
        await reach(.stopped, on: session)
        XCTAssertNil(session.notice)
        session.leave()
    }

    /// Stopping a screen ends its lease, so a hold from before that is over, and says so.
    func testAScreenStoppedElsewhereEndsTheHold() async {
        let session = await holding()
        host.always("display.status", .init(result: screen(running: false)))
        await socket(0).end(code: 4001)
        await reach(.stopped, on: session)
        session.open()
        await reach(.bot, on: session)
        XCTAssertEqual(session.notice, .returnedToBot)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    // MARK: - Control

    func testTakeOverAcquiresWithTheMintedIDAndSavesIt() async throws {
        let session = await holding()
        let acquire = try XCTUnwrap(requests("display.lease.acquire").first)
        XCTAssertEqual(acquire["params"]["viewer_id"].text, "viewer-1")
        XCTAssertEqual(acquire["params"]["profile"].text, "work")
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["viewer-1"])
        session.suspend()
    }

    /// A chat's Take Over (#1632) opens the Screen and takes control at its first frame.
    func testTakingOverWhenLiveAcquiresAtTheFirstFrame() async {
        standUp()
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        let session = makeSession { $0.takesOverWhenLive = true }
        session.open()
        let stream = await socket(0)
        XCTAssertTrue(requests("display.lease.acquire").isEmpty, "nothing taken before the picture shows")
        await stream.serve(ScriptedRFBSocket.oneFrame)
        await reach(.mine, on: session)
        XCTAssertEqual(requests("display.lease.acquire").count, 1)
        session.suspend()
    }

    /// Switching apps keeps control: nothing releases, and the return moves the hold to the new
    /// socket's id with no prompt.
    func testReturningFromTheBackgroundTakesTheHoldBackUnderTheNewID() async throws {
        let session = await holding()
        session.suspend()
        XCTAssertTrue(requests("display.lease.release").isEmpty)
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["viewer-1"])

        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "viewer-1"))
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-2")])))
        session.open()
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        XCTAssertEqual(session.control, .mine)
        XCTAssertEqual(requests("display.lease.acquire").last?["params"]["viewer_id"].text, "viewer-2")
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["viewer-2"])
        session.suspend()
    }

    /// A hash that isn't ours means someone else took over meanwhile: no acquire, so no eviction.
    func testReturningToSomeoneElsesTakeoverWatchesWithoutTakingItBack() async {
        let session = await holding()
        session.suspend()
        let acquires = requests("display.lease.acquire").count

        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "someone-else"))
        session.open()
        await reach(.other, on: session)

        XCTAssertEqual(session.notice, .someoneTookOver)
        XCTAssertEqual(requests("display.lease.acquire").count, acquires)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// The release names the saved id, even from a connection that didn't mint it. The host then
    /// answers for that holder only, so someone else's takeover can't be revoked.
    func testHandBackReleasesTheSavedIDAndCountsOnlyWhenTheAgentHolds() async throws {
        let session = await holding()
        host.next("display.lease.release", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        session.handBack()
        await waitUntil("a notice") { session.notice != nil }
        XCTAssertEqual(session.notice, .handBackFailed)
        XCTAssertEqual(session.control, .mine)
        XCTAssertNotNil(holds.hold(server: server, profile: "work"))

        host.next("display.lease.release", .init(result: .object(["lease": lease()])))
        session.handBack()
        await reach(.bot, on: session)
        let release = try XCTUnwrap(requests("display.lease.release").last)
        XCTAssertEqual(release["params"]["viewer_id"].text, "viewer-1")
        XCTAssertEqual(release["params"]["force"].flag, true)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// The host's event can beat its reply, and a hand-back the user asked for isn't news to them.
    func testOwnHandBacksLeaseEventRaisesNoNotice() async throws {
        let session = await holding()
        let event: BotJSON = .object(["method": .string("event"), "params": .object([
            "type": .string("display.lease"), "payload": .object(["profile_key": .string("/home/work"), "lease": lease()])
        ])])
        host.next("display.lease.release", .init(result: .object(["lease": lease()]), before: [event]))
        session.handBack()
        await reach(.bot, on: session)
        await waitUntil("the hold is forgotten") { [holds, server] in
            _ = holds.revision
            return holds.hold(server: server, profile: "work") == nil
        }
        XCTAssertNil(session.notice)
        session.leave()
    }

    func testClosingTheViewWhileHoldingHandsBack() async throws {
        let session = await holding()
        let released = expectation(description: "release")
        host.expect(released, onNext: "display.lease.release")
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        session.leave()
        await fulfillment(of: [released], timeout: 5)
    }

    /// The host may have granted a Take Over whose reply hasn't come, so closing must still release it.
    func testClosingBeforeTheAcquireReplyStillHandsBack() async throws {
        standUp()
        host.withhold("display.lease.acquire")
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        let sent = expectation(description: "acquire sent")
        host.expect(sent, onNext: "display.lease.acquire")
        session.takeOver()
        await fulfillment(of: [sent], timeout: 5)

        let released = expectation(description: "release")
        host.expect(released, onNext: "display.lease.release")
        session.leave()
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(requests("display.lease.release").last?["params"]["viewer_id"].text, "viewer-1")
    }

    /// Last Take Over wins: code 4000 drops this viewer to watching, on a new ticket.
    func testAnotherPersonTakingOverDropsThisViewerToWatching() async {
        let session = await holding()
        standUp(viewer: "viewer-1", lease: lease(holder: "human", viewer: "someone-else"))
        await socket(0).end(code: 4000)
        await reach(.other, on: session)
        XCTAssertEqual(session.notice, .someoneTookOver)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.leave()
    }

    func testForceHandBackSendsNoIDAndNeedsNoHold() async throws {
        standUp(lease: lease(holder: "human", viewer: "a-stale-app"))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        let session = makeSession()
        session.open()
        await reach(.other, on: session)
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        session.forceHandBack()
        await reach(.bot, on: session)
        let release = try XCTUnwrap(requests("display.lease.release").last)
        XCTAssertEqual(release["params"]["viewer_id"], .null)
        XCTAssertEqual(release["params"]["force"].flag, true)
        session.leave()
    }

    /// `display.lease` reaches every attached screen, so only this screen's key may move control.
    func testALeaseEventForAnotherProfileChangesNothing() async {
        let session = await holding()
        session.handle(.object(["type": .string("display.lease"), "payload": .object([
            "profile_key": .string("/home/another"), "lease": lease()
        ])]))
        XCTAssertEqual(session.control, .mine)

        session.handle(.object(["type": .string("display.lease"), "payload": .object([
            "profile_key": .string("/home/work"), "lease": lease()
        ])]))
        XCTAssertEqual(session.control, .bot)
        XCTAssertEqual(session.notice, .returnedToBot)
        session.leave()
    }

    // MARK: - The host's desktop

    private let plugin = "/api/plugins/hermex-screen"

    /// A session on a host with no stock screen, whose plugin routes `rest` answers.
    private func makeHostSession(removesFromItsProfile: Bool = false, rest: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> ScreenSession {
        host.always("display.status", .init(result: screen(supported: false)))
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        var options = ScreenSession.Options()
        options.removesFromItsProfile = removesFromItsProfile
        options.backoff = [.zero]
        options.pluginRecheck = .zero
        options.holds = holds
        options.now = { [unowned self] in clock }
        options.socketFactory = { [unowned self] upgrade in
            let socket = ScriptedRFBSocket()
            opened.add(socket, upgrade)
            return socket
        }
        return ScreenSession(profile: "work", title: "Work", server: server,
                             client: BotClient(http: host.connection(record, rest: rest)), options: options)
    }

    private func pluginStatus(_ fields: [String: BotJSON] = [:]) -> BotJSON {
        .object(["supported": .bool(true), "driver": .object(["available": .bool(true)]),
                 "permissions": .object(["accessibility": .bool(true), "screen_recording": .bool(true)]),
                 "locked": .bool(false), "lease": lease()].merging(fields) { $1 })
    }

    private func requestBody(_ request: URLRequest) -> BotJSON {
        guard let stream = request.httpBodyStream else { return .null }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }

    /// A plugin that serves every route, recording what the app sent.
    private func livePlugin(_ overrides: @escaping (String) -> HermesHostFixture.Reply? = { _ in nil },
                            sent: @escaping (String, BotJSON) -> Void = { _, _ in }) -> (URLRequest) -> HermesHostFixture.Reply? {
        { [plugin, unowned self] request in
            guard let path = request.url?.path, path.hasPrefix(plugin) else { return nil }
            let route = String(path.dropFirst(plugin.count))
            sent(route, requestBody(request))
            if let reply = overrides(route) { return reply }
            switch route {
            case "/capabilities": return .json(200, .object(["routes": .array([])]))
            case "/status": return .json(200, pluginStatus())
            case "/observe": return .json(200, .object(["viewer_id": .string("viewer-1"), "stream_ticket": .string("plugin-ticket"), "lease": lease()]))
            case "/lease/acquire": return .json(200, .object(["lease": lease(holder: "human", viewer: "viewer-1")]))
            case "/lease/release": return .json(200, .object(["lease": lease()]))
            default: return nil
            }
        }
    }

    func testAPluginsRouteSaysWhereItStands() {
        func state(_ status: Int, _ fields: [String: BotJSON]) -> HermexScreenPlugin.State? {
            HermexScreenPlugin.State(status: status, body: .object(fields))
        }
        XCTAssertEqual(state(200, [:]), .live)
        XCTAssertEqual(state(404, ["detail": .string("Plugin not found")]), .notInstalled)
        XCTAssertEqual(state(404, ["detail": .string("No such API endpoint: /api/plugins/x")]), .notMounted)
        XCTAssertEqual(state(404, ["error": .string("Headless backend (hermes serve): web UI disabled")]), .notMounted)
        XCTAssertEqual(state(404, ["detail": .string("Not Found")]), .failedToLoad)
        XCTAssertNil(state(500, [:]))
    }

    func testAHostWithThePluginStreamsAndTakesOverThroughIt() async throws {
        var sent: [(String, BotJSON)] = []
        let session = makeHostSession(rest: livePlugin(sent: { sent.append(($0, $1)) }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertEqual(session.source, .hostDesktop)
        let url = try XCTUnwrap(upgrades.first?.url)
        XCTAssertEqual(url.path, "\(plugin)/stream")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "stream_ticket" }?.value, "plugin-ticket")
        XCTAssertNotNil(query.first { $0.name == "ticket" }?.value, "the dashboard's gate needs its own pass")

        session.takeOver()
        await reach(.mine, on: session)
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.source, .hostDesktop)
        XCTAssertEqual(sent.last { $0.0 == "/lease/acquire" }?.1["viewer_id"].text, "viewer-1")

        session.handBack()
        await reach(.bot, on: session)
        let release = try XCTUnwrap(sent.last { $0.0 == "/lease/release" })
        XCTAssertEqual(release.1["viewer_id"].text, "viewer-1")
        session.leave()
    }

    /// Nothing changes on the host until the tap, and the install names the pinned commit.
    func testInstallingThePluginIsPinnedAndWaitsForTheTap() async throws {
        var installed: BotJSON?
        var mounted = false
        let session = makeHostSession { [plugin, unowned self] request in
            if request.url?.path == "/api/dashboard/agent-plugins/install" {
                installed = requestBody(request)
                mounted = true
                return .json(200, .object(["ok": .bool(true)]))
            }
            if request.url?.path == "\(plugin)/capabilities", !mounted {
                return .json(404, .object(["detail": .string("Plugin not found")]))
            }
            return livePlugin()(request)
        }
        session.open()
        await reach(.pluginNotInstalled, on: session)
        XCTAssertNil(installed)

        session.open()
        await reach(.pluginNotInstalled, on: session)
        XCTAssertNil(installed, "Check Again never installs")

        session.installPlugin()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertEqual(installed?["identifier"].text, HermexScreenPlugin.installIdentifier)
        XCTAssertEqual(installed?["ref"].text?.count, 40)
        XCTAssertEqual(installed?["enable"].flag, true)
        session.leave()
    }

    /// A hot-mount can be in flight, so one read isn't enough to offer a restart; and never on a
    /// gateway's Webapp, whose drain hermex-push's restart skips (#1606).
    func testARestartIsOfferedOnlyIfASecondReadStillSaysSoAndOnlyWithARoute() async {
        for webapp in [false, true] {
            var reads = 0, statuses = 0
            let session = makeHostSession { [plugin] request in
                switch request.url?.path {
                case "\(plugin)/capabilities"?:
                    reads += 1
                    return .json(404, .object(["detail": .string("No such API endpoint: /x")]))
                case "/api/plugins/hermex-push/capabilities"?:
                    return .json(200, .object(["routes": .array([.string("POST /restart")])]))
                // The Webapp names its install only once signed in.
                case "/api/status"? where webapp:
                    statuses += 1
                    return .json(200, .object(statuses == 1 ? ["auth_required": .bool(true), "auth_providers": .array([.string("basic")])]
                                              : ["auth_required": .bool(true), "install_id": .string("fixture-install")]))
                default: return nil
                }
            }
            session.open()
            await reach(.pluginNeedsRestart(canRestart: !webapp), on: session)
            XCTAssertEqual(reads, 2)
            session.leave()
        }
    }

    func testAHostThatCantServeSaysWhyInsteadOfStreaming() async {
        func phase(for fields: [String: BotJSON]) async -> ScreenSession.Phase {
            let session = makeHostSession(rest: livePlugin({ [unowned self] route in
                route == "/status" ? .json(200, pluginStatus(fields)) : nil
            }))
            session.open()
            while session.phase == .connecting {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking { _ = session.phase } onChange: { continuation.resume() }
                }
            }
            let phase = session.phase
            session.leave()
            return phase
        }
        let driver = await phase(for: ["driver": .object(["problem": .string("this driver has no click tool")])])
        XCTAssertEqual(driver, .driverProblem("this driver has no click tool"))
        let permissions = await phase(for: ["permissions": .object(["accessibility": .bool(true), "screen_recording": .bool(false)])])
        XCTAssertEqual(permissions, .permissionsMissing(accessibility: false, screenRecording: true))
        let refused = await phase(for: ["refusal": .string("Windows isn't supported yet.")])
        XCTAssertEqual(refused, .hostRefused("Windows isn't supported yet."))
    }

    /// A takeover left by a plugin that has gone still holds every Profile's stock lease, so the
    /// force Hand Back clears them there.
    func testForceWithThePluginGoneClearsEveryProfilesStockLease() async throws {
        host.always("profiles.list", .init(result: .object(["profiles": .array([
            .object(["name": .string("work")]), .object(["name": .string("home")])
        ])])))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        let session = makeHostSession { [plugin] request in
            guard request.url?.path.hasPrefix(plugin) == true else { return nil }
            return .json(404, .object(["detail": .string("Plugin not found")]))
        }
        host.always("display.status", .init(result: screen(supported: false, lease: lease(holder: "human", viewer: "a-gone-plugin"))))
        session.open()
        await reach(.pluginNotInstalled, on: session)
        XCTAssertEqual(session.control, .other)

        session.forceHandBack()
        await reach(.bot, on: session)
        let profiles = requests("display.lease.release").compactMap { $0["params"]["profile"].text }
        XCTAssertEqual(Set(profiles), ["work", "home"])
        XCTAssertTrue(requests("display.lease.release").allSatisfy { $0["params"]["viewer_id"] == .null })
        session.leave()
    }

    /// Hermes runs no plugin code on removal, so a hold has to end first.
    func testRemovingThePluginReleasesAnyHoldFirst() async throws {
        var order: [String] = []
        let deleted = expectation(description: "the plugin is deleted")
        let session = makeHostSession { [unowned self] request in
            if request.url?.path == "/api/dashboard/agent-plugins/hermex-screen", request.httpMethod == "DELETE" {
                order.append("delete")
                deleted.fulfill()
                return .json(200, .object(["ok": .bool(true)]))
            }
            return livePlugin({ route in
                if route == "/lease/release" { order.append("release") }
                return nil
            })(request)
        }
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await reach(.mine, on: session)
        session.removePlugin()
        await fulfillment(of: [deleted], timeout: 5)
        XCTAssertEqual(order, ["release", "delete"])
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// The Plugins screen names a Profile, and the REST route acts on the dashboard's instead (#1582).
    func testRemovingFromThePluginsScreenNamesItsProfile() async throws {
        host.always("plugins.manage", .init(result: .object(["ok": .bool(true), "name": .string(HermexScreenPlugin.name)])))
        let removed = expectation(description: "the removal reached the host")
        host.expect(removed, onNext: "plugins.manage")
        let session = makeHostSession(removesFromItsProfile: true, rest: livePlugin({ _ in nil }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.removePlugin()
        await fulfillment(of: [removed], timeout: 5)

        let params = try XCTUnwrap(host.requests.last { $0["method"].text == "plugins.manage" })["params"]
        XCTAssertEqual(params["action"].text, "remove")
        XCTAssertEqual(params["profile"].text, "work")
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.httpMethod == "DELETE" }.count, 0)
        session.leave()
    }

    /// The removal menu only shows with nobody holding, since a takeover on a removed plugin has
    /// nothing left to end it.
    func testThePluginCanBeRemovedOnlyWithNoTakeoverOnIt() async {
        var lease = self.lease()
        let session = makeHostSession(rest: livePlugin({ [unowned self] route in
            route == "/observe" ? .json(200, .object(["viewer_id": .string("viewer-1"), "stream_ticket": .string("t"), "lease": lease])) : nil
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertTrue(session.canRemovePlugin)

        lease = self.lease(holder: "human", viewer: "someone-else")
        await socket(0).end(code: 4401)
        await reach(.other, on: session)
        XCTAssertFalse(session.canRemovePlugin)
        session.leave()
    }

    /// Someone can take over while the confirmation is open, which would strand their takeover.
    func testRemovingRechecksForATakeoverBeforeDeleting() async {
        var deleted = false
        var held = false
        let session = makeHostSession { [unowned self] request in
            if request.httpMethod == "DELETE" { deleted = true; return .json(200, .object([:])) }
            return livePlugin({ [unowned self] route in
                route == "/status" && held ? .json(200, pluginStatus(["lease": lease(holder: "human", viewer: "someone-else")])) : nil
            })(request)
        }
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        held = true
        session.removePlugin()
        await waitUntil("the failure's notice") { session.notice == .pluginActionFailed }
        XCTAssertFalse(deleted)
        session.leave()
    }

    /// A host's calls go by HTTP, so a release sent ahead of a slow acquire would finish first and
    /// leave the acquire to pause every bot with nobody watching.
    func testClosingOnAHostWaitsForATakeOverStillOnItsWay() async {
        var order: [String] = []
        let acquiring = expectation(description: "the acquire reached the host")
        let released = expectation(description: "the release reached the host")
        let session = makeHostSession(rest: livePlugin({ route in
            if route == "/lease/acquire" {
                order.append("acquire")
                acquiring.fulfill()
                return .park
            }
            if route == "/lease/release" {
                order.append("release")
                released.fulfill()
            }
            return nil
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await fulfillment(of: [acquiring], timeout: 5)
        session.leave()
        XCTAssertEqual(order, ["acquire"], "nothing overtakes it while it's unanswered")

        HermesHostFixture.releaseParked(.json(200, .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        await fulfillment(of: [released], timeout: 5)
        XCTAssertEqual(order, ["acquire", "release"])
    }

    /// The store is shared, so a Screen reopened while this one closed may hold the screen by now.
    func testClosingReleasesOnlyWhatThisViewTook() async {
        var released: [String?] = []
        let acquiring = expectation(description: "the acquire reached the host")
        let done = expectation(description: "the release reached the host")
        let session = makeHostSession(rest: livePlugin({ route in
            guard route == "/lease/acquire" else { return nil }
            acquiring.fulfill()
            return .park
        }, sent: { route, body in
            guard route == "/lease/release" else { return }
            released.append(body["viewer_id"].text)
            done.fulfill()
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await fulfillment(of: [acquiring], timeout: 5)
        session.leave()
        let newer = ScreenHold(viewerIDs: ["newer-screen"], isConfirmed: true, lastInput: clock, source: .hostDesktop)
        holds.save(newer, server: server, profile: "work")

        HermesHostFixture.releaseParked(.json(200, .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(released, ["viewer-1"])
        await waitUntil("the reply is settled") { [holds, server] in
            _ = holds.revision
            return holds.hold(server: server, profile: "work") == newer
        }
    }

    /// A reply arriving after a hand-back can't bring back the hold it replaced.
    func testALateAcquireReplyDoesntRestoreAForgottenHold() async {
        let acquiring = expectation(description: "the acquire reached the host")
        let session = makeHostSession(rest: livePlugin({ route in
            guard route == "/lease/acquire" else { return nil }
            acquiring.fulfill()
            return .park
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await fulfillment(of: [acquiring], timeout: 5)
        holds.save(nil, server: server, profile: "work")

        HermesHostFixture.releaseParked(.json(200, .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        await reach(.mine, on: session)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.suspend()
    }

    /// A blocked state still needs its way out: a hold of this iPhone's shows Hand Back, and
    /// anyone else's shows the force.
    func testABlockedHostStateStillReportsWhoHoldsIt() async {
        let blocked: [String: BotJSON] = ["driver": .object(["problem": .string("no click tool")]),
                                          "lease": lease(holder: "human", viewer: "mine")]
        holds.save(ScreenHold(viewerIDs: ["mine"], isConfirmed: true, lastInput: clock, source: .hostDesktop), server: server, profile: "work")
        let mine = makeHostSession(rest: livePlugin({ [unowned self] route in
            route == "/status" ? .json(200, pluginStatus(blocked)) : nil
        }))
        mine.open()
        await reach(.driverProblem("no click tool"), on: mine)
        XCTAssertEqual(mine.control, .mine)
        mine.suspend()

        holds.save(nil, server: server, profile: "work")
        let other = makeHostSession(rest: livePlugin({ [unowned self] route in
            route == "/status" ? .json(200, pluginStatus(blocked)) : nil
        }))
        other.open()
        await reach(.driverProblem("no click tool"), on: other)
        XCTAssertEqual(other.control, .other)
        other.leave()
    }

    /// The plugin counts only input it receives, so Keep Control has to reach it.
    func testKeepControlRenewsThePluginsTimerAsWellAsThePhones() async throws {
        let session = makeHostSession(rest: livePlugin())
        session.open()
        let stream = await socket(0)
        await stream.serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await reach(.mine, on: session)
        let moved = expectation(description: "a pointer event reaches the plugin")
        stream.fulfill(moved) { $0.first == 5 }
        session.keepControl()
        await fulfillment(of: [moved], timeout: 5)
        session.leave()
    }

    /// A saved host hold whose plugin has gone still ends, on each Profile's stock lease, by its id.
    func testAHoldOutlivingThePluginHandsBackThroughStockLeases() async throws {
        host.always("profiles.list", .init(result: .object(["profiles": .array([
            .object(["name": .string("work")]), .object(["name": .string("home")])
        ])])))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        let client = BotClient(http: host.connection(record) { [plugin] request in
            request.url?.path.hasPrefix(plugin) == true ? .json(404, .object(["detail": .string("Plugin not found")])) : nil
        })
        try await client.connect()
        let hold = ScreenHold(viewerIDs: ["old"], isConfirmed: true, lastInput: clock, source: .hostDesktop)
        _ = try await ScreenSource.hostDesktop.release(hold, profile: "work", client: client)
        let released = requests("display.lease.release")
        XCTAssertEqual(Set(released.compactMap { $0["params"]["profile"].text }), ["work", "home"])
        XCTAssertTrue(released.allSatisfy { $0["params"]["viewer_id"].text == "old" })
        client.close()
    }

    /// A lock can come and go while the stream runs, and on Windows it decides whether Take Over shows.
    func testALockOrUnlockDuringAStreamIsNoticed() async {
        var locked = true
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        host.always("display.status", .init(result: screen(supported: false)))
        var options = ScreenSession.Options()
        options.pluginRecheck = .zero
        options.lockPoll = .milliseconds(5)
        options.holds = holds
        options.socketFactory = { [unowned self] upgrade in
            let socket = ScriptedRFBSocket()
            opened.add(socket, upgrade)
            return socket
        }
        let session = ScreenSession(profile: "work", title: "Work", server: server, client: BotClient(http: host.connection(record, rest: livePlugin({ [unowned self] route in
            route == "/status" ? .json(200, pluginStatus(["locked": .bool(locked)])) : nil
        }))), options: options)
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertTrue(session.isHostLocked)
        locked = false
        await waitUntil("the unlock is noticed") { !session.isHostLocked }
        session.leave()
    }

    /// A restart drops the gateway with it, and the read that follows finds the routes mounted.
    func testRestartingForThePluginEndsLiveOnceTheRoutesAreMounted() async {
        var restarted = false
        let session = makeHostSession { [plugin, unowned self] request in
            switch request.url?.path {
            case "/api/plugins/hermex-push/restart"?:
                restarted = true
                return .json(202, .object(["ok": .bool(true)]))
            case "/api/plugins/hermex-push/capabilities"?:
                return .json(200, .object(["routes": .array([.string("POST /restart")])]))
            case "\(plugin)/capabilities"? where !restarted:
                return .json(404, .object(["detail": .string("No such API endpoint: /x")]))
            default:
                return livePlugin()(request)
            }
        }
        session.open()
        await reach(.pluginNeedsRestart(canRestart: true), on: session)
        session.restartForPlugin()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.leave()
    }

    func testAPluginActionThatFailsSaysSoAndKeepsTheOffer() async {
        let session = makeHostSession { [plugin] request in
            if request.url?.path == "/api/dashboard/agent-plugins/install" { return .json(500, .object([:])) }
            if request.url?.path == "\(plugin)/capabilities" { return .json(404, .object(["detail": .string("Plugin not found")])) }
            return nil
        }
        session.open()
        await reach(.pluginNotInstalled, on: session)
        session.installPlugin()
        await waitUntil("the failure's notice") { session.notice == .pluginActionFailed }
        await reach(.pluginNotInstalled, on: session)
        session.leave()
    }

    /// The plugin refused, so the hold saved ahead of the call never landed.
    func testARefusedTakeOverLeavesNoHold() async {
        let session = makeHostSession(rest: livePlugin({ route in
            route == "/lease/acquire" ? .json(409, .object(["detail": .string("viewer_id was not minted"), "code": .string("viewer_mismatch")])) : nil
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await waitUntil("the failure's notice") { session.notice == .takeOverFailed }
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// The plugin's own timer runs with or without the phone, and closes with its own code.
    func testThePluginsTimerEndingATakeoverSaysSo() async {
        let session = makeHostSession(rest: livePlugin())
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.takeOver()
        await reach(.mine, on: session)
        await socket(0).end(code: 4002)
        await reach(.bot, on: session)
        XCTAssertEqual(session.notice, .handedBackAutomatically)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// A host's desktop has no stopped state, so a capture failure re-reads what's wrong.
    func testAStreamEndingOnAHostReadsItsStateAgain() async {
        var failing = false
        let session = makeHostSession(rest: livePlugin({ [unowned self] route in
            route == "/status" && failing ? .json(200, pluginStatus(["permissions": .object(["screen_recording": .bool(false)])])) : nil
        }))
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        failing = true
        await socket(0).end(code: 4001)
        await reach(.permissionsMissing(accessibility: false, screenRecording: true), on: session)
        session.leave()
    }

    /// A plugin whose capture keeps failing with no reason in its status would otherwise show
    /// "Reconnecting" forever. Two failures in a row before a frame settle; a frame, or Check
    /// Again, starts the count over.
    func testAHostThatKeepsFailingToCaptureSaysSoInsteadOfRetryingForever() async {
        let session = makeHostSession(rest: livePlugin())
        session.open()
        await socket(0).end(code: 4001)
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        await socket(1).end(code: 4001)
        await socket(2).end(code: 4001)
        await socket(3).end(code: 4001)
        await reach(.driverProblem("This computer's driver couldn't capture the screen."), on: session)

        session.open()
        await socket(4).end(code: 4001)
        await socket(5).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        session.leave()
    }

    // MARK: - Idle

    func testIdleAsksThenHandsBackAndInputPutsItOff() async {
        let session = await holding { options in
            options.idlePrompt = .milliseconds(20)
            options.idleLimit = .milliseconds(60)
            options.now = { Date() }
        }
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        await waitUntil("Still there?") { session.isAskingStillThere }
        session.noteActivity()
        XCTAssertFalse(session.isAskingStillThere)
        await reach(.bot, on: session)
        XCTAssertEqual(session.notice, .handedBackAutomatically)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// A stock lease never expires, so one failed hand-back at the limit can't be the last try.
    func testAHandBackAtTheLimitThatFailsTriesAgain() async {
        let session = await holding { options in
            options.idlePrompt = .milliseconds(1)
            options.idleLimit = .milliseconds(2)
            options.idleRetry = .milliseconds(1)
            options.now = { Date() }
        }
        host.next("display.lease.release", .init(error: 5300))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        await reach(.bot, on: session)
        XCTAssertEqual(session.notice, .handedBackAutomatically)
        XCTAssertGreaterThanOrEqual(requests("display.lease.release").count, 2)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// A stock lease never expires, so a return past the limit hands back rather than retaking it.
    func testReturningPastTheLimitHandsBackInsteadOfTakingItBack() async {
        let session = await holding()
        session.suspend()
        let acquires = requests("display.lease.acquire").count
        clock.addTimeInterval(16 * 60)
        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "viewer-1"))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        session.open()
        await reach(.bot, on: session)
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        XCTAssertEqual(session.notice, .handedBackAutomatically)
        XCTAssertEqual(requests("display.lease.acquire").count, acquires)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// Recent input counts on a reconnect, though the saved time moves only on leaving the foreground.
    func testAReconnectAfterRecentInputKeepsControlPastTheOriginalDeadline() async {
        let session = await holding()
        clock.addTimeInterval(14 * 60)
        session.noteActivity()
        clock.addTimeInterval(14 * 60)
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "viewer-1"))
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-2")])))
        await socket(0).end(error: URLError(.networkConnectionLost))
        await socket(1).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertEqual(session.control, .mine)
        XCTAssertTrue(requests("display.lease.release").isEmpty)
        session.suspend()
    }

    /// The host can take the lease while the reply dies with a suspended app. The saved hold is
    /// what lets the return resume it rather than call it someone else's.
    func testSuspendingBeforeTheAcquireReplyStillResumesTheTakeover() async {
        standUp()
        host.withhold("display.lease.acquire")
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        let sent = expectation(description: "acquire sent")
        host.expect(sent, onNext: "display.lease.acquire")
        session.takeOver()
        await fulfillment(of: [sent], timeout: 5)
        session.suspend()
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["viewer-1"])

        host.allow("display.lease.acquire")
        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "viewer-1"))
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-2")])))
        session.open()
        await reach(.mine, on: session)
        XCTAssertNil(session.notice)
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["viewer-2"])
        session.suspend()
    }

    /// An acquire that never landed isn't someone else's takeover.
    func testAnUnconfirmedHoldTheHostDoesntShowGoesQuietly() async {
        holds.save(ScreenHold(viewerIDs: ["never-landed"], isConfirmed: false, lastInput: clock, source: .botDesktop), server: server, profile: "work")
        standUp()
        let session = makeSession()
        session.open()
        await socket(0).serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertNil(session.notice)
        XCTAssertEqual(session.control, .bot)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        session.leave()
    }

    /// The host's filter reads the first 14 client bytes as the handshake.
    func testInputDuringAReconnectIsDroppedUntilTheNewStreamsHandshakeIsDone() async {
        let session = await holding()
        standUp(viewer: "viewer-2", lease: lease(holder: "human", viewer: "viewer-1"))
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-2")])))
        await socket(0).end(error: URLError(.networkConnectionLost))
        let stream = await socket(1)
        session.press(.escape)
        await stream.serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)
        XCTAssertFalse(stream.sentBytes.contains { $0.first == 4 })
        session.suspend()
    }

    private func reconcilingClient() async throws -> BotClient {
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        let client = BotClient(http: host.connection(record))
        try await client.connect()
        return client
    }

    func testReconcileForgetsAHoldTheHostNoLongerShows() async throws {
        let client = try await reconcilingClient()
        holds.save(ScreenHold(viewerIDs: ["gone"], isConfirmed: true, lastInput: clock, source: .botDesktop), server: server, profile: "work")
        host.always("display.status", .init(result: screen()))
        await ScreenHolds.reconcile(server: server, client: client, store: holds, now: clock)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        XCTAssertTrue(requests("display.lease.release").isEmpty)
        client.close()
    }

    func testReconcileHandsBackAHoldPastItsDeadline() async throws {
        let client = try await reconcilingClient()
        holds.save(ScreenHold(viewerIDs: ["old"], isConfirmed: true, lastInput: clock.addingTimeInterval(-16 * 60), source: .botDesktop),
                   server: server, profile: "work")
        host.always("display.status", .init(result: screen(lease: lease(holder: "human", viewer: "old"))))
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        await ScreenHolds.reconcile(server: server, client: client, store: holds, now: clock)
        XCTAssertEqual(requests("display.lease.release").last?["params"]["viewer_id"].text, "old")
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        client.close()
    }

    /// A reply about an old hold must not erase one retaken since.
    func testForgettingAnOldHoldLeavesANewerOne() {
        holds.save(ScreenHold(viewerIDs: ["new"], isConfirmed: true, lastInput: clock, source: .botDesktop), server: server, profile: "work")
        holds.forget(viewerIDs: ["old"], server: server, profile: "work")
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["new"])
    }

    func testAHoldNeverShowsUnderAnotherServer() {
        let other = URL(string: "https://other.example")!
        holds.save(ScreenHold(viewerIDs: ["mine"], isConfirmed: true, lastInput: Date(), source: .botDesktop), server: server, profile: "work")
        XCTAssertNil(holds.hold(server: other, profile: "work"))
        holds.removeAll(server: other)
        XCTAssertNotNil(holds.hold(server: server, profile: "work"))
    }

    // MARK: - Input

    func testInputOnlyGoesOutWhileHoldingAndModifiersWrapTheNextKey() async throws {
        standUp()
        host.always("display.lease.acquire", .init(result: .object(["lease": lease(holder: "human", viewer: "viewer-1")])))
        let session = makeSession()
        session.open()
        let stream = await socket(0)
        await stream.serve(ScriptedRFBSocket.oneFrame)
        await reach(.live, on: session)

        session.press(.escape)
        session.click(x: 1, y: 0, button: RFBMessage.Button.left)
        XCTAssertFalse(stream.sentBytes.contains { $0.first == 4 || $0.first == 5 }, "a watcher sends no input")

        session.takeOver()
        await reach(.mine, on: session)
        let typed = RFBMessage.key(.control, down: true) + RFBMessage.key(ScreenKey(keysym: 0x63), down: true)
            + RFBMessage.key(ScreenKey(keysym: 0x63), down: false) + RFBMessage.key(.control, down: false)
        let chorded = expectation(description: "the key goes out inside its modifier")
        stream.fulfill(chorded) { $0 == typed }
        session.toggleModifier(.control)
        session.press(ScreenKey(keysym: 0x63))
        await fulfillment(of: [chorded], timeout: 5)
        XCTAssertTrue(session.latchedModifiers.isEmpty)

        let accent = RFBMessage.key(ScreenKey(keysym: 0xE9), down: true) + RFBMessage.key(ScreenKey(keysym: 0xE9), down: false)
        let accented = expectation(description: "the typed letter goes out")
        stream.fulfill(accented) { $0 == accent }
        session.type("é")
        await fulfillment(of: [accented], timeout: 5)
        session.leave()
    }

    /// A fast finger falls behind by one position, not by a queue, and a click keeps its place.
    func testPointerMovesCoalesceButClicksKeepTheirPlace() {
        var queue = ScreenInputQueue()
        queue.movePointer(x: 1, y: 1, buttons: 0)
        queue.movePointer(x: 2, y: 2, buttons: 0)
        queue.append(RFBMessage.pointer(x: 2, y: 2, buttons: 1))
        queue.movePointer(x: 3, y: 3, buttons: 0)
        XCTAssertEqual(queue.drain(), RFBMessage.pointer(x: 2, y: 2, buttons: 0) + RFBMessage.pointer(x: 2, y: 2, buttons: 1)
            + RFBMessage.pointer(x: 3, y: 3, buttons: 0))
        XCTAssertTrue(queue.isEmpty)
    }

    func testTypedScalarsBecomeKeysyms() {
        XCTAssertEqual(ScreenKey(typing: "a"), ScreenKey(keysym: 0x61))
        XCTAssertEqual(ScreenKey(typing: "\u{E9}"), ScreenKey(keysym: 0xE9))
        XCTAssertEqual(ScreenKey(typing: "\u{20AC}"), ScreenKey(keysym: 0x0100_20AC))
        XCTAssertEqual(ScreenKey(typing: "\n"), .enter)
        XCTAssertNil(ScreenKey(typing: "\u{7}"))
    }

    func testAPicturePointMapsToAFramebufferPixelKeptOnThePicture() throws {
        let pixel = try XCTUnwrap(screenPixel(at: CGPoint(x: 195, y: 61), in: CGSize(width: 390, height: 244), width: 1440, height: 900))
        XCTAssertEqual(pixel.x, 720)
        XCTAssertEqual(pixel.y, 225)
        let edge = try XCTUnwrap(screenPixel(at: CGPoint(x: 500, y: -5), in: CGSize(width: 390, height: 244), width: 1440, height: 900))
        XCTAssertEqual(edge.x, 1439)
        XCTAssertEqual(edge.y, 0)
    }
}

/// The stream sockets a session opened, which a test can wait on.
@MainActor @Observable private final class OpenedStreams {
    private(set) var sockets: [ScriptedRFBSocket] = []
    private(set) var upgrades: [URLRequest] = []

    func add(_ socket: ScriptedRFBSocket, _ upgrade: URLRequest) {
        upgrades.append(upgrade)
        sockets.append(socket)
    }
}

/// A stream socket scripted by the test, which answers each read in order.
private actor ScriptedRFBSocketState {
    var frames: [Result<Data, Error>] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false

    func next() async throws -> Data {
        if !frames.isEmpty { return try frames.removeFirst().get() }
        if closed { throw URLError(.cancelled) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func deliver(_ frame: Result<Data, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: frame)
        } else {
            frames.append(frame)
        }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: URLError(.cancelled))
        waiter = nil
    }
}

final class ScriptedRFBSocket: RFBSocket, @unchecked Sendable {
    private let state = ScriptedRFBSocketState()
    private let lock = NSLock()
    private var sent: [Data] = []
    private var sendWaiters: [(expectation: XCTestExpectation, matches: (Data) -> Bool)] = []
    var pingFailure: Error?

    /// Everything the client sent, a frame each.
    var sentBytes: [Data] { lock.withLock { sent } }

    /// The handshake, then one 2x1 update of a Tight fill.
    static let oneFrame: Data = {
        var bytes = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
        bytes += [0, 2, 0, 1, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes += [0, 0, 0, 1, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 7, 0x80, 1, 2, 3]
        return Data(bytes)
    }()

    func serve(_ data: Data) async { await state.deliver(.success(data)) }
    func end(code: Int) async { await state.deliver(.failure(RFBStreamEnd.closed(code: code))) }
    func end(error: Error) async { await state.deliver(.failure(error)) }

    func receive() async throws -> Data { try await state.next() }
    func send(_ data: Data) async throws {
        lock.withLock {
            sent.append(data)
            sendWaiters.removeAll { waiter in
                guard waiter.matches(data) else { return false }
                waiter.expectation.fulfill()
                return true
            }
        }
    }

    /// Fulfills `expectation` when a later frame the client sends matches.
    func fulfill(_ expectation: XCTestExpectation, when matches: @escaping (Data) -> Bool) {
        lock.withLock { sendWaiters.append((expectation, matches)) }
    }
    func ping() async throws { if let pingFailure { throw pingFailure } }
    func close() { Task { await state.close() } }
}
