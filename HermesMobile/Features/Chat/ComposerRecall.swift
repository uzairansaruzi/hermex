import Foundation

/// What ↑ in an empty composer brings back on a hardware keyboard: the last
/// message the user sent in this chat. It is read from the chat's own
/// transcript, so it survives leaving the chat and relaunching the app, and it
/// is per chat and per server by construction.
enum ComposerRecall {
    /// The ↑ command's name in the iPad ⌘ overlay.
    static let commandTitle = String(localized: "Recall Last Message")

    /// The newest message the user wrote, as the text they typed, or nil when
    /// they have sent nothing here. Scans from the end, skipping every row the
    /// user didn't write: other roles, and Bot system deliveries (a display
    /// kind other than a steer). A steer loses its out-of-band wrapper and a
    /// send loses its `[Attached files: …]` marker; an attachment-only send has
    /// no typed text left, so the message before it wins.
    static func lastSentText(in messages: [ChatMessage]) -> String? {
        for message in messages.reversed() {
            guard message.role == "user",
                  message.displayKind == nil || message.displayKind == ChatMessage.steerDisplayKind,
                  let content = message.content
            else {
                continue
            }

            let typed = MessageAttachment.contentWithoutAttachedFilesMarker(
                in: ChatMessage.strippedSteerText(from: content) ?? content
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !typed.isEmpty, !PendingAttachment.isAttachmentOnlyMessageText(typed) else { continue }
            return typed
        }
        return nil
    }
}
