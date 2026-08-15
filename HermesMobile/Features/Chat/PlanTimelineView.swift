import SwiftUI

/// The agent's plan, as a collapsed progress pill that opens into a checklist.
///
/// Sits above the composer rather than inside the transcript, because
/// `todo_state` is session state and not turn history — the server re-sends the
/// whole list on every write, so a transcript-embedded card would stack a stale
/// copy per update. One pinned surface, always showing the latest snapshot.
struct PlanTimelineView: View {
    let state: TodoState
    @Binding var isExpanded: Bool
    /// Whether the session still has work in flight. Gates the beam.
    ///
    /// Every other beam in the app is activity-gated, but this is the one
    /// surface designed to *stay* open, so without a liveness input an expanded
    /// plan on an idle session drives a 30fps timeline and a per-frame
    /// rasterization forever. That is a battery cost with nothing to report.
    var isLive: Bool = false
#if DEBUG
    /// Gallery-only deterministic interaction driver. Production always leaves
    /// this at zero; page 20 advances 0 -> 1 -> 2 to prove a long task opens
    /// and closes through the same local state path as a tap.
    var debugRowInteractionPhase: Int = 0
#endif

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ActivityBeamStyle.storageKey) private var beamStyleRawValue = ActivityBeamStyle.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex


    /// Natural height of each checklist row. Keeping the measurements separate
    /// lets the scroll window stop after exactly five tasks even when one row
    /// wraps or has been opened to show its full text.
    @State private var measuredRowHeights: [Int: CGFloat] = [:]

    /// Rows start as compact two-line summaries. Expansion belongs to this
    /// surface rather than the snapshot model because it is presentation state
    /// and should reset when the whole plan is dismissed.
    @State private var expandedRowOffsets: Set<Int> = []

    /// Height of the space the card is docked in, from the environment rather
    /// than the screen: on iPad Split View and with the keyboard raised the
    /// screen is not what the card actually gets.
    @Environment(\.planDockHeight) private var availableHeight

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                expandedRows
            }

            header
        }
        // Hugs its content instead of filling the transcript width. A plan is a
        // short list of short lines; a full-width slab over the composer reads
        // as a sheet rather than an inline status surface. The cap is enforced
        // on the row labels (see `PlanRowLabel`), so the card ends up as wide as
        // its longest *wrapped* row rather than its longest ideal one.
        .fixedSize(horizontal: true, vertical: false)
        .composerStatusSurface(
            isExpanded: isExpanded,
            palette: palette,
            beamStyle: beamStyle,
            beamActive: isExpanded && isPlanRunning && beamStyle.isVisible
        )
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                expandedRowOffsets.removeAll()
            }
        }
        .onChange(of: state.todos.count) { _, count in
            expandedRowOffsets = expandedRowOffsets.filter { $0 < count }
            measuredRowHeights = measuredRowHeights.filter { $0.key < count }
        }
#if DEBUG
        .onChange(of: debugRowInteractionPhase) { _, phase in
            guard !state.todos.isEmpty else { return }
            if phase == 1 {
                if !expandedRowOffsets.contains(0) { toggleRowDetail(at: 0) }
            } else if phase == 2 {
                if expandedRowOffsets.contains(0) { toggleRowDetail(at: 0) }
            }
        }
#endif
        .accessibilityElement(children: .contain)
    }

    // MARK: - Collapsed pill

    private var header: some View {
        Button {
            withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                progressGlyph

                Text(progressLabel)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.textSecondary)
                    // Rolls the digit instead of hard-cutting when a step
                    // completes. This pill is on screen for the whole run, so
                    // it is the counter the user actually watches.
                    .contentTransition(
                        reduceMotion ? .identity : .numericText(value: Double(state.currentStep))
                    )
                    .lineLimit(1)
            }
            // Roomier than a status chip: the pill is the resting state of this
            // surface, so it reads as a control rather than a label. No chevron
            // — the whole pill is the hit target, and the affordance is the
            // floating shape itself.
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            // No surface of its own. The outer view owns the one background,
            // border, glass, and shadow for both states; the header only
            // supplies its hit target. Giving the header its own glass meant a
            // second `glassEffect` capsule stayed rendered inside the expanded
            // card — `glassEffect` paints its own surface and specular edge, so
            // fading the *fill and stroke* to zero could not hide it. That was
            // the double outline.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded ? "Double tap to collapse the plan." : "Double tap to expand the plan.")
    }

    @ViewBuilder
    private var progressGlyph: some View {
        // A plan whose steps were all *cancelled* is not a success. Only the
        // genuinely-completed case earns the green check.
        if state.isFinished, !state.hasCancelledWork {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green.opacity(0.85))
        } else if state.isFinished {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.55))
        } else {
            PlanProgressRing(
                fraction: completionFraction,
                reduceMotion: reduceMotion,
                // Accent-tinted rather than gray: in the collapsed pill the ring
                // is the only live element, and a gray arc on a gray capsule
                // reads as decoration instead of progress.
                tint: HeaderLogoColor.color(for: headerLogoColorHex),
                trackTint: palette.textTertiary
            )
            .frame(width: 13, height: 13)
        }
    }

    // MARK: - Expanded checklist

    /// The checklist, always inside a bounded scroll window, so a long plan
    /// cannot push its own collapse control off the screen.
    ///
    /// The card is docked above the composer and grows upward, so before this
    /// an eight-step plan ran off the top of the display: the trailing rows
    /// were clipped and the header — the only way to close it — went with them.
    /// The plan could be opened and then never collapsed.
    ///
    /// **Why the window is unconditional.** The first cap keyed the scroll
    /// path on *step count* (> `maximumVisibleRows`), which left the short
    /// path completely unbounded — a seven-step plan whose rows wrap at a
    /// large type size, or a card caught by a squeezed dock (keyboard up,
    /// Split View), could still overrun the composer with no way to scroll or
    /// close (the field report: rows cut off behind the composer, header
    /// unreachable, nothing scrollable). The window's height equals the
    /// content's natural height whenever it fits, so a short plan lays out
    /// pixel-identically to the old path; the `ScrollView` only actually
    /// scrolls (`basedOnSize`) when the content genuinely exceeds the window.
    ///
    private var expandedRows: some View {
        ScrollView(.vertical) {
            paddedRows
        }
        // Never nil. A ScrollView is greedy, so an absent height means it
        // takes everything offered — which is how the original bug looked.
        // `windowHeight` always returns a bounded value, so a rebuild that
        // clears the measurement costs at most one frame at the estimated
        // height rather than an overflow.
        .frame(height: windowHeight, alignment: .top)
        .scrollClipDisabled(false)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .onPreferenceChange(PlanRowHeightsKey.self) { heights in
            guard !heights.isEmpty else { return }
            withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
                measuredRowHeights.merge(heights) { _, latest in latest }
            }
        }
    }

    private var paddedRows: some View {
        rows
            .padding(.horizontal, ComposerStatusSurfaceMetrics.horizontalPadding)
            .padding(.top, ComposerStatusSurfaceMetrics.topPadding)
            .padding(.bottom, ComposerStatusSurfaceMetrics.bottomPadding)
    }

    /// Five tasks stay visible before the checklist scrolls. This keeps the
    /// card compact enough to leave useful transcript context on a phone.
    static let maximumVisibleRows = PlanTimelineLayout.maximumVisibleRows

    /// Height of the checklist's scroll window — used for every expanded plan.
    ///
    /// **Never optional.** A `ScrollView` is greedy: give it no height and it
    /// takes everything offered, which is exactly how the original overflow
    /// looked. So this always returns a bounded value: the smaller of the
    /// compact content height (a fitting plan renders identically to an
    /// unwindowed one), the first `maximumVisibleRows` measured rows, and a
    /// share of the dock the card actually sits in. Before the first
    /// measurement lands it estimates from the row count, clamped by the same
    /// dock ceiling, so a rebuild that clears the measurement (leaving and
    /// re-entering a session, returning from the background) costs at most one
    /// frame at the estimate rather than an overflowing card.
    ///
    /// The first five row heights are measured separately rather than averaged
    /// across the whole plan, so an expanded task or Dynamic Type wrapping
    /// cannot make the nominal five-task window accidentally show six.
    private var windowHeight: CGFloat {
        PlanTimelineLayout.windowHeight(
            rowHeights: measuredRowHeights,
            todoCount: state.todos.count,
            availableHeight: availableHeight
        )
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Index-qualified identity: `TodoItem.id` falls back to its content
            // when the server omits an id, so two id-less rows with the same
            // text would collide and recycle onto each other mid-animation.
            ForEach(Array(state.todos.enumerated()), id: \.offset) { index, todo in
                PlanRowView(
                    index: index + 1,
                    todo: todo,
                    palette: palette,
                    reduceMotion: reduceMotion,
                    // A row stays `in_progress` forever if the stream dies
                    // before a final snapshot, so the spin follows session
                    // liveness rather than the row's status alone.
                    isLive: isLive,
                    isDetailExpanded: expandedRowOffsets.contains(index),
                    onToggleDetail: { toggleRowDetail(at: index) },
                    onCollapsePlan: collapsePlan
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PlanRowHeightsKey.self,
                            value: [index: proxy.size.height]
                        )
                    }
                }
                .transition(ChatMotion.cardContentTransition(reduceMotion: reduceMotion))
                .animation(
                    ChatMotion.cardContent(
                        reduceMotion: reduceMotion,
                        delay: ChatMotion.cardContentLeadIn
                            + ChatMotion.cardRowDelay(index: staggerIndex(for: index), reduceMotion: reduceMotion)
                    ),
                    value: isExpanded
                )
            }
        }
    }

    private func toggleRowDetail(at index: Int) {
        withAnimation(ChatMotion.quickState(reduceMotion: reduceMotion)) {
            if expandedRowOffsets.contains(index) {
                expandedRowOffsets.remove(index)
            } else {
                expandedRowOffsets.insert(index)
            }
        }
    }

    private func collapsePlan() {
        withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
            isExpanded = false
        }
    }

    // MARK: - Derived


    /// Upper bound so a long step can't stretch the card back to full width on
    /// a large phone. Past this the row wraps instead.
    ///
    /// `fixedSize` alone was not enough: it sizes to the widest row's *ideal*
    /// width, and a five-word step is already wider than this, so the card kept
    /// filling the screen. Capping the row label is what actually makes the
    /// card narrow — the cap has to bite on the text, not just the container.
    static let maximumWidth: CGFloat = 268

    /// The plan is doing work: a row is in progress and the session still has
    /// a stream attached. A finished plan, or one left open on an idle session,
    /// has nothing to report and must not keep the beam running.
    private var isPlanRunning: Bool {
        isLive && state.todos.contains { $0.status == .inProgress }
    }

    private var beamStyle: BeamStyle {
        // Follows the accent hue rather than the user's global beam style, so
        // the plan's edge matches the orange running mark on the tool rows —
        // both are "this is live" in the same color. `.off` still wins, because
        // that setting means the user wants no traveling edges anywhere.
        //
        // Note the tool indicator's orange is the *accent* (`HeaderLogoColor`,
        // default #FFD700), not the `ember` preset, so `.accent` is what
        // actually matches it.
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

    /// Stagger order, measured from the pill outward.
    ///
    /// This card is anchored at its *bottom* (the pill sits above the composer)
    /// and grows upward, so it uncovers its last row first. Staggering in
    /// natural top-down order therefore fights the reveal: the rows the user
    /// can already see are the ones still waiting to fade in. Counting from the
    /// bottom row makes the fade follow the opening edge.
    private func staggerIndex(for index: Int) -> Int {
        max(0, state.todos.count - 1 - index)
    }

    private var completionFraction: Double {
        guard !state.todos.isEmpty else { return 0 }
        let resolved = state.todos.filter { $0.status.isResolved }.count
        return Double(resolved) / Double(state.todos.count)
    }

    private var progressLabel: String {
        if state.isFinished {
            return "\(state.todos.count) of \(state.todos.count)"
        }
        return "\(state.currentStep) of \(state.todos.count)"
    }

    private var accessibilityLabel: String {
        let done = state.todos.filter { $0.status == .completed }.count
        return "Plan, \(done) of \(state.todos.count) steps complete."
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }
}

// MARK: - Row

/// One numbered plan step.
private struct PlanRowView: View {
    let index: Int
    let todo: TodoItem
    let palette: ChatPalette
    let reduceMotion: Bool
    /// Session still streaming; see `PlanTimelineView.isLive`.
    var isLive: Bool = false
    let isDetailExpanded: Bool
    let onToggleDetail: () -> Void
    let onCollapsePlan: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            PlanStatusGlyph(
                status: todo.status,
                reduceMotion: reduceMotion,
                palette: palette,
                isLive: isLive
            )
                .frame(width: 15, height: 15)

            Text("\(index).")
                .font(AppFont.footnote().monospacedDigit())
                .foregroundStyle(palette.textTertiary)

            PlanRowLabel(
                text: todo.content,
                isStruck: todo.status.isResolved,
                color: todo.status.isResolved ? palette.textTertiary : palette.textPrimary,
                reduceMotion: reduceMotion,
                isExpanded: isDetailExpanded,
                onToggleDetail: onToggleDetail
            )
            .frame(maxWidth: PlanTimelineView.maximumWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDetailExpanded {
                onToggleDetail()
            } else {
                onCollapsePlan()
            }
        }
        // Status is otherwise conveyed only by symbol shape and color, neither
        // of which VoiceOver reads.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index), \(statusDescription): \(todo.content)")
        .accessibilityHint(
            isDetailExpanded
                ? "Double tap to show only the first two lines."
                : "Double tap to show the full step."
        )
        .accessibilityIdentifier("plan-step-\(index)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggleDetail() }
        .accessibilityAction(
            named: "Collapse plan",
            onCollapsePlan
        )
    }

    private var statusDescription: String {
        switch todo.status {
        case .pending: String(localized: "not started")
        case .inProgress: String(localized: "in progress")
        case .completed: String(localized: "completed")
        case .cancelled: String(localized: "cancelled")
        }
    }
}

/// Checkbox / spinner / cross for a plan row.
///
/// Status changes are an SF Symbol swap, so `.contentTransition(.symbolEffect(.replace))`
/// carries the transition natively — no custom animation for the tick itself.
/// (`.symbolEffect(.replace, value:)` is not the right spelling here: `replace`
/// is a content transition between two symbols, not a discrete effect fired at
/// one.)
private struct PlanStatusGlyph: View {
    let status: TodoItem.Status
    let reduceMotion: Bool
    let palette: ChatPalette
    var isLive: Bool = false

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(
                reduceMotion ? .easeOut(duration: 0.10) : .snappy(duration: 0.28, extraBounce: 0.08),
                value: status
            )
            .modifier(PlanSpinModifier(isActive: isLive && status == .inProgress, reduceMotion: reduceMotion))
    }

    private var symbolName: String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .pending: palette.textTertiary
        case .inProgress: palette.textPrimary.opacity(0.8)
        case .completed: Color.green.opacity(0.85)
        case .cancelled: Color.red.opacity(0.55)
        }
    }
}

/// Continuous rotation for the in-progress row.
///
/// Deliberately `.animation(_:value:)` on a plain rotation rather than a
/// `TimelineView`: timelines ignore low-frequency mode and keep ticking
/// off-screen, which is the pattern the tool rows had to move away from.
private struct PlanSpinModifier: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool
    @State private var spinning = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                spinning
                    ? .linear(duration: 2.4).repeatForever(autoreverses: false)
                    : .default,
                value: spinning
            )
            .onAppear { spinning = isActive && !reduceMotion }
            .onChange(of: isActive) { _, active in spinning = active && !reduceMotion }
    }
}

/// Row text whose strikethrough sweeps in from the leading edge.
///
/// SwiftUI's `.strikethrough` toggles instantly, which reads as a hard cut on a
/// row that just completed. Drawing the rule as an overlay lets it animate its
/// own width, so the line draws itself across the words.
private struct PlanRowLabel: View {
    let text: String
    let isStruck: Bool
    let color: Color
    let reduceMotion: Bool
    let isExpanded: Bool
    let onToggleDetail: () -> Void

    var body: some View {
        Text(text)
            .font(AppFont.footnote())
            .foregroundStyle(color)
            .lineLimit(isExpanded ? nil : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomTrailing) {
                if !isExpanded {
                    Button(action: onToggleDetail) {
                        // SwiftUI owns the actual trailing ellipsis. Overlay a
                        // clear 44x44pt target around that location so a thumb
                        // does not have to land on three tiny glyphs. Keeping
                        // it to Apple's standard minimum avoids stealing a
                        // normal center-card tap, which collapses the plan.
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Once open, the task itself is the collapse target; the user
                // no longer has to chase an ellipsis that is no longer shown.
                if isExpanded {
                    onToggleDetail()
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(color)
                        .frame(width: isStruck ? proxy.size.width : 0, height: 1)
                        .offset(y: proxy.size.height / 2)
                        // Single-line rows get a true sweep. A wrapped row would
                        // need one rule per line, so the overlay stands down and
                        // the row relies on its dimmed foreground instead.
                        .opacity(proxy.size.height > 24 ? 0 : 1)
                        .animation(
                            reduceMotion ? .easeOut(duration: 0.10) : .easeOut(duration: 0.22),
                            value: isStruck
                        )
                }
                .allowsHitTesting(false)
            }
    }
}

/// Thin ring that fills as steps resolve — the collapsed pill's progress cue.
private struct PlanProgressRing: View {
    let fraction: Double
    let reduceMotion: Bool
    let tint: Color
    /// Unfilled track. Defaults to a faded `tint` when omitted.
    var trackTint: Color?

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder((trackTint ?? tint).opacity(0.3), lineWidth: 1.8)

            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(0.9)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.10) : .smooth(duration: 0.32, extraBounce: 0),
            value: fraction
        )
    }
}

/// Carries each checklist row's natural height up so the card can stop after
/// exactly five rows instead of estimating from one average height.
private struct PlanRowHeightsKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

/// Pure plan-window sizing, separated so row-count, wrapped-text, and squeezed
/// dock edge cases can be verified without snapshot-testing SwiftUI internals.
enum PlanTimelineLayout {
    static let maximumVisibleRows = 5
    static let maximumContainerFraction: CGFloat = 0.5
    static let minimumWindowHeight: CGFloat = 120
    static let estimatedRowHeight: CGFloat = 44
    static let topChrome = ComposerStatusSurfaceMetrics.topPadding
    static let bottomChrome = ComposerStatusSurfaceMetrics.bottomPadding
    static let verticalChrome = topChrome + bottomChrome

    static func windowHeight(
        rowHeights: [Int: CGFloat],
        todoCount: Int,
        availableHeight: CGFloat
    ) -> CGFloat {
        let ceiling = max(minimumWindowHeight, availableHeight * maximumContainerFraction)
        let visibleCount = min(max(0, todoCount), maximumVisibleRows)
        guard visibleCount > 0 else { return 0 }

        let visibleHeights = (0..<visibleCount).compactMap { rowHeights[$0] }
        let contentHeight: CGFloat
        let chrome = todoCount <= maximumVisibleRows ? verticalChrome : topChrome
        if visibleHeights.count == visibleCount {
            contentHeight = visibleHeights.reduce(0, +) + chrome
        } else {
            contentHeight = CGFloat(visibleCount) * estimatedRowHeight + chrome
        }
        return min(contentHeight, ceiling)
    }
}

private struct PlanDockHeightKey: EnvironmentKey {
    /// A mid-size phone, used only until a host supplies the real value.
    static let defaultValue: CGFloat = 844
}

extension EnvironmentValues {
    /// Height available to the composer dock, so the plan card can bound itself
    /// against the space it actually has rather than the whole screen.
    var planDockHeight: CGFloat {
        get { self[PlanDockHeightKey.self] }
        set { self[PlanDockHeightKey.self] = newValue }
    }
}
