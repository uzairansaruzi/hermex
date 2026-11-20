import Foundation

enum ComposerRecall {
    static let commandTitle = String(localized: "Recall Last Message")

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
