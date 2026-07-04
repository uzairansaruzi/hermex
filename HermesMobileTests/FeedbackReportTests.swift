import XCTest
import UIKit
@testable import HermesMobile

final class FeedbackReportTests: XCTestCase {
    func testAnnotationRectangleNormalizesDraggedBounds() {
        let annotation = FeedbackAnnotationRectangle(
            start: CGPoint(x: 80, y: 180),
            end: CGPoint(x: 20, y: 60),
            canvasSize: CGSize(width: 100, height: 200)
        )

        XCTAssertEqual(annotation.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(annotation.y, 0.3, accuracy: 0.0001)
        XCTAssertEqual(annotation.width, 0.6, accuracy: 0.0001)
        XCTAssertEqual(annotation.height, 0.6, accuracy: 0.0001)
        XCTAssertTrue(annotation.isVisibleMark)
    }

    func testAnnotationRectangleClampsOutsideDrag() {
        let annotation = FeedbackAnnotationRectangle(
            start: CGPoint(x: -50, y: -20),
            end: CGPoint(x: 250, y: 120),
            canvasSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(annotation.x, 0)
        XCTAssertEqual(annotation.y, 0)
        XCTAssertEqual(annotation.width, 1)
        XCTAssertEqual(annotation.height, 1)
    }

    func testFeedbackRequestPayloadEncodesExpectedShape() throws {
        let submission = FeedbackSubmission(
            text: "The composer overlapped the send button.",
            app: FeedbackAppMetadata(
                id: "zora-ios",
                name: "Zora",
                version: "1.4",
                build: "42",
                bundleId: "com.sourcebottle.hermex",
                platform: "ios"
            ),
            device: FeedbackDeviceMetadata(
                model: "iPhone",
                systemName: "iOS",
                systemVersion: "18.5",
                idiom: "phone"
            ),
            screen: FeedbackScreenMetadata(name: "SessionList"),
            screenshot: nil,
            annotation: FeedbackAnnotationPayload(rectangles: [
                FeedbackAnnotationRectangle(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, x: 0.1, y: 0.2, width: 0.3, height: 0.4)
            ])
        )

        let data = try JSONEncoder().encode(FeedbackRequestPayload(submission: submission))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "The composer overlapped the send button.")

        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(app["id"] as? String, "zora-ios")
        XCTAssertEqual(app["bundleId"] as? String, "com.sourcebottle.hermex")

        let screen = try XCTUnwrap(object["screen"] as? [String: Any])
        XCTAssertEqual(screen["name"] as? String, "SessionList")

        let annotation = try XCTUnwrap(object["annotation"] as? [String: Any])
        XCTAssertEqual(annotation["type"] as? String, "rectangle-markup")
        let rectangles = try XCTUnwrap(annotation["rectangles"] as? [[String: Any]])
        XCTAssertEqual(rectangles.count, 1)
        let x = try XCTUnwrap(rectangles[0]["x"] as? Double)
        XCTAssertEqual(x, 0.1, accuracy: 0.0001)
    }

    func testMockFeedbackClientReturnsSuccessfulResponse() async throws {
        let response = try await FeedbackClient.mockSuccess.submit(FeedbackSubmission(
            text: "It broke",
            app: FeedbackAppMetadata(id: "zora-ios", name: "Zora", version: "1", build: "1", bundleId: "com.sourcebottle.hermex", platform: "ios"),
            device: FeedbackDeviceMetadata(model: "iPhone", systemName: "iOS", systemVersion: "18", idiom: "phone"),
            screen: FeedbackScreenMetadata(name: "Test"),
            screenshot: nil,
            annotation: nil
        ))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.feedback?.status, "new")
    }

    func testFeedbackShakePresentationRefreshesResponderAfterSheetDismissal() {
        var presentation = FeedbackShakePresentationState()
        let initialRefreshID = presentation.responderRefreshID

        presentation.present(FeedbackDraft(screenName: "SessionList", screenshot: nil, capturedAt: Date()))
        XCTAssertNotNil(presentation.draft)
        XCTAssertEqual(presentation.responderRefreshID, initialRefreshID)

        presentation.feedbackSheetDismissed()
        let firstDismissalRefreshID = presentation.responderRefreshID
        XCTAssertNil(presentation.draft)
        XCTAssertNotEqual(firstDismissalRefreshID, initialRefreshID)

        presentation.present(FeedbackDraft(screenName: "Chat", screenshot: nil, capturedAt: Date()))
        XCTAssertNotNil(presentation.draft)
        XCTAssertEqual(presentation.responderRefreshID, firstDismissalRefreshID)

        presentation.feedbackSheetDismissed()
        XCTAssertNil(presentation.draft)
        XCTAssertNotEqual(presentation.responderRefreshID, initialRefreshID)
        XCTAssertNotEqual(presentation.responderRefreshID, firstDismissalRefreshID)
    }
}
