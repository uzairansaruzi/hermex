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
    /// user didn't write: other roles, Bot system deliveries (a display kind
    /// other than a steer), and the compaction markers the transcript draws as
    /// cards. A steer loses its out-of-band wrapper and a send loses its
    /// `[Attached files: …]` marker; an attachment-only send has no typed text
    /// left, so the message before it wins.
    ///
    /// - Parameter typedText: removes a surface's own attachment text from a
    ///   user row. Bot Chat passes `BotAttachmentUpload.typedText(of:)`.
    static func lastSentText(
        in messages: [ChatMessage],
        typedText: (String) -> String = { $0 }
    ) -> String? {
        for message in messages.reversed() {
            guard message.role == "user",
                  message.displayKind == nil || message.displayKind == ChatMessage.steerDisplayKind,
                  ChatMarkerMessageClassifier.classify(message) == nil,
                  let content = message.content
            else {
                continue
            }

            let typed = typedText(MessageAttachment.contentWithoutAttachedFilesMarker(
                in: ChatMessage.strippedSteerText(from: content) ?? content
            ))
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !typed.isEmpty, !PendingAttachment.isAttachmentOnlyMessageText(typed) else { continue }
            return typed
        }
        return nil
    }
}
