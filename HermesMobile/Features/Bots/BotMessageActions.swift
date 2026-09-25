import SwiftUI
import UIKit

/// The long-press actions a Bot transcript message offers.
///
/// Copy is the whole menu, by the canonical-chat policy settled in issue #481.
/// The host can rewind and branch a Bot's history, but Bot Chat does not offer
/// edit, regenerate or branch yet (#745). The copied text is the Markdown
/// source the transcript rendered, so a code block pastes as a code block.
@MainActor
enum BotMessageActions {
    /// `copy` is injectable so a test can read the text without a pasteboard.
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
