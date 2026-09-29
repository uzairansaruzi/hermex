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

    /// Mid-run, Send's glyph and VoiceOver label say what a tap will do to the
    /// response (#858). Idle it is the plain arrow; with an empty draft the
    /// circle stays Stop.
    func testRunningSendShowsDefaultBehaviorGlyphAndLabel() {
        let expected: [(StreamingSendBehavior, glyph: String, label: String)] = [
            (.steer, "arrow.turn.up.right", "Steer active response"),
            (.queue, "text.append", "Send after response"),
            (.interrupt, "stop.circle", "Stop and send")
        ]
        for (behavior, glyph, label) in expected {
            let running = ChatComposerSendButton(
                isWaitingForStream: true, hasText: true, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(running.systemName, glyph, "\(behavior)")
            XCTAssertEqual(running.accessibilityLabel, label, "\(behavior)")

            let quoteOnly = ChatComposerSendButton(
                isWaitingForStream: true, hasText: false, hasQuotes: true, defaultBehavior: behavior
            )
            XCTAssertEqual(quoteOnly.systemName, glyph, "\(behavior)")

            let idle = ChatComposerSendButton(
                isWaitingForStream: false, hasText: true, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(idle.systemName, "arrow.up", "\(behavior)")
            XCTAssertEqual(idle.accessibilityLabel, "Send", "\(behavior)")

            let stop = ChatComposerSendButton(
                isWaitingForStream: true, hasText: false, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(stop.systemName, "stop.fill", "\(behavior)")
            XCTAssertEqual(stop.accessibilityLabel, "Stop response", "\(behavior)")
        }
    }

    /// A long-press offers every behavior, in the Bot card's order, only while
    /// Send shows mid-run. Staged files are deliberately not an input: unlike
    /// Bots (`BotPromptMode.busyChoices(hasAttachments:)`), Sessions keep Steer
    /// with files staged, because #856 sends them with the steer as a note.
    func testRunningSendOffersEveryChoiceAndIdleOrStopOffersNone() {
        for behavior in StreamingSendBehavior.allCases {
            let running = ChatComposerSendButton(
                isWaitingForStream: true, hasText: true, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(running.choices, [.steer, .queue, .interrupt], "\(behavior)")
            XCTAssertEqual(running.choices.map(\.title), ["Steer", "Queue", "Stop and send"])

            let idle = ChatComposerSendButton(
                isWaitingForStream: false, hasText: true, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(idle.choices, [], "a long-press adds nothing while idle")

            let stop = ChatComposerSendButton(
                isWaitingForStream: true, hasText: false, hasQuotes: false, defaultBehavior: behavior
            )
            XCTAssertEqual(stop.choices, [], "Stop has no choices")
        }
    }

    /// A quick tap acts; the release of a hold that opened the card does not,
    /// and only that one release is dropped.
    func testHoldReleaseIsDroppedAndQuickTapActs() {
        var hold = ChatComposerSendHold()
        hold.pressBegan()
        XCTAssertTrue(hold.activate(), "a quick tap")

        hold.pressBegan()
        hold.openedChoices()
        XCTAssertFalse(hold.activate(), "the hold's own release")
        XCTAssertTrue(hold.activate(), "the next activation")
    }

    /// A hold released off Send never reaches the Button, so closing the card
    /// clears the mark. Otherwise the next VoiceOver or keyboard activation,
    /// which has no touch-down, would do nothing. A finger still down (the run
    /// ended under it) keeps its release dropped.
    func testClosingTheCardAfterLiftingOffSendKeepsTheNextActivation() {
        var liftedOff = ChatComposerSendHold()
        liftedOff.pressBegan()
        liftedOff.openedChoices()
        liftedOff.choicesClosed(isPressing: false)
        XCTAssertTrue(liftedOff.activate(), "an activation after the card closed")

        var stillHeld = ChatComposerSendHold()
        stillHeld.pressBegan()
        stillHeld.openedChoices()
        stillHeld.choicesClosed(isPressing: true)
        XCTAssertFalse(stillHeld.activate(), "the held finger's release")
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
