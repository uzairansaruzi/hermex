import SwiftUI

/// How the most recent response run ended, keyed to the turn it answered. The
/// view model records one when a stream finishes so the settled turn's fold
/// row can read "You stopped after 8s" and failed or stopped turns start open.
struct TranscriptTurnRunOutcome: Equatable {
    enum Ending: Equatable {
        case completed
        case cancelled
        case failed
    }

    let turnKey: String
    let startedAt: Date
    let endedAt: Date
    let ending: Ending

    var elapsed: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// One settled turn collapsed behind a single row.
struct TranscriptTurnFold: Equatable, Identifiable {
    enum Label: Equatable {
        case worked(elapsed: String?)
        case stopped(elapsed: String?)

        var title: String {
            switch self {
            case .worked(let elapsed?):
                String(localized: "Worked for \(elapsed)")
            case .worked(nil):
                String(localized: "Worked")
            case .stopped(let elapsed?):
                String(localized: "You stopped after \(elapsed)")
            case .stopped(nil):
                String(localized: "You stopped this response")
            }
        }
    }

    let turnKey: String
    /// Transcript row that draws the fold row above its content: the first row
    /// of the turn with something to hide.
    let hostRenderID: String
    let label: Label

    var id: String { turnKey }
}

/// What one transcript row does about folding, resolved against the set of
/// turns the user has expanded.
struct TranscriptTurnFoldRowState: Equatable {
    /// Non-nil on the host row, which draws the fold row.
    let fold: TranscriptTurnFold?
    let isExpanded: Bool
    let hidesBubble: Bool
    let hidesActivity: Bool
}

/// Folding of settled turns: a pure presentation layer over the displayed
/// transcript. A turn keeps its first and last text reply visible; every other
/// entry (reasoning, tool rows, interim replies) hides behind one row labelled
/// with the elapsed time. The turn a stream is answering, and any turn holding
/// the streaming message, never folds. Cache, message actions, and stream
/// recovery see none of this.
struct TranscriptTurnFolds: Equatable {
    private struct Membership: Equatable {
        let foldIndex: Int
        let isHost: Bool
        let foldsBubble: Bool
        let foldsActivity: Bool
    }

    private(set) var folds: [TranscriptTurnFold] = []
    private var membershipByRenderID: [String: Membership] = [:]

    static let none = TranscriptTurnFolds()

    /// - Parameters:
    ///   - activityAnchorIDs: anchors whose reasoning or tool groups are rendered.
    ///     Pass an empty set when thinking and tool cards are hidden, so a turn
    ///     with nothing visible to hide gets no row.
    ///   - rendersBubble: whether a transcript message draws a bubble at all;
    ///     activity-only assistant shells do not.
    static func derive(
        transcriptMessages: [TranscriptMessage],
        messages: [ChatMessage],
        messageOffset: Int?,
        activityAnchorIDs: Set<String>,
        rendersBubble: (ChatMessage) -> Bool,
        isStreamActive: Bool,
        streamingAssistantMessageID: String?,
        latestRunOutcome: TranscriptTurnRunOutcome?
    ) -> TranscriptTurnFolds {
        let offset = max(0, messageOffset ?? 0)
        let turnKeyByAnchorID = TranscriptTurnClassifier.assistantTurnKeysByAnchorID(
            messages,
            messageOffset: messageOffset
        )

        var startTimestampByTurnKey: [String: Double] = [:]
        for (index, message) in messages.enumerated()
        where TranscriptTurnClassifier.isUserTurnBoundary(message) {
            startTimestampByTurnKey[TranscriptTurnClassifier.userTurnKey(absoluteIndex: offset + index)] = message.timestamp
        }

        let unsettledTurnKey = isStreamActive
            ? TranscriptTurnClassifier.latestTurnKey(in: messages, messageOffset: messageOffset)
            : nil
        let streamingTurnKey = streamingAssistantMessageID.flatMap { turnKeyByAnchorID[$0] }

        struct Row {
            let renderID: String
            let message: ChatMessage
            let hasActivity: Bool
            let hasBubble: Bool
        }

        var turnKeys: [String] = []
        var rowsByTurnKey: [String: [Row]] = [:]
        for transcriptMessage in transcriptMessages where transcriptMessage.message.role == "assistant" {
            guard let turnKey = turnKeyByAnchorID[transcriptMessage.anchorID] else { continue }
            if rowsByTurnKey[turnKey] == nil {
                turnKeys.append(turnKey)
                rowsByTurnKey[turnKey] = []
            }
            rowsByTurnKey[turnKey]?.append(Row(
                renderID: transcriptMessage.renderID,
                message: transcriptMessage.message,
                hasActivity: activityAnchorIDs.contains(transcriptMessage.anchorID),
                hasBubble: rendersBubble(transcriptMessage.message)
            ))
        }

        var result = TranscriptTurnFolds()
        for turnKey in turnKeys {
            guard turnKey != unsettledTurnKey, turnKey != streamingTurnKey,
                  let rows = rowsByTurnKey[turnKey]
            else { continue }

            let bubbleRows = rows.filter(\.hasBubble)
            let firstBubbleID = bubbleRows.first?.renderID
            let lastBubbleID = bubbleRows.last?.renderID

            var memberships: [(renderID: String, foldsBubble: Bool, foldsActivity: Bool)] = []
            for row in rows {
                let foldsBubble = row.hasBubble
                    && row.renderID != firstBubbleID
                    && row.renderID != lastBubbleID
                memberships.append((row.renderID, foldsBubble, row.hasActivity))
            }

            guard let host = memberships.first(where: { $0.foldsBubble || $0.foldsActivity }) else {
                continue
            }

            let outcome = latestRunOutcome?.turnKey == turnKey ? latestRunOutcome : nil
            let elapsed = elapsedSeconds(
                rows: rows.map(\.message),
                startTimestamp: startTimestampByTurnKey[turnKey],
                outcome: outcome
            )
            let elapsedLabel = elapsed.map(ChatWorkingElapsedFormatter.label(seconds:))
            let label: TranscriptTurnFold.Label = outcome?.ending == .cancelled
                ? .stopped(elapsed: elapsedLabel)
                : .worked(elapsed: elapsedLabel)

            let foldIndex = result.folds.count
            result.folds.append(TranscriptTurnFold(
                turnKey: turnKey,
                hostRenderID: host.renderID,
                label: label
            ))
            for membership in memberships {
                result.membershipByRenderID[membership.renderID] = Membership(
                    foldIndex: foldIndex,
                    isHost: membership.renderID == host.renderID,
                    foldsBubble: membership.foldsBubble,
                    foldsActivity: membership.foldsActivity
                )
            }
        }

        return result
    }

    /// Nil for rows outside any fold.
    func rowState(for renderID: String, expandedTurnKeys: Set<String>) -> TranscriptTurnFoldRowState? {
        guard let membership = membershipByRenderID[renderID] else { return nil }

        let fold = folds[membership.foldIndex]
        let isExpanded = expandedTurnKeys.contains(fold.turnKey)
        return TranscriptTurnFoldRowState(
            fold: membership.isHost ? fold : nil,
            isExpanded: isExpanded,
            hidesBubble: membership.foldsBubble && !isExpanded,
            hidesActivity: membership.foldsActivity && !isExpanded
        )
    }

    /// Server-measured `_turnDuration` first; the client-measured run for the
    /// turn that just finished next; the gap from the user message to the
    /// turn's last message last. Nil when none of those exist.
    private static func elapsedSeconds(
        rows: [ChatMessage],
        startTimestamp: Double?,
        outcome: TranscriptTurnRunOutcome?
    ) -> TimeInterval? {
        if let duration = rows.reversed().lazy.compactMap(\.turnDuration).first, duration >= 0 {
            return duration
        }

        if let outcome {
            return outcome.elapsed
        }

        guard let startTimestamp,
              let endTimestamp = rows.compactMap(\.timestamp).max(),
              endTimestamp >= startTimestamp
        else {
            return nil
        }

        return endTimestamp - startTimestamp
    }
}

/// The 44 pt row a settled turn folds behind: elapsed label in monospaced
/// digits, a chevron, and a bottom hairline. Tapping toggles the turn through
/// the transcript's disclosure handler so the row stays put while it animates.
struct TranscriptTurnFoldRowView: View {
    let fold: TranscriptTurnFold
    let isExpanded: Bool
    let onToggle: () -> Void

    static let minimumHeight: CGFloat = 44

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text(fold.label.title)
                    .font(AppFont.subheadline(weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Self.minimumHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.separator).opacity(0.5))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fold.label.title)
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityHint(
            isExpanded
                ? String(localized: "Double tap to hide this turn's work.")
                : String(localized: "Double tap to show this turn's work.")
        )
    }
}
