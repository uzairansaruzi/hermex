import SwiftUI
import UIKit

/// What an approval card shows. A webui server's approval always offers all four
/// choices; a Hermes session's offers only the ones its host computed (#1011).
struct ApprovalRequestContent: Equatable {
    let description: String?
    let command: String?
    let scopeLine: AttributedString?
    let pendingCount: Int
    /// In the host's order: `once` first, `deny` last.
    let choices: [ApprovalChoice]
}

extension ApprovalPromptState {
    var requestContent: ApprovalRequestContent {
        ApprovalRequestContent(description: pending.description, command: pending.command, scopeLine: scopeLine,
                               pendingCount: pendingCount, choices: ApprovalChoice.allCases)
    }
}

extension BotApprovalRequest {
    /// This approval in a Hermes session's card, one of `pendingCount` open approvals.
    func requestContent(pendingCount: Int) -> ApprovalRequestContent {
        ApprovalRequestContent(description: consequence, command: command, scopeLine: scopeLine,
                               pendingCount: max(pendingCount, 1),
                               choices: choices.compactMap { ApprovalChoice(rawValue: $0.rawValue) })
    }
}

/// A pending approval pinned above the composer, in the clarification's slot (#1584), so
/// the transcript stays readable while the agent waits. The warning-accented bar is the
/// permanent footprint: its height feeds the transcript's bottom inset. The expanded card
/// rises over it through the bar's clip window, scrolls once it is taller than the space
/// above the composer, and falls back to the bar when not even a line of it fits. A new
/// approval arrives expanded; ChatView gives each one its own identity.
struct ApprovalRequestInset: View {
    let content: ApprovalRequestContent
    /// Height between the chat's top safe edge and this inset's bottom edge.
    let maximumExpandedHeight: CGFloat
    let isResponding: Bool
    let isStopping: Bool
    let errorMessage: String?
    var summary: ApprovalSummaryPresentation? = nil
    let isHapticsEnabled: Bool
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void
    let onStop: () -> Void
    let onDismissKeyboard: () -> Void
    /// The bar's height, the only part of this view that takes layout space.
    let onFootprintChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var minimumCardHeight: CGFloat = 88
    @State private var isExpanded = true
    @State private var contentHeight: CGFloat?

    var body: some View {
        ClarificationRequestBar(
            summary: Self.barSummary(for: content),
            isStopping: isStopping,
            onExpand: {
                if !canFit { onDismissKeyboard() }
                setExpanded(true)
            },
            onStop: onStop,
            kind: .approval(pendingCount: content.pendingCount)
        )
        // Hidden under the card, so its tinted edge never shows around the card's corners.
        .opacity(isExpanded ? 0 : 1)
        .accessibilityHidden(isExpanded)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onFootprintChange(height)
        }
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                card
                    .offset(y: isExpanded ? 0 : maximumExpandedHeight)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
            }
            .clipped()
        }
        .onChange(of: canFit, initial: true) { _, canFit in
            if !canFit { setExpanded(false) }
        }
        .onAppear(perform: announceRequest)
    }

    /// One line of what is being approved: the command's first line, else its description.
    static func barSummary(for content: ApprovalRequestContent) -> String {
        [content.command, content.description]
            .map { ClarificationRequestBar.summary(for: $0 ?? "") }
            .first { !$0.isEmpty } ?? ""
    }

    /// Room for at least the card's header and a line of it.
    private var canFit: Bool { maximumExpandedHeight >= minimumCardHeight }

    /// The card, scrolling once it is taller than the space left. Hidden until measured.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
        return ScrollView {
            ApprovalRequestCard(
                content: content, isResponding: isResponding, errorMessage: errorMessage,
                onChoice: onChoice, onSkipAll: onSkipAll, summary: summary,
                onCollapse: { setExpanded(false) }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(0, min(contentHeight ?? maximumExpandedHeight, maximumExpandedHeight)))
        .clipShape(shape)
        .pendingRequestCardSurface(cornerRadius: ChatComposerMetrics.cardCornerRadius)
        .frame(maxWidth: 560)
        .opacity(contentHeight == nil ? 0 : 1)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        if !expanded {
            onDismissKeyboard()
        }
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
        withAnimation(ChatMotion.clarificationToggle(reduceMotion: reduceMotion)) {
            isExpanded = expanded
        }
    }

    /// The card no longer takes over the screen, so VoiceOver hears that one arrived.
    private func announceRequest() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let announcement = String(localized: "Approval needed: \(Self.barSummary(for: content))")
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// An approval's card: what will run, what each choice covers, the offered choices as
/// one-tap buttons, and Skip all. `ApprovalRequestInset` gives it its place and surface.
struct ApprovalRequestCard: View {
    let content: ApprovalRequestContent
    let isResponding: Bool
    let errorMessage: String?
    let onChoice: (ApprovalChoice) -> Void
    let onSkipAll: () -> Void
    var summary: ApprovalSummaryPresentation? = nil
    /// The header's collapse control; nil leaves it out.
    var onCollapse: (() -> Void)? = nil
    @AppStorage(ApprovalSummaries.enabledKey) private var explainsApprovals = ApprovalSummaries.enabledByDefault
    @ScaledMetric(relativeTo: .body) private var collapseButtonSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            details
            actions
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Approval required")
                    .font(AppFont.headline())

                Text("Pending approvals: \(content.pendingCount)")
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }

            Spacer(minLength: 8)

            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: collapseButtonSize, height: collapseButtonSize)
                        .background(.primary.opacity(0.08))
                        .foregroundStyle(.appSecondary)
                        .clipShape(Circle())
                }
                .buttonStyle(.chatTactile(.icon))
                .accessibilityLabel("Collapse approval")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = nonEmpty(content.description) {
                Text(description)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.appPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let command = nonEmpty(content.command) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Raised, since the card itself now sits on the surface color.
                .background(Color(uiColor: .appRaised), in: RoundedRectangle(cornerRadius: 8))
            }

            if explainsApprovals, let summary {
                ApprovalSummaryLine(presentation: summary)
            }

            if let scope = content.scopeLine {
                Text(scope)
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if content.pendingCount > 1 {
                Text("1 of \(content.pendingCount) pending")
                    .font(AppFont.caption())
                    .foregroundStyle(.appSecondary)
            }

            if let errorMessage = nonEmpty(errorMessage) {
                Text(errorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { choice in
                        approvalButton(choice)
                    }
                }
            }

            Button {
                onSkipAll()
            } label: {
                Label("Skip all this session", systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.chatDecision(.secondary))
            .disabled(isResponding)
        }
    }

    /// Two per row in the offered order, so all four read as the familiar 2×2 and a withheld
    /// choice never moves Allow once or Deny out of reach.
    private var rows: [[ApprovalChoice]] {
        stride(from: 0, to: content.choices.count, by: 2).map {
            Array(content.choices[$0..<min($0 + 2, content.choices.count)])
        }
    }

    private func approvalButton(_ choice: ApprovalChoice) -> some View {
        Button(role: choice == .deny ? .destructive : nil) {
            onChoice(choice)
        } label: {
            Label(Self.title(for: choice), systemImage: Self.symbol(for: choice))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.chatDecision(Self.emphasis(for: choice)))
        .disabled(isResponding)
    }

    private static func title(for choice: ApprovalChoice) -> LocalizedStringKey {
        switch choice {
        case .once: return "Allow once"
        case .session: return "Allow session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    private static func symbol(for choice: ApprovalChoice) -> String {
        switch choice {
        case .once: return "checkmark.circle.fill"
        case .session: return "lock.open"
        case .always: return "star.fill"
        case .deny: return "xmark.circle.fill"
        }
    }

    private static func emphasis(for choice: ApprovalChoice) -> ChatDecisionButtonStyle.Emphasis {
        switch choice {
        case .once: return .primary
        case .session, .always: return .secondary
        case .deny: return .destructive
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
