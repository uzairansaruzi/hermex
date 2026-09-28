import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientChatEndpointTests: APIClientTestCase {
    func testStartChatBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["message"] as? String, "Please try again")
            XCTAssertEqual(body?["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body?["model"] as? String, "gpt-5.4")

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-123",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-abc",
            message: "Please try again",
            workspace: "/tmp/workspace",
            model: "gpt-5.4"
        )

        XCTAssertEqual(response.streamId, "stream-123")
        XCTAssertEqual(response.sessionId, "session-abc")
    }

    func testStartChatIncludesAttachmentPayloads() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["message"] as? String, "Summarize this CSV\n\n[Attached files: /tmp/workspace/data.csv]")
            let attachments = try XCTUnwrap(body["attachments"] as? [[String: Any]])
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachments.first?["name"] as? String, "data.csv")
            XCTAssertEqual(attachments.first?["path"] as? String, "/tmp/workspace/data.csv")
            XCTAssertEqual(attachments.first?["mime"] as? String, "text/csv")
            XCTAssertEqual(attachments.first?["size"] as? Double, 42)
            XCTAssertEqual(attachments.first?["is_image"] as? Bool, false)

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-123",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-abc",
            message: "Summarize this CSV\n\n[Attached files: /tmp/workspace/data.csv]",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            attachments: [
                .object([
                    "name": .string("data.csv"),
                    "path": .string("/tmp/workspace/data.csv"),
                    "mime": .string("text/csv"),
                    "size": .number(42),
                    "is_image": .bool(false)
                ])
            ]
        )

        XCTAssertEqual(response.streamId, "stream-123")
        XCTAssertEqual(response.sessionId, "session-abc")
    }

    func testStartChatIncludesProviderAndProfileContext() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["session_id"] as? String, "session-openrouter")
            XCTAssertEqual(body["message"] as? String, "Use the selected profile model")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "deepseek/deepseek-chat-v3-0324:free")
            XCTAssertEqual(body["model_provider"] as? String, "openrouter")
            XCTAssertEqual(body["profile"] as? String, "work")
            XCTAssertNil(body["modelProvider"])
            XCTAssertNil(body["explicit_model_pick"])

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-openrouter",
              "session_id": "session-openrouter"
            }
            """, for: request)
        }

        let response = try await client.startChat(
            sessionID: "session-openrouter",
            message: "Use the selected profile model",
            workspace: "/tmp/workspace",
            model: "deepseek/deepseek-chat-v3-0324:free",
            modelProvider: "openrouter",
            profile: "work"
        )

        XCTAssertEqual(response.streamId, "stream-openrouter")
        XCTAssertEqual(response.sessionId, "session-openrouter")
    }

    func testStartChatIncludesExplicitModelPickOnlyWhenRequested() async throws {
        var requestCount = 0
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            XCTAssertEqual(request.httpMethod, "POST")

            requestCount += 1
            let body = try XCTUnwrap(apiTestJSONBody(from: request))
            XCTAssertEqual(body["model"] as? String, "gpt-5.4-mini")

            if requestCount == 1 {
                XCTAssertEqual(body["explicit_model_pick"] as? Bool, true)
            } else {
                XCTAssertNil(body["explicit_model_pick"])
            }

            return apiTestJSONResponse("""
            {
              "stream_id": "stream-\(requestCount)",
              "session_id": "session-abc"
            }
            """, for: request)
        }

        _ = try await client.startChat(
            sessionID: "session-abc",
            message: "Use the explicit model",
            workspace: "/tmp/workspace",
            model: "gpt-5.4-mini",
            explicitModelPick: true
        )
        _ = try await client.startChat(
            sessionID: "session-abc",
            message: "Use the ordinary model context",
            workspace: "/tmp/workspace",
            model: "gpt-5.4-mini"
        )

        XCTAssertEqual(requestCount, 2)
    }

    func testPendingAttachmentBuildsBrowserCompatibleChatMessageText() {
        let html = PendingAttachment(
            name: "sample.html",
            path: "/tmp/workspace/sample.html",
            mime: "text/html",
            size: 42,
            isImage: false,
            thumbnailData: nil
        )
        let image = PendingAttachment(
            name: "image.jpg",
            path: "/tmp/workspace/image.jpg",
            mime: "image/jpeg",
            size: 100,
            isImage: true,
            thumbnailData: Data()
        )

        let message = PendingAttachment.chatMessageText(
            draft: "Analyze these files",
            attachments: [html, image]
        )

        XCTAssertEqual(
            message,
            "Analyze these files\n\n[Attached files: /tmp/workspace/sample.html, /tmp/workspace/image.jpg]"
        )
    }

    func testChatAttachmentPreviewItemInfersImageMessageAttachment() {
        let item = ChatAttachmentPreviewItem(
            message: MessageAttachment(
                name: nil,
                path: "/tmp/workspace/photo.PNG",
                mime: nil,
                size: 128,
                isImage: nil
            ),
            localData: Data([0x01])
        )

        XCTAssertEqual(item.displayName, "photo.PNG")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/photo.PNG")
        XCTAssertTrue(item.inferredIsImage)
        XCTAssertFalse(item.isKnownUnsupportedBinary)
    }

    func testChatAttachmentPreviewItemUsesPendingFileMetadata() {
        let item = ChatAttachmentPreviewItem(
            pending: PendingAttachment(
                name: "report.pdf",
                path: "/tmp/workspace/report.pdf",
                mime: "application/pdf",
                size: 2_048,
                isImage: false,
                thumbnailData: nil
            )
        )

        XCTAssertEqual(item.displayName, "report.pdf")
        XCTAssertEqual(item.displayPath, "/tmp/workspace/report.pdf")
        XCTAssertFalse(item.inferredIsImage)
        XCTAssertTrue(item.isKnownUnsupportedBinary)
    }

    func testCancelChatBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/cancel")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["stream_id"], "stream-123")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "cancelled": true,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.cancelChat(streamID: "stream-123")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.cancelled, true)
        XCTAssertEqual(response.streamId, "stream-123")
    }

    func testChatStreamStatusBuildsExpectedQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat/stream/status")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["stream_id"], "stream-123")

            return apiTestJSONResponse("""
            {
              "active": true,
              "stream_id": "stream-123"
            }
            """, for: request)
        }

        let response = try await client.chatStreamStatus(streamID: "stream-123")

        XCTAssertEqual(response.active, true)
        XCTAssertEqual(response.streamId, "stream-123")
    }

    func testChatStreamURLUsesEndpointReplayQueryItems() {
        let client = makeClient { _ in
            throw URLError(.badURL)
        }
        let base = URL(string: "https://example.test")!

        XCTAssertEqual(
            client.chatStreamURL(streamID: "stream-123", replayAfterSeq: 4),
            Endpoint.chatStream(streamID: "stream-123", replayAfterSeq: 4).url(relativeTo: base)
        )
        XCTAssertEqual(
            client.chatStreamURL(streamID: "stream-123"),
            Endpoint.chatStream(streamID: "stream-123").url(relativeTo: base)
        )

        let replayQuery = queryDictionary(
            of: Endpoint.chatStream(streamID: "stream-123", replayAfterSeq: 4)
        )
        XCTAssertEqual(replayQuery["stream_id"], "stream-123")
        XCTAssertEqual(replayQuery["replay"], "1")
        XCTAssertEqual(replayQuery["after_seq"], "4")

        let liveQuery = queryDictionary(of: Endpoint.chatStream(streamID: "stream-123"))
        XCTAssertEqual(liveQuery["stream_id"], "stream-123")
        XCTAssertNil(liveQuery["replay"])
        XCTAssertNil(liveQuery["after_seq"])
    }

    private func queryDictionary(of endpoint: Endpoint) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value) })
    }
}
