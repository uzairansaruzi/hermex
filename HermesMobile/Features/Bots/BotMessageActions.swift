import SwiftUI
import UIKit

/// The long-press actions a Bot transcript message offers.
///
/// Copy is the only action on every message, by the canonical-chat policy
/// settled in issue #481. The host can rewind and branch a Bot's history, but
/// Bot Chat does not offer edit, regenerate or branch yet (#745). The copied
/// text is the Markdown source the transcript rendered, so a code block pastes
/// as a code block. A Bot Chat prompt also gets the Tapback row and, once you
/// have reacted, Remove Reaction (#761).
@MainActor
enum BotMessageActions {
    /// Your side of a row's reactions, for the long-press menu.
    struct Reacting {
        /// Your current emoji on the row, if any.
        let current: String?
        /// Called with the emoji picked, or nil to remove yours.
        let react: (String?) -> Void
    }

    /// `copy` is injectable so a test can read the text without a pasteboard.
    static func items(
        copyText: String?,
        isHapticsEnabled: Bool,
        reacting: Reacting? = nil,
        copy: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) -> [ChatMessageActionItem] {
        var items: [ChatMessageActionItem] = []
        if let reacting {
            items += BotReaction.quickReactions.map { emoji in
                ChatMessageActionItem(
                    kind: .react(emoji),
                    title: String(localized: "React with \(emoji)"),
                    systemImage: "",
                    isEnabled: true,
                    perform: { reacting.react(emoji) },
                    isSelected: reacting.current == emoji
                )
            }
        }
        if let copyText, !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(ChatMessageActionItem(
                kind: .copy,
                title: String(localized: "Copy"),
                systemImage: "doc.on.doc",
                isEnabled: true,
                perform: {
                    copy(copyText)
                    ChatHaptics.copied(isEnabled: isHapticsEnabled)
                }
            ))
        }
        if let reacting, reacting.current != nil {
            items.append(ChatMessageActionItem(
                kind: .removeReaction,
                title: String(localized: "Remove Reaction"),
                systemImage: "minus.circle",
                isEnabled: true,
                perform: { reacting.react(nil) }
            ))
        }
        return items
    }
}

/// One Tapback on a Bot Chat row, as `display_metadata.reactions` and the
/// `message.react` reply carry it. The host keeps at most one per author, so a
/// row shows chips, never counts.
struct BotReaction: Hashable {
    enum Author: String { case user, agent }

    let emoji: String
    let author: Author

    /// Desktop's six quick reactions, in Apple's Tapback order (D26).
    static let quickReactions = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    /// The host's reaction list, read tolerantly: entries that aren't objects,
    /// have an empty emoji or an unknown author are dropped, and only the first
    /// entry per author counts.
    static func list(_ value: JSONValue?) -> [BotReaction] {
        guard case .array(let rows)? = value else { return [] }
        var seen = Set<Author>()
        return rows.compactMap { row in
            guard case .object(let fields) = row,
                  case .string(let rawEmoji)? = fields["emoji"],
                  case .string(let rawAuthor)? = fields["author"],
                  let author = Author(rawValue: rawAuthor),
                  !seen.contains(author) else { return nil }
            let emoji = rawEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !emoji.isEmpty else { return nil }
            seen.insert(author)
            return BotReaction(emoji: emoji, author: author)
        }
    }
}

extension ChatMessage {
    /// The row's reactions from `display_metadata.reactions`.
    var botReactions: [BotReaction] {
        BotReaction.list(displayMetadata?["reactions"])
    }

    /// This row with the host's reaction list in place of its own; an empty
    /// list removes the key, as the host does.
    func replacingBotReactions(_ reactions: JSONValue) -> ChatMessage {
        var metadata = displayMetadata ?? [:]
        if case .array(let rows) = reactions, !rows.isEmpty {
            metadata["reactions"] = reactions
        } else {
            metadata.removeValue(forKey: "reactions")
        }
        return ChatMessage(
            role: role, content: content, timestamp: timestamp, messageId: messageId, name: name,
            toolCallId: toolCallId, toolUseId: toolUseId, toolCalls: toolCalls, contentParts: contentParts,
            reasoning: reasoning, attachments: attachments, displayKind: displayKind,
            displayMetadata: metadata.isEmpty ? nil : metadata,
            turnTps: turnTps, turnDuration: turnDuration, rowID: rowID
        )
    }
}
