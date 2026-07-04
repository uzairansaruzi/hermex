import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientSessionDetailTests: APIClientTestCase {
    func testSessionRequestBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["messages"], "1")
            XCTAssertEqual(query["msg_limit"], "25")
            XCTAssertEqual(query["msg_before"], "50")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {"role": "user", "content": "Hello", "_ts": 1770000000},
                  {"role": "assistant", "content": "Hi", "timestamp": 1770000001}
                ],
                "_messages_truncated": true,
                "_messages_offset": 25
              }
            }
            """, for: request)
        }

        let response = try await client.session(
            id: "abc123",
            includeMessages: true,
            messageLimit: 25,
            messageBefore: 50
        )

        XCTAssertEqual(response.session?.sessionId, "abc123")
        XCTAssertEqual(response.session?.messages?.count, 2)
        XCTAssertEqual(response.session?.messages?.first?.timestamp, 1_770_000_000)
        XCTAssertEqual(response.session?.messagesTruncated, true)
        XCTAssertEqual(response.session?.messagesOffset, 25)
    }

    func testSessionColdLoadSendsExpandRenderableFlag() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], "abc123")
            XCTAssertEqual(query["msg_limit"], "50")
            XCTAssertEqual(query["expand_renderable"], "1")
            XCTAssertNil(query["msg_before"])

            return apiTestJSONResponse("""
            { "session": { "session_id": "abc123" } }
            """, for: request)
        }

        _ = try await client.session(
            id: "abc123",
            includeMessages: true,
            messageLimit: 50,
            expandRenderable: true
        )
    }

    func testSessionLoadEarlierOmitsExpandRenderableFlag() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["msg_before"], "100")
            XCTAssertNil(query["expand_renderable"])

            return apiTestJSONResponse("""
            { "session": { "session_id": "abc123" } }
            """, for: request)
        }

        _ = try await client.session(
            id: "abc123",
            includeMessages: true,
            messageLimit: 50,
            messageBefore: 100
        )
    }

    func testSessionDecodesPersistedToolCalls() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {"role": "assistant", "content": "I checked the file.", "_ts": 1770000000}
                ],
                "tool_calls": [
                  {
                    "name": "read_file",
                    "snippet": "let value = 42",
                    "tid": "call_123",
                    "assistant_msg_idx": 12,
                    "args": {
                      "path": "/tmp/example.swift",
                      "limit": 120
                    }
                  }
                ],
                "_messages_offset": 12
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let toolCall = try XCTUnwrap(response.session?.toolCalls?.first)

        XCTAssertEqual(toolCall.name, "read_file")
        XCTAssertEqual(toolCall.snippet, "let value = 42")
        XCTAssertEqual(toolCall.tid, "call_123")
        XCTAssertEqual(toolCall.assistantMsgIdx, 12)
        XCTAssertEqual(toolCall.args?["path"], .string("/tmp/example.swift"))
        XCTAssertEqual(toolCall.args?["limit"], .number(120))
    }

    func testSessionDecodesPersistedAssistantReasoning() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {
                    "role": "assistant",
                    "content": "The file defines a SwiftUI view.",
                    "reasoning": "I inspected the file and looked for the main type.",
                    "_ts": 1770000000
                  }
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let message = try XCTUnwrap(response.session?.messages?.first)

        XCTAssertEqual(message.reasoning, "I inspected the file and looked for the main type.")
    }

    func testSessionDecodesMessageAttachments() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {
                    "role": "user",
                    "content": "Please analyze this",
                    "_ts": 1770000000,
                    "attachments": [
                      {"name": "report.pdf", "path": "/uploads/abc123/report.pdf", "mime": "application/pdf", "size": 1024},
                      {"name": "image.jpg", "path": "/uploads/abc123/image.jpg", "mime": "image/jpeg", "size": 2048, "is_image": true}
                    ]
                  }
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let message = try XCTUnwrap(response.session?.messages?.first)

        XCTAssertEqual(message.attachments?.count, 2)
        XCTAssertEqual(message.attachments?.first?.name, "report.pdf")
        XCTAssertEqual(message.attachments?.first?.path, "/uploads/abc123/report.pdf")
        XCTAssertEqual(message.attachments?.first?.mime, "application/pdf")
        XCTAssertEqual(message.attachments?.first?.size, 1024)
        XCTAssertNil(message.attachments?.first?.isImage)

        XCTAssertEqual(message.attachments?.last?.name, "image.jpg")
        XCTAssertEqual(message.attachments?.last?.isImage, true)
    }

    func testSessionDecodesTolerantMessageAttachments() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {
                    "role": "user",
                    "content": "Normal attachments",
                    "_ts": 1770000000,
                    "attachments": [
                      {"name": "report.pdf", "path": "/uploads/report.pdf", "mime": "application/pdf", "size": 1024},
                      {"filename": "image.jpg", "path": "/uploads/image.jpg", "mime": "image/jpeg", "size": 2048, "is_image": true}
                    ]
                  },
                  {
                    "role": "user",
                    "content": "Legacy bare string",
                    "_ts": 1770000001,
                    "attachments": ["legacy_file.txt"]
                  },
                  {
                    "role": "user",
                    "content": "Mixed quality",
                    "_ts": 1770000002,
                    "attachments": [
                      {"name": "good.csv", "path": "/uploads/good.csv", "mime": "text/csv", "size": 42},
                      12345,
                      {"path": "/uploads/minimal.txt", "mime": "text/plain"}
                    ]
                  },
                  {
                    "role": "user",
                    "content": "Null attachments",
                    "_ts": 1770000003,
                    "attachments": null
                  },
                  {
                    "role": "user",
                    "content": "No attachments key",
                    "_ts": 1770000004
                  }
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let messages = try XCTUnwrap(response.session?.messages)
        XCTAssertEqual(messages.count, 5)

        // Message 1: normal + filename alias
        let msg1 = messages[0]
        XCTAssertEqual(msg1.attachments?.count, 2)
        XCTAssertEqual(msg1.attachments?[0].name, "report.pdf")
        XCTAssertEqual(msg1.attachments?[0].size, 1024)
        XCTAssertEqual(msg1.attachments?[1].name, "image.jpg")
        XCTAssertEqual(msg1.attachments?[1].isImage, true)

        // Message 2: legacy bare string
        let msg2 = messages[1]
        XCTAssertEqual(msg2.attachments?.count, 1)
        XCTAssertEqual(msg2.attachments?.first?.name, "legacy_file.txt")
        XCTAssertNil(msg2.attachments?.first?.path)

        // Message 3: mixed quality — malformed entries are dropped
        let msg3 = messages[2]
        XCTAssertEqual(msg3.attachments?.count, 2)
        XCTAssertEqual(msg3.attachments?[0].name, "good.csv")
        XCTAssertEqual(msg3.attachments?[1].path, "/uploads/minimal.txt")
        XCTAssertNil(msg3.attachments?[1].name)

        // Message 4: explicit null
        let msg4 = messages[3]
        XCTAssertNil(msg4.attachments)

        // Message 5: missing key
        let msg5 = messages[4]
        XCTAssertNil(msg5.attachments)
    }

    func testSessionInfersAttachmentsFromAttachedFilesMarkerWhenServerOmitsMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {
                    "role": "user",
                    "content": "Analyze these\\n\\n[Attached files: image_1778030812_E9EE.jpg, /Users/hermes/projects/workspace/17mb.csv]",
                    "_ts": 1770000000
                  }
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let message = try XCTUnwrap(response.session?.messages?.first)
        let attachments = try XCTUnwrap(message.attachments)

        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0].name, "image_1778030812_E9EE.jpg")
        XCTAssertEqual(attachments[0].path, "/Users/hermes/projects/workspace/image_1778030812_E9EE.jpg")
        XCTAssertEqual(attachments[0].isImage, true)
        XCTAssertEqual(attachments[1].name, "17mb.csv")
        XCTAssertEqual(attachments[1].path, "/Users/hermes/projects/workspace/17mb.csv")
        XCTAssertEqual(attachments[1].isImage, false)
    }

    func testSessionEnrichesLegacyAttachmentNamesFromAttachedFilesMarkerPaths() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "messages": [
                  {
                    "role": "user",
                    "content": "Review these\\n\\n[Attached files: /Users/hermes/projects/workspace/image_1778032969_13BE.jpg, /Users/hermes/projects/workspace/hermes-agent-slideshow.html]",
                    "_ts": 1770000000,
                    "attachments": [
                      "image_1778032969_13BE.jpg",
                      "hermes-agent-slideshow.html"
                    ]
                  }
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let message = try XCTUnwrap(response.session?.messages?.first)
        let attachments = try XCTUnwrap(message.attachments)

        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0].name, "image_1778032969_13BE.jpg")
        XCTAssertEqual(attachments[0].path, "/Users/hermes/projects/workspace/image_1778032969_13BE.jpg")
        XCTAssertEqual(attachments[0].isImage, true)
        XCTAssertEqual(attachments[1].name, "hermes-agent-slideshow.html")
        XCTAssertEqual(attachments[1].path, "/Users/hermes/projects/workspace/hermes-agent-slideshow.html")
        XCTAssertEqual(attachments[1].isImage, false)
    }

    func testSessionDecodesWebUICreatedSessionWithUnexpectedOptionalFieldTypes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/session")

            return apiTestJSONResponse("""
            {
              "session": {
                "session_id": 12345,
                "title": 987,
                "message_count": "2",
                "pinned": "false",
                "estimated_cost": "0.12",
                "pending_attachments": {"unexpected": true},
                "messages": [
                  {
                    "role": "user",
                    "content": [
                      {"type": "text", "text": "Hello from rich content"}
                    ],
                    "_ts": "1770000000.5",
                    "message_id": 42,
                    "attachments": [
                      {"filename": "image.png", "path": "/uploads/image.png", "size": "2048", "is_image": "true"},
                      12345
                    ]
                  },
                  {
                    "role": "assistant",
                    "content": "Loaded",
                    "timestamp": 1770000001,
                    "tool_calls": {"unexpected": "shape"},
                    "reasoning": {"text": "not the persisted string"}
                  }
                ],
                "tool_calls": [
                  {
                    "name": "read_file",
                    "snippet": 123,
                    "tid": 456,
                    "assistant_msg_idx": "4",
                    "args": ["unexpected"]
                  },
                  "malformed"
                ],
                "_messages_offset": "4",
                "_messages_truncated": "true"
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "webui-created")
        let session = try XCTUnwrap(response.session)

        XCTAssertEqual(session.sessionId, "12345")
        XCTAssertEqual(session.title, "987")
        XCTAssertEqual(session.messageCount, 2)
        XCTAssertEqual(session.pinned, false)
        XCTAssertEqual(session.estimatedCost ?? -1, 0.12, accuracy: 0.0001)
        XCTAssertNil(session.pendingAttachments)
        XCTAssertEqual(session.messagesOffset, 4)
        XCTAssertEqual(session.messagesTruncated, true)

        let messages = try XCTUnwrap(session.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertTrue(messages[0].content?.contains("Hello from rich content") == true)
        XCTAssertEqual(messages[0].timestamp, 1_770_000_000.5)
        XCTAssertEqual(messages[0].messageId, "42")
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertEqual(messages[0].attachments?.first?.name, "image.png")
        XCTAssertEqual(messages[0].attachments?.first?.size, 2048)
        XCTAssertEqual(messages[0].attachments?.first?.isImage, true)

        XCTAssertEqual(messages[1].content, "Loaded")
        XCTAssertNil(messages[1].toolCalls)
        XCTAssertNil(messages[1].reasoning)

        let toolCall = try XCTUnwrap(session.toolCalls?.first)
        XCTAssertEqual(session.toolCalls?.count, 1)
        XCTAssertEqual(toolCall.name, "read_file")
        XCTAssertEqual(toolCall.snippet, "123")
        XCTAssertEqual(toolCall.tid, "456")
        XCTAssertEqual(toolCall.assistantMsgIdx, 4)
        XCTAssertNil(toolCall.args)
    }

    func testSessionToleratesNumericFieldsOutsideIntRange() async throws {
        // Values beyond Int range reach the lossy int decoder's Double branch,
        // which used to trap instead of decoding to nil (#62).
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "session": {
                "session_id": "huge-numbers",
                "message_count": 1e300,
                "input_tokens": -1e300,
                "output_tokens": "1e300",
                "context_length": 9223372036854775808,
                "messages": [
                  {"role": "assistant", "content": "Still standing"}
                ]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "huge-numbers")
        let session = try XCTUnwrap(response.session)

        XCTAssertNil(session.messageCount)
        XCTAssertNil(session.inputTokens)
        XCTAssertNil(session.outputTokens)
        XCTAssertNil(session.contextLength)
        XCTAssertEqual(session.messages?.first?.content, "Still standing")
    }

    func testSessionDecodesCompressionAnchorMetadata() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "compression_anchor_visible_idx": 7,
                "compression_anchor_message_key": {
                  "role": "user",
                  "ts": 1770000000.5,
                  "text": "What does the resolver do?",
                  "attachments": 1
                },
                "compression_anchor_summary": "Summary of the compacted conversation."
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let session = try XCTUnwrap(response.session)

        XCTAssertEqual(session.compressionAnchorVisibleIdx, 7)
        XCTAssertEqual(session.compressionAnchorMessageKey?.role, "user")
        XCTAssertEqual(session.compressionAnchorMessageKey?.ts, 1_770_000_000.5)
        XCTAssertEqual(session.compressionAnchorMessageKey?.text, "What does the resolver do?")
        XCTAssertEqual(session.compressionAnchorMessageKey?.attachments, 1)
        XCTAssertEqual(session.compressionAnchorSummary, "Summary of the compacted conversation.")
    }

    func testSessionWithoutCompressionAnchorMetadataDecodesNil() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            { "session": { "session_id": "abc123" } }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let session = try XCTUnwrap(response.session)

        XCTAssertNil(session.compressionAnchorVisibleIdx)
        XCTAssertNil(session.compressionAnchorMessageKey)
        XCTAssertNil(session.compressionAnchorSummary)
    }

    func testSessionToleratesMalformedCompressionAnchorMetadata() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "compression_anchor_visible_idx": "not-a-number",
                "compression_anchor_message_key": "unexpected-string",
                "compression_anchor_summary": ["unexpected", "array"]
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let session = try XCTUnwrap(response.session)

        XCTAssertEqual(session.sessionId, "abc123")
        XCTAssertNil(session.compressionAnchorVisibleIdx)
        XCTAssertNil(session.compressionAnchorMessageKey)
        XCTAssertNil(session.compressionAnchorSummary)
    }

    func testSessionDecodesPartialAndLossyCompressionAnchorKeyFields() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "session": {
                "session_id": "abc123",
                "compression_anchor_visible_idx": "12",
                "compression_anchor_message_key": {
                  "role": "assistant",
                  "ts": null,
                  "text": "Partial key",
                  "attachments": "3",
                  "unexpected_extra": {"nested": true}
                }
              }
            }
            """, for: request)
        }

        let response = try await client.session(id: "abc123")
        let session = try XCTUnwrap(response.session)

        XCTAssertEqual(session.compressionAnchorVisibleIdx, 12)
        XCTAssertEqual(session.compressionAnchorMessageKey?.role, "assistant")
        XCTAssertNil(session.compressionAnchorMessageKey?.ts)
        XCTAssertEqual(session.compressionAnchorMessageKey?.text, "Partial key")
        XCTAssertEqual(session.compressionAnchorMessageKey?.attachments, 3)
        XCTAssertNil(session.compressionAnchorSummary)
    }

    func testPersistedToolCallsMapToLoadedMessageIDsUsingOffset() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Can you inspect this?",
                timestamp: 1_770_000_000,
                messageId: nil
            ),
            ChatMessage(
                role: "assistant",
                content: "I checked the file.",
                timestamp: 1_770_000_001,
                messageId: nil
            )
        ]
        let persistedToolCalls = [
            PersistedToolCall(
                name: "old_tool",
                snippet: "Outside the loaded tail",
                tid: "old",
                assistantMsgIdx: 8,
                args: nil
            ),
            PersistedToolCall(
                name: "read_file",
                snippet: "let value = 42",
                tid: "call_123",
                assistantMsgIdx: 11,
                args: ["path": .string("/tmp/example.swift")]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: persistedToolCalls,
            messages: messages,
            messageOffset: 10
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "raw:11")
        XCTAssertEqual(groups.first?.toolCalls.first?.id, "call_123")
        XCTAssertEqual(groups.first?.toolCalls.first?.name, "read_file")
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "let value = 42")
        XCTAssertEqual(groups.first?.toolCalls.first?.args?["path"], .string("/tmp/example.swift"))
        XCTAssertEqual(groups.first?.toolCalls.first?.isCompleted, true)
    }

    func testPersistedToolCallsGroupPerAssistantTurnAndPreserveToolIDs() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Inspect the workspace",
                timestamp: 1_770_000_000,
                messageId: "user-a"
            ),
            ChatMessage(
                role: "assistant",
                content: "First answer",
                timestamp: 1_770_000_001,
                messageId: "assistant-a"
            ),
            ChatMessage(
                role: "user",
                content: "Now build it",
                timestamp: 1_770_000_001.5,
                messageId: "user-b"
            ),
            ChatMessage(
                role: "assistant",
                content: "Second answer",
                timestamp: 1_770_000_002,
                messageId: "assistant-b"
            )
        ]
        let persistedToolCalls = [
            PersistedToolCall(
                name: "read_file",
                snippet: "File contents",
                tid: "tool-a1",
                assistantMsgIdx: 1,
                args: nil
            ),
            PersistedToolCall(
                name: "search_files",
                snippet: "Search results",
                tid: "tool-a2",
                assistantMsgIdx: 1,
                args: nil
            ),
            PersistedToolCall(
                name: "terminal",
                snippet: "Build output",
                tid: "tool-b1",
                assistantMsgIdx: 3,
                args: nil
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: persistedToolCalls,
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "persisted-tools-assistant-a")
        XCTAssertEqual(groups[0].activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups[0].toolCalls.map(\.id), ["tool-a1", "tool-a2"])
        XCTAssertEqual(groups[0].toolCalls.map(\.name), ["read_file", "search_files"])
        XCTAssertEqual(groups[0].isComplete, true)

        XCTAssertEqual(groups[1].id, "persisted-tools-assistant-b")
        XCTAssertEqual(groups[1].activityTitle, "Activity: 1 tool")
        XCTAssertEqual(groups[1].toolCalls.map(\.id), ["tool-b1"])
        XCTAssertEqual(groups[1].toolCalls.first?.name, "terminal")
    }

    func testPersistedToolCallsCoalesceConsecutiveAssistantSegmentsInOneTurn() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Inspect the workspace",
                timestamp: 1_770_000_000,
                messageId: "user-a"
            ),
            ChatMessage(
                role: "assistant",
                content: "First tool segment",
                timestamp: 1_770_000_001,
                messageId: "assistant-a"
            ),
            ChatMessage(
                role: "assistant",
                content: "Second tool segment",
                timestamp: 1_770_000_002,
                messageId: "assistant-b"
            )
        ]
        let persistedToolCalls = [
            PersistedToolCall(
                name: "skill_view",
                snippet: "xurl",
                tid: "skill-xurl",
                assistantMsgIdx: 1,
                args: ["name": .string("xurl")]
            ),
            PersistedToolCall(
                name: "skill_view",
                snippet: "xitter",
                tid: "skill-xitter",
                assistantMsgIdx: 1,
                args: ["name": .string("xitter")]
            ),
            PersistedToolCall(
                name: "terminal",
                snippet: "xurl not installed",
                tid: "terminal-xurl",
                assistantMsgIdx: 2,
                args: ["command": .string("which xurl")]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: persistedToolCalls,
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "persisted-tools-assistant-a")
        XCTAssertEqual(groups.first?.anchorMessageID, "assistant-a")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 3 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["skill-xurl", "skill-xitter", "terminal-xurl"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["skill_view", "skill_view", "terminal"])
    }

    func testToolCallGroupAnchorLookupReturnsGroupsByAnchor() {
        let firstAssistantGroup = ToolCallGroup(
            id: "group-a",
            anchorMessageID: "assistant-a",
            toolCalls: [
                ToolCall(id: "tool-a", name: "read_file", preview: nil, args: nil)
            ]
        )
        let transcriptTailGroup = ToolCallGroup(
            id: "group-tail",
            anchorMessageID: nil,
            toolCalls: [
                ToolCall(id: "tool-tail", name: "terminal", preview: nil, args: nil)
            ]
        )
        let secondAssistantGroup = ToolCallGroup(
            id: "group-b",
            anchorMessageID: "assistant-b",
            toolCalls: [
                ToolCall(id: "tool-b", name: "search_files", preview: nil, args: nil)
            ]
        )
        let secondGroupForFirstAssistant = ToolCallGroup(
            id: "group-a-2",
            anchorMessageID: "assistant-a",
            toolCalls: [
                ToolCall(id: "tool-a-2", name: "apply_patch", preview: nil, args: nil)
            ]
        )

        let lookup = ToolCallGroupAnchorLookup(groups: [
            firstAssistantGroup,
            transcriptTailGroup,
            secondAssistantGroup,
            secondGroupForFirstAssistant
        ])

        XCTAssertEqual(lookup.groups(anchorMessageID: "assistant-a").map(\.id), ["group-a", "group-a-2"])
        XCTAssertEqual(lookup.groups(anchorMessageID: "assistant-b").map(\.id), ["group-b"])
        XCTAssertEqual(lookup.groups(anchorMessageID: nil).map(\.id), ["group-tail"])
        XCTAssertTrue(lookup.groups(anchorMessageID: "missing").isEmpty)
    }

    func testMessageToolCallsGroupWhenSessionToolCallsAreOmitted() {
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                toolCalls: [
                    .object([
                        "id": .string("call-1"),
                        "function": .object([
                            "name": .string("terminal"),
                            "arguments": .string(#"{"command":"pwd"}"#)
                        ])
                    ]),
                    .object([
                        "id": .string("call-2"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string(#"{"path":"CURRENT.md"}"#)
                        ])
                    ])
                ]
            ),
            ChatMessage(
                role: "tool",
                content: "/Users/uzair/project",
                timestamp: 1_770_000_002,
                messageId: "tool-result-1",
                toolCallId: "call-1"
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "persisted-tools-assistant-tools")
        XCTAssertEqual(groups.first?.anchorMessageID, "assistant-tools")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["call-1", "call-2"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["terminal", "read_file"])
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "/Users/uzair/project")
        XCTAssertEqual(groups.first?.toolCalls.first?.args?["command"], .string("pwd"))
        XCTAssertEqual(groups.first?.toolCalls.last?.args?["path"], .string("CURRENT.md"))
        XCTAssertEqual(groups.first?.isComplete, true)
    }

    func testContentArrayDisplaysTextAndPreservesToolParts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let message = try decoder.decode(ChatMessage.self, from: Data("""
        {
          "role": "assistant",
          "message_id": "assistant-array",
          "content": [
            {
              "type": "tool_use",
              "id": "toolu-1",
              "name": "search_files",
              "input": { "pattern": "*.md" }
            },
            {
              "type": "text",
              "text": "File search finished."
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(message.content, "File search finished.")
        XCTAssertEqual(message.contentParts?.count, 2)
    }

    func testAnthropicToolUseContentArrayBuildsActivityGroup() {
        let messages = [
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                contentParts: [
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-search-files"),
                        "name": .string("search_files"),
                        "input": .object([
                            "pattern": .string("*.md")
                        ])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-web-search"),
                        "name": .string("web_search"),
                        "input": .object([
                            "query": .string("Google AI updates 2026")
                        ])
                    ])
                ]
            ),
            ChatMessage(
                role: "user",
                content: nil,
                timestamp: 1_770_000_002,
                messageId: "tool-results",
                contentParts: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-search-files"),
                        "content": .string("Timed out after 60s searching /Users/hermes")
                    ]),
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-web-search"),
                        "content": .array([
                            .object(["text": .string("Live web result")])
                        ])
                    ])
                ]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "assistant-tools")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["toolu-search-files", "toolu-web-search"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["search_files", "web_search"])
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "Timed out after 60s searching /Users/hermes")
        XCTAssertEqual(groups.first?.toolCalls.last?.preview, "Live web result")
        XCTAssertEqual(groups.first?.toolCalls.first?.args?["pattern"], .string("*.md"))
        XCTAssertEqual(groups.first?.toolCalls.last?.args?["query"], .string("Google AI updates 2026"))
    }

    func testAnthropicToolUseSnapshotsCoalesceIntoOneTurnActivity() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Check option 2",
                timestamp: 1_770_000_000,
                messageId: "user-option"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-skills",
                contentParts: [
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-skill-xurl"),
                        "name": .string("skill_view"),
                        "input": .object(["name": .string("xurl")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-skill-xitter"),
                        "name": .string("skill_view"),
                        "input": .object(["name": .string("xitter")])
                    ])
                ]
            ),
            ChatMessage(
                role: "user",
                content: nil,
                timestamp: 1_770_000_002,
                messageId: "tool-results",
                contentParts: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-skill-xurl"),
                        "content": .string("X/Twitter via xurl CLI")
                    ]),
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-skill-xitter"),
                        "content": .string("Interact with X/Twitter via x-cli")
                    ])
                ]
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_003,
                messageId: "assistant-snapshot",
                contentParts: [
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-skill-xurl"),
                        "name": .string("skill_view"),
                        "input": .object(["name": .string("xurl")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-skill-xitter"),
                        "name": .string("skill_view"),
                        "input": .object(["name": .string("xitter")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal-xurl"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("which xurl")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal-xcli"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("which x-cli")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal-version"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("x --version")])
                    ])
                ]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "assistant-skills")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 5 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), [
            "toolu-skill-xurl",
            "toolu-skill-xitter",
            "toolu-terminal-xurl",
            "toolu-terminal-xcli",
            "toolu-terminal-version"
        ])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), [
            "skill_view",
            "skill_view",
            "terminal",
            "terminal",
            "terminal"
        ])
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "X/Twitter via xurl CLI")
    }

    func testPersistedToolCallsPointingAtToolResultRowsAnchorToAssistantTurn() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Use terminal and search files",
                timestamp: 1_770_000_000,
                messageId: "user-tools"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                contentParts: [
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("ls -la")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-search"),
                        "name": .string("search_files"),
                        "input": .object(["pattern": .string("config.yaml")])
                    ])
                ]
            ),
            ChatMessage(
                role: "user",
                content: nil,
                timestamp: 1_770_000_002,
                messageId: "tool-results",
                contentParts: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-terminal"),
                        "content": .string("81 entries")
                    ]),
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-search"),
                        "content": .string("5 matches")
                    ])
                ]
            ),
            ChatMessage(
                role: "assistant",
                content: "Both tools are operational.",
                timestamp: 1_770_000_003,
                messageId: "assistant-final"
            )
        ]
        let persistedToolCalls = [
            PersistedToolCall(
                name: "terminal",
                snippet: "81 entries",
                tid: "toolu-terminal",
                assistantMsgIdx: 1,
                args: ["command": .string("ls -la")]
            ),
            PersistedToolCall(
                name: "search_files",
                snippet: "5 matches",
                tid: "toolu-search",
                assistantMsgIdx: 2,
                args: ["pattern": .string("config.yaml")]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: persistedToolCalls,
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "assistant-tools")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["toolu-terminal", "toolu-search"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["terminal", "search_files"])
    }

    func testGeneratedLiveFallbackMergesWithCompletedTurnActivity() {
        let messages = [
            ChatMessage(
                role: "user",
                content: "Check option 2",
                timestamp: 1_770_000_000,
                messageId: "user-option"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-skills"
            )
        ]
        let completedGroup = ToolCallGroup(
            id: "persisted-tools-assistant-skills",
            anchorMessageID: "assistant-skills",
            toolCalls: [
                ToolCall(
                    id: "toolu-skill-xurl",
                    name: "skill_view",
                    preview: "X/Twitter via xurl CLI",
                    args: ["name": .string("xurl")],
                    isCompleted: true
                )
            ]
        )
        let liveFallbackGroup = ToolCallGroup(
            id: "completed-live-tools-assistant-skills",
            anchorMessageID: "assistant-skills",
            toolCalls: [
                ToolCall(
                    name: "skill_view",
                    preview: "xurl",
                    args: ["name": .string("xurl")],
                    isCompleted: true
                ),
                ToolCall(
                    name: "terminal",
                    preview: "xurl not installed",
                    args: ["command": .string("which xurl")],
                    isCompleted: true
                )
            ]
        )

        let groups = ToolCallGroup.coalescingByAssistantTurn(
            ToolCallGroup.merging(
                primaryGroups: [completedGroup],
                fallbackGroups: [liveFallbackGroup]
            ),
            messages: messages
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["skill_view", "terminal"])
        XCTAssertEqual(groups.first?.toolCalls.first?.id, "toolu-skill-xurl")
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "X/Twitter via xurl CLI")
        XCTAssertEqual(groups.first?.toolCalls.last?.preview, "xurl not installed")
    }

    func testMergingToolCallsPreservesErrorState() {
        let completedGroup = ToolCallGroup(
            id: "persisted-tools-assistant-tools",
            anchorMessageID: "assistant-tools",
            toolCalls: [
                ToolCall(
                    id: "call-terminal",
                    name: "terminal",
                    preview: "date",
                    args: ["command": .string("date")],
                    isError: false,
                    isCompleted: true
                )
            ]
        )
        let liveFallbackGroup = ToolCallGroup(
            id: "completed-live-tools-assistant-tools",
            anchorMessageID: "assistant-tools",
            toolCalls: [
                ToolCall(
                    id: "call-terminal",
                    name: "terminal",
                    preview: "command failed",
                    args: ["command": .string("date")],
                    isError: true,
                    isCompleted: true
                )
            ]
        )

        let groups = ToolCallGroup.merging(
            primaryGroups: [completedGroup],
            fallbackGroups: [liveFallbackGroup]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.toolCalls.count, 1)
        XCTAssertEqual(groups.first?.toolCalls.first?.isError, true)
    }

    func testToolCallStatusDisplayHidesCompletedCollapsedText() {
        let display = ToolCallStatusDisplay(
            toolCall: ToolCall(
                name: "terminal",
                preview: nil,
                args: nil,
                duration: 1.24,
                isCompleted: true
            )
        )

        XCTAssertNil(display.collapsedText)
        XCTAssertEqual(display.detailText, "Completed in 1.2s")
    }

    func testToolCallStatusDisplayShowsRunningCollapsedText() {
        let display = ToolCallStatusDisplay(
            toolCall: ToolCall(
                name: "search_files",
                preview: nil,
                args: nil,
                isCompleted: false
            )
        )

        XCTAssertEqual(display.collapsedText, "Running")
        XCTAssertEqual(display.detailText, "Running")
    }

    func testToolCallStatusDisplayShowsFailedCollapsedText() {
        let display = ToolCallStatusDisplay(
            toolCall: ToolCall(
                name: "skill_view",
                preview: nil,
                args: nil,
                duration: 0.8,
                isError: true,
                isCompleted: true
            )
        )

        XCTAssertEqual(display.collapsedText, "Failed")
        XCTAssertEqual(display.detailText, "Failed")
    }

    func testToolCallDisplayFormatterParsesTerminalJSONOutput() {
        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: #"{"output":"line one\nline two\n","exit_code":0,"error":null}"#,
            toolName: "terminal"
        )

        XCTAssertEqual(display?.title, "Result")
        XCTAssertEqual(display?.text, "line one\nline two")
        XCTAssertEqual(display?.isMonospaced, true)
    }

    func testToolCallDisplayFormatterParsesEscapedTerminalJSONOutput() {
        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: #"{\"output\":\"pwd\n\",\"exit_code\":0,\"error\":null}"#,
            toolName: "terminal"
        )

        XCTAssertEqual(display?.text, "pwd")
    }

    func testToolCallDisplayFormatterToleratesOutOfRangeExitCode() {
        // An exit code beyond Int range comes straight from tool output and
        // used to trap while rendering the card (#62).
        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: #"{"output":"done\n","exit_code":1e300,"error":null}"#,
            toolName: "terminal"
        )

        XCTAssertEqual(display?.text, "done")
    }

    func testToolCallDisplayFormatterFallsBackToOriginalPreviewWhenParsingFails() {
        let preview = #"{"output": "unterminated""#

        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: preview,
            toolName: "web_search"
        )

        XCTAssertEqual(display?.text, preview)
        XCTAssertEqual(display?.isMonospaced, false)
    }

    func testToolCallDisplayFormatterShowsNestedArgumentsReadably() {
        let rows = ToolCallDisplayFormatter.argumentRows(from: [
            "input": .object([
                "path": .string("Sources"),
                "options": .object([
                    "recursive": .bool(true)
                ]),
                "patterns": .array([
                    .string("*.swift"),
                    .string("*.md")
                ])
            ])
        ])

        XCTAssertEqual(rows.first?.key, "input")
        XCTAssertEqual(rows.first?.value, """
        options:
          recursive: true
        path: Sources
        patterns:
          - *.swift
          - *.md
        """)
    }

    func testToolCallDisplayFormatterFormatsStructuredNonTerminalResults() {
        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: #"{"results":[{"title":"Hermes WebUI","url":"https://example.com","snippet":"Agent UI"}]}"#,
            toolName: "web_search"
        )

        let text = display?.text ?? ""
        XCTAssertTrue(text.contains("title: Hermes WebUI"))
        XCTAssertTrue(text.contains("url: https://example.com"))
        XCTAssertFalse(text.contains(#"{"title""#))
        XCTAssertFalse(text.contains(#"\"title\""#))
    }

    func testToolCallDisplayFormatterPrefersStructuredResultOverTerminalKeysForNonTerminalTools() {
        let display = ToolCallDisplayFormatter.resultDisplay(
            preview: #"{"results":[{"title":"Hermes WebUI","url":"https://example.com","snippet":"Agent UI"}],"exit_code":0,"error":null}"#,
            toolName: "web_search"
        )

        let text = display?.text ?? ""
        XCTAssertTrue(text.contains("title: Hermes WebUI"))
        XCTAssertTrue(text.contains("url: https://example.com"))
        XCTAssertFalse(text.contains("Exit code: 0"))
    }

    func testOpenAIToolRowsWithNilMessageIDsUseRawIndexAnchors() {
        let finalAnswer = "Both tools are operational."
        let messages = [
            ChatMessage(
                role: "user",
                content: "Use terminal and search files",
                timestamp: nil,
                messageId: nil
            ),
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: nil,
                messageId: nil,
                toolCalls: [
                    .object([
                        "id": .string("functions.terminal:1"),
                        "function": .object([
                            "name": .string("terminal"),
                            "arguments": .string(#"{"command":"ls -la"}"#)
                        ])
                    ])
                ],
                reasoning: "The user wants me to use terminal and search_files. I should run a quick command to show both work."
            ),
            ChatMessage(
                role: "tool",
                content: #"{"success":true,"output":"81 entries"}"#,
                timestamp: nil,
                messageId: nil,
                toolCallId: "functions.terminal:1"
            ),
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: nil,
                messageId: nil,
                toolCalls: [
                    .object([
                        "id": .string("functions.search_files:2"),
                        "function": .object([
                            "name": .string("search_files"),
                            "arguments": .string(#"{"pattern":"config.yaml"}"#)
                        ])
                    ])
                ],
                reasoning: "Terminal works. Now run search_files to show that works too."
            ),
            ChatMessage(
                role: "tool",
                content: #"{"success":true,"total_count":5}"#,
                timestamp: nil,
                messageId: nil,
                toolCallId: "functions.search_files:2"
            ),
            ChatMessage(
                role: "assistant",
                content: finalAnswer,
                timestamp: nil,
                messageId: nil,
                reasoning: """
                The user wants me to use terminal and search_files. I should run a quick command to show both work.
                Terminal works. Now run search_files to show that works too.
                Both tools worked. I should give a concise summary.

                \(finalAnswer)
                """
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: 4
        )
        let reasoningGroups = ChatViewModel.reasoningDisplayGroups(
            messages: messages,
            messageOffset: 4,
            archivedGroups: []
        )
        let transcriptMessages = ChatViewModel.transcriptMessages(from: messages, messageOffset: 4)

        XCTAssertEqual(transcriptMessages.map(\.anchorID), ["raw:4", "raw:5", "raw:7", "raw:9"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "raw:5")
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["functions.terminal:1", "functions.search_files:2"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["terminal", "search_files"])
        XCTAssertEqual(reasoningGroups.map(\.anchorMessageID), ["raw:5", "raw:7", "raw:9"])
        XCTAssertEqual(reasoningGroups[0].text, "The user wants me to use terminal and search_files. I should run a quick command to show both work.")
        XCTAssertEqual(reasoningGroups[1].text, "Terminal works. Now run search_files to show that works too.")
        XCTAssertTrue(reasoningGroups[2].text.contains("Both tools worked. I should give a concise summary."))
        XCTAssertFalse(reasoningGroups[2].text.contains(finalAnswer))
    }

    func testPartialPersistedToolCallsMergeMissingMessageToolCalls() {
        let messages = [
            ChatMessage(
                role: "assistant",
                content: "",
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                toolCalls: [
                    .object([
                        "id": .string("call-terminal"),
                        "function": .object([
                            "name": .string("terminal"),
                            "arguments": .string(#"{"command":"date"}"#)
                        ])
                    ]),
                    .object([
                        "id": .string("call-web-search"),
                        "function": .object([
                            "name": .string("web_search"),
                            "arguments": .string(#"{"query":"I/O 2026 search updates"}"#)
                        ])
                    ])
                ]
            )
        ]
        let persistedToolCalls = [
            PersistedToolCall(
                name: "terminal",
                snippet: "Mon May 25 13:07:35 EDT 2026",
                tid: "call-terminal",
                assistantMsgIdx: 0,
                args: ["command": .string("date")]
            )
        ]

        let groups = ToolCallGroup.groups(
            persistedToolCalls: persistedToolCalls,
            messages: messages,
            messageOffset: nil
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(groups.first?.toolCalls.map(\.id), ["call-terminal", "call-web-search"])
        XCTAssertEqual(groups.first?.toolCalls.map(\.name), ["terminal", "web_search"])
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, "Mon May 25 13:07:35 EDT 2026")
        XCTAssertEqual(groups.first?.toolCalls.last?.args?["query"], .string("I/O 2026 search updates"))
    }

    func testLiveToolCallGroupUsesStableAnchorKeyAndPreservesToolIDs() {
        let toolCalls = [
            ToolCall(
                id: "terminal-1",
                name: "terminal",
                preview: "Running tests",
                args: nil,
                isCompleted: false
            ),
            ToolCall(
                id: "read-file-1",
                name: "read_file",
                preview: "File contents",
                args: nil,
                isError: true,
                isCompleted: true
            )
        ]

        let anchoredGroup = ToolCallGroup.live(
            anchorMessageID: "assistant-live",
            toolCalls: toolCalls
        )
        let unanchoredGroup = ToolCallGroup.live(
            anchorMessageID: nil,
            toolCalls: toolCalls
        )

        XCTAssertEqual(anchoredGroup.id, "live-tools-assistant-live")
        XCTAssertEqual(anchoredGroup.anchorMessageID, "assistant-live")
        XCTAssertEqual(anchoredGroup.activityTitle, "Activity: 2 tools")
        XCTAssertEqual(anchoredGroup.toolCalls.map(\.id), ["terminal-1", "read-file-1"])
        XCTAssertEqual(anchoredGroup.isComplete, false)
        XCTAssertEqual(anchoredGroup.hasFailedTool, true)
        XCTAssertEqual(unanchoredGroup.id, "live-tools-unanchored")
    }
}
