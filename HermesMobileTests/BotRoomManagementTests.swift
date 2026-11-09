import XCTest
@testable import HermesMobile

@MainActor final class BotRoomManagementTests: XCTestCase {
    func testUnifiedGroupPickerDispatchesLocalMixedAndPeerOnlySelections() async throws {
        let peer = try XCTUnwrap(BotPeer(.object(["route_id": .string("opaque"), "kind": .string("peer"),
            "alias": .string("remote"), "profile": .string("dev"), "reachability": .string("reachable"),
            "display_name": .string("Same name"), "installation_id": .string("other")])))
        let peer2 = try XCTUnwrap(BotPeer(.object(["route_id": .string("opaque-2"), "kind": .string("peer"),
            "alias": .string("second"), "profile": .string("dev"), "reachability": .string("reachable")])))
        let local = profile("dev", display: "Same name")
        for (selection, expected) in [([local, profile("default")], "groups.create"),
                                      ([local, BotProfile(peer: peer)], "groups.create_mixed"),
                                      ([BotProfile(peer: peer), BotProfile(peer: peer2)], "groups.create_mixed")] {
            let wire = UnifiedRosterGroupWire(peers: [peer.json, peer2.json])
            let store = BotConnectionStore(keychain: InMemoryKeychainStore())
            try store.save(connection, server: server)
            let creator = BotRoomCreator(server: server, connection: connection, roster: selection,
                seatable: ["dev", "default"], store: store, makeWire: { _ in wire })
            selection.forEach(creator.select)
            XCTAssertEqual(creator.selected.count, 2)
            await creator.create()
            XCTAssertEqual(wire.writes.map(\.method), [expected])
            XCTAssertNotNil(creator.created)
            let payload = try XCTUnwrap(wire.writes.first).params()
            let rows = try XCTUnwrap(payload["members"]?.list)
            if expected == "groups.create_mixed" {
                XCTAssertEqual(rows.filter { $0["kind"].text == "peer" }.count, selection.filter { $0.peer != nil }.count)
                XCTAssertEqual(rows.last?["route_id"].text, selection.last?.peer?.id)
                XCTAssertEqual(rows.last?["profile"], .null)
            } else { XCTAssertTrue(rows.allSatisfy { $0["kind"] == .null }) }
        }
    }

    func testMixedCreateRefreshesOpaqueRoutesBeforeDispatch() async throws {
        func peer(_ route: String) throws -> BotPeer {
            try XCTUnwrap(BotPeer(.object(["kind": .string("peer"), "route_id": .string(route),
                "alias": .string("office"), "profile": .string("dev"),
                "reachability": .string("reachable"), "installation_id": .string("install:office")])))
        }
        let old = try peer("before-restart"), fresh = try peer("after-restart")
        let wire = UnifiedRosterGroupWire(peers: [fresh.json])
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let roster = [profile("dev"), BotProfile(peer: old)]
        let creator = BotRoomCreator(server: server, connection: connection, roster: roster,
            store: store, makeWire: { _ in wire })
        roster.forEach(creator.select)
        await creator.create()
        let call = try XCTUnwrap(wire.writes.first)
        XCTAssertEqual(try call.params()["members"]?.list?.last?["route_id"].text, "after-restart")
        XCTAssertEqual(creator.created?.members.last?.peerID, "after-restart")
    }

    func testMixedRetryUsesTheFreshRouteAfterALostCreate() async throws {
        func peer(_ route: String) throws -> BotPeer {
            try XCTUnwrap(BotPeer(.object(["kind": .string("peer"), "route_id": .string(route),
                "alias": .string("office"), "profile": .string("dev"),
                "reachability": .string("reachable"), "installation_id": .string("install:office")])))
        }
        let old = try peer("before-restart"), fresh = try peer("after-restart")
        let wire = UnifiedRosterGroupWire(peers: [old.json])
        wire.createError = BotFailure.transport
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let roster = [profile("dev"), BotProfile(peer: old)]
        let creator = BotRoomCreator(server: server, connection: connection, roster: roster,
            store: store, makeWire: { _ in wire })
        roster.forEach(creator.select)
        await creator.create()
        XCTAssertNil(creator.created)
        wire.peers = [fresh.json]
        await creator.create()
        let retry = try XCTUnwrap(wire.writes.last)
        XCTAssertEqual(try retry.params()["members"]?.list?.last?["route_id"].text, "after-restart")
        XCTAssertEqual(try retry.params()["room_id"].text, try wire.writes.first?.params()["room_id"].text)
    }

    func testMixedReplyWithAnotherPeerTargetDoesNotReportSuccess() async throws {
        let peer = try XCTUnwrap(BotPeer(.object(["kind": .string("peer"), "route_id": .string("selected"),
            "alias": .string("office"), "profile": .string("dev"), "reachability": .string("reachable")])))
        let wire = UnifiedRosterGroupWire(peers: [peer.json])
        wire.returnedPeerID = "another-peer"
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let roster = [profile("dev"), BotProfile(peer: peer)]
        let creator = BotRoomCreator(server: server, connection: connection, roster: roster,
            store: store, makeWire: { _ in wire })
        roster.forEach(creator.select)
        await creator.create()
        XCTAssertEqual(wire.writes.count, 1)
        XCTAssertNil(creator.created)
        XCTAssertTrue(creator.locked)
    }

    func testPeerGoingOfflineAfterSelectionPreventsMixedCreate() async throws {
        let peer = try XCTUnwrap(BotPeer(.object(["route_id": .string("opaque"), "kind": .string("peer"),
            "alias": .string("remote"), "profile": .string("dev"), "reachability": .string("reachable")])))
        let wire = UnifiedRosterGroupWire(peers: [peer.unavailable.json])
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let roster = [profile("dev"), BotProfile(peer: peer)]
        let creator = BotRoomCreator(server: server, connection: connection, roster: roster,
            store: store, makeWire: { _ in wire })
        roster.forEach(creator.select)
        await creator.create()
        XCTAssertTrue(wire.writes.isEmpty)
        XCTAssertNil(creator.created)
        XCTAssertNotNil(creator.message)
    }

    func testUnavailablePeerIsVisibleButCannotBeSelectedOrDispatched() throws {
        let peer = try XCTUnwrap(BotPeer(.object(["route_id": .string("offline"), "kind": .string("peer"),
            "alias": .string("remote"), "profile": .string("dev"), "reachability": .string("unreachable"),
            "unavailable_reason": .string("Unreachable")])))
        let creator = BotRoomCreator(server: server, connection: connection,
            roster: [profile("dev"), BotProfile(peer: peer)], seatable: ["dev"])
        XCTAssertEqual(creator.remaining.count, 2)
        creator.remaining.forEach(creator.select)
        XCTAssertEqual(creator.selected.count, 1)
        XCTAssertFalse(creator.mayCreate)
    }

    private let server = URL(string: "https://webui.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!, username: "u", password: "p")
    private func profile(_ id: String, hidden: Bool = false, display: String? = nil) -> BotProfile {
        var row: [String: BotJSON] = ["name": .string(id), "ui_meta": .object(["hermes-bots": .object(["hidden": .bool(hidden)])])]
        if let display { row["display_name"] = .string(display) }
        return BotProfile(.object(row))!
    }
    private func creator(_ wire: RoomWire, store: BotConnectionStore? = nil, seatable: Set<String>? = nil,
                         reconciled: @escaping ([BotGroupRoom]) -> Void = { _ in }) throws -> BotRoomCreator {
        let store = store ?? BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        return BotRoomCreator(server: server, connection: connection,
            roster: [profile("default", display: "Hermes"), profile("dev"), profile("hidden", hidden: true)] + (1...5).map { profile("bot\($0)") },
            seatable: seatable, store: store, makeWire: { _ in wire }, onReconciled: reconciled)
    }
    private func reader(_ wire: RoomWire, changed: @escaping (BotGroupRoom) -> Void = { _ in },
                        disbanded: @escaping () -> Void = {}) -> BotRoomReader {
        BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: "fixture-room"),
            connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, cache: BotHistoryCache(), makeWire: { _ in wire },
            onChanged: changed, onDisbanded: disbanded)
    }

    func testMemberBoundsAndHiddenFilter() throws {
        let creator = try creator(RoomWire())
        XCTAssertFalse(creator.mayContinue)
        XCTAssertFalse(creator.remaining.contains { $0.id == "hidden" })
        creator.query = "hidden"
        XCTAssertEqual(creator.remaining.map(\.id), ["hidden"])
        creator.select(creator.roster[2])
        XCTAssertFalse(creator.mayContinue)
        creator.select(creator.roster[0]); XCTAssertTrue(creator.mayContinue)
        for bot in creator.roster { creator.select(bot) }
        XCTAssertEqual(creator.selected.count, 6)
        creator.remove(creator.selected[0]); XCTAssertEqual(creator.selected.count, 5)
    }

    /// A canonical host names the Profiles it can seat (#1605). No other bot is listed, can be
    /// chosen, or is sent, and one the host stopped seating after the sheet opened stops Create.
    func testOnlyBotsTheHostCanSeatCanJoinAGroup() async throws {
        let wire = RoomWire()
        let creator = try creator(wire, seatable: ["default", "dev", "bot1"])
        XCTAssertEqual(creator.remaining.map(\.id), ["default", "dev", "bot1"])
        XCTAssertTrue(creator.leavesOutBots)
        creator.select(creator.roster.first { $0.id == "bot2" }!)
        XCTAssertTrue(creator.selected.isEmpty)
        creator.select(creator.roster[0]); creator.select(creator.roster[1])
        var caps = RoomFixture.capabilities.fields!
        caps["seatable_profiles"] = .array([.string("default"), .string("bot1")])
        wire.capabilities = .object(caps)
        await creator.create()
        XCTAssertTrue(wire.writes.isEmpty)
        XCTAssertNil(creator.created)
        XCTAssertNotNil(creator.message)
        // The picker follows the host's answer: the refused bot leaves, and one it seats now shows.
        XCTAssertEqual(creator.selected.map(\.id), ["default"])
        XCTAssertEqual(creator.remaining.map(\.id), ["bot1"])
        XCTAssertTrue(try self.creator(RoomWire(), seatable: ["dev"]).tooFewToSeat)

        // The host refuses an unseatable member before it looks for the room, so a Try Again after
        // a lost reply reads the rooms: the one it made, or an unlocked choice and no resend.
        for made in [true, false] {
            let wire = RoomWire(), creator = try self.creator(wire, seatable: ["default", "dev"])
            creator.select(creator.roster[0]); creator.select(creator.roster[1])
            wire.loseWrite = true
            await creator.create()
            wire.loseWrite = false
            let sent = try XCTUnwrap(wire.writes.first?.1)
            var room = RoomFixture.room(latest: 0).fields!
            room["room_id"] = sent["room_id"]; room["members"] = sent["members"]
            if made { wire.listedRooms = [.object(room)] }
            wire.capabilities = .object(caps)
            await creator.create()
            XCTAssertEqual(wire.writes.count, 1)
            XCTAssertEqual(creator.created?.id, made ? sent["room_id"]?.text : nil)
            XCTAssertEqual(creator.locked, made)
        }
    }

    func testCreatePayloadAndExplicitRetryKeepIdentityAndMissingDisplayName() async throws {
        let wire = RoomWire(), creator = try creator(wire)
        creator.select(creator.roster[0]); creator.select(creator.roster[1])
        wire.loseWrite = true
        await creator.create()
        XCTAssertNil(creator.created)
        let first = try XCTUnwrap(wire.writes.first?.1)
        XCTAssertNotNil(UUID(uuidString: first["room_id"]!.text!))
        let members = try XCTUnwrap(first["members"]?.list)
        XCTAssertEqual(members[0]["handle"], .string("default"))
        XCTAssertEqual(members[0]["display_name"], .string("Hermes"))
        XCTAssertEqual(Set(members[1].fields!.keys), ["member_id", "profile", "handle"])
        XCTAssertEqual(members[1]["member_id"], .string("dev"))
        creator.remove(creator.selected[0]); XCTAssertEqual(creator.selected.count, 2)
        wire.loseWrite = false
        await creator.create()
        XCTAssertEqual(wire.writes.count, 2)
        XCTAssertEqual(wire.writes[1].1, first)
        XCTAssertEqual(creator.created?.id, first["room_id"]?.text)
        await creator.create(); XCTAssertEqual(wire.writes.count, 2)
    }

    func testConflictRereadsListAndWorkerUnavailableExplainsRecovery() async throws {
        let wire = RoomWire(); var reconciled = false
        let creator = try creator(wire, reconciled: { reconciled = !$0.isEmpty })
        creator.select(creator.roster[0]); creator.select(creator.roster[1])
        wire.writeFailure = BotRoomFailure(code: 4110, reason: nil)
        await creator.create()
        XCTAssertTrue(reconciled); XCTAssertEqual(wire.listCalls, 1)
        wire.writeFailure = BotRoomFailure(code: 4123, reason: nil)
        await creator.create()
        XCTAssertTrue(creator.message?.contains("Restart the Hermes gateway") == true)
        XCTAssertNil(creator.created)
    }

    func testConflictRecoversRenamedRoomOnlyWithMatchingMembersAndAuthority() async throws {
        for mismatch in ["none", "id", "members", "authority"] {
            let wire = RoomWire(), creator = try creator(wire)
            creator.select(creator.roster[0]); creator.select(creator.roster[1])
            wire.loseWrite = true
            await creator.create()
            let attempt = try XCTUnwrap(creator.attempt)
            var room = RoomFixture.room(latest: 0).fields!
            room["room_id"] = .string(mismatch == "id" ? "other-room" : attempt.roomID)
            room["members"] = .array(mismatch == "members" ? [] : attempt.members.map(\.json))
            room["name"] = .string("Renamed on Desktop")
            if mismatch == "authority" { room["authority_gateway_id"] = .string("foreign") }
            wire.listedRooms = [.object(room)]
            wire.loseWrite = false; wire.writeFailure = BotRoomFailure(code: 4110, reason: nil)
            await creator.create()
            XCTAssertEqual(wire.writes.count, 2)
            XCTAssertEqual(wire.writes[0].1, wire.writes[1].1)
            XCTAssertEqual(wire.listCalls, 1)
            if mismatch == "none" {
                XCTAssertEqual(creator.created?.name, "Renamed on Desktop")
                XCTAssertNil(creator.message)
                await creator.create(); XCTAssertEqual(wire.writes.count, 2)
            } else { XCTAssertNil(creator.created, mismatch) }
        }
    }

    func testCreationRejectsReplacedConnectionAtDispatch() async throws {
        let wire = RoomWire(), store = BotConnectionStore(keychain: InMemoryKeychainStore())
        let creator = try creator(wire, store: store)
        creator.select(creator.roster[0]); creator.select(creator.roster[1])
        wire.beforeWrite = {
            try! store.save(BotConnection(id: UUID(), name: "Other", address: self.connection.address, username: "other", password: "p"), server: self.server)
        }
        await creator.create()
        XCTAssertTrue(wire.writes.isEmpty); XCTAssertNil(creator.created)
    }

    func testLateCreationCannotPublishAfterSheetCloses() async throws {
        let wire = RoomWire(), creator = try creator(wire)
        creator.select(creator.roster[0]); creator.select(creator.roster[1])
        let held = expectation(description: "create held")
        wire.holdWrite = true; wire.onWriteHeld = { held.fulfill() }
        let create = Task { await creator.create() }
        await fulfillment(of: [held], timeout: 2)
        creator.suspend(); wire.releaseWrite(); await create.value
        XCTAssertNil(creator.created); XCTAssertFalse(creator.busy)
        XCTAssertNotNil(creator.attempt)
    }

    func testRenameWaitsForResultEvenWhenPollSeesNewName() async {
        let wire = RoomWire(); var names: [String] = []
        let reader = reader(wire, changed: { names.append($0.name) }); await reader.open()
        let held = expectation(description: "rename held")
        wire.holdWrite = true; wire.onWriteHeld = { held.fulfill() }
        let rename = Task { await reader.rename("New name") }
        await fulfillment(of: [held], timeout: 2)
        await reader.poll()
        XCTAssertEqual(reader.room.name, "Comms"); XCTAssertFalse(names.contains("New name"))
        wire.releaseWrite(); await rename.value
        XCTAssertEqual(reader.room.name, "New name"); XCTAssertTrue(names.contains("New name"))
        XCTAssertEqual(reader.events.filter { $0.kind == "room.renamed" }.count, 1)
        XCTAssertNotNil(UUID(uuidString: wire.writes[0].1["event_id"]!.text!))
        reader.close()
    }

    func testDisbandStopsAtStoppingAndRevalidatesAtDispatch() async {
        let wire = RoomWire(), reader = reader(wire)
        wire.driverStatus = RoomFixture.status(stopping: 1); await reader.open()
        XCTAssertFalse(reader.mayDisband); await reader.disband(); XCTAssertTrue(wire.writes.isEmpty)
        wire.driverStatus = RoomFixture.status(); await reader.poll(); XCTAssertTrue(reader.mayDisband)
        wire.beforeWrite = { wire.driverStatus = RoomFixture.status(stopping: 1); await reader.poll() }
        await reader.disband(); XCTAssertTrue(wire.writes.isEmpty)
        reader.close()
    }

    func testLostDisbandReplyReadsListAndNeverRetries() async {
        let wire = RoomWire(); var removed = 0
        let reader = reader(wire, disbanded: { removed += 1 }); await reader.open()
        wire.loseWrite = true
        await reader.disband()
        XCTAssertEqual(removed, 1); XCTAssertEqual(wire.listCalls, 1)
        XCTAssertEqual(wire.writes.map(\.0), ["groups.disband"])
        XCTAssertEqual(reader.link, .idle)
    }

    func testDisbandTombstoneRemovesRoomButRejectionDoesNot() async {
        let wire = RoomWire(); var removed = false
        let reader = reader(wire, disbanded: { removed = true }); await reader.open()
        wire.writeFailure = BotRoomFailure(code: 5114, reason: nil)
        await reader.disband(); XCTAssertFalse(removed); XCTAssertFalse(reader.uncertainDisband)
        wire.writeFailure = nil
        await reader.disband(); XCTAssertTrue(removed)
        XCTAssertEqual(reader.link, .idle)
    }

    func testForeignAuthorityHidesManagementAndOldViewCannotCloseNewOwner() async {
        let wire = RoomWire(), reader = reader(wire)
        wire.authority = "foreign"; await reader.open()
        XCTAssertFalse(reader.showsRename); XCTAssertFalse(reader.showsDisband)
        await reader.rename("No"); await reader.disband(); XCTAssertTrue(wire.writes.isEmpty)
        let first = UUID(), second = UUID()
        await reader.open(owner: first); await reader.open(owner: second)
        reader.leave(owner: first); XCTAssertEqual(reader.link, .live)
        reader.leave(owner: second); XCTAssertEqual(reader.link, .idle)
    }

    /// Peer administration and extra member keys have no `HermesCall` shape at all;
    /// what remains is the value rules the host applies.
    func testRoomMutationValidationIsExactAndCountsUnicodeLikeServer() throws {
        let members = [profile("default"), profile("dev")].map(BotRoomCreator.member)
        var room = HermesCall.RoomCreation(roomID: "room", name: "Group", members: members)
        XCTAssertEqual(try HermesCall.groupsCreate(room).params()["members"]?.list?.count, 2)
        for count in [0, 1, 7] {
            room.members = (0..<count).map { BotRoomCreator.member(profile("bot\($0)")) }
            XCTAssertThrowsError(try HermesCall.groupsCreate(room).params())
        }
        room.members = [members[0], members[0]]
        XCTAssertThrowsError(try HermesCall.groupsCreate(room).params(), "a Profile joins once")
        room.members = [HermesCall.RoomMember(memberID: "dev", profile: "dev", handle: "all"), members[0]]
        XCTAssertThrowsError(try HermesCall.groupsCreate(room).params(), "a handle cannot shadow @all")
        XCTAssertFalse(BotRoomRPC.validName(String(repeating: "👩‍💻", count: 100)))
        XCTAssertThrowsError(try HermesCall.groupsRename(roomID: "room", eventID: "", name: "x").params())
        XCTAssertThrowsError(try HermesCall.groupsDisband(roomID: "../room").params())
    }
}

@MainActor private final class UnifiedRosterGroupWire: BotTransport {
    var replayEpoch: String? { nil }
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var peers: [BotJSON]
    var writes: [HermesCall] = []
    var returnedPeerID: String?
    var createError: Error?
    init(peers: [BotJSON]) { self.peers = peers }
    func connect() async throws {}
    func close() {}
    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        switch call {
        case .peersRoster: return .object(["bots": .array(peers)])
        case .groupsList: return .object(["rooms": .array([]), "next_offset": .null])
        case .groupsCapabilities:
            return .object(["driver": .bool(true), "authority_gateway_id": .string("install"),
                "methods": .array(["groups.list", "groups.state", "groups.log", "groups.create"].map(BotJSON.string))])
        case .groupsCreate(let room), .groupsCreateMixed(let room):
            _ = try call.params(); writes.append(call)
            if let createError { self.createError = nil; throw createError }
            return .object(["room": .object(["room_id": .string(room.roomID), "name": .string(room.name),
                "authority_gateway_id": .string("install"), "members": .array(room.members.map { member in
                    var fields = member.json.fields ?? [:]
                    if let peer = member.peer {
                        fields["target"] = .object(["kind": .string("peer"), "peer_id": .string(returnedPeerID ?? peer.id),
                            "installation_id": peer.installationID.map(BotJSON.string) ?? .null,
                            "profile": .string(peer.profile)])
                    }
                    return .object(fields)
                })])])
        default: throw BotFailure.unsupported
        }
    }
}
