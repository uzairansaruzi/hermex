import SwiftUI

/// One user-written reply for the chip row above the Bot Chat composer. The id
/// is minted once when the reply is created, so list identity never churns.
struct BotQuickReply: Codable, Identifiable, Hashable {
    let id: String
    var text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id
        self.text = text
    }
}

/// Quick replies are device-local and global: one JSON string under one
/// `@AppStorage` key, the same list for every server, connection and Profile.
/// The host has no saved-prompt store to share, and the text is the user's
/// own rather than server data (`docs/agents/multi-server-state-isolation.md`).
enum BotQuickReplyStore {
    static let storageKey = "botQuickReplies"

    /// Reads the stored list. An empty or unreadable value is an empty list;
    /// entries with a blank id or text, and repeats of an id, are dropped.
    static func decode(_ raw: String) -> [BotQuickReply] {
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let id = entry.id, let text = entry.text,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted else { return nil }
            return BotQuickReply(id: id, text: text)
        }
    }

    static func encode(_ replies: [BotQuickReply]) -> String {
        guard let data = try? JSONEncoder().encode(replies) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One stored element. Any shape decodes; a field of the wrong type is nil.
    private struct Entry: Decodable {
        let id: String?
        let text: String?

        private enum CodingKeys: String, CodingKey { case id, text }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? container?.decodeIfPresent(String.self, forKey: .id)
            text = try? container?.decodeIfPresent(String.self, forKey: .text)
        }
    }
}

/// When the chip row may stand in the status pill's slot: only when there is
/// nothing else to act on, so the pill and the chips never stack and a chip can
/// never land on top of work the user already started.
enum BotQuickReplyPolicy {
    static func showsRow(replies: [BotQuickReply], draft: String, hasQuotes: Bool, hasAttachments: Bool,
                         maySend: Bool, hasPendingRequest: Bool, hasPill: Bool) -> Bool {
        !replies.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasQuotes && !hasAttachments && maySend && !hasPendingRequest && !hasPill
    }
}

/// Starters the Settings editor offers. Adding one saves its localized text as
/// a plain reply the user owns; nothing keeps it tied to the suggestion.
enum BotQuickReplySuggestion: CaseIterable, Identifiable {
    case continueWork, runTests, summarize

    var id: Self { self }

    var text: String {
        switch self {
        case .continueWork: String(localized: "Continue")
        case .runTests: String(localized: "Run the tests")
        case .summarize: String(localized: "Summarize")
        }
    }
}

/// The chips above the Bot Chat composer: one line each, scrolling sideways.
/// A tap hands the reply to the composer, which fills the draft; it never sends.
struct BotQuickReplyRow: View {
    let replies: [BotQuickReply]
    let onPick: (BotQuickReply) -> Void

    @ScaledMetric(relativeTo: .footnote) private var chipMaxWidth: CGFloat = 210

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(replies) { reply in
                    Button { onPick(reply) } label: {
                        Text(verbatim: reply.text)
                            .font(AppFont.footnote())
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: chipMaxWidth)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.primary.opacity(0.10), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: reply.text))
                    .accessibilityHint(Text("Fills the draft without sending"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Quick Replies"))
        .accessibilityIdentifier("bot-quick-replies")
    }
}
