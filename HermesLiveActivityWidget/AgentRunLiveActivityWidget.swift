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
            AgentRunActivityContent(context: context)
                .agentRunPalette(on: .lockScreen)
                .activityBackgroundTint(AgentRunPalette.Surface.lockScreen.backgroundTint)
                .activitySystemActionForegroundColor(AgentRunPalette.Surface.lockScreen.actionForeground)
                .widgetURL(AgentRunTapTarget.url(attributes: context.attributes, sessionID: context.presentedState.sessionID, activityID: context.activityID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentRunIslandBadge(status: context.presentedState.status, bot: context.attributes.bot,
                                        title: context.presentedState.sessionTitle)
                        .padding(.leading, 18)
                        .agentRunPalette(on: .host)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    AgentRunIslandStatusView(state: context.presentedState)
                        .padding(.trailing, 18)
                        .agentRunPalette(on: .host)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    AgentRunExpandedIslandBottomView(state: context.presentedState, isBot: context.attributes.bot != nil)
                        .agentRunPalette(on: .host)
                }
            } compactLeading: {
                AgentRunIslandCompactMark(state: context.presentedState, isBot: context.attributes.bot != nil)
                    .agentRunPalette(on: .host)
            } compactTrailing: {
                AgentRunCompactTrailingView(state: context.presentedState)
                    .agentRunPalette(on: .host)
            } minimal: {
                AgentRunIslandCompactMark(state: context.presentedState, isBot: context.attributes.bot != nil)
                    .agentRunPalette(on: .host)
            }
            .widgetURL(AgentRunTapTarget.url(attributes: context.attributes, sessionID: context.presentedState.sessionID, activityID: context.activityID))
            // The keyline only rings the iPhone's black Island, so it keeps the dark hues.
            .keylineTint(AgentRunPalette.dark.status(context.presentedState.status, isStale: context.presentedState.isStale))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The activity's content view for every family: the two-line small layout on the
/// Apple Watch Smart Stack and CarPlay (#1400), the Lock Screen card everywhere else.
/// The family is read here because ActivityConfiguration's builder closures get no
/// environment.
private struct AgentRunActivityContent: View {
    let context: ActivityViewContext<AgentRunActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            AgentRunSmallView(state: context.presentedState, isBot: context.attributes.bot != nil)
        } else {
            AgentRunLockScreenView(context: context)
        }
    }
}

/// Title first, then state (#1400): the full ask or outcome title, the elapsed timer
/// while working, or the latest-status wording for stale work. Stale asks stay asks.
/// No excerpt, chips or pill: the card has to make sense at a glance without a tap.
private struct AgentRunSmallView: View {
    let state: AgentRunActivityAttributes.ContentState
    let isBot: Bool
    @Environment(\.agentRunPalette) private var palette

    private var presentation: AgentRunCompactPresentation { AgentRunCompactPresentation(state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: AgentRunStatusStyle.symbolName(for: state.status))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(palette.status(state.status, isStale: state.isStale))
                    .widgetAccentable()
                    // Working has no status words on the second line, so the glyph names the phase.
                    .accessibilityLabel(state.status.title)
                    .accessibilityHidden(presentation != .working)

                Text(state.sessionTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            statusLine
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch presentation {
        case .working:
            AgentRunElapsedTimerText(startedAt: state.startedAt, alignment: .leading)
                .foregroundStyle(palette.secondaryText)
        case .staleWork:
            Text(AgentRunStaleBotPresentation.presentation(state: state, isBot: isBot)?.lead
                 ?? String(localized: "Latest status shown"))
                .foregroundStyle(palette.secondaryText)
        case .approval, .clarification, .waiting, .complete, .failed, .cancelled:
            Text(state.status.title)
                .foregroundStyle(state.isStale ? palette.secondaryText : palette.status(state.status, isStale: false))
        }
    }
}

private struct AgentRunExpandedIslandBottomView: View {
    let state: AgentRunActivityAttributes.ContentState
    let isBot: Bool
    @Environment(\.agentRunPalette) private var palette

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
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(state.responseExcerpt)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
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
    @Environment(\.agentRunPalette) private var palette

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
                    .foregroundStyle(palette.secondaryText)
                    .textCase(.uppercase)

                Text(context.presentedState.sessionTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
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
            .foregroundStyle(palette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(excerptText)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.status(context.presentedState.status, isStale: context.presentedState.isStale).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.stroke, lineWidth: 1)
        )
    }

    private var excerptText: String {
        if !context.presentedState.responseExcerpt.isEmpty {
            return context.presentedState.responseExcerpt
        }

        if context.presentedState.isFinal {
            return String(localized: "Response is ready to review.", table: "Auxiliary")
        }

        return String(localized: "Waiting for the next agent update.", table: "Auxiliary")
    }
}

/// Bounded detail chips: a bot's counts, or a webui run's counts and freshness (#644).
/// Only the system-drawn relative time moves; the app never repaints this row.
private struct AgentRunChipRow: View {
    let chips: [AgentRunDetailChip]
    let isDimmed: Bool
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                label(for: chip)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDimmed || !chip.isCount ? palette.secondaryText : palette.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    @Environment(\.agentRunPalette) private var palette

    private var avatar: UIImage? {
        AgentRunActivityAvatarFile.url(named: bot?.avatarFile).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    var body: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFit()
                .frame(width: size, height: size)
                .opacity(isStale ? 0.6 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(palette.status(status, isStale: isStale))
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().stroke(palette.avatarOutline, lineWidth: 2))
                        .widgetAccentable()
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
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            AgentRunLeadingMark(bot: bot, status: status, isStale: false)
            Text(bot == nil ? "Hermex" : title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
        }
    }
}

private struct AgentRunIslandStatusView: View {
    let state: AgentRunActivityAttributes.ContentState
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(state.status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.status(state.status, isStale: state.isStale))
                .lineLimit(1)

            if state.isFinal {
                Text("Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
            } else if state.isStale {
                Text("Latest")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
            } else {
                HStack(spacing: 3) {
                    Circle()
                        .fill(palette.liveDot)
                        .frame(width: 4, height: 4)
                    AgentRunElapsedTimerText(startedAt: state.startedAt, alignment: .trailing)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(palette.secondaryText)
            }
        }
    }
}

/// The compact leading and minimal glyph. It names the working phase on its own, so
/// it carries the full status for VoiceOver (#1398).
private struct AgentRunIslandCompactMark: View {
    let state: AgentRunActivityAttributes.ContentState
    let isBot: Bool
    @Environment(\.agentRunPalette) private var palette

    private var status: AgentRunActivityStatus { state.status }

    var body: some View {
        ZStack {
            Circle()
                .fill(palette.status(status, isStale: false).opacity(0.25))

            Image(systemName: AgentRunStatusStyle.symbolName(for: status))
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.status(status, isStale: false))
        }
        .widgetAccentable()
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
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        if let word {
            Text(word)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.status(state.status, isStale: state.isStale))
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
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: Circle())
            .overlay(Circle().stroke(color.opacity(0.36), lineWidth: 1))
            .widgetAccentable()
    }

    var color: Color {
        palette.status(status, isStale: isStale)
    }

    var symbolName: String {
        AgentRunStatusStyle.symbolName(for: status)
    }
}

private struct AgentRunTimerPill: View {
    let state: AgentRunActivityAttributes.ContentState
    @Environment(\.agentRunPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.isFinal ? palette.status(state.status, isStale: state.isStale) : palette.liveDot)
                .frame(width: 5, height: 5)

            if state.isFinal {
                Text("Done")
            } else {
                AgentRunElapsedTimerText(startedAt: state.startedAt, alignment: .center)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 62, alignment: .center)
        .background(palette.fill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(palette.stroke, lineWidth: 1))
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

/// Every color the Live Activity draws, chosen from the surface under it and from how the
/// system renders it (#1399). `agentRunPalette(on:)` builds one per surface; views read it
/// from the environment. Status glyphs and words carry status in every treatment.
struct AgentRunPalette {
    /// What the activity draws on.
    enum Surface {
        /// The fixed near-black card: dark whatever the system appearance.
        case darkCard
        /// System material or a host's own background (the iPhone Island, a Mac menu
        /// bar): light or dark per the environment's `colorScheme`.
        case host

        /// iOS 26 and later asks for system material; iOS 18–25 keeps the dark card.
        static var lockScreen: Surface {
            if #available(iOS 26, *) { .host } else { .darkCard }
        }

        /// nil asks for the system default material.
        var backgroundTint: Color? { self == .darkCard ? AgentRunPalette.darkCardBackground : nil }
        var actionForeground: Color? { self == .darkCard ? .white : nil }
    }

    /// Today's look: the dark card in full color. The environment default, and the
    /// Island keyline's colors.
    static let dark = AgentRunPalette(surface: .darkCard, colorScheme: .dark, renderingMode: .fullColor,
                                      isLuminanceReduced: false, increasedContrast: false)

    private static let darkCardBackground = Color(red: 0.025, green: 0.028, blue: 0.038)

    let primaryText: Color
    let secondaryText: Color
    let stroke: Color
    /// Chip and timer pill fill: kept faint so the background shows through.
    let fill: Color
    /// Rings the avatar's status badge so it reads as cut out of the background.
    let avatarOutline: Color
    private let isDark: Bool
    /// Replaces every status hue: secondary when luminance is reduced (Always-On),
    /// primary when the system tints or desaturates the activity.
    private let statusOverride: Color?

    /// Rules in order: reduced luminance mutes status, accented or vibrant rendering
    /// draws in hierarchical primary and secondary, and full color contrasts with the
    /// actual background, which is always dark for the dark card.
    init(surface: Surface, colorScheme: ColorScheme, renderingMode: WidgetRenderingMode,
         isLuminanceReduced: Bool, increasedContrast: Bool) {
        isDark = surface == .darkCard || colorScheme == .dark
        let isMonochrome = renderingMode != .fullColor
        let ink: Color = isDark ? .white : .black
        if isMonochrome {
            primaryText = .primary
            secondaryText = .secondary
            stroke = Color.primary.opacity(increasedContrast ? 0.3 : 0.15)
            fill = Color.primary.opacity(0.08)
        } else {
            primaryText = ink
            secondaryText = ink.opacity(isDark ? (increasedContrast ? 0.82 : 0.68) : (increasedContrast ? 0.78 : 0.6))
            stroke = ink.opacity(increasedContrast ? 0.3 : (isDark ? 0.13 : 0.12))
            fill = ink.opacity(isDark ? 0.08 : 0.06)
        }
        avatarOutline = isDark ? Self.darkCardBackground : .white
        statusOverride = isLuminanceReduced ? secondaryText : (isMonochrome ? primaryText : nil)
    }

    func status(_ status: AgentRunActivityStatus, isStale: Bool) -> Color {
        if let statusOverride { return statusOverride }
        let hue = isStale ? Self.neutral : Self.hue(for: status)
        return isDark ? hue.dark : hue.light
    }

    /// The working dot beside the timer.
    var liveDot: Color {
        statusOverride ?? (isDark ? Color(red: 0.35, green: 0.95, blue: 0.7) : Color(red: 0.06, green: 0.5, blue: 0.32))
    }

    private static let neutral = (dark: Color.white.opacity(0.54), light: Color.black.opacity(0.45))

    /// Bright hues for dark backgrounds, darker variants of the same hue for light ones.
    private static func hue(for status: AgentRunActivityStatus) -> (dark: Color, light: Color) {
        switch status {
        case .starting, .thinking, .responding:
            (Color(red: 1.0, green: 0.82, blue: 0.18), Color(red: 0.54, green: 0.42, blue: 0.0))
        case .usingTool:
            (Color(red: 0.50, green: 0.72, blue: 1.0), Color(red: 0.12, green: 0.37, blue: 0.75))
        case .searchingFiles:
            (Color(red: 0.22, green: 0.92, blue: 0.95), Color(red: 0.0, green: 0.45, blue: 0.48))
        case .readingFiles:
            (Color(red: 0.58, green: 0.78, blue: 1.0), Color(red: 0.17, green: 0.40, blue: 0.70))
        case .runningCommand:
            (Color(red: 0.76, green: 0.55, blue: 1.0), Color(red: 0.42, green: 0.25, blue: 0.72))
        case .waiting, .waitingForApproval:
            (Color(red: 1.0, green: 0.58, blue: 0.24), Color(red: 0.72, green: 0.35, blue: 0.0))
        case .waitingForClarification:
            (Color(red: 1.0, green: 0.65, blue: 0.30), Color(red: 0.66, green: 0.36, blue: 0.04))
        case .complete:
            (Color(red: 0.35, green: 0.95, blue: 0.55), Color(red: 0.12, green: 0.56, blue: 0.24))
        case .failed:
            (Color(red: 1.0, green: 0.32, blue: 0.32), Color(red: 0.70, green: 0.15, blue: 0.12))
        case .cancelled:
            neutral
        }
    }
}

extension EnvironmentValues {
    /// Set by `agentRunPalette(on:)`; defaults to the dark card.
    @Entry var agentRunPalette = AgentRunPalette.dark
}

/// Reads how the system draws this view and hands the matching palette down. The reads
/// live in a view modifier because ActivityConfiguration's builder closures get no
/// environment.
private struct AgentRunPaletteScope: ViewModifier {
    let surface: AgentRunPalette.Surface
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    func body(content: Content) -> some View {
        content.environment(\.agentRunPalette, AgentRunPalette(
            surface: surface, colorScheme: colorScheme, renderingMode: renderingMode,
            isLuminanceReduced: isLuminanceReduced, increasedContrast: contrast == .increased))
    }
}

private extension View {
    func agentRunPalette(on surface: AgentRunPalette.Surface) -> some View {
        modifier(AgentRunPaletteScope(surface: surface))
    }
}

private enum AgentRunStatusStyle {
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
