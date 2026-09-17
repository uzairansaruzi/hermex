import XCTest
@testable import HermesMobile

final class BotHistoryCacheTests: XCTestCase {
    private let server = URL(string: "https://one.example")!
    private let otherServer = URL(string: "https://two.example")!
    private let connection = UUID()

    private func message(_ id: String, _ text: String, role: String = "assistant") -> ChatMessage {
        ChatMessage(role: role, content: text, timestamp: nil, messageId: id)
    }

    private func roomKey(connectionID: UUID? = nil, serverURL: URL? = nil) -> BotRoomKey {
        BotRoomKey(server: serverURL ?? server, connectionID: connectionID ?? connection, roomID: "fixture-room")
    }

    private var room: BotGroupRoom { BotGroupRoom(RoomFixture.room(latest: 3))! }

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
        let restored = BotHistoryCache(directory: directory)
        let snapshot = try await restored.roomHistory(key)
        XCTAssertEqual(snapshot?.messages.compactMap(\.seq), [1, 2])
        XCTAssertEqual(snapshot?.cursor, 4, "Invisible events still advance the persisted cursor")
        let hits = try await restored.search("Message", scope: scope, profileIDs: [], roomIDs: [key.roomID])
        XCTAssertEqual(hits.map(\.message.seq), [2, 1])
        XCTAssertEqual(hits.first?.message.sender, "chief-of-staff")
        XCTAssertEqual(hits.first?.snapshot.profileName, "Comms")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(server.absoluteString))
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
                                              profileIDs: [], roomIDs: [owner.roomID])
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
        try await cache.removeServer(server, activeConnectionID: connection)
        try await cache.appendRoom(key: key, room: room, page: page, since: 0, receivedAt: now.addingTimeInterval(3))
        let removed = try await cache.roomHistory(key)
        XCTAssertNil(removed)
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
        try await cache.replace(scope: scope, profileID: "bot", root: "r", tip: "t", messages: [message("bot", "Message")])
        let hits = try await cache.search("Message", scope: scope, profileIDs: nil, roomIDs: nil)
        XCTAssertEqual(hits.count, 100, "Bot and room hits share one limit")
        XCTAssertTrue(hits.contains { $0.snapshot.roomID == nil })
        XCTAssertTrue(hits.contains { $0.snapshot.roomID == key.roomID })
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

    func testSearchReturnsIndividualIncomingAndOutgoingMessagesOnlyWithinCapturedIdentity() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let otherScope = BotHistoryCache.Scope(server: otherServer, connectionID: connection)
        let replacement = BotHistoryCache.Scope(server: server, connectionID: UUID())
        for owner in [scope, otherScope, replacement] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [
                message("one", "Newport this Friday", role: "user"),
                message("two", "Yes, Newport is available"),
                message("tool", "Newport tool result", role: "tool"),
                message("unknown", "Newport", role: "future-role")
            ])
        }
        try await cache.replace(scope: scope, profileID: "another", root: "root", tip: "tip", messages: [message("one", "Newport")])
        let hits = try await cache.search("NEWPORT", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(hits.map(\.message.id), ["two", "one"])
        XCTAssertEqual(hits.map(\.message.role), ["assistant", "user"])
        XCTAssertTrue(hits.allSatisfy { $0.snapshot.scope == scope && $0.snapshot.profileID == "inbox" })
        let empty = try await cache.search("  ", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(empty.isEmpty)
    }

    func testReplacementDropsUndoneHistoryAndRetainsFrozenResultForReadOnlyNavigation() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("root/0", "Newport")])
        let hits = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let selected = try XCTUnwrap(hits.first)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "compressed", messages: [message("root/0", "Manhattan")])
        let afterCompression = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(afterCompression.isEmpty)
        XCTAssertEqual(selected.snapshot.tip, "tip")
        XCTAssertEqual(selected.snapshot.messages.first?.text, "Newport")
        try await cache.replace(scope: scope, profileID: "inbox", root: "replacement", tip: "replacement", messages: [])
        let afterReset = try await cache.search("Manhattan", scope: scope, profileIDs: ["inbox"])
        XCTAssertTrue(afterReset.isEmpty)
    }

    func testCacheSurvivesRelaunchAndHasNoServerAddressInItsFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let cache = BotHistoryCache(directory: directory)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")])
        let restored = BotHistoryCache(directory: directory)
        let hits = try await restored.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(hits.map(\.message.id), ["one"])
        let offlineHits = try await restored.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertEqual(offlineHits.count, 1, "A temporarily unavailable roster must not hide the on-device cache")
        let deletedBotHits = try await restored.search("Newport", scope: scope, profileIDs: [])
        XCTAssertTrue(deletedBotHits.isEmpty, "An authoritative live roster excludes removed bots")
        let disk = try String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains(server.absoluteString))
        XCTAssertFalse(disk.contains("runtime"))
    }

    func testExpiredHistoryIsPrunedFromDiskOnLoadAndLaterSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        let cache = BotHistoryCache(directory: directory)
        try await cache.replace(scope: scope, profileID: "old", root: "root", tip: "tip",
                                messages: [message("old", "Expired Newport")],
                                receivedAt: now.addingTimeInterval(-BotHistoryCache.lifetime - 1))
        let restored = BotHistoryCache(directory: directory)
        let expired = try await restored.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertTrue(expired.isEmpty)
        let file = directory.appendingPathComponent("history.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"))
        try await restored.replace(scope: scope, profileID: "new", root: "root", tip: "tip",
                                   messages: [message("new", "Fresh Newport")], receivedAt: now)
        let later = try await restored.search("Newport", scope: scope, profileIDs: nil,
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
            BotHistoryCache.Snapshot(id: UUID(), scope: scope, profileID: "old", profileName: nil,
                root: "root", tip: "tip", savedAt: now.addingTimeInterval(-BotHistoryCache.lifetime - 1),
                messages: [.init(id: "old", role: "assistant", text: "Expired Newport")]),
            BotHistoryCache.Snapshot(id: UUID(), scope: scope, profileID: "fresh", profileName: nil,
                root: "root", tip: "tip", savedAt: now,
                messages: [.init(id: "fresh", role: "assistant", text: "Fresh Newport")])
        ]
        try JSONEncoder().encode(rows).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let cache = BotHistoryCache(directory: directory)
        let hits = try await cache.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertEqual(hits.map(\.message.id), ["fresh"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"),
                      "The fixture must prevent the cleanup write")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retried = try await cache.search("Newport", scope: scope, profileIDs: nil)
        XCTAssertEqual(retried.map(\.message.id), ["fresh"])
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("Expired Newport"))
    }

    func testClearIsServerScopedAndRejectsEarlierQueuedWrites() async throws {
        let cache = BotHistoryCache()
        let now = Date()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let other = BotHistoryCache.Scope(server: otherServer, connectionID: connection)
        for owner in [scope, other] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")], receivedAt: now)
        }
        try await cache.remove(server: server, now: now.addingTimeInterval(1))
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("old", "Newport")], receivedAt: now)
        let cleared = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let retained = try await cache.search("Newport", scope: other, profileIDs: ["inbox"])
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(retained.count, 1)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: [message("new", "Newport")], receivedAt: now.addingTimeInterval(2))
        let fresh = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(fresh.map(\.message.id), ["new"])
    }

    func testRemovingConnectionRevokesFutureWritesAndPreservesOtherConnection() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let other = BotHistoryCache.Scope(server: server, connectionID: UUID())
        try await cache.remove(server: server, connectionID: connection)
        for owner in [scope, other] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "tip", messages: [message("one", "Newport")])
        }
        let removed = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let retained = try await cache.search("Newport", scope: other, profileIDs: ["inbox"])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.count, 1)
    }

    func testLateSnapshotCannotOverwriteANewerSnapshotAndServerRemovalPurgesAllConnections() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let oldConnection = BotHistoryCache.Scope(server: server, connectionID: UUID())
        let now = Date()
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "new", messages: [message("new", "Newport")], receivedAt: now)
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "old", messages: [message("old", "Newport")], receivedAt: now.addingTimeInterval(-1))
        let current = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        XCTAssertEqual(current.map(\.message.id), ["new"])
        try await cache.replace(scope: oldConnection, profileID: "inbox", root: "root", tip: "old", messages: [message("old", "Newport")])
        try await cache.removeServer(server, activeConnectionID: connection)
        for owner in [scope, oldConnection] {
            try await cache.replace(scope: owner, profileID: "inbox", root: "root", tip: "old", messages: [message("late", "Newport")])
            let remaining = try await cache.search("Newport", scope: owner, profileIDs: ["inbox"])
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testCacheBoundsResultsAndExpiryAndHandlesUnicode() async throws {
        let cache = BotHistoryCache()
        let scope = BotHistoryCache.Scope(server: server, connectionID: connection)
        let now = Date()
        var rows = (0..<600).map { message(String($0), "Café près de Newport 🏡") }
        rows.append(message("large", String(repeating: "Newport", count: 5000)))
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: rows, receivedAt: now)
        let hits = try await cache.search("CAFÉ", scope: scope, profileIDs: ["inbox"], now: now)
        XCTAssertEqual(hits.count, BotHistoryCache.maximumHits)
        XCTAssertLessThanOrEqual(hits[0].snapshot.messages.count, BotHistoryCache.maximumMessages)
        XCTAssertFalse(hits.contains { $0.message.id == "large" })
        let expired = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"], now: now.addingTimeInterval(BotHistoryCache.lifetime + 1))
        XCTAssertTrue(expired.isEmpty)
    }
}
