import SwiftUI
import UIKit

@MainActor
enum BotMessageActions {
    static func items(
        copyText: String?,
        isHapticsEnabled: Bool,
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) -> [ChatMessageActionItem] {
        guard let copyText, !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [ChatMessageActionItem(
            kind: .copy,
            title: String(localized: "Copy"),
            systemImage: "doc.on.doc",
            isEnabled: true,
            perform: {
                copy(copyText)
                ChatHaptics.copied(isEnabled: isHapticsEnabled)
            }
        )]
    }
}
