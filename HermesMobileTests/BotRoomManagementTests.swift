import XCTest
@testable import HermesMobile

@MainActor final class BotRoomManagementTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!, username: "u", password: "p")
    private func profile(_ id: String, hidden: Bool = false, display: String? = nil) -> BotProfile {
        var row: [String: BotJSON] = ["name": .string(id), "ui_meta": .object(["hermes-bots": .object(["hidden": .bool(hidden)])])]
        if let display { row["display_name"] = .string(display) }
        return BotProfile(.object(row))!
    }
    private func creator(_ wire: RoomWire, store: BotConnectionStore? = nil,
                         reconciled: @escaping ([BotGroupRoom]) -> Void = { _ in }) throws -> BotRoomCreator {
        let store = store ?? BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        return BotRoomCreator(server: server, connection: connection,
            roster: [profile("default", display: "Hermes"), profile("dev"), profile("hidden", hidden: true)] + (1...5).map { profile("bot\($0)") },
            store: store, makeWire: { _ in wire }, onReconciled: reconciled)
    }
    private func reader(_ wire: RoomWire, changed: @escaping (BotGroupRoom) -> Void = { _ in },
                        disbanded: @escaping () -> Void = {}) -> BotRoomReader {
        BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: "fixture-room"),
            connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, makeWire: { _ in wire },
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
            room["room_id"] = mismatch == "id" ? .string("other-room") : attempt["room_id"]
            room["members"] = mismatch == "members" ? .array([]) : attempt["members"]
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

    func testRoomMutationValidationIsExactAndCountsUnicodeLikeServer() throws {
        let members = [profile("default"), profile("dev")].map(BotRoomCreator.member)
        var params: [String: BotJSON] = ["room_id": .string("room"), "name": .string("Group"), "members": .array(members)]
        XCTAssertNoThrow(try BotRoomRPC.validate("groups.create", params))
        for count in [0, 1, 7] {
            params["members"] = .array((0..<count).map { BotRoomCreator.member(profile("bot\($0)")) })
            XCTAssertThrowsError(try BotRoomRPC.validate("groups.create", params))
        }
        var injected = members[0].fields!; injected["target"] = .object(["kind": .string("peer")])
        params["members"] = .array([.object(injected), members[1]])
        XCTAssertThrowsError(try BotRoomRPC.validate("groups.create", params))
        XCTAssertFalse(BotRoomRPC.validName(String(repeating: "👩‍💻", count: 100)))
        XCTAssertThrowsError(try BotRoomRPC.validate("groups.rename", ["room_id": .string("room"), "name": .string("x")]))
        XCTAssertThrowsError(try BotRoomRPC.validate("groups.disband", ["room_id": .string("room"), "target": .string("peer")]))
        for method in ["groups.promote", "groups.demote", "groups.replicate", "groups.replica_state", "groups.peer.invite"] {
            XCTAssertFalse(BotRoomRPC.methods.contains(method))
            XCTAssertThrowsError(try BotRoomRPC.validate(method, [:]))
        }
    }
}
