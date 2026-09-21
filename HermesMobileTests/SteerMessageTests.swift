import SwiftData
import XCTest
@testable import HermesMobile

/// Issue #536: steering hints render inline in the transcript as compact
/// "Steer" bubbles instead of leaking the server's out-of-band wrapper.
final class SteerMessageTests: XCTestCase {
    private static let steerOpenLine = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]"
    private static let steerCloseLine = "[/OUT-OF-BAND USER MESSAGE]"

    private static func wrapped(_ text: String) -> String {
        "\(steerOpenLine)\n\(text)\n\(steerCloseLine)"
    }

    // MARK: - Decoding

    /// The REST client decodes with `convertFromSnakeCase`.
    func testDisplayKindDecodesFromSnakeCaseWireFormat() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(
            ChatMessage.self,
            from: Data(#"{"role":"user","display_kind":"steer","content":"go on"}"#.utf8)
        )
        XCTAssertEqual(message.displayKind, "steer")
        XCTAssertTrue(message.isSteerMessage)
    }

    /// The SSE `done` payload's primary path uses a plain decoder.
    func testDisplayKindDecodesWithPlainDecoder() throws {
        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"user","display_kind":"steer","content":"go on"}"#.utf8)
        )
        XCTAssertEqual(message.displayKind, "steer")
        XCTAssertTrue(message.isSteerMessage)
    }

    func testUnknownDisplayKindFallsBackToOrdinaryMessage() throws {
        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"user","display_kind":"notice","content":"hello"}"#.utf8)
        )
        XCTAssertEqual(message.displayKind, "notice")
        XCTAssertFalse(message.isSteerMessage)
        XCTAssertEqual(message.steerText, "hello")
    }

    func testMissingDisplayKindDecodesAsNil() throws {
        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"user","content":"hello"}"#.utf8)
        )
        XCTAssertNil(message.displayKind)
        XCTAssertFalse(message.isSteerMessage)
    }

    // MARK: - Marker stripping

    func testStrippedSteerText() {
        XCTAssertEqual(
            ChatMessage.strippedSteerText(from: Self.wrapped("use shorter sentences")),
            "use shorter sentences"
        )
        XCTAssertEqual(
            ChatMessage.strippedSteerText(from: Self.wrapped("line one\nline two")),
            "line one\nline two"
        )
        XCTAssertEqual(ChatMessage.strippedSteerText(from: Self.wrapped("")), "")
        // A bare mention of the marker is not a wrapped block.
        XCTAssertNil(ChatMessage.strippedSteerText(from: "hello"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "\(Self.steerOpenLine)\nno closing line"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "prefix\n\(Self.wrapped("x"))"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "\(Self.wrapped("x"))\nsuffix"))
        // Only the exact server marker counts; a lookalike opening line does not.
        XCTAssertNil(ChatMessage.strippedSteerText(
            from: "[OUT-OF-BAND USER MESSAGE\nuse shorter sentences\n\(Self.steerCloseLine)"
        ))
    }

    func testIsSteerMessageViaDisplayKindWithoutMarker() {
        let message = ChatMessage(
            role: "user",
            content: "use shorter sentences",
            timestamp: nil,
            messageId: "m1",
            displayKind: "steer"
        )
        XCTAssertTrue(message.isSteerMessage)
        XCTAssertEqual(message.steerText, "use shorter sentences")
    }

    func testIsSteerMessageViaMarkerWithoutDisplayKind() {
        let message = ChatMessage(
            role: "user",
            content: Self.wrapped("use shorter sentences"),
            timestamp: nil,
            messageId: "m1"
        )
        XCTAssertTrue(message.isSteerMessage)
        XCTAssertEqual(message.steerText, "use shorter sentences")
    }

    // MARK: - Turn classification

    func testSteerRowsAreNotUserTurnBoundaries() {
        let user = ChatMessage(role: "user", content: "Keep going", timestamp: nil, messageId: "u1")
        let steer = ChatMessage(
            role: "user",
            content: Self.wrapped("use shorter sentences"),
            timestamp: nil,
            messageId: "s1",
            displayKind: "steer"
        )
        let assistant = ChatMessage(role: "assistant", content: "On it.", timestamp: nil, messageId: "a1")

        XCTAssertTrue(TranscriptTurnClassifier.isUserTurnBoundary(user))
        XCTAssertFalse(TranscriptTurnClassifier.isUserTurnBoundary(steer))
        XCTAssertFalse(TranscriptTurnClassifier.isUserTurnBoundary(assistant))

        let messages = [user, steer, assistant]
        XCTAssertEqual(TranscriptTurnClassifier.latestTurnKey(in: messages), "turn:user:0")
        XCTAssertEqual(
            TranscriptTurnClassifier.assistantTurnKeysByAnchorID(messages)["a1"],
            "turn:user:0"
        )
    }

    // MARK: - Cache round-trip

    @MainActor
    func testCacheRoundTripsDisplayKind() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: CachedSession.self,
            CachedMessage.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let serverURL = URL(string: "https://example.test")!

        try CacheStore.cacheMessages(
            [ChatMessage(
                role: "user",
                content: Self.wrapped("use shorter sentences"),
                timestamp: 1_770_000_000,
                messageId: "m-steer",
                displayKind: "steer"
            )],
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            cachedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )

        let restored = try CacheStore.cachedMessages(
            serverURL: serverURL,
            sessionID: "abc123",
            in: context,
            now: Date(timeIntervalSince1970: 1_770_000_100)
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.displayKind, "steer")
        XCTAssertTrue(restored.first?.isSteerMessage ?? false)
        XCTAssertEqual(restored.first?.steerText, "use shorter sentences")
    }

    // MARK: - Bot projection

    func testBotProjectionCarriesDisplayKind() {
        let history: [BotJSON] = [
            .object(["role": .string("user"), "text": .string("Clear the inbox")]),
            .object([
                "role": .string("user"),
                "text": .string(Self.wrapped("archive first")),
                "display_kind": .string("steer"),
            ]),
        ]
        let projected = BotTranscriptProjection.project(history: history, root: "root")
        XCTAssertEqual(projected.messages.count, 2)
        let steer = projected.messages[1]
        XCTAssertEqual(steer.displayKind, "steer")
        XCTAssertTrue(steer.isSteerMessage)
        XCTAssertEqual(steer.steerText, "archive first")
        XCTAssertFalse(projected.messages[0].isSteerMessage)
    }

    /// Steers in bot history get the same mention-note stripping as ordinary
    /// user rows: the hidden agent-profile annotation must not leak profile
    /// IDs into the cached transcript.
    func testBotProjectionStripsMentionAnnotationFromSteers() throws {
        let profile = try XCTUnwrap(BotProfile(.object(["name": .string("analyst")])))
        let mentions = BotMentions(roster: [profile], excluding: "other")
        let steerText = "@analyst dig deeper"
        let annotated = steerText + mentions.annotation(for: steerText)
        XCTAssertNotEqual(annotated, steerText)

        let history: [BotJSON] = [
            .object([
                "role": .string("user"),
                "text": .string(Self.wrapped(annotated)),
                "display_kind": .string("steer"),
            ]),
        ]
        let projected = BotTranscriptProjection.project(history: history, root: "root")
        XCTAssertEqual(projected.messages.count, 1)
        XCTAssertTrue(projected.messages[0].isSteerMessage)
        XCTAssertEqual(projected.messages[0].steerText, steerText)
    }

    // MARK: - Regenerate

    /// Regenerating a steered reply resends the prompt, not the steer.
    func testRegenerateSkipsSteerRows() {
        let messages = [
            ChatMessage(role: "user", content: "Tell me a long story", timestamp: nil, messageId: "u1"),
            ChatMessage(role: "user", content: Self.wrapped("About elephants"), timestamp: nil, messageId: "s1"),
            ChatMessage(role: "assistant", content: "The Long Voice", timestamp: nil, messageId: "a1"),
        ]
        XCTAssertEqual(
            ChatViewModel.precedingUserMessageText(in: messages, beforeVisibleIndex: 2),
            "Tell me a long story"
        )
    }

    // MARK: - Active-stream snapshot restoration

    /// A steer echo appended after the streaming assistant must not move the
    /// assistant search range: the persisted assistant row is reconciled with
    /// the snapshot instead of being duplicated.
    func testSteerEchoDoesNotBreakActiveStreamSnapshotMerge() {
        let snapshotAssistant = ChatMessage(
            role: "assistant",
            content: "partial response",
            timestamp: 1_770_000_090,
            messageId: "a-snapshot"
        )
        let snapshot = ActiveChatStreamSnapshot(
            messages: [
                ChatMessage(role: "user", content: "hi", timestamp: 1_770_000_080, messageId: "u-1"),
                snapshotAssistant,
            ],
            messagesOffset: 0,
            displayTitle: "",
            completedToolCallGroups: [],
            completedReasoningGroups: [],
            liveToolCalls: [],
            liveReasoningText: "",
            activeStreamLastEventID: nil,
            streamingAssistantMessageID: "a-snapshot",
            toolCallAnchorMessageID: nil,
            reasoningAnchorMessageID: nil,
            contextWindowSnapshot: nil,
            localAttachmentPreviews: [:],
            pinnedLocalNotices: []
        )
        // The persisted assistant row carries a different id than the
        // snapshot's, as when the stream persisted under a new row while the
        // steer echo was still trailing.
        let loadedMessages = [
            ChatMessage(role: "user", content: "hi", timestamp: 1_770_000_080, messageId: "u-1"),
            ChatMessage(role: "assistant", content: "partial response and more", timestamp: 1_770_000_095, messageId: "a-persisted"),
            ChatMessage(role: "user", content: "keep it short", timestamp: 1_770_000_100, messageId: "local-steer-1", displayKind: "steer"),
        ]

        let merge = ChatViewModel.mergingLoadedMessages(loadedMessages, withActiveStreamSnapshot: snapshot)

        XCTAssertEqual(merge.messages.map(\.messageId), ["u-1", "a-persisted", "local-steer-1"])
        XCTAssertEqual(merge.streamingAssistantMessageID, "a-persisted")
        XCTAssertFalse(merge.usedSnapshotMessagesOffset)
    }

    /// A trailing steer echo must not hide an in-flight assistant response
    /// from the stream coordinator's latest-load check.
    func testTrailingSteerEchoDoesNotHideInFlightAssistant() {
        let withSteerEcho = [
            ChatMessage(role: "user", content: "hi", timestamp: 1_770_000_080, messageId: "u-1"),
            ChatMessage(role: "assistant", content: "partial", timestamp: 1_770_000_090, messageId: "a-1"),
            ChatMessage(role: "user", content: "keep it short", timestamp: 1_770_000_100, messageId: "local-steer-1", displayKind: "steer"),
        ]
        XCTAssertTrue(ChatViewModel.hasAssistantResponseAfterLatestUser(in: withSteerEcho))

        let steerOnly = [
            ChatMessage(role: "user", content: "hi", timestamp: 1_770_000_080, messageId: "u-1"),
            ChatMessage(role: "user", content: "keep it short", timestamp: 1_770_000_100, messageId: "local-steer-1", displayKind: "steer"),
        ]
        XCTAssertFalse(ChatViewModel.hasAssistantResponseAfterLatestUser(in: steerOnly))
    }

    // MARK: - Local echo lifecycle

    /// A steer echo only matches a persisted steer row: without kind-aware
    /// dedup, an ordinary repeated prompt with identical text could swallow
    /// the persisted steer row (or vice versa).
    func testSteerEchoOnlyMatchesPersistedSteerRows() {
        let persistedSteer = ChatMessage(
            role: "user",
            content: Self.wrapped("use shorter sentences"),
            timestamp: 1_770_000_095,
            messageId: "msg-steer-1",
            displayKind: "steer"
        )

        let echo = ChatMessage(
            role: "user",
            content: "use shorter sentences",
            timestamp: 1_770_000_100,
            messageId: "local-steer-1",
            displayKind: "steer"
        )
        let mergedEcho = ChatViewModel.mergingLoadedMessages(
            [persistedSteer],
            withLocalOptimisticMessages: [echo]
        )
        XCTAssertEqual(mergedEcho.map(\.messageId), ["msg-steer-1"])

        let ordinaryPrompt = ChatMessage(
            role: "user",
            content: "use shorter sentences",
            timestamp: 1_770_000_100,
            messageId: "local-2"
        )
        let mergedOrdinary = ChatViewModel.mergingLoadedMessages(
            [persistedSteer],
            withLocalOptimisticMessages: [ordinaryPrompt]
        )
        XCTAssertEqual(mergedOrdinary.count, 2)
        XCTAssertTrue(mergedOrdinary.contains { $0.messageId == "msg-steer-1" })
        XCTAssertTrue(mergedOrdinary.contains { $0.messageId == "local-2" })
    }

    /// An accepted steer appends a local echo immediately; when the persisted
    /// steer row arrives in `.done`, the echo is replaced with no duplicate.
    @MainActor
    func testAcceptedSteerEchoIsReplacedByPersistedRowOnDone() async throws {
        let streamClient = ScriptedSSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(
                    #"{"session_id":"session-abc","stream_id":"stream-123"}"#,
                    for: request
                )
            case "/api/chat/steer":
                return apiTestJSONResponse(#"{"accepted":true}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let didStart = await viewModel.sendMessage("Start a response")
        XCTAssertTrue(didStart)

        let steerCommand = try XCTUnwrap(SlashCommandCatalog.command(named: "steer"))
        let result = await viewModel.executeSlashCommand(steerCommand, args: "use shorter sentences")
        XCTAssertEqual(result, .executed(message: nil))

        let echoes = viewModel.messages.filter(\.isSteerMessage)
        XCTAssertEqual(echoes.count, 1)
        XCTAssertEqual(echoes.first?.content, "use shorter sentences")
        XCTAssertEqual(echoes.first?.displayKind, ChatMessage.steerDisplayKind)
        XCTAssertTrue(echoes.first?.messageId?.hasPrefix("local-") ?? false)

        let now = Date().timeIntervalSince1970
        let wrappedJSON = Self.wrapped("use shorter sentences")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let sessionDetail = try decodeSessionDetail(#"""
        {
          "session_id": "session-abc",
          "messages": [
            {"role": "user", "content": "Start a response", "message_id": "msg-1", "_ts": \#(now - 60)},
            {"role": "user", "display_kind": "steer", "content": "\#(wrappedJSON)", "message_id": "msg-steer-1", "_ts": \#(now - 5)},
            {"role": "assistant", "content": "Short reply.", "message_id": "msg-2", "_ts": \#(now)}
          ]
        }
        """#)
        streamClient.emit(.done(DoneStreamEvent(session: sessionDetail)))

        let steers = viewModel.messages.filter(\.isSteerMessage)
        XCTAssertEqual(steers.count, 1, "the local echo must not duplicate the persisted row")
        XCTAssertEqual(steers.first?.messageId, "msg-steer-1")
        XCTAssertFalse(viewModel.messages.contains { $0.messageId?.hasPrefix("local-steer-") ?? false })
    }

    // MARK: - Helpers

    private func decodeSessionDetail(_ json: String) throws -> SessionDetail {
        // Mirrors the SSE `done` path, which decodes the session snake_case.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: Data(json.utf8))
    }

    @MainActor
    private func makeViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: urlSession)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data("""
            {
              "session_id": "session-abc",
              "title": "Planning",
              "workspace": "/tmp/workspace"
            }
            """.utf8)
        )

        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }
}
