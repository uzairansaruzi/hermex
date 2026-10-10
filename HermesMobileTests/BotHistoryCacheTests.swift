import XCTest
@testable import HermesMobile

/// The room search index and its rules: bounded, scoped to its server and connection, and
/// revocable. A bot's chat is searched on its host (#1146), so only rooms are saved here.
final class BotHistoryCacheTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private let otherServer = URL(string: "https://two.example")!
    private let connection = UUID()

    private func roomKey(connectionID: UUID? = nil, serverURL: URL? = nil, roomID: String = "fixture-room") -> BotRoomKey {
        BotRoomKey(server: serverURL ?? server, connectionID: connectionID ?? connection, roomID: roomID)
    }

    private var room: BotGroupRoom { BotGroupRoom(RoomFixture.room(latest: 3))! }

    /// Saves `texts` as one page of `room`'s user messages, seq 1 onwards.
    private func append(_ cache: BotHistoryCache, room roomID: String, _ texts: [String], roles: [String]? = nil,
                        key: BotRoomKey? = nil, receivedAt: Date = Date()) async throws {
        let key = key ?? roomKey(roomID: roomID)
        var fields = RoomFixture.room(latest: texts.count).fields!
        fields["room_id"] = .string(roomID)
        let events: [BotJSON] = texts.enumerated().map { index, text in
            .object(["room_id": .string(roomID), "seq": .number(Double(index + 1)),
                     "kind": .string(roles?[index] ?? "message.user"), "actor": .object(["id": .string("chief")]),
                     "payload": .object(["text": .string(text)])])
        }
        try await cache.appendRoom(key: key, room: BotGroupRoom(.object(fields))!,
                                   page: RoomFixture.page(events, cursor: texts.count), since: 0, receivedAt: receivedAt)
    }

    func testOldRoomMessageSnapshotRemainsReadableWithoutAReplyTarget() throws {
        let data = Data(#"{"id":"3","role":"message.member","text":"Old message","seq":3}"#.utf8)
        let message = try JSONDecoder().decode(BotHistoryCache.Message.self, from: data)
        let event = try XCTUnwrap(message.roomEvent.flatMap(BotRoomEvent.init))
        XCTAssertEqual(event.payload["text"].text, "Old message")
        XCTAssertNil(event.threadID)
        XCTAssertTrue(BotRoomThread.group([event], hasEarlier: false).isEmpty)
    }

    func testRoomThreadIdentitySurvivesDiskReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BotHistoryCache(directory: directory), key = roomKey()
        let event: BotJSON = .object([
            "room_id": .string(key.roomID), "seq": .number(1), "kind": .string("message.user"),
            "event_id": .string("user:fixture"),
            "payload": .object(["text": .string("Desktop root"), "thread_id": .string("desktop-thread")])
        ])
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page([event], cursor: 1), since: 0)
        let restored = try await BotHistoryCache(directory: directory).roomHistory(key)
        XCTAssertEqual(restored?.replayPage["events"].list?.first?["payload"]["thread_id"].text,
                       "desktop-thread", "Disk replay must preserve the Desktop thread reply target")
        XCTAssertEqual(restored?.replayPage["events"].list?.first?["event_id"].text, "user:fixture")
    }

    func testRoomOverlapsAreIdempotentOnDiskAndOnlyMessagesAreSearchable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BotHistoryCache(directory: directory), key = roomKey()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let first = RoomFixture.page([RoomFixture.event(1), RoomFixture.event(2, kind: "message.member")], cursor: 2)
        try await cache.appendRoom(key: key, room: room, page: first, since: 0)
        let file = directory.appendingPathComponent("history.json")
        let before = try Data(contentsOf: file)
        try await cache.appendRoom(key: key, room: room, page: first, since: 0)
        XCTAssertEqual(try Data(contentsOf: file), before, "Duplicate pages must not rewrite timestamps or rows")
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page([
            RoomFixture.event(2, kind: "message.member"), RoomFixture.event(3, kind: "turn.failed"),
            RoomFixture.event(4, kind: "future.event")], cursor: 4), since: 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "Invisible events move the cursor without rewriting the file")
        let live = try await cache.roomHistory(key)
        XCTAssertEqual(live?.cursor, 4)
        try await append(cache, room: "other-room", ["Newport"])
        let restored = BotHistoryCache(directory: directory)
        let snapshot = try await restored.roomHistory(key)
        XCTAssertEqual(snapshot?.messages.compactMap(\.seq), [1, 2])
        XCTAssertEqual(snapshot?.cursor, 4, "The next real write persists the newer cursor")
        let hits = try await restored.search("Message", scope: scope, roomIDs: [key.roomID])
        XCTAssertEqual(hits.map(\.message.seq), [2, 1])
        XCTAssertEqual(hits.first?.message.sender, "chief-of-staff")
        XCTAssertEqual(hits.first?.snapshot.profileName, "Comms")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(server.absoluteString))
    }

    func testReopenAfterKillRereadsFromTheOlderPersistedCursorWithoutDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BotHistoryCache(directory: directory), key = roomKey()
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page([RoomFixture.event(1)], cursor: 1), since: 0)
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page(
            [RoomFixture.event(2, kind: "tool.started")], cursor: 2), since: 1)
        // Killed here: the relaunched cache holds the older cursor and re-reads from it.
        let relaunched = BotHistoryCache(directory: directory)
        let saved = try await relaunched.roomHistory(key)
        XCTAssertEqual(saved?.cursor, 1)
        try await relaunched.appendRoom(key: key, room: room, page: RoomFixture.page([
            RoomFixture.event(2, kind: "tool.started"), RoomFixture.event(3, kind: "message.member")], cursor: 3), since: 1)
        let reopened = try await BotHistoryCache(directory: directory).roomHistory(key)
        XCTAssertEqual(reopened?.messages.compactMap(\.seq), [1, 3])
        XCTAssertEqual(reopened?.cursor, 3)
        XCTAssertEqual(reopened?.earlierBoundary, 0)
    }

    func testCursorOnlyMovesAreSavedPeriodicallySoActiveRoomsKeepTheirRetention() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = BotHistoryCache(directory: directory), key = roomKey()
        let start = Date()
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page([RoomFixture.event(1)], cursor: 1),
                                   since: 0, receivedAt: start)
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page(
            [RoomFixture.event(2, kind: "tool.started")], cursor: 2), since: 1, receivedAt: start + 1)
        let unsaved = try await BotHistoryCache(directory: directory).roomHistory(key, now: start + 1)
        XCTAssertEqual(unsaved?.cursor, 1)
        let later = start + BotHistoryCache.cursorOnlySaveInterval + 1
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page(
            [RoomFixture.event(3, kind: "tool.started")], cursor: 3), since: 2, receivedAt: later)
        let saved = try await BotHistoryCache(directory: directory).roomHistory(key, now: later)
        XCTAssertEqual(saved?.cursor, 3)
        XCTAssertEqual(saved?.savedAt, later, "The saved retention timestamp follows an active room")
        let file = directory.appendingPathComponent("history.json"), before = try Data(contentsOf: file)
        try await BotHistoryCache(directory: directory).appendRoom(key: key, room: room, page: RoomFixture.page(
            [RoomFixture.event(4, kind: "tool.started")], cursor: 4), since: 3, receivedAt: later + 1)
        XCTAssertEqual(try Data(contentsOf: file), before, "A relaunch does not rewrite on its first cursor-only poll")
    }

    func testPruneEvictsOldestRoomsToTheCountAndByteBudgets() async throws {
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        func savedRooms(_ directory: URL) async throws -> Set<String> {
            let hits = try await BotHistoryCache(directory: directory).search("Newport", scope: scope, roomIDs: nil)
            return Set(hits.compactMap(\.snapshot.roomID))
        }
        let counted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sized = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for directory in [counted, sized] { try? FileManager.default.removeItem(at: directory) } }
        let cache = BotHistoryCache(directory: counted), start = Date()
        for index in 0...100 {
            try await append(cache, room: "room\(index)", ["Newport"], receivedAt: start + Double(index))
        }
        let afterCount = try await savedRooms(counted)
        XCTAssertEqual(afterCount.count, 100)
        XCTAssertFalse(afterCount.contains("room0"), "The 101st room evicts the oldest")
        let large = BotHistoryCache(directory: sized)
        let rows = (0..<300).map { "Newport \($0) " + String(repeating: "x", count: 16_000) }
        for (index, roomID) in ["large1", "large2"].enumerated() {
            try await append(large, room: roomID, rows, receivedAt: start + Double(index))
        }
        let afterBytes = try await savedRooms(sized)
        XCTAssertEqual(afterBytes, ["large2"], "Two 4.8 MB rooms exceed the 8 MB budget")
        XCTAssertLessThanOrEqual(try Data(contentsOf: sized.appendingPathComponent("history.json")).count,
                                 BotHistoryCache.maximumBytes)
    }

    func testSameNamedRoomsStayScopedAndRemovalRejectsLatePages() async throws {
        let cache = BotHistoryCache(), key = roomKey()
        let otherConnection = roomKey(connectionID: UUID()), otherServer = roomKey(serverURL: otherServer)
        let page = RoomFixture.page([RoomFixture.event(1)], cursor: 1)
        for owner in [key, otherConnection, otherServer] {
            try await cache.appendRoom(key: owner, room: room, page: page, since: 0)
        }
        try await cache.removeRoom(key)
        try await cache.appendRoom(key: key, room: room, page: page, since: 0)
        let removed = try await cache.roomHistory(key)
        XCTAssertNil(removed)
        for owner in [otherConnection, otherServer] {
            let hits = try await cache.search("Message", scope: .init(server: owner.server, connectionID: owner.connectionID),
                                              roomIDs: [owner.roomID])
            XCTAssertEqual(hits.count, 1)
        }
        try await cache.remove(server: server, connectionID: otherConnection.connectionID)
        try await cache.appendRoom(key: otherConnection, room: room, page: page, since: 0)
        let removedConnection = try await cache.roomHistory(otherConnection)
        XCTAssertNil(removedConnection)
        let retainedServer = try await cache.roomHistory(otherServer)
        XCTAssertNotNil(retainedServer)
    }

    func testRoomClearAndServerRemovalFollowBotHistoryRules() async throws {
        let cache = BotHistoryCache(), key = roomKey(), now = Date()
        let page = RoomFixture.page([RoomFixture.event(1)], cursor: 1)
        try await cache.appendRoom(key: key, room: room, page: page, since: 0, receivedAt: now)
        try await cache.remove(server: server, now: now.addingTimeInterval(1))
        try await cache.appendRoom(key: key, room: room, page: page, since: 0, receivedAt: now)
        let cleared = try await cache.roomHistory(key)
        XCTAssertNil(cleared)
        try await cache.appendRoom(key: key, room: room, page: page, since: 0, receivedAt: now.addingTimeInterval(2))
        let fresh = try await cache.roomHistory(key)
        XCTAssertEqual(fresh?.messages.count, 1)
        let otherServerKey = roomKey(serverURL: otherServer), oldConnection = roomKey(connectionID: UUID())
        for owner in [otherServerKey, oldConnection] {
            try await cache.appendRoom(key: owner, room: room, page: page, since: 0, receivedAt: now.addingTimeInterval(2))
        }
        try await cache.removeServer(server, activeConnectionID: connection)
        for owner in [key, oldConnection] {
            try await cache.appendRoom(key: owner, room: room, page: page, since: 0, receivedAt: now.addingTimeInterval(3))
            let removed = try await cache.roomHistory(owner)
            XCTAssertNil(removed, "a removed server takes every connection's rooms and refuses late pages")
        }
        let retained = try await cache.roomHistory(otherServerKey)
        XCTAssertNotNil(retained)
    }

    func testRoomSizeLimitAndSharedSearchCapAndRetentionBoundary() async throws {
        let cache = BotHistoryCache(), key = roomKey(), now = Date()
        var large = RoomFixture.event(601).fields!
        large["payload"] = .object(["text": .string(String(repeating: "é", count: 8193))])
        try await cache.appendRoom(key: key, room: room, page: RoomFixture.page(
            (1...600).map { RoomFixture.event($0) } + [.object(large)], cursor: 601), since: 0, receivedAt: now)
        let saved = try await cache.roomHistory(key)
        XCTAssertEqual(saved?.messages.count, 500)
        XCTAssertEqual(saved?.earlierBoundary, 100)
        XCTAssertEqual(saved?.cursor, 601)
        XCTAssertFalse(saved?.messages.contains { $0.seq == 601 } ?? true)
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        try await append(cache, room: "other-room", ["Message elsewhere"], receivedAt: now)
        let hits = try await cache.search("Message", scope: scope, roomIDs: nil, now: now)
        XCTAssertEqual(hits.count, BotHistoryCache.maximumHits, "every room's hits share one limit")
        XCTAssertEqual(hits.first?.snapshot.roomID, "other-room", "the newest room's hits come first")
        let expired = try await cache.roomHistory(key, now: now.addingTimeInterval(BotHistoryCache.lifetime + 1))
        XCTAssertNil(expired)
    }

    func testDisbandedRoomsDisappearAfterCompleteListAndOtherConnectionsRemain() async throws {
        let cache = BotHistoryCache(), key = roomKey(), other = roomKey(connectionID: UUID())
        let page = RoomFixture.page([RoomFixture.event(1)], cursor: 1)
        for owner in [key, other] { try await cache.appendRoom(key: owner, room: room, page: page, since: 0) }
        try await cache.retainRooms([], scope: .init(server: server, connectionID: connection))
        try await cache.appendRoom(key: key, room: room, page: page, since: 0)
        let removed = try await cache.roomHistory(key), retained = try await cache.roomHistory(other)
        XCTAssertNil(removed); XCTAssertNotNil(retained)
    }

    func testSearchReturnsIndividualMessagesOnlyWithinCapturedIdentityAndRooms() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let texts = ["Café près de Newport 🏡", "Oui, Newport est libre", "Newport tool result"]
        let roles = ["message.user", "message.member", "tool.completed"]
        for owner in [roomKey(), roomKey(serverURL: otherServer), roomKey(connectionID: UUID())] {
            try await append(cache, room: owner.roomID, texts, roles: roles, key: owner)
        }
        try await append(cache, room: "another", ["Newport"])
        let hits = try await cache.search("NEWPORT", scope: scope, roomIDs: ["fixture-room"])
        XCTAssertEqual(hits.map(\.message.seq), [2, 1])
        XCTAssertEqual(hits.map(\.message.role), ["message.member", "message.user"])
        XCTAssertTrue(hits.allSatisfy { $0.snapshot.scope == scope && $0.snapshot.roomID == "fixture-room" })
        let unicode = try await cache.search("CAFÉ", scope: scope, roomIDs: ["fixture-room"])
        XCTAssertEqual(unicode.map(\.message.seq), [1])
        let everyRoom = try await cache.search("Newport", scope: scope, roomIDs: nil)
        XCTAssertEqual(Set(everyRoom.compactMap(\.snapshot.roomID)), ["fixture-room", "another"],
                       "a list not yet read must not hide the saved rooms")
        let noRooms = try await cache.search("Newport", scope: scope, roomIDs: [])
        XCTAssertTrue(noRooms.isEmpty, "an authoritative list excludes rooms no longer on it")
        let empty = try await cache.search("  ", scope: scope, roomIDs: nil)
        XCTAssertTrue(empty.isEmpty)
    }

    /// Bot Chat saved its own snapshots here until #1148. They are dropped, and written out
    /// without, the first time the cache loads.
    func testLegacyBotChatSnapshotsAreDroppedOnLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        let scope = try String(decoding: JSONEncoder().encode(BotHistoryCache.Scope(server: server, connectionID: connection)),
                               as: UTF8.self)
        let saved = Date().timeIntervalSinceReferenceDate
        try Data(#"""
        [{"id":"\#(UUID())","scope":\#(scope),"profileID":"inbox","root":"root","tip":"tip","savedAt":\#(saved),
          "messages":[{"id":"root/0","role":"assistant","text":"Bot Newport"}]},
         {"id":"\#(UUID())","scope":\#(scope),"profileID":"","profileName":"Comms","root":"","tip":"","savedAt":\#(saved),
          "roomID":"fixture-room","cursor":1,"earlierBoundary":0,
          "messages":[{"id":"1","role":"message.user","text":"Room Newport","seq":1}]}]
        """#.utf8).write(to: file)

        let cache = BotHistoryCache(directory: directory)
        let hits = try await cache.search("Newport", scope: .init(server: server, connectionID: connection), roomIDs: nil)
        XCTAssertEqual(hits.map(\.message.text), ["Room Newport"])
        let restored = try await cache.roomHistory(roomKey())
        XCTAssertEqual(restored?.profileName, "Comms")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Bot Newport"))
    }

    func testExpiredHistoryIsPrunedFromDiskOnLoadAndLaterSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        let cache = BotHistoryCache(directory: directory)
        try await append(cache, room: "old", ["Expired Newport"], receivedAt: now.addingTimeInterval(-BotHistoryCache.lifetime - 1))
        let restored = BotHistoryCache(directory: directory)
        let expired = try await restored.search("Newport", scope: scope, roomIDs: nil)
        XCTAssertTrue(expired.isEmpty)
        let file = directory.appendingPathComponent("history.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"))
        try await append(restored, room: "new", ["Fresh Newport"], receivedAt: now)
        let later = try await restored.search("Newport", scope: scope, roomIDs: nil,
                                             now: now.addingTimeInterval(BotHistoryCache.lifetime + 1))
        XCTAssertTrue(later.isEmpty)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Fresh Newport"))
    }

    func testExpiryWriteFailureKeepsFreshResultsAndRetriesCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        let rows = [
            BotHistoryCache.Snapshot(id: UUID(), scope: scope, profileName: nil,
                savedAt: now.addingTimeInterval(-BotHistoryCache.lifetime - 1),
                messages: [.init(id: "old", role: "message.user", text: "Expired Newport", seq: 1)], roomID: "old"),
            BotHistoryCache.Snapshot(id: UUID(), scope: scope, profileName: nil, savedAt: now,
                messages: [.init(id: "fresh", role: "message.user", text: "Fresh Newport", seq: 1)], roomID: "fresh")
        ]
        try JSONEncoder().encode(rows).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let cache = BotHistoryCache(directory: directory)
        let hits = try await cache.search("Newport", scope: scope, roomIDs: nil)
        XCTAssertEqual(hits.map(\.message.id), ["fresh"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"),
                      "The fixture must prevent the cleanup write")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retried = try await cache.search("Newport", scope: scope, roomIDs: nil)
        XCTAssertEqual(retried.map(\.message.id), ["fresh"])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"))
    }
}

final class BotRecentTranscriptTests: XCTestCase {
    private let server = URL(string: "https://recent.example")!
    private let connection = UUID()
    private func room(_ id: String = "room") -> BotRoomKey {
        BotRoomKey(server: server, connectionID: connection, roomID: id)
    }
    private func key(_ id: String = "room") -> BotRecentTranscripts.Key { .init(room(id)) }
    private func log(_ text: String = "cached") -> BotRoomLog {
        var log = BotRoomLog()
        var event = RoomFixture.event(1).fields!
        event["payload"] = .object(["text": .string(text)])
        log.apply(RoomFixture.page([.object(event)], cursor: 1))
        return log
    }

    func testNewestOwnerWinsAndEvictionBoundsRecentRooms() {
        let recent = BotRecentTranscripts(maximumEntries: 2)
        let old = recent.begin(key()), new = recent.begin(key())
        recent.save(log("new"), for: key(), owner: new)
        recent.save(log("stale"), for: key(), owner: old)
        XCTAssertEqual(recent.log(for: key())?.events.first?.payload["text"].text, "new")
        recent.save(log(), for: key("second"), owner: recent.begin(key("second")))
        _ = recent.log(for: key())
        recent.save(log(), for: key("third"), owner: recent.begin(key("third")))
        XCTAssertNil(recent.log(for: key("second")))
        XCTAssertNotNil(recent.log(for: key()))
        XCTAssertNotNil(recent.log(for: key("third")))
    }

    func testOversizedLogDoesNotKeepOldContentOrBreakTheBudget() {
        let recent = BotRecentTranscripts(maximumBytes: 2048)
        let owner = recent.begin(key())
        recent.save(log(), for: key(), owner: owner)
        recent.save(log(String(repeating: "large", count: 1000)), for: key(), owner: owner)
        XCTAssertNil(recent.log(for: key()))
    }

    func testClearAndRemovalInvalidateWarmValuesAndLateWriters() async throws {
        let cache = BotHistoryCache()
        let other = BotRecentTranscripts.Key(BotRoomKey(server: URL(string: "https://other.example")!,
                                                        connectionID: connection, roomID: "room"))
        let owner = cache.recent.begin(key())
        cache.recent.save(log(), for: key(), owner: owner)
        cache.recent.save(log("other"), for: other, owner: cache.recent.begin(other))
        try await cache.remove(server: server)
        cache.recent.save(log("late"), for: key(), owner: owner)
        XCTAssertNil(cache.recent.log(for: key()))
        XCTAssertNotNil(cache.recent.log(for: other))

        cache.recent.save(log(), for: key(), owner: cache.recent.begin(key()))
        try await cache.remove(server: server, connectionID: connection)
        XCTAssertNil(cache.recent.log(for: key()))
        XCTAssertNotNil(cache.recent.log(for: other))
    }

    func testRoomRemovalAndAnAuthoritativeListClearTheImmediateLog() async throws {
        let cache = BotHistoryCache()
        let owner = cache.recent.begin(key())
        cache.recent.save(log(), for: key(), owner: owner)
        try await cache.removeRoom(room())
        cache.recent.save(log(), for: key(), owner: owner)
        XCTAssertNil(cache.recent.log(for: key()))

        cache.recent.save(log(), for: key("kept"), owner: cache.recent.begin(key("kept")))
        cache.recent.save(log(), for: key("gone"), owner: cache.recent.begin(key("gone")))
        try await cache.retainRooms(["kept"], scope: .init(server: server, connectionID: connection))
        XCTAssertNotNil(cache.recent.log(for: key("kept")))
        XCTAssertNil(cache.recent.log(for: key("gone")))
    }
}
