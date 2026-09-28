import Foundation

/// Decides whether the composer's Send/Stop action button is disabled.
/// Send is allowed when the user typed something, added a quote, or staged at
/// least one attachment. Attachment-only sends synthesize their message text in
/// `PendingAttachment.chatMessageText`; the busy flags always disable.
enum ChatComposerSendGate {
    static func showsStopButton(
        isWaitingForStream: Bool,
        hasText: Bool,
        hasQuotes: Bool
    ) -> Bool {
        isWaitingForStream && !hasText && !hasQuotes
    }

    static func isDisabled(
        hasText: Bool,
        hasQuotes: Bool = false,
        hasStagedAttachments: Bool,
        isSending: Bool,
        isCompressingSession: Bool,
        isUploadingAttachment: Bool,
        isUpdatingConfiguration: Bool
    ) -> Bool {
        guard !isSending, !isCompressingSession, !isUploadingAttachment, !isUpdatingConfiguration else {
            return true
        }

        return !hasText && !hasQuotes && !hasStagedAttachments
    }
}
