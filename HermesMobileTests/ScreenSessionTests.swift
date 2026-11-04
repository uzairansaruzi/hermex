import CoreGraphics
import XCTest
@testable import HermesMobile

/// The Screen's states and control rules over a scripted gateway and stream socket.
@MainActor final class ScreenSessionTests: XCTestCase {
    private let host = BotSocketHost()
    private let server = URL(string: "https://hermes.example")!
    private var holds = ScreenHoldStore(keychain: InMemoryKeychainStore())
    private var sockets: [ScriptedRFBSocket] = []
    private var upgrades: [URLRequest] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(backoff: [Duration] = [.zero], configure: (inout ScreenSession.Options) -> Void = { _ in }) -> ScreenSession {
        let record = BotConnection(id: UUID(), name: "Host", address: server, username: "u", password: "p")
        var options = ScreenSession.Options()
        options.backoff = backoff
        options.holds = holds
        options.now = { [unowned self] in clock }
        options.socketFactory = { [unowned self] upgrade in
            upgrades.append(upgrade)
            let socket = ScriptedRFBSocket()
            sockets.append(socket)
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
        while sockets.count <= index { await Task.yield() }
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

    func testAHostWithoutTheMethodsOrSupportSaysSo() async {
        host.always("display.status", .init(error: -32601))
        let lacking = makeSession()
        lacking.open()
        await reach(.unavailable, on: lacking)
        lacking.leave()

        host.always("display.status", .init(result: screen(supported: false)))
        let unsupported = makeSession()
        unsupported.open()
        await reach(.unsupported, on: unsupported)
        unsupported.leave()
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
        session.stopScreen(force: true)
        while requests("display.stop").count < 2 { await Task.yield() }
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
        while session.notice == nil { await Task.yield() }
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
        while session.notice == nil { await Task.yield() }
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
        while holds.hold(server: server, profile: "work") != nil { await Task.yield() }
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

    // MARK: - Idle

    func testIdleAsksThenHandsBackAndInputPutsItOff() async {
        let session = await holding { options in
            options.idlePrompt = .milliseconds(20)
            options.idleLimit = .milliseconds(60)
            options.now = { Date() }
        }
        host.always("display.lease.release", .init(result: .object(["lease": lease()])))
        while !session.isAskingStillThere { await Task.yield() }
        session.noteActivity()
        XCTAssertFalse(session.isAskingStillThere)
        await reach(.bot, on: session)
        XCTAssertEqual(session.notice, .handedBackAutomatically)
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
        holds.save(ScreenHold(viewerIDs: ["never-landed"], isConfirmed: false, lastInput: clock), server: server, profile: "work")
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
        holds.save(ScreenHold(viewerIDs: ["gone"], isConfirmed: true, lastInput: clock), server: server, profile: "work")
        host.always("display.status", .init(result: screen()))
        await ScreenHolds.reconcile(server: server, client: client, store: holds, now: clock)
        XCTAssertNil(holds.hold(server: server, profile: "work"))
        XCTAssertTrue(requests("display.lease.release").isEmpty)
        client.close()
    }

    func testReconcileHandsBackAHoldPastItsDeadline() async throws {
        let client = try await reconcilingClient()
        holds.save(ScreenHold(viewerIDs: ["old"], isConfirmed: true, lastInput: clock.addingTimeInterval(-16 * 60)),
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
        holds.save(ScreenHold(viewerIDs: ["new"], isConfirmed: true, lastInput: clock), server: server, profile: "work")
        holds.forget(viewerIDs: ["old"], server: server, profile: "work")
        XCTAssertEqual(holds.hold(server: server, profile: "work")?.viewerIDs, ["new"])
    }

    func testAHoldNeverShowsUnderAnotherServer() {
        let other = URL(string: "https://other.example")!
        holds.save(ScreenHold(viewerIDs: ["mine"], isConfirmed: true, lastInput: Date()), server: server, profile: "work")
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
        session.toggleModifier(.control)
        session.press(ScreenKey(keysym: 0x63))
        let typed = RFBMessage.key(.control, down: true) + RFBMessage.key(ScreenKey(keysym: 0x63), down: true)
            + RFBMessage.key(ScreenKey(keysym: 0x63), down: false) + RFBMessage.key(.control, down: false)
        while !stream.sentBytes.contains(where: { $0 == typed }) { await Task.yield() }
        XCTAssertTrue(session.latchedModifiers.isEmpty)

        session.type("é")
        let accent = RFBMessage.key(ScreenKey(keysym: 0xE9), down: true) + RFBMessage.key(ScreenKey(keysym: 0xE9), down: false)
        while !stream.sentBytes.contains(where: { $0 == accent }) { await Task.yield() }
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
    func send(_ data: Data) async throws { lock.withLock { sent.append(data) } }
    func ping() async throws { if let pingFailure { throw pingFailure } }
    func close() { Task { await state.close() } }
}
