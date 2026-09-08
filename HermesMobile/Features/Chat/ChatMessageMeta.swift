import SwiftUI

/// Timestamps belong to user messages and settled terminal replies. Actions
/// remain reachable on every actionable message, including a turn still streaming.
enum TranscriptMessageMetaPolicy {
    static func showsRow(hasActions: Bool, hasTimestamp: Bool) -> Bool {
        hasActions || hasTimestamp
    }

    /// Render IDs of the last bubble-bearing reply of each settled assistant turn.
    static func terminalReplyRenderIDs(
        transcriptMessages: [TranscriptMessage],
        messages: [ChatMessage],
        messageOffset: Int?,
        rendersBubble: (ChatMessage) -> Bool,
        isStreamActive: Bool,
        streamingAssistantMessageID: String?
    ) -> Set<String> {
        let turnKeyByAnchorID = TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
            messages,
            messageOffset: messageOffset
        )
        let unsettledTurnKey = isStreamActive
            ? TranscriptTurnClassifier.latestTurnKey(in: messages, messageOffset: messageOffset)
            : nil
        let streamingTurnKey = streamingAssistantMessageID.flatMap { turnKeyByAnchorID[$0] }

        var lastReplyByTurnKey: [String: String] = [:]
        for transcriptMessage in transcriptMessages
        where transcriptMessage.message.role == "assistant" && rendersBubble(transcriptMessage.message) {
            guard let turnKey = turnKeyByAnchorID[transcriptMessage.anchorID],
                  turnKey != unsettledTurnKey,
                  turnKey != streamingTurnKey
            else { continue }
            lastReplyByTurnKey[turnKey] = transcriptMessage.renderID
        }

        return Set(lastReplyByTurnKey.values)
    }
}

/// The row under a message bubble: timestamp, copy, and completed-response actions.
/// User rows read `[time][copy]` against the trailing edge, assistant rows
/// `[copy][actions][time]` against the leading edge, so Copy always sits at the
/// outer edge and RTL mirrors both through the semantic alignments.
struct ChatMessageMetaRow: View {
    let isUserMessage: Bool
    let timeText: String?
    let onCopy: (() -> Void)?
    var actionMenu: ChatMessageActionMenu? = nil

    var body: some View {
        HStack(spacing: 4) {
            if isUserMessage {
                time
                copyButton
            } else {
                copyButton
                if let actionMenu {
                    Menu { actionMenu } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .chatMinimumHitTarget(in: Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("More")
                }
                time
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }

    @ViewBuilder
    private var time: some View {
        if let timeText {
            Text(timeText)
                .font(AppFont.caption(weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if let onCopy {
            ChatCopyButton(action: onCopy)
                .foregroundStyle(.secondary)
        }
    }
}

/// A copy button that answers with a checkmark for `feedbackDuration` after
/// each tap. The caller writes the pasteboard and fires the haptic; this only
/// owns the feedback state, and SwiftUI cancels the reset with the view.
struct ChatCopyButton: View {
    static let feedbackDuration: Duration = .milliseconds(1200)

    var label = String(localized: "Copy")
    var copiedLabel = String(localized: "Copied")
    var size: CGFloat = 28
    var glyphSize: CGFloat = 13
    var glyphWeight: Font.Weight = .medium
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsCopied = false
    @State private var copyCount = 0

    var body: some View {
        Button {
            action()
            showsCopied = true
            copyCount += 1
        } label: {
            Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: glyphSize, weight: glyphWeight))
                .frame(width: size, height: size)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .chatMinimumHitTarget(
                    horizontalPadding: max(0, (44 - size) / 2),
                    verticalPadding: max(0, (44 - size) / 2),
                    in: Rectangle()
                )
        }
        .buttonStyle(.chatTactile(.icon))
        .accessibilityLabel(showsCopied ? copiedLabel : label)
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: Self.feedbackDuration)
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

// MARK: - Timestamp formatting

/// Formats a message's unix `timestamp` as a short, locale-/24h-aware time
/// (e.g. `2:14 PM` or `14:14`). Returns `nil` for a missing or non-finite
/// timestamp so the meta row simply omits the time.
enum ChatMessageTimestampFormatter {
    private static let sharedFormatter: DateFormatter = makeFormatter(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    static func shortTime(forUnixTimestamp timestamp: Double?) -> String? {
        format(timestamp, with: sharedFormatter)
    }

    /// Test seam: format against an explicit locale/time zone so 12h/24h
    /// assertions stay deterministic regardless of host device settings.
    static func shortTime(
        forUnixTimestamp timestamp: Double?,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        format(timestamp, with: makeFormatter(locale: locale, timeZone: timeZone))
    }

    private static func makeFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static func format(_ timestamp: Double?, with formatter: DateFormatter) -> String? {
        guard let timestamp, timestamp.isFinite else { return nil }
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
