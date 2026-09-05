import Foundation

/// Decides whether the composer's Send/Stop action button is disabled.
/// Send is allowed when the user typed something OR staged at least one
/// attachment (attachment-only sends synthesize their message text in
/// `PendingAttachment.chatMessageText`); the busy flags always disable.
enum ChatComposerSendGate {
    static func isDisabled(
        hasText: Bool,
        hasStagedAttachments: Bool,
        isSending: Bool,
        isCompressingSession: Bool,
        isUploadingAttachment: Bool,
        isUpdatingConfiguration: Bool
    ) -> Bool {
        guard !isSending, !isCompressingSession, !isUploadingAttachment, !isUpdatingConfiguration else {
            return true
        }

        return !hasText && !hasStagedAttachments
    }
}
