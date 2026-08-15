import SwiftUI

struct GoalControlsMenu: View {
    let currentGoal: SubmittedGoal?
    let isViewingCachedData: Bool
    let isActionDisabled: Bool
    let onSetGoal: () -> Void
    let onSubmitCommand: (String) -> Void

    var body: some View {
        Menu {
            Button {
                onSetGoal()
            } label: {
                Label("Set Goal", systemImage: "target")
            }
            .disabled(isActionDisabled)

            Divider()

            commandButton(String(localized: "Status"), systemImage: "list.bullet.clipboard", command: "status")
            commandButton(String(localized: "Pause"), systemImage: "pause.circle", command: "pause")
            commandButton(String(localized: "Resume"), systemImage: "play.circle", command: "resume")

            Divider()

            commandButton(String(localized: "Mark Done"), systemImage: "checkmark.circle", command: "done")
            commandButton(String(localized: "Clear"), systemImage: "xmark.circle", command: "clear")

            Button(role: .destructive) {
                onSubmitCommand("stop")
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .disabled(isActionDisabled)
        } label: {
            Label("Goal", systemImage: goalIconName)
        }
        .disabled(isViewingCachedData)
        .accessibilityLabel("Goal controls")
    }

    private var goalIconName: String {
        switch currentGoal?.status?.lowercased() {
        case "active":
            return "target"
        case "paused":
            return "pause.circle"
        case "done":
            return "checkmark.circle"
        case "cleared":
            return "xmark.circle"
        default:
            return "target"
        }
    }

    private func commandButton(_ title: String, systemImage: String, command: String) -> some View {
        Button {
            onSubmitCommand(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(isActionDisabled)
    }
}

/// Persistent goal status above the composer, using the same pill-to-card
/// interaction as the plan surface rather than pinning a verbose server notice.
struct GoalStatusSurface: View {
    let goal: SubmittedGoal
    @Binding var isExpanded: Bool
    var isLive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.planDockHeight) private var availableHeight
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ActivityBeamStyle.storageKey) private var beamStyleRawValue = ActivityBeamStyle.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    @State private var measuredContentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                details
            }
            header
        }
        .fixedSize(horizontal: true, vertical: false)
        .composerStatusSurface(
            isExpanded: isExpanded,
            palette: palette,
            beamStyle: beamStyle,
            beamActive: isExpanded && isRunning && beamStyle.isVisible
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        Button {
            withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                GoalStatusGlyph(
                    status: goal.presentationStatus,
                    isRunning: isRunning,
                    reduceMotion: reduceMotion,
                    tint: statusTint
                )
                .frame(width: 14, height: 14)

                Text(statusLabel)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .opacity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Goal, \(statusLabel).")
        .accessibilityHint(isExpanded ? "Double tap to collapse the goal." : "Double tap to expand the goal.")
        .accessibilityIdentifier("goal.header")
    }

    private var details: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Goal")
                    .font(AppFont.footnote().weight(.semibold))
                    .foregroundStyle(palette.textSecondary)

                Text(goal.displayGoal)
                    .font(AppFont.body())
                    .foregroundStyle(palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = goal.turnProgress,
                   let turnsUsed = goal.turnsUsed,
                   let maxTurns = goal.maxTurns {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: progress)
                            .tint(statusTint)
                        Text("\(turnsUsed) of \(maxTurns) turns")
                            .font(AppFont.caption())
                            .foregroundStyle(palette.textTertiary)
                            .monospacedDigit()
                    }
                }

                if let verdict = nonempty(goal.lastVerdict) {
                    metadataRow(label: "Last verdict", value: verdict)
                }
                if let reason = nonempty(goal.lastReason) {
                    metadataRow(label: "Reason", value: reason)
                }
                if let pausedReason = nonempty(goal.pausedReason) {
                    metadataRow(label: "Paused", value: pausedReason)
                }
            }
            .frame(width: GoalStatusSurfaceLayout.contentWidth, alignment: .leading)
            .padding(.horizontal, ComposerStatusSurfaceMetrics.horizontalPadding)
            .padding(.top, ComposerStatusSurfaceMetrics.topPadding)
            .padding(.bottom, ComposerStatusSurfaceMetrics.bottomPadding)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GoalContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(height: detailsHeight, alignment: .top)
        .scrollClipDisabled(false)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .onPreferenceChange(GoalContentHeightKey.self) { height in
            guard height > 0 else { return }
            measuredContentHeight = height
        }
        .overlay(alignment: .bottomTrailing) {
            if measuredContentHeight > detailsHeight + 1 {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.textSecondary)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint("Swipe vertically to read the full goal.")
        .accessibilityIdentifier("goal.details-scroll")
    }

    private func metadataRow(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppFont.caption().weight(.semibold))
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(AppFont.footnote())
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var detailsHeight: CGFloat {
        GoalStatusSurfaceLayout.detailsHeight(
            measuredContentHeight: measuredContentHeight,
            goalLength: goal.displayGoal.count,
            availableHeight: availableHeight
        )
    }

    private var isRunning: Bool {
        isLive && goal.presentationStatus == .active
    }

    private var statusLabel: String {
        isRunning ? String(localized: "Running") : goal.presentationStatus.label
    }

    private var statusTint: Color {
        switch goal.presentationStatus {
        case .active: HeaderLogoColor.color(for: headerLogoColorHex)
        case .paused: .orange
        case .done: .green
        case .cleared: .secondary
        case .unknown: palette.textSecondary
        }
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }

    private var beamStyle: BeamStyle {
        let stored = ActivityBeamStyle.storedValue(beamStyleRawValue)
        let effective: ActivityBeamStyle = stored == .off ? .off : .accent
        return BeamStyle(
            resolved: effective.resolved(
                palette: palette,
                colorScheme: colorScheme,
                accent: HeaderLogoColor.color(for: headerLogoColorHex)
            )
        )
    }
}

/// Pure sizing policy for regression tests: even an enormous goal remains below
/// half of the live dock and short goals do not create a needlessly tall card.
enum GoalStatusSurfaceLayout {
    static let contentWidth: CGFloat = 268
    static let maximumHeight: CGFloat = 300
    static let minimumHeight: CGFloat = 96
    static let maximumDockFraction: CGFloat = 0.44
    static let estimatedLineHeight: CGFloat = 21
    static let estimatedCharactersPerLine = 32
    static let fixedContentHeight: CGFloat = 86

    static func detailsHeight(
        measuredContentHeight: CGFloat,
        goalLength: Int,
        availableHeight: CGFloat
    ) -> CGFloat {
        let lineCount = max(1, Int(ceil(Double(max(0, goalLength)) / Double(estimatedCharactersPerLine))))
        let estimate = fixedContentHeight + CGFloat(lineCount) * estimatedLineHeight
        let natural = measuredContentHeight > 0 ? measuredContentHeight : estimate
        let ceiling = min(maximumHeight, max(minimumHeight, availableHeight * maximumDockFraction))
        return min(max(minimumHeight, natural), ceiling)
    }
}

private struct GoalContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct GoalStatusGlyph: View {
    let status: GoalPresentationStatus
    let isRunning: Bool
    let reduceMotion: Bool
    let tint: Color

    @State private var spinning = false

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                spinning
                    ? .linear(duration: 2.2).repeatForever(autoreverses: false)
                    : .snappy(duration: 0.24),
                value: spinning
            )
            .animation(
                reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.28, extraBounce: 0.08),
                value: status
            )
            .onAppear { spinning = isRunning && !reduceMotion }
            .onChange(of: isRunning) { _, running in
                spinning = running && !reduceMotion
            }
            .onChange(of: reduceMotion) { _, isReduced in
                spinning = isRunning && !isReduced
            }
    }

    private var symbolName: String {
        switch status {
        case .active: isRunning ? "circle.dotted" : "target"
        case .paused: "pause.circle.fill"
        case .done: "checkmark.circle.fill"
        case .cleared: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct GoalSubmissionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var goalDraft: String
    let isSubmitting: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $goalDraft)
                .font(.body)
                .padding()
                .scrollContentBackground(.hidden)
                .appSurfaceBackground(.canvas)
                .navigationTitle("Set Goal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Set") {
                            let submittedGoal = goalDraft
                            dismiss()
                            onSubmit(submittedGoal)
                        }
                        .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .adaptiveFormPresentation()
    }
}
