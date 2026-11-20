import SwiftUI

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
    let hostRenderID: String
    let label: Label

    var id: String { turnKey }
}

struct TranscriptTurnFoldRowState: Equatable {
    let fold: TranscriptTurnFold?
    let isExpanded: Bool
    let hidesBubble: Bool
    let hidesActivity: Bool
}

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
        where TranscriptTurnClassifier.isTurnBoundary(message) {
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
                    .foregroundStyle(.appSecondary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.appTertiary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Self.minimumHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.appSeparator).opacity(0.5))
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

@MainActor
final class TranscriptStructureMemo {
    struct Inputs: Equatable {
        let structureRevision: Int
        let activityAnchorIDs: Set<String>
        let foldsSettledTurns: Bool
        let isStreamActive: Bool
        let streamingAssistantMessageID: String?
        let latestRunOutcome: TranscriptTurnRunOutcome?
    }

    struct Structure {
        let folds: TranscriptTurnFolds
        let terminalReplyRenderIDs: Set<String>
    }

    private var last: (inputs: Inputs, structure: Structure)?

    func structure(for inputs: Inputs, derive: () -> Structure) -> Structure {
        if let last, last.inputs == inputs { return last.structure }

        let structure = derive()
        last = (inputs, structure)
        return structure
    }
}
