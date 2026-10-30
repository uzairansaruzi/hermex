import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HermesLiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentRunLiveActivityWidget()
    }
}

struct AgentRunLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentRunActivityAttributes.self) { context in
            AgentRunLockScreenView(context: context)
                .activityBackgroundTint(AgentRunLiveActivityTheme.background)
                .activitySystemActionForegroundColor(AgentRunLiveActivityTheme.primaryText)
                .widgetURL(AgentRunTapTarget.url(attributes: context.attributes, sessionID: context.presentedState.sessionID, activityID: context.activityID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentRunIslandBadge(status: context.presentedState.status, bot: context.attributes.bot,
                                        title: context.presentedState.sessionTitle)
                        .padding(.leading, 18)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    AgentRunIslandStatusView(state: context.presentedState)
                        .padding(.trailing, 18)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    AgentRunExpandedIslandBottomView(state: context.presentedState, isBot: context.attributes.bot != nil)
                }
            } compactLeading: {
                AgentRunIslandCompactMark(state: context.presentedState, isBot: context.attributes.bot != nil)
            } compactTrailing: {
                AgentRunCompactTrailingView(state: context.presentedState)
            } minimal: {
                AgentRunIslandCompactMark(state: context.presentedState, isBot: context.attributes.bot != nil)
            }
            .widgetURL(AgentRunTapTarget.url(attributes: context.attributes, sessionID: context.presentedState.sessionID, activityID: context.activityID))
            .keylineTint(AgentRunStatusStyle.color(for: context.presentedState.status, isStale: context.presentedState.isStale))
        }
    }
}

private struct AgentRunExpandedIslandBottomView: View {
    let state: AgentRunActivityAttributes.ContentState
    let isBot: Bool

    /// One line without reply text: what the agent is doing, then its counts.
    private var countsLine: String {
        AgentRunStaleBotPresentation.expandedCountsLine(state: state, isBot: isBot)
    }

    /// A stale approval or clarification keeps its ask in this line. Every other
    /// state still yields the line to reply text.
    private var showsStaleWaitingAnswer: Bool {
        AgentRunStaleBotPresentation.prefersWaitingAnswer(state: state, isBot: isBot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.responseExcerpt.isEmpty || showsStaleWaitingAnswer {
                Text(countsLine)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(state.responseExcerpt)
                    .font(.caption2)
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

private struct AgentRunLockScreenView: View {
    let context: ActivityViewContext<AgentRunActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            activityRow
            // A stale ask stays on the chips, including its answer action, even when
            // reply text would otherwise take this row. Counts stay counts.
            if isBot, (showsStaleWaitingAnswer || context.presentedState.responseExcerpt.isEmpty), !botChips.isEmpty {
                AgentRunChipRow(chips: botChips.map(AgentRunDetailChip.text), isDimmed: context.presentedState.isStale)
            } else if !isBot, context.presentedState.responseExcerpt.isEmpty {
                // No reply text to show: the relay's counts and freshness, or nothing
                // at all rather than filler (#644).
                let chips = context.presentedState.detailChips
                if !chips.isEmpty { AgentRunChipRow(chips: chips, isDimmed: false) }
            } else {
                transcriptPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var isBot: Bool { context.attributes.bot != nil }

    private var activityText: String {
        if let stale = AgentRunStaleBotPresentation.presentation(state: context.presentedState, isBot: isBot) {
            return stale.lead
        }

        if context.presentedState.isStale {
            // Stale webui names the card as stale. A disconnected Bot is handled above.
            return "Latest status shown"
        }

        if let errorSummary = context.presentedState.errorSummary, !errorSummary.isEmpty {
            return errorSummary
        }

        return context.presentedState.currentActivity
    }

    /// The bot's counts. A stale activity adds one action: answer, or reconnect.
    private var botChips: [String] {
        AgentRunStaleBotPresentation.lockScreenChips(state: context.presentedState, isBot: isBot)
    }

    private var showsStaleWaitingAnswer: Bool {
        AgentRunStaleBotPresentation.prefersWaitingAnswer(state: context.presentedState, isBot: isBot)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            AgentRunLeadingMark(bot: context.attributes.bot, status: context.presentedState.status,
                                isStale: context.presentedState.isStale, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(isBot ? "Hermex · \(String(localized: "Bot"))" : "Hermex")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                    .textCase(.uppercase)

                Text(context.presentedState.sessionTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.82)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            AgentRunTimerPill(state: context.presentedState)
        }
    }

    private var activityRow: some View {
        Text(activityText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(excerptText)
                .font(.caption)
                .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AgentRunStatusStyle.color(for: context.presentedState.status, isStale: context.presentedState.isStale).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AgentRunLiveActivityTheme.stroke, lineWidth: 1)
        )
    }

    private var excerptText: String {
        if !context.presentedState.responseExcerpt.isEmpty {
            return context.presentedState.responseExcerpt
        }

        if context.presentedState.isFinal {
            return "Response is ready to review."
        }

        return "Waiting for the next agent update."
    }
}

/// Bounded detail chips: a bot's counts, or a webui run's counts and freshness (#644).
/// Only the system-drawn relative time moves; the app never repaints this row.
private struct AgentRunChipRow: View {
    let chips: [AgentRunDetailChip]
    let isDimmed: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                label(for: chip)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDimmed || !chip.isCount ? AgentRunLiveActivityTheme.secondaryText : AgentRunLiveActivityTheme.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for chip: AgentRunDetailChip) -> Text {
        switch chip {
        case .text(let text): Text(text)
        case .updated(let date): Text("Updated \(Text(date, style: .relative)) ago")
        case .openReply: Text("Open to read the reply")
        }
    }
}

private extension AgentRunDetailChip {
    var isCount: Bool { if case .text = self { true } else { false } }
}

/// The bot's avatar with its status as a corner badge, or the plain status dot for a
/// session and for a bot whose avatar file is missing.
private struct AgentRunLeadingMark: View {
    let bot: AgentRunActivityBot?
    let status: AgentRunActivityStatus
    let isStale: Bool
    var size: CGFloat = 22

    private var avatar: UIImage? {
        AgentRunActivityAvatarFile.url(named: bot?.avatarFile).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    var body: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFit()
                .frame(width: size, height: size)
                .opacity(isStale ? 0.6 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(AgentRunStatusStyle.color(for: status, isStale: isStale))
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().stroke(AgentRunLiveActivityTheme.background, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
                .accessibilityHidden(true)
        } else {
            AgentRunStatusDot(status: status, isStale: isStale, size: size)
        }
    }
}

private struct AgentRunIslandBadge: View {
    let status: AgentRunActivityStatus
    let bot: AgentRunActivityBot?
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            AgentRunLeadingMark(bot: bot, status: status, isStale: false)
            Text(bot == nil ? "Hermex" : title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentRunLiveActivityTheme.primaryText)
                .lineLimit(1)
        }
    }
}

private struct AgentRunIslandStatusView: View {
    let state: AgentRunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(state.status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentRunStatusStyle.color(for: state.status, isStale: state.isStale))
                .lineLimit(1)

            if state.isFinal {
                Text("Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
            } else if state.isStale {
                Text("Latest")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
            } else {
                HStack(spacing: 3) {
                    Circle()
                        .fill(AgentRunLiveActivityTheme.liveDot)
                        .frame(width: 4, height: 4)
                    AgentRunElapsedTimerText(startedAt: state.startedAt, alignment: .trailing)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
            }
        }
    }
}

/// The compact leading and minimal glyph. It names the working phase on its own, so
/// it carries the full status for VoiceOver (#1398).
private struct AgentRunIslandCompactMark: View {
    let state: AgentRunActivityAttributes.ContentState
    let isBot: Bool

    private var status: AgentRunActivityStatus { state.status }

    var body: some View {
        ZStack {
            Circle()
                .fill(AgentRunStatusStyle.color(for: status, isStale: false).opacity(0.25))

            Image(systemName: AgentRunStatusStyle.symbolName(for: status))
                .font(.caption2.weight(.bold))
                .foregroundStyle(AgentRunStatusStyle.color(for: status, isStale: false))
        }
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// "Hermex, Thinking". Stale work says it shows the latest status, or for a Bot
    /// that it is disconnected; a stale Bot also says how to recover (#584).
    private var accessibilityLabel: String {
        let compact = AgentRunCompactPresentation(state: state)
        let stale = AgentRunStaleBotPresentation.presentation(state: state, isBot: isBot)
        var parts = ["Hermex"]
        if compact == .staleWork {
            parts.append(stale?.lead ?? String(localized: "Latest status shown"))
        } else {
            parts.append(status.title)
        }
        if let stale, compact == .staleWork || stale.isPendingInput {
            parts.append(stale.action)
        }
        return parts.joined(separator: ", ")
    }
}

/// Compact trailing: empty while working, one short word for an ask, an outcome, or
/// stale work (#1398). The leading mark already reads the full status, so VoiceOver
/// skips the word.
private struct AgentRunCompactTrailingView: View {
    let state: AgentRunActivityAttributes.ContentState

    var body: some View {
        if let word {
            Text(word)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AgentRunStatusStyle.color(for: state.status, isStale: state.isStale))
                .minimumScaleFactor(0.72)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }

    private var word: String? {
        switch AgentRunCompactPresentation(state: state) {
        case .working: nil
        case .approval: String(localized: "Approve")
        case .clarification: String(localized: "Question")
        case .waiting: String(localized: "Waiting")
        case .complete: String(localized: "Done")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Stopped")
        case .staleWork: String(localized: "Latest")
        }
    }
}

private struct AgentRunStatusDot: View {
    let status: AgentRunActivityStatus
    let isStale: Bool
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(color.opacity(0.36), lineWidth: 1))
    }

    var color: Color {
        AgentRunStatusStyle.color(for: status, isStale: isStale)
    }

    var symbolName: String {
        AgentRunStatusStyle.symbolName(for: status)
    }
}

private struct AgentRunTimerPill: View {
    let state: AgentRunActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.isFinal ? AgentRunStatusStyle.color(for: state.status, isStale: state.isStale) : AgentRunLiveActivityTheme.liveDot)
                .frame(width: 5, height: 5)

            if state.isFinal {
                Text("Done")
            } else {
                AgentRunElapsedTimerText(startedAt: state.startedAt, alignment: .center)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AgentRunLiveActivityTheme.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 62, alignment: .center)
        .background(AgentRunLiveActivityTheme.pillBackground, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(AgentRunLiveActivityTheme.stroke, lineWidth: 1))
    }
}

private struct AgentRunElapsedTimerText: View {
    let startedAt: Date
    var alignment: TextAlignment = .trailing

    // `Text(timerInterval:)` reserves layout width for the largest value its range
    // could ever show, then draws the shorter live value leading-aligned inside that
    // leftover slack — which left-shifted the digits in the Dynamic Island and the
    // Lock Screen pill (#247). Bounding the range keeps an MM:SS-sized box, and an
    // explicit `multilineTextAlignment` pins the digits to the edge each call site
    // wants (trailing under the Dynamic Island status, centered in the pill).
    private static let maxDisplayInterval: TimeInterval = 99 * 60 + 59

    var body: some View {
        Text(
            timerInterval: startedAt...startedAt.addingTimeInterval(Self.maxDisplayInterval),
            countsDown: false,
            showsHours: false
        )
        .monospacedDigit()
        .multilineTextAlignment(alignment)
        .lineLimit(1)
    }
}

private enum AgentRunLiveActivityTheme {
    static let background = Color(red: 0.025, green: 0.028, blue: 0.038)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let stroke = Color.white.opacity(0.13)
    static let pillBackground = Color.white.opacity(0.08)
    static let liveDot = Color(red: 0.35, green: 0.95, blue: 0.7)
}

private enum AgentRunStatusStyle {
    static func color(for status: AgentRunActivityStatus, isStale: Bool) -> Color {
        if isStale {
            return Color.white.opacity(0.52)
        }

        switch status {
        case .starting, .thinking, .responding:
            return Color(red: 1.0, green: 0.82, blue: 0.18)
        case .usingTool:
            return Color(red: 0.50, green: 0.72, blue: 1.0)
        case .searchingFiles:
            return Color(red: 0.22, green: 0.92, blue: 0.95)
        case .readingFiles:
            return Color(red: 0.58, green: 0.78, blue: 1.0)
        case .runningCommand:
            return Color(red: 0.76, green: 0.55, blue: 1.0)
        case .waiting, .waitingForApproval:
            return Color(red: 1.0, green: 0.58, blue: 0.24)
        case .waitingForClarification:
            return Color(red: 1.0, green: 0.65, blue: 0.30)
        case .complete:
            return Color(red: 0.35, green: 0.95, blue: 0.55)
        case .failed:
            return Color(red: 1.0, green: 0.32, blue: 0.32)
        case .cancelled:
            return Color.white.opacity(0.56)
        }
    }

    static func symbolName(for status: AgentRunActivityStatus) -> String {
        switch status {
        case .starting:
            "sparkle"
        case .thinking:
            "brain.head.profile"
        case .usingTool:
            "wrench.and.screwdriver"
        case .searchingFiles:
            "magnifyingglass"
        case .readingFiles:
            "doc.text"
        case .runningCommand:
            "terminal"
        case .responding:
            "text.bubble"
        case .waiting:
            "hourglass"
        case .waitingForApproval:
            "checkmark.shield"
        case .waitingForClarification:
            "questionmark.bubble"
        case .complete:
            "checkmark"
        case .failed:
            "exclamationmark"
        case .cancelled:
            "xmark"
        }
    }
}

private extension ActivityViewContext where Attributes == AgentRunActivityAttributes {
    var presentedState: AgentRunActivityAttributes.ContentState {
        state.presented(attributes: attributes, systemIsStale: isStale)
    }
}
