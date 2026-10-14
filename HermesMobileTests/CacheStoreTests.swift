import SwiftData
import XCTest
@testable import HermesMobile

@MainActor
final class CacheStoreTests: XCTestCase {
    func testCacheSessionsWritesVisibleSessionsAndRemovesStaleEntries() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let firstResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Planning", "last_message_at": 1770000000, "archived": false},
            {"session_id": "stale", "title": "Old thread", "last_message_at": 1760000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true},
            {"title": "Missing ID", "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(firstResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "stale"])
        XCTAssertEqual(cachedSessions.first(where: { $0.sessionID == "keep" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "keep", "title": "Updated planning", "last_message_at": 1770000100, "archived": false},
            {"session_id": "new", "title": "New thread", "last_message_at": 1770000200, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(secondResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["keep", "new"])

        let updatedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "keep" })
        XCTAssertEqual(updatedSession.title, "Updated planning")
        XCTAssertEqual(updatedSession.lastMessageAt, 1_770_000_100)
        XCTAssertEqual(updatedSession.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedSession.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    func testCachedSessionsPreserveSubagentClassificationAndReadOnlySafety() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "subagent-child",
              "title": "Delegated research",
              "source_tag": "subagent",
              "raw_source": "subagent",
              "session_source": "other",
              "source_label": "Subagent",
              "parent_session_id": "parent-1",
              "relationship_type": "child_session",
              "read_only": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try XCTUnwrap(
            CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now).first
        )
        XCTAssertEqual(cached.rawSource, "subagent")
        XCTAssertEqual(cached.parentSessionId, "parent-1")
        XCTAssertEqual(cached.relationshipType, "child_session")
        XCTAssertTrue(cached.isDelegatedSubagentSession)
        XCTAssertTrue(cached.isSessionReadOnly)
        XCTAssertFalse(AutomatedSessionVisibility(showsCron: true, showsCli: true).shows(cached))
        XCTAssertTrue(AutomatedSessionVisibility.showAll.shows(cached))
    }

    func testCachedSessionsPreserveClaudeCodeClassificationAndVisibility() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {
              "session_id": "claude-code",
              "title": "Imported transcript",
              "source_tag": "claude_code",
              "raw_source": "claude_code",
              "is_cli_session": true,
              "read_only": true,
              "archived": false
            },
            {
              "session_id": "ordinary-cli",
              "title": "Terminal chat",
              "source_tag": "cli",
              "is_cli_session": true,
              "archived": false
            }
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cached = try CacheStore.cachedSessions(
            serverURL: serverURL,
            in: context,
            now: cachedAt.addingTimeInterval(60)
        )
        let hidden = AutomatedSessionVisibility(
            showsCron: true,
            showsCli: true,
            showsClaudeCode: false
        )

        XCTAssertTrue(try XCTUnwrap(cached.first { $0.sessionId == "claude-code" }).isClaudeCodeSession)
        XCTAssertEqual(cached.filter(hidden.shows).compactMap(\.sessionId), ["ordinary-cli"])
    }

    func testCachedSessionsPreserveExternalSourceLabelAndImportClassification() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let session = SessionSummary(
            sessionId: "telegram",
            title: "Support chat",
            archived: false,
            isCliSession: true,
            rawSource: "telegram",
            sessionSource: "messaging",
            sourceLabel: "Telegram"
        )

        try CacheStore.cacheSession(session, serverURL: serverURL, in: context, cachedAt: cachedAt)

        let cached = try XCTUnwrap(
            CacheStore.cachedSessions(
                serverURL: serverURL,
                in: context,
                now: cachedAt.addingTimeInterval(60)
            ).first
        )
        XCTAssertTrue(cached.requiresExternalImport)
        XCTAssertEqual(cached.sourceDisplayLabel, "Telegram")
    }

    func testCacheMessagesWritesLoadedWindowAndRemovesStaleMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)
        let firstMessages = [
            ChatMessage(
                role: "user",
                content: "Hello",
                timestamp: 1_770_000_000,
                messageId: "m1"
            ),
            ChatMessage(
                role: "assistant",
                content: "Hi",
                timestamp: 1_770_000_001,
                messageId: "m2",
                reasoning: "Greet the user."
            )
        ]

        try CacheStore.cacheMessages(
            firstMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: firstCachedAt
        )

        var cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m1", "m2"])
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m2" })?.reasoning, "Greet the user.")
        XCTAssertEqual(cachedMessages.first(where: { $0.messageId == "m1" })?.expiresAt, firstCachedAt.addingTimeInterval(CachePolicy.ttl))

        let secondMessages = [
            ChatMessage(
                role: "assistant",
                content: "Updated hi",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Updated reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "Next",
                timestamp: 1_770_000_003,
                messageId: "m3"
            )
        ]

        try CacheStore.cacheMessages(
            secondMessages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: secondCachedAt
        )

        cachedMessages = try fetchCachedMessages(in: context)
        XCTAssertEqual(cachedMessages.compactMap(\.messageId).sorted(), ["m2", "m3"])

        let updatedMessage = try XCTUnwrap(cachedMessages.first { $0.messageId == "m2" })
        XCTAssertEqual(updatedMessage.content, "Updated hi")
        XCTAssertEqual(updatedMessage.sortIndex, 0)
        XCTAssertEqual(updatedMessage.cachedAt, secondCachedAt)
        XCTAssertEqual(updatedMessage.expiresAt, secondCachedAt.addingTimeInterval(CachePolicy.ttl))
    }

    func testCacheSessionUpsertsOneSessionWithoutRemovingExistingSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let secondCachedAt = Date(timeIntervalSince1970: 1_770_000_100)

        let existingResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "existing", "title": "Existing", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)
        try CacheStore.cacheSessions(
            try XCTUnwrap(existingResponse.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: firstCachedAt
        )

        let forkResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fork", "title": "Existing (fork)", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)
        let fork = try XCTUnwrap(forkResponse.sessions?.first)

        try CacheStore.cacheSession(
            fork,
            serverURL: serverURL,
            in: context,
            cachedAt: secondCachedAt
        )

        let cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.sessionID).sorted(), ["existing", "fork"])

        let forkedSession = try XCTUnwrap(cachedSessions.first { $0.sessionID == "fork" })
        XCTAssertEqual(forkedSession.title, "Existing (fork)")
        XCTAssertEqual(forkedSession.cachedAt, secondCachedAt)
    }

    func testCachedSessionsReturnsOnlyUnexpiredVisibleSessionsForServer() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let otherServerURL = URL(string: "https://other.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh", "title": "Fresh thread", "last_message_at": 1770000000, "archived": false},
            {"session_id": "archived", "title": "Archived thread", "archived": true}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let otherResponse = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "other", "title": "Other server", "last_message_at": 1770000100, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(otherResponse.sessions),
            serverURL: otherServerURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: now)

        XCTAssertEqual(cachedSessions.map(\.sessionId), ["fresh"])
        XCTAssertEqual(cachedSessions.first?.title, "Fresh thread")
    }

    func testCachedSessionsIgnoresExpiredSessions() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired", "title": "Expired thread", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(response.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedSessions = try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: expiredNow)

        XCTAssertTrue(cachedSessions.isEmpty)
    }

    func testCachedMessagesReturnsUnexpiredMessagesInStoredOrderForSession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Second",
                timestamp: 1_770_000_002,
                messageId: "m2",
                reasoning: "Cached reasoning."
            ),
            ChatMessage(
                role: "user",
                content: "First",
                timestamp: 1_770_000_001,
                messageId: "m1"
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Other session",
                    timestamp: 1_770_000_003,
                    messageId: "other"
                )
            ],
            serverURL: serverURL,
            sessionID: "other-session",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.map(\.messageId), ["m2", "m1"])
        XCTAssertEqual(cachedMessages.first?.reasoning, "Cached reasoning.")
    }

    func testAssistantTurnTpsDecodesAndRoundTripsThroughCache() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"assistant","content":"Done","messageId":"m1","_turnTps":48.75}"#.utf8)
        )

        XCTAssertEqual(message.turnTps, 48.75)

        try CacheStore.cacheMessages(
            [message],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        XCTAssertEqual(try fetchCachedMessages(in: context).first?.turnTps, 48.75)
        XCTAssertEqual(
            try CacheStore.cachedMessages(
                serverURL: serverURL,
                sessionID: "abc123",
                in: context,
                now: cachedAt.addingTimeInterval(60)
            ).first?.turnTps,
            48.75
        )
    }

    func testCachedMessagesIgnoresExpiredMessages() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = cachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired",
                    timestamp: 1_770_000_001,
                    messageId: "expired"
                )
            ],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: expiredNow
        )

        XCTAssertTrue(cachedMessages.isEmpty)
    }

    func testCacheMaintenanceDeletesExpiredSessionsAndMessagesOnWrite() throws {
        let context = try makeContext()
        let oldServerURL = URL(string: "https://old.example.test")!
        let triggerServerURL = URL(string: "https://trigger.example.test")!
        let oldCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let currentCachedAt = oldCachedAt.addingTimeInterval(CachePolicy.ttl + 1)

        let oldSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "expired-session", "title": "Expired", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(oldSessions.sessions),
            serverURL: oldServerURL,
            in: context,
            cachedAt: oldCachedAt
        )

        try CacheStore.cacheMessages(
            [
                ChatMessage(
                    role: "user",
                    content: "Expired message",
                    timestamp: 1_770_000_000,
                    messageId: "expired-message"
                )
            ],
            serverURL: oldServerURL,
            sessionID: "expired-session",
            in: context,
            cachedAt: oldCachedAt
        )

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "fresh-session", "title": "Fresh", "last_message_at": 1770604801, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: triggerServerURL,
            in: context,
            cachedAt: currentCachedAt
        )

        XCTAssertEqual(try fetchCachedSessions(in: context).map(\.sessionID), ["fresh-session"])
        XCTAssertTrue(try fetchCachedMessages(in: context).isEmpty)

        // The expiry delete must reach the store, not just this context.
        let storeContext = ModelContext(context.container)
        XCTAssertEqual(try fetchCachedSessions(in: storeContext).map(\.sessionID), ["fresh-session"])
        XCTAssertTrue(try fetchCachedMessages(in: storeContext).isEmpty)
    }

    func testCacheMaintenanceEvictsOldestMessagesAboveLimit() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)

        for index in 0...CachePolicy.maxMessages {
            context.insert(
                CachedMessage(
                    serverURLString: serverURL.absoluteString,
                    sessionID: "abc123",
                    message: ChatMessage(
                        role: "user",
                        content: "Message \(index)",
                        timestamp: Double(index),
                        messageId: "message-\(index)"
                    ),
                    sortIndex: index,
                    cachedAt: cachedAt
                )
            )
        }

        let triggerSessions = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "abc123", "title": "Trigger", "last_message_at": 1770000000, "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(
            try XCTUnwrap(triggerSessions.sessions),
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try fetchCachedMessages(in: context)

        XCTAssertEqual(cachedMessages.count, CachePolicy.maxMessages)
        XCTAssertNil(cachedMessages.first { $0.messageId == "message-0" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-1" })
        XCTAssertNotNil(cachedMessages.first { $0.messageId == "message-\(CachePolicy.maxMessages)" })
    }

    func testCacheMessagesSkipsUnchangedRowsUntilTheRefreshInterval() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        // Built fresh per call so the tool-call dictionaries are new instances,
        // like a reloaded transcript; equal values must still compare equal.
        func window(toolPath: String = "notes.txt", reply: String = "Reading") -> [ChatMessage] {
            [
                ChatMessage(role: "user", content: "Read my notes", timestamp: 1_770_000_000, messageId: "m1"),
                ChatMessage(
                    role: "assistant",
                    content: reply,
                    timestamp: 1_770_000_001,
                    messageId: "m2",
                    toolCalls: [.object([
                        "id": .string("call-1"),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string("{\"path\": \"\(toolPath)\"}")
                        ])
                    ])]
                )
            ]
        }
        func cachedAtByID() throws -> [String: Date] {
            try fetchCachedMessages(in: context).reduce(into: [:]) { $0[$1.messageId ?? ""] = $1.cachedAt }
        }

        try CacheStore.cacheMessages(window(), serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: firstCachedAt)

        // Identical window inside the refresh interval: no row is rewritten.
        let soon = firstCachedAt.addingTimeInterval(10 * 60)
        try CacheStore.cacheMessages(window(), serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: soon)
        XCTAssertEqual(try cachedAtByID(), ["m1": firstCachedAt, "m2": firstCachedAt])

        // A changed tool call with the same call count is still a change.
        let edited = firstCachedAt.addingTimeInterval(20 * 60)
        try CacheStore.cacheMessages(
            window(toolPath: "todo.txt"),
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: edited
        )
        XCTAssertEqual(try cachedAtByID(), ["m1": firstCachedAt, "m2": edited])
        let restored = try CacheStore.cachedMessages(serverURL: serverURL, sessionID: "abc123", in: context, now: edited)
        XCTAssertEqual(restored.last?.toolCalls, window(toolPath: "todo.txt").last?.toolCalls)

        // Past the refresh interval, unchanged rows get a new cachedAt and expiry.
        let later = firstCachedAt.addingTimeInterval(CachePolicy.rowRefreshInterval)
        try CacheStore.cacheMessages(
            window(toolPath: "todo.txt"),
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: later
        )
        XCTAssertEqual(try cachedAtByID(), ["m1": later, "m2": edited])
        XCTAssertEqual(
            try fetchCachedMessages(in: context).first { $0.messageId == "m1" }?.expiresAt,
            later.addingTimeInterval(CachePolicy.ttl)
        )
    }

    func testCacheMessagesKeepsExpiredRowsTheWriteRefreshes() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let firstCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let expiredNow = firstCachedAt.addingTimeInterval(CachePolicy.ttl + 1)
        let message = ChatMessage(role: "user", content: "Still here", timestamp: 1_770_000_000, messageId: "m1")

        try CacheStore.cacheMessages([message], serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: firstCachedAt)
        try CacheStore.cacheMessages([message], serverURL: serverURL, sessionID: "abc123", in: context, cachedAt: expiredNow)

        let cached = try XCTUnwrap(fetchCachedMessages(in: context).first)
        XCTAssertEqual(cached.expiresAt, expiredNow.addingTimeInterval(CachePolicy.ttl))
        XCTAssertEqual(
            try CacheStore.cachedMessages(serverURL: serverURL, sessionID: "abc123", in: context, now: expiredNow)
                .map(\.content),
            ["Still here"]
        )
    }

    func testCacheMaintenanceEvictsOnlyTheLeastRecentlyCachedOverflowAcrossServers() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let olderCachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let newerCachedAt = olderCachedAt.addingTimeInterval(60)
        let overflow = 3

        // Server B's rows were cached first, so they go first even though their
        // timestamps and sort indexes are the highest in the table.
        for index in 0..<overflow {
            context.insert(CachedMessage(
                serverURLString: serverB.absoluteString,
                sessionID: "b-session",
                message: ChatMessage(role: "user", content: "B \(index)", timestamp: 9_000_000_000, messageId: "b-\(index)"),
                sortIndex: 10_000 + index,
                cachedAt: olderCachedAt
            ))
        }
        for index in 0..<CachePolicy.maxMessages {
            context.insert(CachedMessage(
                serverURLString: serverA.absoluteString,
                sessionID: "a-session",
                message: ChatMessage(role: "user", content: "A \(index)", timestamp: Double(index), messageId: "a-\(index)"),
                sortIndex: index,
                cachedAt: newerCachedAt
            ))
        }
        try context.save()

        try CacheStore.cacheSession(
            SessionSummary(sessionId: "a-session", title: "Trigger", archived: false),
            serverURL: serverA,
            in: context,
            cachedAt: newerCachedAt
        )

        let remaining = try fetchCachedMessages(in: context)
        XCTAssertEqual(remaining.count, CachePolicy.maxMessages)
        XCTAssertFalse(remaining.contains { $0.serverURLString == serverB.absoluteString })
    }

    func testCacheSessionsKeepsOneRowForADuplicatedSession() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let response = try decodeSessions("""
        {
          "sessions": [
            {"session_id": "dup", "title": "First copy", "archived": false},
            {"session_id": "dup", "title": "Second copy", "archived": false}
          ]
        }
        """)

        try CacheStore.cacheSessions(try XCTUnwrap(response.sessions), serverURL: serverURL, in: context, cachedAt: cachedAt)

        let cachedSessions = try fetchCachedSessions(in: context)
        XCTAssertEqual(cachedSessions.map(\.title), ["Second copy"])
    }

    func testCacheMessagesRoundTripsAttachments() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let messages = [
            ChatMessage(
                role: "user",
                content: "Here is a photo",
                timestamp: 1_770_000_000,
                messageId: "m1",
                attachments: [
                    MessageAttachment(
                        name: "photo.png",
                        path: "/uploads/photo.png",
                        mime: "image/png",
                        size: 12345,
                        isImage: true
                    )
                ]
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let attachment = try XCTUnwrap(cachedMessages.first?.attachments?.first)
        XCTAssertEqual(attachment.name, "photo.png")
        XCTAssertEqual(attachment.path, "/uploads/photo.png")
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.size, 12345)
        XCTAssertEqual(attachment.isImage, true)
    }

    func testCacheMessagesRoundTripsToolCallAndStructuredContentFields() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        let toolCalls: [JSONValue] = [
            .object([
                "id": .string("call-1"),
                "function": .object([
                    "name": .string("read_file"),
                    "arguments": .string("{\"path\": \"notes.txt\"}")
                ])
            ])
        ]
        let contentParts: [JSONValue] = [
            .object(["type": .string("text"), "text": .string("Reading the file")]),
            .object(["type": .string("tool_use"), "id": .string("call-1")])
        ]

        let messages = [
            ChatMessage(
                role: "assistant",
                content: "Reading the file",
                timestamp: 1_770_000_000,
                messageId: "m1",
                toolUseId: "call-1",
                toolCalls: toolCalls,
                contentParts: contentParts
            )
        ]

        try CacheStore.cacheMessages(
            messages,
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: cachedAt
        )

        let cachedMessages = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: now
        )

        XCTAssertEqual(cachedMessages.count, 1)
        let restored = try XCTUnwrap(cachedMessages.first)
        XCTAssertEqual(restored.toolUseId, "call-1")
        XCTAssertEqual(restored.toolCalls, toolCalls)
        XCTAssertEqual(restored.contentParts, contentParts)
    }

    // MARK: - Per-server isolation (#18)

    func testCachedMessagesAreScopedToTheirServerForTheSameSessionID() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertEqual(aMessages.map(\.content), ["From A"])
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testCacheSessionsForOneServerDoesNotDeleteAnotherServersStaleSessions() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a1", "title": "A one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "b1", "title": "B one", "last_message_at": 1770000000, "archived": false}]}
            """).sessions),
            serverURL: serverB,
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A with a different set so its stale-removal pass runs.
        // It must drop A's "a1" without touching server B's "b1".
        try CacheStore.cacheSessions(
            try XCTUnwrap(decodeSessions("""
            {"sessions": [{"session_id": "a2", "title": "A two", "last_message_at": 1770000100, "archived": false}]}
            """).sessions),
            serverURL: serverA,
            in: context,
            cachedAt: cachedAt
        )

        let aSessions = try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now)
        let bSessions = try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now)

        XCTAssertEqual(aSessions.map(\.sessionId), ["a2"])
        XCTAssertEqual(bSessions.map(\.sessionId), ["b1"])
    }

    func testCacheMessagesForOneServerDoesNotDeleteAnotherServersMessages() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From A", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )
        try CacheStore.cacheMessages(
            [ChatMessage(role: "user", content: "From B", timestamp: 1_770_000_000, messageId: "m1")],
            serverURL: serverB,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        // Re-cache server A's session with no messages so its stale-removal pass
        // wipes A's window; server B's identically-keyed session must survive.
        try CacheStore.cacheMessages(
            [],
            serverURL: serverA,
            sessionID: "shared",
            in: context,
            cachedAt: cachedAt
        )

        let aMessages = try CacheStore.cachedMessages(serverURL: serverA, sessionID: "shared", in: context, now: now)
        let bMessages = try CacheStore.cachedMessages(serverURL: serverB, sessionID: "shared", in: context, now: now)

        XCTAssertTrue(aMessages.isEmpty)
        XCTAssertEqual(bMessages.map(\.content), ["From B"])
    }

    func testClearCacheRemovesOnlyTheGivenServersData() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let now = cachedAt.addingTimeInterval(60)

        for (server, title) in [(serverA, "A one"), (serverB, "B one")] {
            try CacheStore.cacheSessions(
                try XCTUnwrap(decodeSessions("""
                {"sessions": [{"session_id": "s1", "title": "\(title)", "last_message_at": 1770000000, "archived": false}]}
                """).sessions),
                serverURL: server,
                in: context,
                cachedAt: cachedAt
            )
            try CacheStore.cacheMessages(
                [ChatMessage(role: "user", content: title, timestamp: 1_770_000_000, messageId: "m1")],
                serverURL: server,
                sessionID: "s1",
                in: context,
                cachedAt: cachedAt
            )
        }

        try CacheStore.clearCache(for: serverA, in: context)

        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverA, in: context, now: now).isEmpty)
        XCTAssertTrue(try CacheStore.cachedMessages(serverURL: serverA, sessionID: "s1", in: context, now: now).isEmpty)
        XCTAssertEqual(
            try CacheStore.cachedSessions(serverURL: serverB, in: context, now: now).map(\.sessionId),
            ["s1"]
        )
        XCTAssertEqual(
            try CacheStore.cachedMessages(serverURL: serverB, sessionID: "s1", in: context, now: now).map(\.content),
            ["B one"]
        )
    }

    func testCachedSessionByIDFindsAnExpiredRowForALabel() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let afterExpiry = cachedAt.addingTimeInterval(CachePolicy.ttl + 60)
        try CacheStore.cacheSessions(
            [SessionSummary(sessionId: "parent", title: "Design review")],
            serverURL: serverURL,
            in: context,
            cachedAt: cachedAt
        )

        XCTAssertTrue(try CacheStore.cachedSessions(serverURL: serverURL, in: context, now: afterExpiry).isEmpty)
        let parent = try CacheStore.cachedSession(id: "parent", serverURL: serverURL, in: context)
        XCTAssertEqual(parent?.sessionId, "parent")
        XCTAssertEqual(parent?.title, "Design review")
    }

    func testCachedSessionByIDMissesAnArchivedSessionBecauseItIsNeverCached() throws {
        let context = try makeContext()
        let serverURL = URL(string: "https://example.test")!
        try CacheStore.cacheSession(
            SessionSummary(sessionId: "parent", title: "Design review"),
            serverURL: serverURL,
            in: context
        )
        try CacheStore.cacheSession(
            SessionSummary(sessionId: "parent", title: "Design review", archived: true),
            serverURL: serverURL,
            in: context
        )

        XCTAssertNil(try CacheStore.cachedSession(id: "parent", serverURL: serverURL, in: context))
    }

    func testCachedSessionByIDNeverCrossesServers() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.example.test")!
        let serverB = URL(string: "https://b.example.test")!
        try CacheStore.cacheSessions(
            [SessionSummary(sessionId: "parent", title: "On server A")],
            serverURL: serverA,
            in: context
        )

        XCTAssertNil(try CacheStore.cachedSession(id: "parent", serverURL: serverB, in: context))
        XCTAssertEqual(try CacheStore.cachedSession(id: "parent", serverURL: serverA, in: context)?.title, "On server A")
    }

    // MARK: Hermes (#1054)

    /// A Hermes session is keyed by its server, Profile and lineage root and keeps the tip it
    /// opens by; its messages share that scope, by row id. It reads back as the list showed it.
    func testHermesKeysCarryTheServerProfileAndLineageRoot() throws {
        let context = try makeContext()
        let row = HermesSessionRow(id: "tip", title: "Chain", preview: "First prompt", lastActive: 1_770_000_000, unread: true,
                                   lineageRootID: "root").summary(in: "default")
        try CacheStore.cacheHermesSessions([row], profile: "default", reachedEnd: false, serverURL: hermesServer, in: context)
        try CacheStore.cacheHermesMessages([hermesMessage(7)], newestCoverage: .from(rowIDs: [7]), serverURL: hermesServer,
                                           profile: "default", lineageRoot: "root", in: context)

        let session = try XCTUnwrap(fetchCachedSessions(in: context).first)
        XCTAssertEqual(session.cacheKey, "https://hermes.example|hermes|default|root")
        XCTAssertEqual(session.sessionID, "tip")
        let message = try XCTUnwrap(fetchCachedMessages(in: context).first)
        XCTAssertEqual(message.cacheKey, "https://hermes.example|hermes|default|root|row|7")
        XCTAssertEqual(message.sessionID, "hermes|default|root")
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "default", in: context), [row])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "root",
                                                           in: context, limit: 10), [hermesMessage(7)])
        XCTAssertEqual(try CacheStore.hermesLineageRoot(forKey: "tip", profile: "default", serverURL: hermesServer, in: context), "root")

        // The same session id in another Profile's store is another session.
        let other = HermesSessionRow(id: "tip", title: "Elsewhere", lineageRootID: "root").summary(in: "research")
        try CacheStore.cacheHermesSessions([other], profile: "research", reachedEnd: true, serverURL: hermesServer, in: context)
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "default", in: context).map(\.title), ["Chain"])
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "research", in: context).map(\.title), ["Elsewhere"])
    }

    /// Each page is upserted and none sweeps, so reading page 1 alone keeps the rows later pages
    /// brought. A walk that reached the list's end drops a cached row it lacks. Archived rows
    /// are never cached.
    func testHermesPagesUpsertAndOnlyAWalkToTheEndRemovesARow() throws {
        let context = try makeContext()
        func cache(_ rows: [HermesSessionRow], reachedEnd: Bool) throws {
            try CacheStore.cacheHermesSessions(rows.map { $0.summary(in: "default") }, profile: "default",
                                               reachedEnd: reachedEnd, serverURL: hermesServer, in: context)
        }
        func cached() throws -> [String?] {
            try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "default", in: context).map(\.title)
        }
        let a = HermesSessionRow(id: "a", title: "A", lastActive: 30)
        let b = HermesSessionRow(id: "b", title: "B", lastActive: 20)
        let c = HermesSessionRow(id: "c", title: "C", lastActive: 10)

        try cache([a, b], reachedEnd: false)
        try cache([a, b, c, HermesSessionRow(id: "gone", title: "Archived", archived: true)], reachedEnd: true)
        XCTAssertEqual(try cached(), ["A", "B", "C"])

        try cache([HermesSessionRow(id: "a", title: "A renamed", lastActive: 40), b], reachedEnd: false)
        XCTAssertEqual(try cached(), ["A renamed", "B", "C"], "page 1 alone keeps page 2's row")

        try cache([HermesSessionRow(id: "a", title: "A renamed", lastActive: 40), c], reachedEnd: true)
        XCTAssertEqual(try cached(), ["A renamed", "C"], "a walk to the end drops the row deleted elsewhere")
    }

    /// A session this phone deleted or archived leaves the cache with its transcript.
    func testRemovingAHermesSessionTakesItsTranscript() throws {
        let context = try makeContext()
        let rows = ["a", "b"].map { HermesSessionRow(id: $0, title: $0.uppercased()).summary(in: "default") }
        try CacheStore.cacheHermesSessions(rows, profile: "default", reachedEnd: true, serverURL: hermesServer, in: context)
        for root in ["a", "b"] {
            try CacheStore.cacheHermesMessages([hermesMessage(1, root: root)], newestCoverage: .from(rowIDs: [1]), serverURL: hermesServer,
                                               profile: "default", lineageRoot: root, in: context)
        }

        try CacheStore.removeHermesSession(lineageRoot: "a", profile: "default", serverURL: hermesServer, in: context)

        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "default", in: context).map(\.title), ["B"])
        XCTAssertEqual(try fetchCachedMessages(in: context).map(\.sessionID), ["hermes|default|b"])
    }

    /// A deleted Profile takes only its own Bot Chat on that connection, archived copies included,
    /// and a discarded connection every one of its own: other connections', servers' and
    /// sessions' stay.
    func testRemovingABotOrAConnectionTakesOnlyItsBotChats() throws {
        let context = try makeContext()
        let mac = UUID(), laptop = UUID()
        let other = URL(string: "https://other.example")!
        for (server, connection, profile) in [(hermesServer, mac, "triage"), (hermesServer, mac, "keep"),
                                              (hermesServer, laptop, "triage"), (other, mac, "triage")] {
            try CacheStore.cacheHermesMessages([hermesMessage(1)], newestCoverage: .all, serverURL: server,
                                               scope: CacheStore.hermesBotChatScope(connectionID: connection, profile: profile, root: "root"),
                                               in: context)
        }
        for profile in ["triage", "keep"] {
            try CacheStore.cacheHermesMessages([hermesMessage(1)], newestCoverage: .all, serverURL: hermesServer,
                                               scope: CacheStore.hermesArchivedBotChatScope(connectionID: mac, profile: profile, root: "old"),
                                               in: context)
        }
        try CacheStore.cacheHermesMessages([hermesMessage(1)], newestCoverage: .all, serverURL: hermesServer, profile: "triage",
                                           lineageRoot: "root", in: context)
        let root = { (server: URL, connection: UUID, profile: String) in
            try CacheStore.cachedHermesBotChatRoot(serverURL: server, connectionID: connection, profile: profile, in: context)
        }
        let session = { try CacheStore.cachedHermesMessages(serverURL: self.hermesServer, profile: "triage", lineageRoot: "root",
                                                            in: context, limit: 100).count }
        let archived = { (profile: String) in
            try CacheStore.cachedHermesMessages(serverURL: self.hermesServer, scope: CacheStore.hermesArchivedBotChatScope(
                connectionID: mac, profile: profile, root: "old"), in: context, limit: 100).count
        }

        try CacheStore.removeHermesBotChats(serverURL: hermesServer, connectionID: mac, profile: "triage", in: context)
        XCTAssertNil(try root(hermesServer, mac, "triage"))
        XCTAssertEqual(try archived("triage"), 0)
        XCTAssertEqual(try root(hermesServer, mac, "keep"), "root")
        XCTAssertEqual(try archived("keep"), 1)
        XCTAssertEqual(try root(hermesServer, laptop, "triage"), "root")
        XCTAssertEqual(try root(other, mac, "triage"), "root")
        XCTAssertEqual(try session(), 1)

        try CacheStore.removeHermesBotChats(serverURL: hermesServer, connectionID: mac, in: context)
        XCTAssertNil(try root(hermesServer, mac, "keep"))
        XCTAssertEqual(try archived("keep"), 0)
        XCTAssertEqual(try root(hermesServer, laptop, "triage"), "root")
        XCTAssertEqual(try root(other, mac, "triage"), "root")
        XCTAssertEqual(try session(), 1)
    }

    /// A newest read after a rewind holds the rows before the cut and the new turn: the cut rows
    /// inside its row ids go, and rows an older page brought on an earlier visit keep their
    /// place before it.
    func testANewestReadDropsTheRowsARewindCut() throws {
        let context = try makeContext()
        try cacheTip(Array(1...6), newest: .from(rowIDs: [4, 5, 6]), in: context)

        // Rewound before row 5; the new turn saved rows 7 and 8.
        try cacheTip([3, 4, 7, 8], newest: .from(rowIDs: [3, 4, 7, 8]), in: context)

        let cached = try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "tip",
                                                         in: context, limit: 100)
        XCTAssertEqual(cached.compactMap(\.rowID), [1, 2, 3, 4, 7, 8])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 2).compactMap(\.rowID), [7, 8])
    }

    /// An undo with no later turn leaves the newest read's ids below the rows it removed, which
    /// go all the same, since the read went back from the newest row; undoing the only exchange
    /// leaves nothing.
    func testANewestReadDropsTheRowsAnUndoRemoved() throws {
        let context = try makeContext()
        try cacheTip(Array(1...6), newest: .from(rowIDs: [4, 5, 6]), in: context)

        // Undid rows 5 and 6; the newest read stopped at row 3, which an older page holds.
        try cacheTip([3, 4], newest: .from(rowIDs: [3, 4]), in: context)
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 100).compactMap(\.rowID), [1, 2, 3, 4])

        // Undid every row left; the read found none and reached the first row.
        try cacheTip([], newest: .all, in: context)
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 100), [])
    }

    /// A compaction re-inserts the session's first rows under new, higher ids, so they show
    /// before rows with lower ones. A newest read that stopped short of them never covered them,
    /// so they stay cached.
    func testANewestReadKeepsTheCompactedHeadRowsItNeverReached() throws {
        let context = try makeContext()
        try cacheTip([1001, 1002, 3, 4, 1003, 1004, 1005], newest: .all, in: context)

        // Reopened: the newest read went back to row 4 only, and a turn saved row 1006.
        try cacheTip([4, 1003, 1004, 1005, 1006], newest: .from(rowIDs: [4, 1003, 1004, 1005, 1006]), in: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: hermesServer, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 100).compactMap(\.rowID),
                       [1001, 1002, 3, 4, 1003, 1004, 1005, 1006])
    }

    /// Two Hermes servers and a webui server never read each other's rows, and clearing one
    /// server, as sign-out and removing it do, takes only its rows, Hermes ones included.
    func testHermesRowsStayWithTheirServerAndClearWithIt() throws {
        let context = try makeContext()
        let serverA = URL(string: "https://a.hermes.example")!
        let serverB = URL(string: "https://b.hermes.example")!
        let webui = URL(string: "https://webui.example")!
        for (server, title) in [(serverA, "On A"), (serverB, "On B")] {
            try CacheStore.cacheHermesSessions([HermesSessionRow(id: "s", title: title).summary(in: "default")], profile: "default",
                                               reachedEnd: true, serverURL: server, in: context)
            try CacheStore.cacheHermesMessages([hermesMessage(1, root: "s")], newestCoverage: .from(rowIDs: [1]), serverURL: server,
                                               profile: "default", lineageRoot: "s", in: context)
        }
        try CacheStore.cacheSessions([SessionSummary(sessionId: "s", title: "On webui")], serverURL: webui, in: context)

        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: serverA, profile: "default", in: context).map(\.title), ["On A"])
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: webui, profile: "default", in: context), [])
        XCTAssertEqual(try CacheStore.cachedSessions(serverURL: webui, in: context).map(\.title), ["On webui"])

        try CacheStore.clearCache(for: serverA, in: context)

        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: serverA, profile: "default", in: context), [])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: serverA, profile: "default", lineageRoot: "s",
                                                           in: context, limit: 10), [])
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: serverB, profile: "default", in: context).map(\.title), ["On B"])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: serverB, profile: "default", lineageRoot: "s",
                                                           in: context, limit: 10).count, 1)
        XCTAssertEqual(try CacheStore.cachedSessions(serverURL: webui, in: context).map(\.title), ["On webui"])
    }

    /// Hermes rows keep the TTL and the cap: an expired one never reads back and the next write
    /// purges it, and the least recently cached messages above the cap go.
    func testHermesRowsKeepTheTTLAndTheCap() throws {
        let context = try makeContext()
        let old = Date(timeIntervalSince1970: 1_770_000_000)
        let later = old.addingTimeInterval(CachePolicy.ttl + 1)
        try CacheStore.cacheHermesSessions([HermesSessionRow(id: "old").summary(in: "default")], profile: "default",
                                           reachedEnd: false, serverURL: hermesServer, in: context, cachedAt: old)
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: hermesServer, profile: "default", in: context, now: later), [])

        let scope = CacheStore.hermesScope(profile: "default", lineageRoot: "tip")
        for id in 1...CachePolicy.maxMessages {
            let key = CacheStore.hermesMessageKey(serverURL: hermesServer, profile: "default", lineageRoot: "tip", rowID: id)
            context.insert(CachedMessage(serverURLString: hermesServer.absoluteString, sessionID: scope, message: hermesMessage(id),
                                         sortIndex: id, cacheKey: key, cachedAt: later.addingTimeInterval(Double(id))))
        }
        try CacheStore.cacheHermesMessages([hermesMessage(9_999)], newestCoverage: .from(rowIDs: [9_999]), serverURL: hermesServer,
                                           profile: "default", lineageRoot: "tip", in: context,
                                           cachedAt: later.addingTimeInterval(Double(CachePolicy.maxMessages + 1)))

        XCTAssertTrue(try fetchCachedSessions(in: context).isEmpty, "the expired session was purged")
        let rows = try fetchCachedMessages(in: context).compactMap(\.rowID)
        XCTAssertEqual(rows.count, CachePolicy.maxMessages)
        XCTAssertFalse(rows.contains(1), "the least recently cached message went")
        XCTAssertTrue(rows.contains(9_999))
    }

    /// A store written before #1054's columns opens with every row, its new columns empty.
    func testAStoreFromBeforeTheHermesColumnsOpensWithItsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).store")
        addTeardownBlock {
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let cachedAt = Date()
        do {
            let container = try ModelContainer(for: Schema(versionedSchema: CacheSchemaBefore1054.self),
                                               configurations: ModelConfiguration(url: url))
            let context = ModelContext(container)
            context.insert(CacheSchemaBefore1054.CachedSession(cacheKey: "https://example.test|session|s1",
                                                               serverURLString: "https://example.test", sessionID: "s1",
                                                               title: "Before", cachedAt: cachedAt))
            context.insert(CacheSchemaBefore1054.CachedMessage(cacheKey: "https://example.test|session|s1|message|m1",
                                                               serverURLString: "https://example.test", sessionID: "s1",
                                                               content: "Kept", cachedAt: cachedAt))
            try context.save()
        }

        let context = ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                                      configurations: ModelConfiguration(url: url)))

        let session = try XCTUnwrap(fetchCachedSessions(in: context).first)
        XCTAssertEqual(session.title, "Before")
        XCTAssertNil(session.lineageRoot)
        let message = try XCTUnwrap(fetchCachedMessages(in: context).first)
        XCTAssertEqual(message.content, "Kept")
        XCTAssertNil(message.rowID)
        XCTAssertEqual(try CacheStore.cachedSessions(serverURL: URL(string: "https://example.test")!, in: context).map(\.title), ["Before"])
    }

    private let hermesServer = URL(string: "https://hermes.example")!

    /// Caches the held rows `ids` of session `tip` in `default`, after a newest read that covered `newest`.
    private func cacheTip(_ ids: [Int], newest: HermesNewestCoverage, in context: ModelContext) throws {
        try CacheStore.cacheHermesMessages(ids.map { hermesMessage($0) }, newestCoverage: newest, serverURL: hermesServer,
                                           profile: "default", lineageRoot: "tip", in: context)
    }

    /// A settled Hermes row as the chat's projection makes it.
    private func hermesMessage(_ rowID: Int, root: String = "tip") -> ChatMessage {
        ChatMessage(role: rowID.isMultiple(of: 2) ? "assistant" : "user", content: "Row \(rowID)", timestamp: Double(rowID),
                    messageId: "\(root)/row-\(rowID)", displayMetadata: ["task_count": .number(1)], rowID: rowID)
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    private func decodeSessions(_ json: String) throws -> SessionsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionsResponse.self, from: Data(json.utf8))
    }

    private func fetchCachedSessions(in context: ModelContext) throws -> [CachedSession] {
        try context.fetch(FetchDescriptor<CachedSession>())
    }

    private func fetchCachedMessages(in context: ModelContext) throws -> [CachedMessage] {
        try context.fetch(FetchDescriptor<CachedMessage>())
    }
}

/// The cache's schema before #1054 added the Hermes columns, for the upgrade test.
enum CacheSchemaBefore1054: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [CachedSession.self, CachedMessage.self] }

    @Model final class CachedSession {
        @Attribute(.unique) var cacheKey: String
        var serverURLString: String
        var sessionID: String
        var title: String?
        var workspace: String?
        var model: String?
        var modelProvider: String?
        var messageCount: Int?
        var createdAt: Double?
        var updatedAt: Double?
        var lastMessageAt: Double?
        var pinned: Bool?
        var archived: Bool?
        var projectId: String?
        var profile: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var estimatedCost: Double?
        var activeStreamId: String?
        var isStreaming: Bool?
        var isCliSession: Bool?
        var userMessageCount: Int?
        var hasPendingUserMessage: Bool?
        var pendingStartedAt: Double?
        var worktreePath: String?
        var sourceTag: String?
        var rawSource: String?
        var sessionSource: String?
        var sourceLabel: String?
        var parentSessionId: String?
        var relationshipType: String?
        var readOnly: Bool?
        var isReadOnly: Bool?
        var cachedAt: Date
        var expiresAt: Date

        init(cacheKey: String, serverURLString: String, sessionID: String, title: String, cachedAt: Date) {
            self.cacheKey = cacheKey
            self.serverURLString = serverURLString
            self.sessionID = sessionID
            self.title = title
            self.cachedAt = cachedAt
            expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        }
    }

    @Model final class CachedMessage {
        @Attribute(.unique) var cacheKey: String
        var serverURLString: String
        var sessionID: String
        var sortIndex: Int
        var role: String?
        var content: String?
        var timestamp: Double?
        var messageId: String?
        var name: String?
        var toolCallId: String?
        var toolUseId: String?
        var toolCallsData: Data?
        var contentPartsData: Data?
        var reasoning: String?
        var attachmentsData: Data?
        var turnTps: Double?
        var turnDuration: Double?
        var displayKind: String?
        var cachedAt: Date
        var expiresAt: Date

        init(cacheKey: String, serverURLString: String, sessionID: String, content: String, cachedAt: Date) {
            self.cacheKey = cacheKey
            self.serverURLString = serverURLString
            self.sessionID = sessionID
            sortIndex = 0
            self.content = content
            self.cachedAt = cachedAt
            expiresAt = cachedAt.addingTimeInterval(CachePolicy.ttl)
        }
    }
}
