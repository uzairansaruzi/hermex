import XCTest
@testable import HermesMobile

@MainActor final class BotRoomTests: XCTestCase {
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!, username: "u", password: "p")

    func testCachedRoomSearchSurvivesColdStartAndListFailureButFreshListAndIdentityWin() async throws {
        for offline in [true, false] {
            let cache = BotHistoryCache(), wire = RoomWire()
            let store = BotConnectionStore(keychain: InMemoryKeychainStore())
            try store.save(connection, server: key().server)
            let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 1)))
            try await cache.appendRoom(key: key(), room: room,
                page: RoomFixture.page([RoomFixture.event(1, kind: "message.member")], cursor: 1), since: 0)
            if offline { wire.connectFailure = BotFailure.transport }
            else { wire.listFailure = BotFailure.transport }
            let inbox = BotInbox(server: key().server, store: store, historyCache: cache, makeWire: { _ in wire })
            await inbox.open()
            XCTAssertTrue(inbox.rooms.isEmpty)
            XCTAssertNil(inbox.searchableRoomIDs)
            let hits = try await cache.search("Message", scope: .init(server: key().server, connectionID: connection.id),
                                             profileIDs: [], roomIDs: inbox.searchableRoomIDs)
            let hit = try XCTUnwrap(hits.first)
            XCTAssertEqual(inbox.roomForSearch(hit)?.name, "Comms")
            XCTAssertEqual(inbox.selectRoomSearchHit(hit)?.id, room.id)
            XCTAssertEqual(inbox.rooms.first?.id, room.id, "The existing room destination can open cached identity")
            let wrongServer = BotInbox(server: URL(string: "https://other.example")!, store: store)
            XCTAssertNil(wrongServer.selectRoomSearchHit(hit))
            wire.connectFailure = nil; wire.listFailure = nil; wire.listedRooms = []
            await inbox.open()
            XCTAssertEqual(inbox.searchableRoomIDs, [])
            XCTAssertNil(inbox.roomForSearch(hit), "An authoritative empty list hides a removed room")
            XCTAssertNil(inbox.selectRoomSearchHit(hit), "A queued tap cannot resurrect a removed room")
            let removed = try await cache.roomHistory(key()); XCTAssertNil(removed)
            let replacement = BotConnection(id: UUID(), name: "Other", address: connection.address, username: "u", password: "p")
            try store.save(replacement, server: key().server)
            wire.connectFailure = BotFailure.transport
            await inbox.open()
            XCTAssertNil(inbox.selectRoomSearchHit(hit), "Offline fallback still revalidates connection identity")
            inbox.close()
        }
    }

    func testRoomOpensFromCacheBeforeStateThenReadsOnlyNewSequences() async throws {
        let cache = BotHistoryCache(), wire = RoomWire()
        wire.latest = 3
        let first = makeReader(wire, cache: cache)
        await first.open(); first.close()
        let nextWire = RoomWire(); nextWire.latest = 5; nextWire.holdState = true
        let parked = expectation(description: "server state is pending")
        nextWire.onHeld = { parked.fulfill() }
        let next = makeReader(nextWire, cache: cache)
        let opening = Task { await next.open() }
        await fulfillment(of: [parked], timeout: 2)
        XCTAssertEqual(next.events.map(\.seq), [1, 2, 3], "Saved messages appear before the server replies")
        nextWire.releaseState(latest: 5)
        await opening.value
        XCTAssertEqual(nextWire.logStarts, [3])
        XCTAssertEqual(next.events.map(\.seq), [1, 2, 3, 4, 5])
        next.close()
    }

    func testExpiredAndDisbandedRoomsPurgeTheirCache() async throws {
        for disband in [false, true] {
            let cache = BotHistoryCache(), wire = RoomWire(); wire.latest = 3
            let reader = makeReader(wire, cache: cache)
            await reader.open()
            let saved = try await cache.roomHistory(key()); XCTAssertNotNil(saved)
            if disband { await reader.disband() }
            else {
                wire.failure = BotRoomFailure(code: 4112, reason: "room_history_expired")
                await reader.poll()
            }
            await reader.historyRemoval?.value
            let removed = try await cache.roomHistory(key())
            XCTAssertNil(removed)
            XCTAssertTrue(reader.events.isEmpty)
        }
    }

    func testSearchSequenceLoadsEvenIfItsSnapshotWasEvicted() async throws {
        let cache = BotHistoryCache(), wire = RoomWire(); wire.latest = 600
        let reader = BotRoomReader(key: key(), connection: connection,
            room: BotGroupRoom(RoomFixture.room(latest: 600))!, cache: cache, initialSequence: 42, makeWire: { _ in wire })
        await reader.open()
        XCTAssertEqual(wire.logStarts.first, 41)
        XCTAssertEqual(reader.initialSequence, 42)
        XCTAssertEqual(reader.events.first?.seq, 42)
        XCTAssertEqual(reader.events.last?.seq, 600)
        reader.close()
        let previousReads = wire.logStarts.count
        wire.latest = 601
        await reader.open()
        XCTAssertEqual(wire.logStarts.count, previousReads + 1, "Reconnect must not replay the initial search target")
        XCTAssertEqual(wire.logStarts.last, 600)
        XCTAssertEqual(reader.events.last?.seq, 601)
        reader.close()
    }

    func testSearchHitKeepsItsSequenceAndOlderTargetLoadsBeforeCachedWindow() async throws {
        let cache = BotHistoryCache(), wire = RoomWire(); wire.latest = 500
        let first = makeReader(wire, cache: cache); await first.open(); first.close()
        let hits = try await cache.search("Message 345", scope: .init(server: key().server, connectionID: connection.id),
                                         profileIDs: [], roomIDs: [key().roomID])
        let selected = try XCTUnwrap(hits.first)
        XCTAssertEqual(selected.message.seq, 345)
        let nextWire = RoomWire(); nextWire.latest = 500
        let next = BotRoomReader(key: key(), connection: connection,
            room: BotGroupRoom(RoomFixture.room(latest: 500))!, cache: cache, initialSequence: 42, makeWire: { _ in nextWire })
        await next.open()
        XCTAssertEqual(nextWire.logStarts.first, 41)
        XCTAssertEqual(next.events.first?.seq, 42)
        XCTAssertEqual(next.events.last?.seq, 500)
        next.close()
    }

    func testUnwritableCacheDoesNotStopLiveRoomReading() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = RoomWire(); wire.latest = 2
        let reader = makeReader(wire, cache: BotHistoryCache(directory: file))
        await reader.open()
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(reader.events.map(\.seq), [1, 2])
        wire.latest = 3; await reader.poll()
        XCTAssertEqual(reader.events.map(\.seq), [1, 2, 3])
        reader.close()
    }

    func testCapturedCommsResponsesDecodeTolerantly() throws {
        let value = try JSONDecoder().decode(BotJSON.self, from: Data(Self.liveFixture.utf8))
        XCTAssertTrue(BotRoomCapabilities(value["capabilities"]).enabled)
        let listed = try XCTUnwrap(value["list"]["rooms"].list?.first.flatMap(BotGroupRoom.init))
        let state = try XCTUnwrap(BotGroupRoom(value["state"]["room"]))
        XCTAssertEqual(listed, state)
        XCTAssertEqual(state.name, "Comms")
        XCTAssertEqual(state.members.map(\.profile), ["chief-of-staff", "inbox-triage"])
        XCTAssertFalse(BotRoomStatus(value["state"]["driver_status"]).working)
    }

    func testCapabilityGateRequiresDriverAndEveryReadMethod() {
        XCTAssertTrue(BotRoomCapabilities(RoomFixture.capabilities).enabled)
        XCTAssertFalse(BotRoomCapabilities(.object(["driver": .bool(false), "methods": .array(BotRoomRPC.methods.map(BotJSON.string))])).enabled)
        for missing in ["groups.list", "groups.state", "groups.log"] {
            XCTAssertFalse(BotRoomCapabilities(.object(["driver": .bool(true), "methods": .array(BotRoomRPC.methods.filter { $0 != missing }.map(BotJSON.string))])).enabled)
        }
        XCTAssertFalse(BotRoomCapabilities(.null).enabled)
    }

    func testReplayIgnoresDuplicateSequencesAndUnknownKindsAdvanceCursor() {
        var log = BotRoomLog(); log.begin(latest: 403)
        XCTAssertEqual(log.cursor, 203)
        XCTAssertEqual(log.earlierBoundary, 203)
        log.apply(RoomFixture.page([RoomFixture.event(204), RoomFixture.event(205, kind: "future.event")], cursor: 205))
        log.apply(RoomFixture.page([RoomFixture.event(204), RoomFixture.event(206, kind: "turn.settled")], cursor: 206))
        XCTAssertEqual(log.events.map(\.seq), [204])
        XCTAssertEqual(log.cursor, 206)
        XCTAssertEqual(BotRoomLog.windowStart(before: 203), 3)
        XCTAssertEqual(BotRoomLog.windowStart(before: 3), 0)
        XCTAssertEqual(BotRoomLog.windowStart(before: 0), 0)
        log.apply(RoomFixture.page([RoomFixture.event(3)], cursor: 3))
        XCTAssertEqual(log.cursor, 206, "Earlier pages cannot rewind live replay")
        XCTAssertEqual(log.events.map(\.seq), [3, 204])
    }

    func testMemberFallbackAndForeignAuthorityAndScopedIdentity() throws {
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let event = try XCTUnwrap(BotRoomEvent(RoomFixture.event(1, kind: "message.member")))
        XCTAssertEqual(event.sender(in: room), "chief-of-staff")
        XCTAssertTrue(room.isForeign(to: "other-install"))
        XCTAssertFalse(room.isForeign(to: "fixture-install"))
        let first = BotRoomKey(server: URL(string: "https://one.example")!, connectionID: connection.id, roomID: room.id)
        XCTAssertNotEqual(first, BotRoomKey(server: first.server, connectionID: UUID(), roomID: room.id))
        XCTAssertNotEqual(first, BotRoomKey(server: URL(string: "https://two.example")!, connectionID: connection.id, roomID: room.id))
    }

    func testOpenDrainsPagesAndEarlierWindowDoesNotSkipOrRewind() async throws {
        let wire = RoomWire(); wire.latest = 450
        let cache = BotHistoryCache()
        let reader = makeReader(wire, cache: cache)
        await reader.open()
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(wire.logStarts, [250, 350])
        XCTAssertEqual(reader.events.first?.seq, 251)
        XCTAssertEqual(reader.events.last?.seq, 450)
        await reader.loadEarlier()
        XCTAssertEqual(Array(wire.logStarts.suffix(2)), [50, 150])
        XCTAssertEqual(reader.events.first?.seq, 51)
        XCTAssertEqual(reader.events.count, 400)
        let saved = try await cache.roomHistory(key())
        XCTAssertEqual(saved?.cursor, 450, "Earlier paging must preserve the newer cached window")
        XCTAssertEqual(saved?.messages.compactMap(\.seq), Array(51...450))
        await reader.loadEarlier()
        XCTAssertEqual(wire.logStarts.last, 0)
        XCTAssertFalse(reader.hasEarlier)
        XCTAssertEqual(reader.events.count, 450)
        wire.latest = 451
        await reader.poll()
        XCTAssertEqual(wire.logStarts.last, 450)
        XCTAssertEqual(reader.events.count, 451)
        reader.close()
        XCTAssertTrue(reader.events.isEmpty)
    }

    func testUnchangedPollDoesNotReadLogAndUnknownEventIsInvisible() async {
        let wire = RoomWire(); wire.latest = 1
        let reader = makeReader(wire)
        await reader.open()
        let before = reader.events
        await reader.poll()
        XCTAssertEqual(wire.logStarts.count, 1)
        XCTAssertEqual(reader.events, before)
        wire.kind = "room.activity"; wire.latest = 2
        await reader.poll()
        XCTAssertEqual(reader.events, before)
        await reader.poll()
        XCTAssertEqual(wire.logStarts, [0, 1], "Invisible activity still advances the read cursor")
        reader.close()
    }

    func testPollCompletingAfterCloseMutatesNothing() async {
        let wire = RoomWire(); let reader = makeReader(wire)
        await reader.open()
        let parked = expectation(description: "state parked")
        wire.holdState = true; wire.onHeld = { parked.fulfill() }
        let poll = Task { await reader.poll() }
        await fulfillment(of: [parked], timeout: 2)
        reader.close()
        wire.releaseState(latest: 50)
        await poll.value
        XCTAssertEqual(reader.link, .idle)
        XCTAssertTrue(reader.events.isEmpty)
        XCTAssertEqual(reader.room.latestSeq, 0)
        XCTAssertEqual(wire.logStarts, [0])
    }

    func testSocketLossStopsReadsAndReconnectUsesFreshSocket() async {
        let wire = RoomWire(); let next = RoomWire(); next.latest = 1
        var wires = [wire, next]
        let reader = BotRoomReader(key: key(), connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, cache: BotHistoryCache(), makeWire: { _ in wires.removeFirst() })
        await reader.open()
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(reader.link, .stopped)
        let reads = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, reads)
        await reader.open()
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(reader.events.count, 1)
        XCTAssertGreaterThan(wire.closed, 0)
        reader.close()
    }

    func testExpiredAndWorkerErrorsHaveRequiredRecovery() async {
        for error in [BotRoomFailure(code: 4114, reason: nil), BotRoomFailure(code: 4112, reason: "room_history_expired")] {
            let wire = RoomWire(); var expired = false
            let reader = makeReader(wire, expired: { expired = true })
            await reader.open()
            wire.failure = error
            await reader.poll()
            XCTAssertTrue(expired)
            XCTAssertTrue(reader.events.isEmpty)
        }
        let wire = RoomWire(); let reader = makeReader(wire)
        wire.failure = BotRoomFailure(code: 4123, reason: nil)
        await reader.open()
        XCTAssertTrue(reader.errorMessage?.contains("Restart the Hermes gateway") == true)
        reader.close()
    }

    func testInboxGateSearchDisbandAndExpiredIdentityStayScoped() async throws {
        let wire = RoomWire()
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: key().server)
        let inbox = BotInbox(server: key().server, store: store, makeWire: { _ in wire })
        await inbox.open()
        XCTAssertEqual(inbox.rooms(matching: "com").map(\.name), ["Comms"])
        XCTAssertTrue(inbox.rooms(matching: "unrelated").isEmpty)
        XCTAssertEqual(wire.stateCalls, 0, "Inbox never follows rooms")
        let roomKey = try XCTUnwrap(inbox.roomKey(inbox.rooms[0]))
        inbox.expireRoom(BotRoomKey(server: roomKey.server, connectionID: UUID(), roomID: roomKey.roomID))
        XCTAssertEqual(inbox.rooms.count, 1)
        inbox.expireRoom(roomKey)
        XCTAssertTrue(inbox.rooms.isEmpty)
        wire.capabilities = .object(["driver": .bool(false)])
        await inbox.open()
        XCTAssertTrue(inbox.rooms(matching: "Comms").isEmpty)
        XCTAssertFalse(inbox.roomCapabilities.enabled)
        XCTAssertEqual(wire.listCalls, 1, "A disabled driver must not list rooms")
        wire.capabilities = RoomFixture.capabilities; wire.disbanded = true
        await inbox.open()
        XCTAssertTrue(inbox.rooms.isEmpty)
        inbox.close()
    }

    func testForeignAuthorityShowsNoteAndAuthorityMoveRereadsState() async {
        let wire = RoomWire(); wire.authority = "another-install"
        let reader = makeReader(wire)
        await reader.open()
        XCTAssertTrue(reader.foreignAuthority)
        wire.latest = 1; wire.epoch = 2
        let reads = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, reads + 2)
        XCTAssertTrue(reader.foreignAuthority)
        reader.close()
    }

    func testStatusPollIntervalsAndMissingFields() {
        XCTAssertEqual(BotRoomStatus(.null).interval, .seconds(10))
        for flag in ["working", "blocked"] {
            XCTAssertEqual(BotRoomStatus(.object([flag: .bool(true)])).interval, .seconds(2))
        }
    }

    func testSendWaitsForAcknowledgmentAndLogReplayAddsNoDuplicate() async throws {
        let wire = RoomWire(); let reader = makeReader(wire)
        await reader.open()
        reader.draft = "  @all hello\n"
        let parked = expectation(description: "send waiting for reply")
        wire.holdWrite = true; wire.onWriteHeld = { parked.fulfill() }
        let send = Task { await reader.send() }
        await fulfillment(of: [parked], timeout: 2)
        XCTAssertTrue(reader.events.isEmpty)
        XCTAssertEqual(reader.draft, "  @all hello\n")
        await reader.poll()
        XCTAssertTrue(reader.events.isEmpty, "Log polling must not show our pending send before acknowledgment")
        wire.releaseWrite()
        await send.value
        XCTAssertEqual(reader.events.count, 1)
        XCTAssertEqual(reader.events[0].payload["text"].text, "@all hello")
        XCTAssertEqual(reader.draft, "")
        await reader.poll()
        XCTAssertEqual(reader.events.count, 1)
        let first = wire.writes[0].1
        XCTAssertEqual(first["payload"]?["text"].text, "  @all hello\n")
        reader.draft = "next"
        wire.holdWrite = false
        await reader.send()
        XCTAssertNotEqual(first["event_id"], wire.writes[1].1["event_id"])
        XCTAssertNotEqual(first["payload"]?["thread_id"], wire.writes[1].1["payload"]?["thread_id"])
        XCTAssertEqual(reader.events.count, 2)
        reader.close()
    }

    func testAcknowledgmentDoesNotSkipEarlierUnreadEvents() {
        var log = BotRoomLog(); log.begin(latest: 0)
        log.acknowledge(RoomFixture.event(3))
        XCTAssertEqual(log.cursor, 0)
        log.apply(RoomFixture.page((1...3).map { RoomFixture.event($0) }, cursor: 3))
        XCTAssertEqual(log.events.map(\.seq), [1, 2, 3])
    }

    func testLostSendKeepsDraftAndOnlyExplicitRetryReusesIdentity() async throws {
        let wire = RoomWire(); let reader = makeReader(wire)
        await reader.open(); reader.draft = "keep me"
        wire.loseWrite = true
        await reader.send()
        XCTAssertEqual(reader.draft, "keep me")
        XCTAssertNotNil(reader.uncertainSend)
        XCTAssertTrue(reader.commandMessage?.contains("Outcome unknown") == true)
        XCTAssertEqual(wire.writes.count, 1)
        wire.loseWrite = false
        await reader.open()
        XCTAssertEqual(wire.writes.count, 1, "Reconnect must never resend")
        await reader.send()
        XCTAssertEqual(wire.writes.count, 1, "Ordinary Send cannot mint another id while outcome is unknown")
        await reader.send(retry: true)
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes[0].1, wire.writes[1].1)
        XCTAssertNil(reader.uncertainSend)
        XCTAssertEqual(reader.draft, "")
        XCTAssertEqual(reader.events.count, 1)
        reader.close()
    }

    func testStaleApprovalFailsAtActualWriteAndRejectsPermanentChoices() async throws {
        let wire = RoomWire(); wire.driverStatus = RoomFixture.status(actions: [RoomFixture.approval])
        let reader = makeReader(wire); await reader.open()
        let action = try XCTUnwrap(reader.status.actions.first)
        XCTAssertEqual(action.approval?.choices, [.once, .deny])
        await reader.act(action, choice: .always)
        XCTAssertTrue(wire.writes.isEmpty)
        wire.beforeWrite = {
            wire.driverStatus = RoomFixture.status(actions: [])
            await reader.poll()
        }
        await reader.act(action, choice: .once)
        XCTAssertTrue(wire.writes.isEmpty)
        XCTAssertFalse(reader.mayAct(action))
        reader.close()
    }

    func testApprovalRejectionRereadsAndLeavesExactTupleInert() async throws {
        let wire = RoomWire(); wire.driverStatus = RoomFixture.status(actions: [RoomFixture.approval])
        let reader = makeReader(wire); await reader.open()
        let action = try XCTUnwrap(reader.status.actions.first)
        wire.writeFailure = BotRoomFailure(code: 5119, reason: nil)
        let reads = wire.stateCalls
        await reader.act(action, choice: .once)
        XCTAssertGreaterThan(wire.stateCalls, reads)
        XCTAssertFalse(reader.mayAct(action))
        await reader.act(action, choice: .deny)
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertEqual(wire.writes[0].1["execution_generation"], .number(1))
        XCTAssertEqual(wire.writes[0].1["request_id"], .string("approval:1"))
        reader.close()
    }

    func testLostApprovalIsNotResentAfterReconnect() async throws {
        let wire = RoomWire(); wire.driverStatus = RoomFixture.status(actions: [RoomFixture.approval])
        let reader = makeReader(wire); await reader.open()
        let action = try XCTUnwrap(reader.status.actions.first)
        wire.loseWrite = true
        await reader.act(action, choice: .deny)
        wire.loseWrite = false
        await reader.open()
        XCTAssertFalse(reader.mayAct(action))
        await reader.act(action, choice: .deny)
        XCTAssertEqual(wire.writes.count, 1)
        reader.close()
    }

    func testStopUsesStateNotCancelledCountAndDisablesAtIdle() async {
        let wire = RoomWire(); wire.driverStatus = RoomFixture.status(running: 1)
        let reader = makeReader(wire); await reader.open()
        XCTAssertTrue(reader.mayStop)
        await reader.stop()
        XCTAssertEqual(reader.statusText, "Stopping…")
        XCTAssertFalse(reader.mayStop)
        wire.driverStatus = RoomFixture.status()
        await reader.poll()
        XCTAssertNil(reader.statusText)
        XCTAssertFalse(reader.showsStop)
        XCTAssertFalse(reader.mayStop)
        reader.close()
    }

    func testRetryRejectionRefreshesAndUnknownActionsStayReadOnly() async throws {
        let wire = RoomWire()
        wire.driverStatus = RoomFixture.status(actions: [.object(["kind": .string("retry"), "task_id": .string("task:1")]),
            .object(["kind": .string("future")])])
        let reader = makeReader(wire); await reader.open()
        let retry = reader.status.actions[0], unknown = reader.status.actions[1]
        XCTAssertTrue(reader.mayAct(retry)); XCTAssertFalse(unknown.isAnswerable)
        await reader.act(unknown)
        XCTAssertTrue(wire.writes.isEmpty)
        wire.writeFailure = BotRoomFailure(code: 5118, reason: nil)
        let reads = wire.stateCalls
        await reader.act(retry)
        XCTAssertEqual(wire.writes.first?.0, "groups.retry")
        XCTAssertGreaterThan(wire.stateCalls, reads)
        reader.close()
    }

    func testForeignOrMissingAuthorityAndMissingMethodPreventWrites() async {
        let wire = RoomWire(); wire.authority = "elsewhere"
        let reader = makeReader(wire); await reader.open(); reader.draft = "hello"
        XCTAssertFalse(reader.showsComposer)
        await reader.send(); XCTAssertTrue(wire.writes.isEmpty)
        wire.authority = "fixture-install"
        var caps = RoomFixture.capabilities.fields!
        caps["methods"] = .array(["groups.list", "groups.state", "groups.log"].map(BotJSON.string))
        wire.capabilities = .object(caps)
        await reader.open()
        XCTAssertFalse(reader.maySend)
        reader.close()
    }

    func testCloseBeforeWriteRejectsDispatchAndLateReplyCannotPublish() async {
        let wire = RoomWire(); let reader = makeReader(wire); await reader.open()
        reader.draft = "hello"
        wire.beforeWrite = { reader.close() }
        await reader.send()
        XCTAssertTrue(wire.writes.isEmpty)
        XCTAssertTrue(reader.events.isEmpty)
        XCTAssertEqual(reader.draft, "hello")
        XCTAssertNil(reader.uncertainSend)
    }

    func testRoomMentionsUseHandlesAndIncludeBroadcastTargets() throws {
        var value = RoomFixture.room(latest: 0).fields!
        value["members"] = .array([.object(["member_id": .string("member"), "handle": .string("chief"), "display_name": .string("Chief of Staff")])])
        let room = try XCTUnwrap(BotGroupRoom(.object(value)))
        XCTAssertEqual(BotRoomMentions.completions(room: room, query: "").map(\.tag), ["chief", "all", "everyone"])
        XCTAssertEqual(BotRoomMentions.completions(room: room, query: "Staff").map(\.tag), ["chief"])
    }

    private func key() -> BotRoomKey { BotRoomKey(server: URL(string: "https://webui.example")!, connectionID: connection.id, roomID: "fixture-room") }
    private func makeReader(_ wire: RoomWire, cache: BotHistoryCache = BotHistoryCache(), expired: @escaping () -> Void = {}) -> BotRoomReader {
        BotRoomReader(key: key(), connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, cache: cache, makeWire: { _ in wire }, onExpired: expired)
    }
}

/// Synthesized protocol fixtures. Live host fixtures are kept separately when available.
enum RoomFixture {
    static let approval = BotJSON.object(["kind": .string("approval"), "member_id": .string("chief"),
        "task_id": .string("task:1"), "execution_generation": .number(1), "request_id": .string("approval:1"),
        "approval": .object(["command": .string("echo hello"), "choices": .array([.string("once"), .string("always"), .string("deny")])])])
    static func status(running: Int = 0, stopping: Int = 0, actions: [BotJSON] = []) -> BotJSON {
        .object(["working": .bool(running > 0), "blocked": .bool(!actions.isEmpty || stopping > 0),
                 "counts": .object(["running": .number(Double(running)), "stopping": .number(Double(stopping))]),
                 "pending_actions": .array(actions)])
    }
    static let capabilities = BotJSON.object(["driver": .bool(true), "methods": .array(BotRoomRPC.methods.map(BotJSON.string)),
        "authority_gateway_id": .string("fixture-install"), "max_log_limit": .number(100)])
    static func room(latest: Int) -> BotJSON {
        .object(["room_id": .string("fixture-room"), "name": .string("Comms"), "latest_seq": .number(Double(latest)),
            "authority_gateway_id": .string("fixture-install"), "authority_epoch": .number(1),
            "members": .array([.object(["member_id": .string("chief"), "profile": .string("chief-of-staff")])])])
    }
    static func event(_ seq: Int, kind: String = "message.user") -> BotJSON {
        .object(["room_id": .string("fixture-room"), "seq": .number(Double(seq)), "kind": .string(kind),
            "actor": .object(["id": .string("chief")]), "payload": .object(["text": .string("Message \(seq)")])])
    }
    static func page(_ events: [BotJSON], cursor: Int, more: Bool = false) -> BotJSON {
        .object(["events": .array(events), "cursor": .number(Double(cursor)), "has_more": .bool(more),
                 "authority": .object(["gateway_id": .string("fixture-install"), "epoch": .number(1)])])
    }
}

@MainActor final class RoomWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var latest = 0
    var capabilities = RoomFixture.capabilities
    var disbanded = false
    var roomName = "Comms"
    var listedRooms: [BotJSON]?
    var listCalls = 0
    var listFailure: Error?
    var connectFailure: Error?
    var authority = "fixture-install"
    var epoch = 1
    var logStarts: [Int] = []
    var stateCalls = 0
    var closed = 0
    var kind = "message.user"
    var failure: Error?
    var driverStatus = RoomFixture.status()
    var writes: [(String, [String: BotJSON])] = []
    var beforeWrite: (() async -> Void)?
    var writeFailure: Error?
    var loseWrite = false
    var holdWrite = false
    var onWriteHeld: (() -> Void)?
    private var writeReply: BotJSON?
    private var heldWrite: CheckedContinuation<BotJSON, Never>?
    private var sentEvents: [String: BotJSON] = [:]
    var holdState = false
    var onHeld: (() -> Void)?
    private var held: CheckedContinuation<BotJSON, Never>?
    func connect() async throws { if let connectFailure { throw connectFailure } }
    func close() { closed += 1 }
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        if ["groups.send", "groups.stop", "groups.approve", "groups.retry", "groups.create", "groups.rename", "groups.disband"].contains(method) {
            await beforeWrite?()
            try validateDispatch?()
            writes.append((method, params))
            if let writeFailure { throw writeFailure }
            var result: BotJSON
            switch method {
            case "groups.send":
                let id = params["event_id"]!.text!
                if sentEvents[id] == nil {
                    latest += 1
                    var event = RoomFixture.event(latest).fields!
                    var payload = params["payload"]!.fields!
                    payload["text"] = .string(payload["text"]!.text!.trimmingCharacters(in: .whitespacesAndNewlines))
                    event["payload"] = .object(payload)
                    sentEvents[id] = .object(event)
                }
                result = .object(["accepted": .bool(true), "client_event_id": params["event_id"]!, "event": sentEvents[id]!])
            case "groups.create":
                var room = RoomFixture.room(latest: 0).fields!
                room["room_id"] = params["room_id"]; room["name"] = params["name"]; room["members"] = params["members"]
                result = .object(["room": .object(room)])
            case "groups.rename":
                roomName = params["name"]!.text!; latest += 1
                var room = RoomFixture.room(latest: latest).fields!
                room["name"] = .string(roomName)
                var event = RoomFixture.event(latest, kind: "room.renamed").fields!
                event["payload"] = .object(["name": .string(roomName)])
                room["event"] = .object(event); sentEvents[params["event_id"]!.text!] = .object(event)
                result = .object(["room": .object(room)])
            case "groups.disband":
                disbanded = true
                result = .object(["tombstone": .object(["room_id": params["room_id"]!, "disbanded_at": .number(100)])])
            case "groups.stop":
                driverStatus = RoomFixture.status(stopping: 1)
                result = .object(["cancelled": .number(1)])
            case "groups.approve": result = .object(["approved": .bool(true)])
            default: result = .object(["retried": .bool(true)])
            }
            if loseWrite { onDisconnect?(BotFailure.transport); throw BotFailure.transport }
            if holdWrite {
                writeReply = result
                return await withCheckedContinuation { heldWrite = $0; onWriteHeld?() }
            }
            return result
        }
        try validateDispatch?()
        switch method {
        case "profiles.list": return .object(["profiles": .array([])])
        case "groups.capabilities": return capabilities
        case "groups.list":
            listCalls += 1
            if let listFailure { throw listFailure }
            if let listedRooms { return .object(["rooms": .array(listedRooms), "next_offset": .null]) }
            var room = RoomFixture.room(latest: latest).fields!
            room["name"] = .string(roomName)
            if disbanded { room["disbanded_at"] = .number(100) }
            return .object(["rooms": .array([.object(room)]), "next_offset": .null])
        case "groups.state":
            stateCalls += 1
            if let failure { throw failure }
            if holdState { return await withCheckedContinuation { held = $0; onHeld?() } }
            var room = RoomFixture.room(latest: latest).fields!
            room["name"] = .string(roomName)
            room["authority_gateway_id"] = .string(authority); room["authority_epoch"] = .number(Double(epoch))
            return .object(["room": .object(room), "driver_status": driverStatus])
        case "groups.log":
            let start = params["since_seq"]!.integer!; logStarts.append(start)
            let end = min(latest, start + params["limit"]!.integer!)
            let events = end > start ? ((start + 1)...end).map { seq in
                sentEvents.values.first { $0["seq"].integer == seq } ?? RoomFixture.event(seq, kind: kind)
            } : []
            var page = RoomFixture.page(events, cursor: end, more: end < latest).fields!
            page["authority"] = .object(["gateway_id": .string(authority), "epoch": .number(Double(epoch))])
            return .object(page)
        default: XCTFail("Unexpected room method: \(method)"); throw BotFailure.unsupported
        }
    }
    func releaseWrite() {
        if let writeReply { heldWrite?.resume(returning: writeReply) }
        heldWrite = nil; writeReply = nil
    }
    func releaseState(latest: Int) {
        held?.resume(returning: .object(["room": RoomFixture.room(latest: latest)])); held = nil
    }
}

private extension BotRoomTests {
    // Read-only tunnel capture, 2026-09-16, Hermes 0.21.2; install identity replaced.
    static let liveFixture = #"""
{
  "capabilities": {
    "protocol_version": 2,
    "driver": true,
    "persistent_process": true,
    "authority_gateway_id": "fixture-install",
    "room_link": {
      "enabled": true,
      "profile": "default",
      "catalog": {
        "installation_id": "fixture-install",
        "protocol_versions": [
          2
        ],
        "link_modes": [
          "direct"
        ],
        "persistent_process": true,
        "text": true,
        "attachments": false,
        "execution_policy": {
          "version": 1,
          "target_profile": "default",
          "enabled_toolsets": [
            "agentmail",
            "bot_room",
            "browser",
            "code_execution",
            "connections",
            "cronjob",
            "delegation",
            "file",
            "firecrawl",
            "image_gen",
            "memory",
            "session_search",
            "skills",
            "terminal",
            "todo",
            "vision",
            "web"
          ],
          "approval_mode": "manual",
          "max_iterations": 75,
          "policy_digest": "46af513ec7dbfd1a0f166c8a3c8d5a2a79543a8b55a105b447fdd21fb7c09605"
        },
        "endpoint": {
          "available": false,
          "reason": "not_configured"
        },
        "catalog_digest": "9bb855f5a5164a77d444b2ca9a4660e3a0e289978a7514139422dedc791d0b98"
      },
      "endpoint": {
        "available": false,
        "reason": "not_configured"
      }
    },
    "features": [
      "authority_epoch",
      "coordinator_fencing",
      "room_identity",
      "monotonic_log",
      "idempotent_send",
      "replayable_disband",
      "typed_events",
      "actor_identity",
      "log_replication",
      "authority_takeover"
    ],
    "methods": [
      "groups.capabilities",
      "groups.list",
      "groups.create",
      "groups.state",
      "groups.send",
      "groups.rename",
      "groups.log",
      "groups.disband",
      "groups.replicate",
      "groups.replica_state",
      "groups.promote",
      "groups.demote",
      "groups.stop",
      "groups.retry",
      "groups.approve",
      "groups.peer.invite",
      "groups.peer.revoke",
      "groups.peer.register"
    ],
    "max_log_limit": 500
  },
  "list": {
    "rooms": [
      {
        "room_id": "5ba46d7d-0364-409d-b5a8-a3f29e6d1ceb",
        "name": "Comms",
        "members": [
          {
            "display_name": "chief-of-staff",
            "handle": "chief-of-staff",
            "member_id": "chief-of-staff",
            "profile": "chief-of-staff",
            "target": {
              "kind": "local",
              "profile": "chief-of-staff"
            }
          },
          {
            "display_name": "inbox-triage",
            "handle": "inbox-triage",
            "member_id": "inbox-triage",
            "profile": "inbox-triage",
            "target": {
              "kind": "local",
              "profile": "inbox-triage"
            }
          }
        ],
        "authority_gateway_id": "fixture-install",
        "authority_epoch": 1,
        "revision": 1,
        "created_at": 1789433946.8950279,
        "updated_at": 1789433946.8950279,
        "idempotent": false,
        "latest_seq": 0
      }
    ],
    "next_offset": null
  },
  "state": {
    "room": {
      "room_id": "5ba46d7d-0364-409d-b5a8-a3f29e6d1ceb",
      "name": "Comms",
      "members": [
        {
          "display_name": "chief-of-staff",
          "handle": "chief-of-staff",
          "member_id": "chief-of-staff",
          "profile": "chief-of-staff",
          "target": {
            "kind": "local",
            "profile": "chief-of-staff"
          }
        },
        {
          "display_name": "inbox-triage",
          "handle": "inbox-triage",
          "member_id": "inbox-triage",
          "profile": "inbox-triage",
          "target": {
            "kind": "local",
            "profile": "inbox-triage"
          }
        }
      ],
      "authority_gateway_id": "fixture-install",
      "authority_epoch": 1,
      "revision": 1,
      "created_at": 1789433946.8950279,
      "updated_at": 1789433946.8950279,
      "idempotent": false,
      "latest_seq": 0
    },
    "driver_status": {
      "running": true,
      "working": false,
      "blocked": false,
      "counts": {},
      "pending_actions": [],
      "peer_routes": []
    }
  }
}
"""#
}
