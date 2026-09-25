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

    private static let sharedSeparatorFormatters = SeparatorFormatters(
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )

    /// The date and time a gap separator shows: "Today at 2:14 PM",
    /// "Yesterday at …", a weekday within the last week, then a date (with
    /// the year only when it differs). Every piece comes from the system's
    /// date formats, so no String Catalog entry is involved.
    static func separator(forUnixTimestamp timestamp: Double?) -> String? {
        separator(forUnixTimestamp: timestamp, now: Date(), formatters: sharedSeparatorFormatters)
    }

    /// Test seam: explicit locale, time zone and "now". Today and Yesterday
    /// come from the system's relative formatting, which reads the real clock,
    /// so a test of those two passes the real current date as `now`.
    static func separator(
        forUnixTimestamp timestamp: Double?,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return separator(
            forUnixTimestamp: timestamp,
            now: now,
            formatters: SeparatorFormatters(locale: locale, timeZone: timeZone, calendar: calendar)
        )
    }

    private static func separator(
        forUnixTimestamp timestamp: Double?,
        now: Date,
        formatters: SeparatorFormatters
    ) -> String? {
        guard let timestamp, timestamp.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = formatters.calendar
        let daysAgo = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let formatter: DateFormatter
        switch daysAgo {
        case 0...1: formatter = formatters.relative
        case 2...6: formatter = formatters.weekday
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            formatter = sameYear ? formatters.sameYear : formatters.otherYear
        }
        return formatter.string(from: date)
    }

    /// The four cached formatters a separator picks from.
    private struct SeparatorFormatters {
        let calendar: Calendar
        let relative: DateFormatter
        let weekday: DateFormatter
        let sameYear: DateFormatter
        let otherYear: DateFormatter

        init(locale: Locale, timeZone: TimeZone, calendar: Calendar) {
            func make(_ configure: (DateFormatter) -> Void) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.calendar = calendar
                configure(formatter)
                return formatter
            }
            self.calendar = calendar
            relative = make {
                $0.dateStyle = .medium
                $0.timeStyle = .short
                $0.doesRelativeDateFormatting = true
            }
            weekday = make { $0.setLocalizedDateFormatFromTemplate("EEEEjmm") }
            sameYear = make { $0.setLocalizedDateFormatFromTemplate("MMMdjmm") }
            otherYear = make { $0.setLocalizedDateFormatFromTemplate("yMMMdjmm") }
        }
    }
}

// MARK: - Gap separators

/// Where a transcript dates itself. A row opens a new stretch when its
/// timestamp is at least `gapThreshold` after the previous stamped row; the
/// first stamped row always does, so the top of a window is dated. Rows
/// without a usable timestamp never open one and are skipped as "previous".
/// Pure comparisons, so a view can run it on every body without formatting.
enum TranscriptTimeline {
    static let gapThreshold: TimeInterval = 30 * 60

    static func gapStarts<ID: Hashable>(
        _ rows: some Sequence<(id: ID, timestamp: Double?)>,
        threshold: TimeInterval = gapThreshold
    ) -> Set<ID> {
        var starts = Set<ID>()
        var previous: Double?
        for row in rows {
            guard let timestamp = row.timestamp, timestamp.isFinite, timestamp > 0 else { continue }
            if previous.map({ timestamp - $0 >= threshold }) ?? true { starts.insert(row.id) }
            previous = timestamp
        }
        return starts
    }
}

/// A centered date and time between hairlines, drawn before a row that opens
/// a new stretch of the transcript. Takes the raw timestamp so SwiftUI skips
/// the formatting when a streaming snapshot rebuilds the transcript.
struct TranscriptTimeSeparator: View {
    let timestamp: Double

    var body: some View {
        if let text = ChatMessageTimestampFormatter.separator(forUnixTimestamp: timestamp) {
            HStack(spacing: 8) {
                hairline
                Text(text)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                hairline
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
