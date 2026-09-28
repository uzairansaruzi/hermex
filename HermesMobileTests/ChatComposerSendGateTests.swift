import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

/// Send-button gate for the composer: text-only, attachment-only, both, or
/// neither (#403). Busy flags always disable; attachment-only sends synthesize
/// their message text in `PendingAttachment.chatMessageText`.
final class ChatComposerSendGateTests: XCTestCase {
    func testQuoteOnlyDraftShowsSendWhileStreamIsActive() {
        XCTAssertFalse(ChatComposerSendGate.showsStopButton(
            isWaitingForStream: true,
            hasText: false,
            hasQuotes: true
        ))
        XCTAssertTrue(ChatComposerSendGate.showsStopButton(
            isWaitingForStream: true,
            hasText: false,
            hasQuotes: false
        ))
    }

    func testQuoteOnlySendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasQuotes: true,
            hasStagedAttachments: false,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
    }

    func testAttachmentOnlySendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
    }

    func testTextOnlySendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: false,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
    }

    func testTextAndAttachmentsSendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
    }

    func testEmptyDraftWithNoAttachmentsIsDisabled() {
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasStagedAttachments: false,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
    }

    func testAttachmentWhileUploadingIsDisabled() {
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: true,
            isUpdatingConfiguration: false
        ))
    }

    func testBusyFlagsDisableEvenWithContent() {
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: true,
            isSending: true,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: true,
            isUploadingAttachment: false,
            isUpdatingConfiguration: false
        ))
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: true,
            isUpdatingConfiguration: false
        ))
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: true,
            hasStagedAttachments: true,
            isSending: false,
            isCompressingSession: false,
            isUploadingAttachment: false,
            isUpdatingConfiguration: true
        ))
    }
}

final class HermexAttachmentPickerPolicyTests: XCTestCase {
    func testMenuUsesBalancedLeftPlacement() {
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: 390), 280)
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuLeadingPadding, 12)
        XCTAssertEqual(HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: 250), 226)
    }

    func testCapacityNeverDropsBelowZero() {
        XCTAssertEqual(HermexAttachmentPickerPolicy.availableCapacity(existingCount: 0), 8)
        XCTAssertEqual(HermexAttachmentPickerPolicy.availableCapacity(existingCount: 7), 1)
        XCTAssertEqual(HermexAttachmentPickerPolicy.availableCapacity(existingCount: 12), 0)
        XCTAssertEqual(
            HermexAttachmentPickerPolicy.availableCapacity(
                existingCount: 7,
                maximum: HermexAttachmentPickerPolicy.maximumSessionImages
            ),
            3
        )
    }

    func testSelectionPreservesOrderAndHonorsCapacity() {
        var selection: [String] = []
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "a", capacity: 2)
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "b", capacity: 2)
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "c", capacity: 2)
        XCTAssertEqual(selection, ["a", "b"])

        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "a", capacity: 2)
        XCTAssertEqual(selection, ["b"])
    }

    func testLibraryRefreshRemovesInvisibleSelectionsWithoutReorderingSurvivors() {
        let selected = ["first", "removed", "last"]
        XCTAssertEqual(
            HermexAttachmentPickerPolicy.visibleSelection(selected, visibleIDs: ["last", "first"]),
            ["first", "last"]
        )
        XCTAssertTrue(HermexAttachmentPickerPolicy.visibleSelection(selected, visibleIDs: []).isEmpty)
    }

    func testLifecycleFenceRejectsLateCompletion() {
        var fence = HermexAttachmentLifecycleFence()
        let first = fence.begin()
        let second = fence.begin()
        XCTAssertFalse(fence.consume(first))
        XCTAssertTrue(fence.consume(second))
        XCTAssertFalse(fence.consume(second))

        let cancelled = fence.begin()
        fence.invalidate()
        XCTAssertFalse(fence.consume(cancelled))
    }

    func testCameraPermissionPolicyCoversDeniedAndRestrictedStates() {
        XCTAssertEqual(HermexAttachmentCameraPermissionPolicy.status(for: .authorized), .configuring)
        XCTAssertEqual(HermexAttachmentCameraPermissionPolicy.status(for: .notDetermined), .requestingPermission)
        XCTAssertEqual(HermexAttachmentCameraPermissionPolicy.status(for: .denied), .denied)
        XCTAssertEqual(HermexAttachmentCameraPermissionPolicy.status(for: .restricted), .restricted)
    }

    /// Detaching the preview makes AVCaptureSession rebuild its graph and wait
    /// for it; on device that held the main thread for ~9 s after leaving the
    /// camera (#809). The detach must happen off the main thread.
    @MainActor
    func testCameraPreviewDetachesOffTheMainThread() {
        let controller = HermexAttachmentCameraController()
        let layer = AVCaptureVideoPreviewLayer(session: controller.session)
        let detached = expectation(description: "preview layer detached")
        var detachedOnMain: Bool?
        let observation = layer.observe(\.session, options: [.new]) { layer, _ in
            guard layer.session == nil else { return }
            detachedOnMain = Thread.isMainThread
            detached.fulfill()
        }

        controller.detachPreviewLayer(layer)

        wait(for: [detached], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(detachedOnMain, false)
        XCTAssertNil(layer.session)
    }

    @MainActor
    func testImageProcessorNormalizesSelectedMediaToBoundedJPEG() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }

        let media = try await HermexAttachmentImageProcessor.prepare(
            data: source,
            filename: "Screenshot.png"
        )

        XCTAssertEqual(media.filename, "Screenshot.jpg")
        XCTAssertFalse(media.data.isEmpty)
        XCTAssertLessThanOrEqual(media.data.count, 8 * 1_024 * 1_024)
        XCTAssertNotNil(UIImage(data: media.data))
    }

    @MainActor
    func testImageProcessorPreservesTransparency() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        }

        let media = try await HermexAttachmentImageProcessor.prepare(
            data: source,
            filename: "Transparent.png"
        )

        XCTAssertEqual(media.filename, "Transparent.png")
        XCTAssertNotNil(UIImage(data: media.data))
    }
}
