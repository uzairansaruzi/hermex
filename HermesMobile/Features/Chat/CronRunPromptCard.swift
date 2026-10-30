import SwiftUI

/// A scheduled task's stored prompt row (#1413). Every cron run opens with the
/// host's `_CRON_HINT` runbook — delivery, silence, failure and recursion rules
/// the six-line fold would spend its preview on — so, like #1140's delegation
/// delivery, a host-authored row is not a user bubble: the card shows the job's
/// own text and keeps the hint one disclosure away.
///
/// Detection is grounded in the pinned hermes-agent construction
/// (`cron/scheduler_prompt.py`): the hint opens the stored row when the job has
/// no skills, and follows the leading slash-skill command(s)
/// (`HermesTranscriptProjection.skillInvocation`'s rewrite) when it has them.
/// Anything else — including a hint quoted mid-message — stays a bubble.
struct CronRunPrompt: Equatable, Sendable {
    /// The hint's exact opener at the pin. The runbook is one bracketed block
    /// (its `[SILENT]` / `[CRON_FAILURE]` tokens nest inside it), so scanning
    /// bracket depth from here finds its matching `]`.
    static let opener = "[IMPORTANT: You are running as a scheduled cron job."

    /// The skill command(s) the history rewrite left in front of the hint (a
    /// single `/name`, or a stacked bundle's `/a /b`); nil when the hint opens
    /// the row itself.
    let skillLabels: String?
    /// The text after the hint, line breaks as received (the skill path's
    /// rewrite has already collapsed whitespace).
    let body: String
    /// The unchanged app-visible input, which Copy keeps — hint and any skill
    /// normalization included. Byte-for-byte raw prompt recovery is out of scope.
    let appVisibleInput: String

    /// Parses a transcript row for a chat whose provenance is a cron run.
    /// `isCronRun` is the stable Boolean `ChatViewModel.isHermesCronRun` derives
    /// from the stored identity; unknown provenance falls back to the bubble.
    init?(message: ChatMessage, isCronRun: Bool) {
        guard isCronRun, message.role == "user" else { return nil }
        self.init(content: message.content ?? "")
    }

    /// Parses the display projection. A missing or unbalanced hint fails, and
    /// the row keeps the existing presentation.
    init?(content: String) {
        let text = Substring(content)
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        // The rewrite's leading command(s): `/name` tokens separated by single
        // spaces, ending exactly where the hint begins. Text anywhere else is
        // never scanned, so an ordinary message that merely quotes the hint
        // cannot become a card.
        let scanStart = index
        var labelsEnd = index
        while index < text.endIndex, text[index] == "/" {
            guard let space = text[index...].firstIndex(of: " ") else { break }
            labelsEnd = space
            index = text.index(after: space)
        }
        let remainder = text[index...]
        guard remainder.hasPrefix(Self.opener) else { return nil }

        var depth = 0
        var hintEnd: String.Index?
        var cursor = remainder.startIndex
        while hintEnd == nil, cursor < remainder.endIndex {
            switch remainder[cursor] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { hintEnd = remainder.index(after: cursor) }
            default: break
            }
            cursor = remainder.index(after: cursor)
        }
        guard let hintEnd else { return nil }

        let body = remainder[hintEnd...].drop(while: \.isWhitespace)
        guard !body.isEmpty else { return nil }

        skillLabels = labelsEnd > scanStart
            ? text[scanStart..<labelsEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        self.body = String(body)
        appVisibleInput = content
    }

    /// The collapsed header's one-line preview of the task text.
    var summary: String {
        let oneLine = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 80 else { return oneLine }
        return "\(oneLine.prefix(80))..."
    }

    /// Whether a Hermes chat's stored identity is a scheduled task's run: a
    /// `cron_` stored target key or root. The chat's `SessionSummary` is a
    /// placeholder with no source markers (`ChatView` builds it from a Profile
    /// only), so the stored identity decides; a webui chat never reaches here.
    static func isCronRun(target: ConversationTarget, storedKey: String?, root: String?) -> Bool {
        [target.sessionKey, storedKey, root].contains { key in
            key?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("cron_") == true
        }
    }
}

/// The compact collapsed card for a cron run's prompt row, following the
/// marker-card disclosure pattern. Expanded shows the body after the hint with
/// normal user-text styling, plus a Copy of the unchanged app-visible input,
/// which the card supplies itself because it bypasses the bubble's meta row.
struct CronRunPromptCard: View {
    let prompt: CronRunPrompt
    let onCopy: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            Button {
                chatDisclosureToggled()
                withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(isExpanded
                               ? String(localized: "Double tap to collapse details.")
                               : String(localized: "Double tap to expand details."))

            if isExpanded {
                Text(prompt.body)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))

                HStack {
                    Spacer(minLength: 8)
                    ChatCopyButton { onCopy(prompt.appVisibleInput) }
                }
                .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .chatTimelineAccessorySurface(
            fallbackMaterial: .thinMaterial,
            cornerRadius: 10
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(localized: "Scheduled task"))
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let labels = prompt.skillLabels {
                        Text(labels)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(prompt.summary)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        var label = String(localized: "Scheduled task")
        if let labels = prompt.skillLabels {
            label += ", \(labels)"
        }
        return label + ". " + prompt.summary
    }
}
