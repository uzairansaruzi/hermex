import SwiftUI

struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    /// Live-phase override fed from `ChatViewModel.isToolPhaseActive` at the
    /// live call sites (defaults false for completed/historical groups). Keeps
    /// the capsule animating through the "composing the next tool call"
    /// window: every call in the live group may already be complete while the
    /// turn is still semantically in its tool step (the backend emits no
    /// argument-streaming events, so that window is otherwise silent).
    var isPhaseActive: Bool = false
    /// When embedded in a merged activity card the parent owns the container
    /// and its beam, so the block must not draw a competing one.
    var drawsOwnChrome: Bool = true
    /// Historical rows pre-mount their settled body while the outer Activity
    /// details are open, then preserve the transcript's exact viewport when
    /// the user expands this inner section. Live tool groups remain lazy.
    var preparesHistoricalDisclosure: Bool = false
    /// Default expansion when the reader has not toggled this block. See
    /// `ReasoningBlockView.startsExpandedOverride` — production passes nil so
    /// sections open as pills; debug galleries force `true`.
    var startsExpandedOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.preserveActivityExpansionPosition) private var preserveActivityExpansionPosition
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?
    /// Natural height of the runs list, measured rather than estimated — the
    /// same discipline as `PlanTimelineView`: an estimated per-row constant
    /// under-measures wrapped rows and silently defeats the cap.
    @State private var measuredRunsHeight: CGFloat?
    @State private var measuredBodyHeight: CGFloat = 0

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle(rawValue: backgroundStyleRawValue) ?? .defaultValue,
            temperature: ChatPaletteTemperature(rawValue: paletteTemperatureRawValue) ?? .defaultValue
        )
    }

    private var isExpanded: Bool {
        #if DEBUG
        if let forced = disclosureLabExpansion { return forced }
        #endif
        return ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpandedOverride ?? startsExpanded
        )
    }

    private var presentsExpandedBody: Bool {
        isExpanded && measuredBodyHeight > 0
    }

    private var keepsBodyMounted: Bool {
        preparesHistoricalDisclosure || isExpanded
    }

    #if DEBUG
    @Environment(\.disclosureLabExpansion) private var disclosureLabExpansion
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: presentsExpandedBody ? 8 : 0) {
            ActivityCapsuleView(
                orbState: runningOrbState,
                label: capsuleLabel,
                isActive: isRunning,
                completedIcon: activityIcon,
                completedIconColor: group.hasFailedTool ? .red : nil,
                completedLabel: completedCapsuleLabel,
                accessory: AnyView(headerTrailing),
                onTap: toggleExpansion,
                chrome: presentsExpandedBody ? .none : .pill
            )
            .accessibilityLabel(activityAccessibilityLabel)
            .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

            if keepsBodyMounted {
                toolBody
            }
        }
        // Expanded, the block is one bordered container carrying one beam;
        // collapsed, the capsule keeps its own pill chrome. Radius 20 rather
        // than the composer's 22: the same value on a smaller shape reads
        // rounder, and the collapsed row stays a true capsule regardless.
        .modifier(
            ToolBlockChrome(
                palette: palette,
                isExpanded: presentsExpandedBody,
                drawsSurface: drawsOwnChrome,
                reduceMotion: reduceMotion,
                isActive: isRunning
            )
        )
        // See `ReasoningBlockView`: the rows report full height immediately
        // while the container's height spring is still running, so unclipped
        // they render outside the block and overlap the neighbouring section.
        .clipShape(ActivityBlockChrome.shape())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var toolBody: some View {
        boundedRunsList
            .padding(.leading, 8)
            .opacity(presentsExpandedBody ? 1 : 0)
            .animation(
                ChatMotion.cardContent(
                    reduceMotion: reduceMotion,
                    delay: ChatMotion.cardContentLeadIn
                ),
                value: presentsExpandedBody
            )
            // Premeasure at the same width the rows receive once the outer
            // ToolBlockChrome adds its expanded horizontal inset. Exchanging
            // these insets in the same disclosure transaction prevents wrapped
            // previews from forcing a late second height.
            .padding(
                .horizontal,
                presentsExpandedBody ? 0 : ActivityBlockChrome.horizontalPadding
            )
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ToolBodyHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .frame(height: presentsExpandedBody ? measuredBodyHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(presentsExpandedBody)
            .accessibilityHidden(!presentsExpandedBody)
            .onPreferenceChange(ToolBodyHeightKey.self, perform: updateMeasuredBodyHeight)
    }

    private func toggleExpansion() {
        let willExpand = !isExpanded
        if willExpand, preparesHistoricalDisclosure {
            preserveActivityExpansionPosition()
        }

        withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
            userToggledExpansion = willExpand
        }
    }

    private func updateMeasuredBodyHeight(_ height: CGFloat) {
        guard height > 0, abs(height - measuredBodyHeight) > 0.5 else { return }
        let firstMeasurement = measuredBodyHeight == 0
        let animation: Animation? = if firstMeasurement, isExpanded {
            ChatMotion.cardExpand(reduceMotion: reduceMotion)
        } else if presentsExpandedBody {
            ChatMotion.disclosure(reduceMotion: reduceMotion)
        } else {
            nil
        }
        withAnimation(animation) {
            measuredBodyHeight = height
        }
    }

    /// Live counts plus the disclosure chevron. "2 running · 2 waiting" is the
    /// one genuinely new piece of information the old capsule never surfaced —
    /// it reports mid-turn state instead of only a post-hoc summary.
    private var headerTrailing: some View {
        HStack(spacing: 8) {
            if let counts = liveCountsText {
                Text(counts)
                    .font(AppFont.caption())
                    .foregroundStyle(palette.textTertiary)
                    .lineLimit(1)
            }
            chevron
        }
    }

    private var liveCountsText: String? {
        guard isRunning else { return nil }
        let running = group.toolCalls.filter { !$0.isCompleted }.count
        guard running > 0 else { return nil }
        let done = group.toolCalls.count - running
        guard done > 0 else {
            return String(localized: "\(running) running")
        }
        return String(localized: "\(running) running · \(done) done")
    }

    /// The runs list, capped to `maximumVisibleRows` and scrollable beyond
    /// that, so a long turn cannot wall off the transcript.
    ///
    /// A 68-tool turn used to render all 68 rows inline — roughly four screens
    /// of tool rows sitting between the summary and the answer. The cap is
    /// eight rows, matching the summary row's eight result dots, so the two
    /// surfaces describe the same window of the turn.
    ///
    /// Structure mirrors `PlanTimelineView.expandedRows`: a group at or under
    /// the cap renders with no scroll view, no measurement, and no view state
    /// at all — the overwhelmingly common case lays out exactly as before.
    /// Only a longer group takes the scrolling path, and that path's height is
    /// never optional, because a `ScrollView` given no height takes everything
    /// offered — which is precisely how the original overflow looked.
    @ViewBuilder
    private var boundedRunsList: some View {
        if group.toolCalls.count <= Self.maximumVisibleRows {
            runsList
        } else {
            ScrollView(.vertical) {
                runsList
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ToolRunsHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
            }
            .frame(height: scrollWindowHeight, alignment: .top)
            // A live group appends rows at the bottom; anchor there so the
            // newest tool stays visible while the turn runs. Settled groups
            // read top-down like any other record.
            .defaultScrollAnchor(isRunning ? .bottom : .top)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .onPreferenceChange(ToolRunsHeightKey.self) { height in
                guard height > 0 else { return }
                measuredRunsHeight = height
            }
        }
    }

    /// How many tool rows stay visible before the list scrolls. Deliberately
    /// the same eight as `TurnActivitySummaryRow`'s result-dot cap.
    static let maximumVisibleRows = 8

    /// Bounded window height for the scrolling path. Never nil — see
    /// `boundedRunsList`. Falls back to a conservative constant until the
    /// first measurement lands, so a rebuild that clears the measurement costs
    /// one frame at the fallback height rather than an overflowing card. The
    /// per-row height comes from the measured content, so the window
    /// self-calibrates to Dynamic Type, wrapped previews, and rows the reader
    /// has expanded inline.
    private var scrollWindowHeight: CGFloat {
        ToolActivityListWindow.height(
            measuredRowsHeight: measuredRunsHeight,
            rowCount: group.toolCalls.count
        )
    }

    /// Expanded body: sequential calls at the base level, parallel batches
    /// indented once behind a rail. Exactly one extra level, ever — the
    /// agent's batches are flat (announce-all-then-run), so clusters cannot
    /// nest. Every running row's indicator is painted by the single overlay
    /// applied here, not per row.
    private var runsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(group.runs.enumerated()), id: \.element.id) { runOffset, run in
                if run.isParallel {
                    parallelCluster(run, rowOffset: rowOffset(before: runOffset))
                } else if let toolCall = run.toolCalls.first {
                    ToolCallCardView(
                        toolCall: toolCall,
                        isNestedInGroup: true,
                        indicatorRowIndex: rowOffset(before: runOffset),
                        isBlockActive: isRunning
                    )
                    .modifier(
                        CardRowReveal(
                            index: rowOffset(before: runOffset),
                            isVisible: presentsExpandedBody,
                            reduceMotion: reduceMotion
                        )
                    )
                }
            }
        }
        .toolRunIndicatorOverlay()
    }

    /// Running count of rows before a run, so every row in the block gets a
    /// distinct stagger index. Using the run offset alone made a cluster's
    /// second row and the next sequential row pulse in lockstep.
    private func rowOffset(before runIndex: Int) -> Int {
        group.runs.prefix(runIndex).reduce(0) { $0 + $1.toolCalls.count }
    }

    private func parallelCluster(_ run: ToolCallRun, rowOffset: Int) -> some View {
        // Rail idiom rather than a computed Path: the rail stretches to the
        // VStack's height by layout, so it survives wrapped labels and
        // accessibility sizes with no geometry math.
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(palette.tableRule)
                .frame(width: 1.5)

            VStack(alignment: .leading, spacing: 6) {
                Text("Parallel · \(run.toolCalls.count)")
                    .font(AppFont.caption2(weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(palette.textTertiary)

                ForEach(Array(run.toolCalls.enumerated()), id: \.element.id) { index, toolCall in
                    ToolCallCardView(
                        toolCall: toolCall,
                        isNestedInGroup: true,
                        indicatorRowIndex: rowOffset + index,
                        isBlockActive: isRunning
                    )
                    .modifier(
                        CardRowReveal(
                            index: rowOffset + index,
                            isVisible: presentsExpandedBody,
                            reduceMotion: reduceMotion
                        )
                    )
                }
            }
        }
        .padding(.leading, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(run.toolCalls.count) tools running in parallel"))
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Live label: verb from the active tool plus the group count, e.g.
    /// "Reading files · 3". Single-tool groups just use the verb phrase.
    private var capsuleLabel: String {
        let verb = activityVerb
        guard group.toolCalls.count > 1 else { return verb }
        return "\(verb) · \(group.toolCalls.count)"
    }

    private var completedCapsuleLabel: String {
        if group.hasFailedTool {
            return String(localized: "Tool failed")
        }
        let count = group.toolCalls.count
        let base = count == 1
            ? String(localized: "Ran 1 tool")
            : String(localized: "Ran \(count) tools")

        // Sum reported durations for a "Ran 3 tools in 8s" summary; if no
        // call reported one, keep the plain count label.
        let durations = group.toolCalls.compactMap(\.duration)
        guard !durations.isEmpty else { return base }
        let total = durations.reduce(0, +)
        return String(localized: "\(base) in \(ActivityDurationFormat.string(total))")
    }

    private var activityVerb: String {
        switch runningOrbState {
        case .thinking:
            String(localized: "Thinking")
        case .searching:
            String(localized: "Reading")
        case .writing:
            String(localized: "Writing")
        case .connecting:
            String(localized: "Connecting")
        case .working:
            String(localized: "Working")
        case .shaping:
            String(localized: "Running")
        case .solving:
            String(localized: "Checking")
        case .listening:
            String(localized: "Waiting")
        }
    }

    private var activityIcon: String {
        if group.hasFailedTool {
            return "exclamationmark.triangle.fill"
        }

        return group.isComplete ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill"
    }

    private var isRunning: Bool {
        !group.hasFailedTool && (!group.isComplete || isPhaseActive)
    }

    private var runningOrbState: ThinkingOrbState {
        let activeTool = group.toolCalls.first { !$0.isCompleted } ?? group.toolCalls.last
        return ThinkingOrbState.forTool(name: activeTool?.name)
    }

    private var activityAccessibilityLabel: String {
        "\(group.activityTitle), \(activityStateText), \(summaryText)"
    }

    private var activityStateText: String {
        if group.hasFailedTool {
            return String(localized: "Failed")
        }

        return group.isComplete ? String(localized: "Completed") : String(localized: "Running")
    }

    private var summaryText: String {
        let names = group.toolCalls.map(\.displayName)
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) {
                result.append(name)
            }
        }

        guard !uniqueNames.isEmpty else {
            return String(localized: "No tools")
        }

        let visibleNames = uniqueNames.prefix(3)
        let remainingCount = uniqueNames.count - visibleNames.count
        let visibleSummary = visibleNames.joined(separator: ", ")

        guard remainingCount > 0 else {
            return visibleSummary
        }

        return "\(visibleSummary), +\(remainingCount)"
    }
}

/// One border and one beam for an expanded tool block.
///
/// Collapsed, the header capsule keeps its own pill chrome and this does
/// nothing. Expanded, the block becomes the single bordered container — the
/// header's chrome is switched off — so exactly one border and at most one
/// beam animate per turn step regardless of how many tools are inside.
private struct ToolBlockChrome: ViewModifier {
    let palette: ChatPalette
    /// Owns the padding — see `ReasoningBlockChrome` for why this must stay
    /// separate from surface ownership.
    let isExpanded: Bool
    /// False when this block is a section inside `ActivityContainerView`.
    let drawsSurface: Bool
    /// Phase-1 curve for the chrome itself; the height rides `cardExpand`.
    var reduceMotion: Bool = false
    let isActive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ActivityBeamStyle.storageKey) private var beamStyleRawValue = ActivityBeamStyle.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex


    /// Single branch on purpose — see `ReasoningBlockChrome`. Branching on
    /// `isEnabled` changes view identity and replaces the subtree mid-animation
    /// instead of animating it.
    func body(content: Content) -> some View {
        let showsSurface = isExpanded && drawsSurface
        content
            .padding(.horizontal, isExpanded ? ActivityBlockChrome.horizontalPadding : 0)
            .padding(.top, isExpanded ? ActivityBlockChrome.topPadding : 0)
            .padding(.bottom, isExpanded ? ActivityBlockChrome.bottomPadding : 0)
            .background(
                shape.fill(palette.surface.opacity(0.8))
                    .opacity(showsSurface ? 1 : 0)
            )
            .overlay(
                shape.strokeBorder(palette.tableRule, lineWidth: 1)
                    .opacity(showsSurface ? 1 : 0)
            )
            // Beam only when this block owns its surface; embedded, the
            // container carries it so exactly one beam animates per turn.
            .borderBeam(style: beamStyle, shape: shape, active: showsSurface && isActive)
            .animation(ChatMotion.cardChrome(reduceMotion: reduceMotion), value: showsSurface)
    }

    /// Shared with the thinking block so both read as the same card family.
    private var shape: RoundedRectangle {
        ActivityBlockChrome.shape()
    }

    private var beamStyle: BeamStyle {
        BeamStyle(
            resolved: ActivityBeamStyle.storedValue(beamStyleRawValue).resolved(
                palette: palette,
                colorScheme: colorScheme,
                accent: HeaderLogoColor.color(for: headerLogoColorHex)
            )
        )
    }
}

/// Staggered fade for one row inside an expanding card.
///
/// The row's opacity is driven by the block's expansion with a per-index delay,
/// so the card populates top-down as it opens instead of every row landing on
/// the same frame. Only `opacity` animates — the row's layout is already
/// established by the container's spring, so nothing moves independently and
/// there is no second layout pass per row.
private struct CardRowReveal: ViewModifier {
    let index: Int
    let isVisible: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(
                ChatMotion.cardContent(
                    reduceMotion: reduceMotion,
                    delay: isVisible
                        ? ChatMotion.cardContentLeadIn
                            + ChatMotion.cardRowDelay(index: index, reduceMotion: reduceMotion)
                        // Collapsing runs in one beat: a reverse stagger reads
                        // as the card struggling to close.
                        : 0
                ),
                value: isVisible
            )
    }
}

/// Reports the natural height of a group's runs list, so the scroll window
/// can size itself from measured rows rather than an estimate.
private struct ToolRunsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ToolBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Pure sizing rule for the capped tool list. Non-private so the unit suite
/// can pin the arithmetic without rendering a view.
enum ToolActivityListWindow {
    /// Fallback window height until the first measurement lands: eight rows at
    /// a compact row's ~28pt plus spacing. Deliberately conservative — one
    /// frame at a slightly-short window beats one frame of overflow.
    static let fallbackHeight: CGFloat = 240

    /// Bounded height for the scrolling window. Never nil by design: a
    /// `ScrollView` given no height takes everything offered.
    static func height(measuredRowsHeight: CGFloat?, rowCount: Int) -> CGFloat {
        guard let measuredRowsHeight, measuredRowsHeight > 0, rowCount > 0 else {
            return fallbackHeight
        }
        let averageRowHeight = measuredRowsHeight / CGFloat(rowCount)
        return averageRowHeight * CGFloat(ToolActivityGroupView.maximumVisibleRows)
    }
}
