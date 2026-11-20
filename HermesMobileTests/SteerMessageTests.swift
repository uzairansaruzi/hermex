import SwiftData
import XCTest
@testable import HermesMobile

final class SteerMessageTests: XCTestCase {
    private static let steerOpenLine = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]"
    private static let steerCloseLine = "[/OUT-OF-BAND USER MESSAGE]"

    private static func wrapped(_ text: String) -> String {
        "\(steerOpenLine)\n\(text)\n\(steerCloseLine)"
    }

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
        XCTAssertNil(ChatMessage.strippedSteerText(from: "hello"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "\(Self.steerOpenLine)\nno closing line"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "prefix\n\(Self.wrapped("x"))"))
        XCTAssertNil(ChatMessage.strippedSteerText(from: "\(Self.wrapped("x"))\nsuffix"))
        XCTAssertNil(ChatMessage.strippedSteerText(
            from: "[OUT-OF-BAND USER MESSAGE\nuse shorter sentences\n\(Self.steerCloseLine)"
        ))
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

        XCTAssertTrue(TranscriptTurnClassifier.isTurnBoundary(user))
        XCTAssertFalse(TranscriptTurnClassifier.isTurnBoundary(steer))
        XCTAssertFalse(TranscriptTurnClassifier.isTurnBoundary(assistant))

        let messages = [user, steer, assistant]
        XCTAssertEqual(TranscriptTurnClassifier.latestTurnKey(in: messages), "turn:user:0")
        XCTAssertEqual(
            TranscriptTurnClassifier.assistantTurnKeysByAnchorID(messages)["a1"],
            "turn:user:0"
        )
    }

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

    func testHermesProjectionStripsMentionAnnotationFromSteers() throws {
        let profile = try XCTUnwrap(BotProfile(.object(["name": .string("analyst")])))
        let mentions = BotMentions(roster: [profile], excluding: "other")
        let steerText = "@analyst dig deeper"
        let annotated = steerText + mentions.annotation(for: steerText)
        XCTAssertNotEqual(annotated, steerText)

        let rows: [BotJSON] = [
            .object([
                "id": .number(1),
                "role": .string("user"),
                "content": .string(Self.wrapped(annotated)),
                "display_kind": .string("steer"),
            ]),
        ]
        let projected = HermesTranscriptProjection.project(rows, root: "root")
        XCTAssertEqual(projected.messages.count, 1)
        XCTAssertTrue(projected.messages[0].isSteerMessage)
        XCTAssertEqual(projected.messages[0].steerText, steerText)
    }

    func testOnlyPromptsAndDelegationDeliveriesOpenATurn() {
        let prompt = ChatMessage(role: "user", content: "Clear the inbox", timestamp: nil, messageId: "1")
        let steer = ChatMessage(role: "user", content: "archive first", timestamp: nil, messageId: "2",
                                displayKind: ChatMessage.steerDisplayKind)
        let delivery = ChatMessage(role: "delegation_completion", content: "Report", timestamp: nil, messageId: "3")
        let reply = ChatMessage(role: "assistant", content: "Done", timestamp: nil, messageId: "4")
        XCTAssertEqual([prompt, steer, delivery, reply].map(TranscriptTurnClassifier.isTurnBoundary), [true, false, true, false])
    }

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

    func testSteerEchoWithAttachmentNoteMatchesPersistedSteerRow() {
        let sent = PendingAttachment.steerMessageText(
            draft: "also read this",
            attachments: [PendingAttachment(name: "notes.txt", path: "/tmp/workspace/notes.txt", mime: "text/plain", size: 5, isImage: false)]
        )
        let persistedSteer = ChatMessage(
            role: "user",
            content: Self.wrapped(sent),
            timestamp: 1_770_000_095,
            messageId: "msg-steer-1",
            displayKind: "steer"
        )
        let echo = ChatMessage(
            role: "user",
            content: sent,
            timestamp: 1_770_000_100,
            messageId: "local-steer-1",
            displayKind: "steer"
        )

        let merged = ChatViewModel.mergingLoadedMessages([persistedSteer], withLocalOptimisticMessages: [echo])

        XCTAssertEqual(merged.map(\.messageId), ["msg-steer-1"])
    }

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

    private func decodeSessionDetail(_ json: String) throws -> SessionDetail {
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
