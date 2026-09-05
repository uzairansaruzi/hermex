import XCTest
@testable import HermesMobile

/// Send-button gate for the composer: text-only, attachment-only, both, or
/// neither (#403). Busy flags always disable; attachment-only sends synthesize
/// their message text in `PendingAttachment.chatMessageText`.
final class ChatComposerSendGateTests: XCTestCase {
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
