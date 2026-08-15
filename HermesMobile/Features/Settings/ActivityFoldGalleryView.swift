#if DEBUG
import SwiftUI

/// Side-by-side of the turn-activity fold's two states
/// (`--surface-gallery-page 14`).
///
/// The point of this page is the *relationship* between collapsed and
/// expanded, not either state on its own — the complaint was that tapping
/// destroys one object and produces two unrelated ones somewhere else. Both
/// states render in one screenshot so the edges, widths, and control position
/// can be compared directly.
struct ActivityFoldGalleryView: View {
    /// Page 14 shows both states; page 16 is the re-parse probe.
    var page: Int = 14

    var body: some View {
        if page == 16 {
            FoldReparseProbeView()
        } else if page == 21 {
            LargeToolGroupSpecimen()
        } else if page == 22 {
            ThinkingRevealProbeView()
        } else {
            states
        }
    }

    private var states: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                specimen(
                    "COLLAPSED",
                    "Resting state after the answer starts.",
                    expanded: false
                )

                specimen(
                    "EXPANDED",
                    "After tapping the row.",
                    expanded: true
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func specimen(_ title: String, _ note: String, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            ActivityFoldSpecimen(startsExpanded: expanded)
        }
    }
}

/// One fold instance, forced into a fixed state.
///
/// `TurnActivityFoldView` owns its expansion internally, so the specimen drives
/// it the same way a reader would — by tapping — rather than by reaching into
/// its state. `isCollapsed: true` puts it in the folded resting state; the
/// expanded specimen then toggles once on appear.
private struct ActivityFoldSpecimen: View {
    let startsExpanded: Bool
    @State private var toggleTrigger = false

    var body: some View {
        TurnActivityFoldView(
            isCollapsed: true,
            initiallyCollapsed: true,
            animatesFold: false
        ) {
            // Mirrors the production composition in `ChatTranscriptView`: one
            // container, sections inside it, divider between them.
            ActivityContainerView {
                ReasoningBlockView(
                    text: Self.thought,
                    isStreaming: false,
                    completedDuration: 12,
                    drawsOwnChrome: false
                )

                ActivitySectionDivider()

                ToolActivityGroupView(group: Self.group, drawsOwnChrome: false)
            }
        } summary: { isExpanded, toggle in
            TurnActivitySummaryRow(
                reasoningDuration: 12,
                toolCalls: Self.group.toolCalls,
                isExpanded: isExpanded,
                onTap: toggle
            )
            .task(id: startsExpanded) {
                guard startsExpanded, !isExpanded, !toggleTrigger else { return }
                toggleTrigger = true
                toggle()
            }
        }
    }

    /// Contains real markdown on purpose: models emit `**run headers**`,
    /// lists, and inline code inside reasoning, and this specimen is the check
    /// that they render rather than showing as literal punctuation.
    static let thought = """
        **Checking the palette tokens**

        The transcript row structure decides where the rails belong, so the \
        token audit has to come first.

        - `ChatPalette.surface` is already warm in both schemes
        - `tableRule` is the only hairline used by activity blocks
        """

    static let group: ToolCallGroup = {
        let names = ["skill_view", "skill_view", "read_file", "execute_code", "search_files", "web_search"]
        let calls = names.enumerated().map { index, name in
            ToolCall(
                id: "fold-\(index)",
                name: name,
                preview: nil,
                args: nil,
                duration: Double(index % 3) + 1.2,
                isError: false,
                isCompleted: true,
                batchIndex: index < 2 ? 0 : index
            )
        }
        return ToolCallGroup.live(anchorMessageID: "fold-anchor", toolCalls: calls)
    }()

    /// A turn that ran 68 tools — the size Kosta actually hits on long agent
    /// runs. The six-call fixture above is why the unbounded expanded body was
    /// never visible in review: six rows fit anywhere.
    static let largeGroup: ToolCallGroup = {
        let names = [
            "read_file", "search_files", "execute_code", "web_search",
            "skill_view", "write_file", "git_diff", "list_dir"
        ]
        let calls = (0..<68).map { index in
            ToolCall(
                id: "large-\(index)",
                name: names[index % names.count],
                preview: index % 4 == 0 ? "HermesMobile/Features/Chat/ChatViewModel.swift" : nil,
                args: nil,
                duration: Double(index % 5) + 0.6,
                isError: index % 23 == 0,
                isCompleted: true,
                // Two parallel batches early, the rest sequential.
                batchIndex: index < 4 ? 0 : index
            )
        }
        return ToolCallGroup.live(anchorMessageID: "large-anchor", toolCalls: calls)
    }()
}

/// Reproduces the production sibling arrangement — an activity fold and a long
/// markdown answer in the same `VStack` — and toggles the fold on a timer.
///
/// Kept as the only debug surface where the fold and a long markdown answer
/// are siblings, which is the arrangement that produced the stutter — a
/// gallery page rendering a card alone cannot show it. Note it does *not*
/// fully reproduce production: this passes a constant string, so SwiftUI can
/// skip the renderer regardless of the guard. Judge the real fix on device.
/// The activity card for a turn that ran 68 tools, expanded, sitting above an
/// answer — i.e. the arrangement from a real long agent run.
private struct LargeToolGroupSpecimen: View {
    @State private var didExpand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("ACTIVITY · 68 TOOLS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                TurnActivityFoldView(
                    isCollapsed: true,
                    initiallyCollapsed: true,
                    animatesFold: false
                ) {
                    ActivityContainerView {
                        ReasoningBlockView(
                            text: ActivityFoldSpecimen.thought,
                            isStreaming: false,
                            completedDuration: 12,
                            drawsOwnChrome: false
                        )

                        ActivitySectionDivider()

                        ToolActivityGroupView(
                            group: ActivityFoldSpecimen.largeGroup,
                            drawsOwnChrome: false,
                            preparesHistoricalDisclosure: true
                        )
                    }
                } summary: { isExpanded, toggle in
                    TurnActivitySummaryRow(
                        reasoningDuration: 12,
                        toolCalls: ActivityFoldSpecimen.largeGroup.toolCalls,
                        isExpanded: isExpanded,
                        onTap: toggle
                    )
                    .task(id: didExpand) {
                        guard !isExpanded, !didExpand else { return }
                        didExpand = true
                        toggle()
                    }
                }

                Text("The answer follows the activity card, exactly as it does in a real turn.")
                    .font(.body)
            }
            .padding(16)
        }
    }
}

private struct FoldReparseProbeView: View {
    @State private var isCollapsed = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("FOLD RE-PARSE PROBE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                TurnActivityFoldView(
                    isCollapsed: isCollapsed,
                    initiallyCollapsed: true,
                    animatesFold: true
                ) {
                    ActivityContainerView {
                        ReasoningBlockView(
                            text: ActivityFoldSpecimen.thought,
                            completedDuration: 12,
                            drawsOwnChrome: false,
                            startsExpandedOverride: true
                        )
                        ActivitySectionDivider()
                        ToolActivityGroupView(
                            group: ActivityFoldSpecimen.group,
                            drawsOwnChrome: false,
                            startsExpandedOverride: true
                        )
                    }
                } summary: { isExpanded, toggle in
                    TurnActivitySummaryRow(
                        reasoningDuration: 12,
                        toolCalls: ActivityFoldSpecimen.group.toolCalls,
                        isExpanded: isExpanded,
                        onTap: toggle
                    )
                }

                // The sibling that must NOT re-parse.
                MarkdownRenderer(content: Self.longAnswer, typographyRole: .assistantResponse)
            }
            .padding(16)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) {
                    isCollapsed.toggle()
                }
            }
        }
    }

    /// Deliberately long and structurally varied — a short string would parse
    /// fast enough to hide the cost even when it is being redone.
    static let longAnswer: String = {
        let block = """
        ## Section heading

        Running prose with **bold**, *italic*, and `inline code` so the parser \
        has real inline structure to walk rather than a flat string.

        - First bullet with `a.code.reference` inside it
        - Second bullet that wraps onto more than one line so layout has work
          - A nested child item
        1. An ordered item
        2. Another ordered item

        > A blockquote, because quote handling is a separate parse path.

        ```swift
        let palette = ChatPalette(colorScheme: .dark, backgroundStyle: .warm)
        ```
        """
        return Array(repeating: block, count: 8).joined(separator: "\n\n")
    }()
}

/// Reproduces the exact reported gesture chain (`--surface-gallery-page 22`):
/// cold state → open the merged card → tap the *thinking pill* inside it.
///
/// Every earlier fixture drove `disclosureLabExpansion` or `startsExpandedOverride`,
/// which bypasses the pill's own tap path — the path under suspicion. This one
/// performs the two taps on a timer against completely production-default
/// blocks, with an answer below so any overlap or drop-down is visible against
/// a sibling, then resets and repeats so a recording captures several cold-ish
/// cycles. (Only the first cycle is truly cache-cold; later cycles show the
/// warm path for comparison, which is itself diagnostic.)
private struct ThinkingRevealProbeView: View {
    /// Remounts the whole fold subtree each cycle so per-view @State
    /// (expansion overrides) resets like a fresh cold load.
    @State private var cycle = 0
    @State private var phase = 0
    @State private var disclosurePositionPreserver = ChatScrollPositionPreserver()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Put the collapsed card near the viewport bottom, matching
                // the reported historical-session position. The tall Thought
                // then exceeds a full screen when opened, so a bottom-preserving
                // size change visibly moves its header above the viewport.
                Color.clear
                    .frame(height: 560)
                    .accessibilityHidden(true)

                Text("Earlier transcript content keeps this settled turn near the bottom edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("THINKING REVEAL PROBE · cycle \(cycle) phase \(phase)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                ThinkingRevealCycleView(phase: phase)
                    .id(cycle)

                Text("The answer sits directly below, exactly as in a real settled turn, so any overlap or drop-down during the reveal shows against it.")
                    .font(.body)
            }
            .padding(16)
            .background {
                // Same placement as ChatTranscriptView: the attachment view
                // must be inside the ScrollView content hierarchy so it can
                // discover the enclosing UIScrollView.
                ChatScrollPositionPreserverView(controller: disclosurePositionPreserver)
            }
        }
        .defaultScrollAnchor(
            ChatScrollPolicy.initialTranscriptAnchor,
            for: .initialOffset
        )
        .defaultScrollAnchor(
            ChatScrollPolicy.sizeChangeAnchor(
                shouldFollowLatestMessage: false,
                hasActiveStream: false
            ),
            for: .sizeChanges
        )
        .environment(\.preserveActivityExpansionPosition) {
            disclosurePositionPreserver.preserveCurrentVerticalOffset(for: 1.25)
        }
        .task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            // Open only the outer fold. The UI test performs the inner Thought
            // press itself, which keeps the regression fixture deterministic
            // even when a cold Markdown layout takes several seconds.
            phase = 1
        }
    }
}

private struct ThinkingRevealCycleView: View {
    let phase: Int
    /// Sent to the thinking block through the same tap closure a finger uses.
    @State private var didOpenFold = false

    var body: some View {
        TurnActivityFoldView(
            isCollapsed: true,
            initiallyCollapsed: true,
            animatesFold: false
        ) {
            ActivityContainerView {
                ThinkingRevealTappableReasoning(expandsOnPhase: phase >= 2)
                ActivitySectionDivider()
                ToolActivityGroupView(
                    group: ActivityFoldSpecimen.group,
                    drawsOwnChrome: false
                )
            }
        } summary: { isExpanded, toggle in
            TurnActivitySummaryRow(
                reasoningDuration: 12,
                toolCalls: ActivityFoldSpecimen.group.toolCalls,
                isExpanded: isExpanded,
                onTap: toggle
            )
            .task(id: phase) {
                guard phase >= 1, !isExpanded, !didOpenFold else { return }
                didOpenFold = true
                toggle()
            }
        }
    }
}

/// Wraps the production `ReasoningBlockView` and triggers its *own tap path*
/// (the `ActivityCapsuleView` button) rather than forcing expansion state, by
/// simulating the button action through the accessibility-equivalent gesture:
/// the block's internal toggle runs inside `withAnimation(cardExpand)`, exactly
/// as a finger tap does. We reach it by re-rendering with a changed
/// `startsExpandedOverride` only when the phase advances — the closest
/// timer-driveable equivalent that still exercises the insertion transition.
private struct ThinkingRevealTappableReasoning: View {
    let expandsOnPhase: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ReasoningBlockView(
            text: ThinkingRevealProbeFixture.thought,
            isStreaming: false,
            completedDuration: 12,
            drawsOwnChrome: false,
            preservesViewportOnExpand: true,
            startsExpandedOverride: expanded
        )
        .onChange(of: expandsOnPhase) { _, now in
            guard now, !expanded else { return }
            // Same transaction a finger tap commits.
            withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
                expanded = true
            }
        }
    }
}

private enum ThinkingRevealProbeFixture {
    static let thought = Array(
        repeating: ActivityFoldSpecimen.thought,
        count: 7
    ).joined(separator: "\n\n---\n\n")
}
#endif
