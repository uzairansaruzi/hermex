#if DEBUG
import SwiftUI

/// A realistic transcript, driven on a timer, for measuring disclosure motion
/// (`--surface-gallery-page 17`).
///
/// Every previous debug surface rendered one card alone, which is precisely
/// why the stutter kept surviving them: the cost comes from the card's
/// *neighbours* — long markdown answers above and below it inside a scroll
/// view — not from the card. This mounts many heavy sibling messages and
/// toggles a fold in the middle of them, which is the production shape.
///
/// Recording this page and diffing frames is the only local way to see the
/// artifact without a device.
struct TranscriptStressLabView: View {
    @State private var isCollapsed = true
    /// Renders the settled (container) composition alongside the live
    /// (independent cards) one, so a single screenshot proves the split.
    var showsBothCompositions = false

    /// Messages above the card under test. Enough of them, and heavy enough,
    /// that a transcript-wide invalidation is visible as a dropped frame.
    private let leadingMessages = 4
    private let trailingMessages = 4

    var body: some View {
        if showsBothCompositions {
            compositionComparison
        } else {
            stressBody
        }
    }

    /// Side-by-side proof that the unified container is settled-only.
    private var compositionComparison: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LIVE TURN — independent cards, own borders")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ReasoningBlockView(text: Self.thought, completedDuration: 12)
                    ToolActivityGroupView(group: Self.group)
                }

                Text("SETTLED TURN — one container, sections inside")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                ActivityContainerView {
                    ReasoningBlockView(
                        text: Self.thought,
                        completedDuration: 12,
                        drawsOwnChrome: false,
                        startsExpandedOverride: true
                    )
                    ActivitySectionDivider()
                    ToolActivityGroupView(
                        group: Self.group,
                        drawsOwnChrome: false,
                        startsExpandedOverride: true
                    )
                }
            }
            .padding(16)
        }
    }

    private var stressBody: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<leadingMessages, id: \.self) { index in
                    answer(index)
                }

                // The card under test, with a marker so frame diffing can find
                // it without relying on pixel coordinates.
                Text("— CARD UNDER TEST —")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .id("card")

                TurnActivityFoldView(
                    isCollapsed: isCollapsed,
                    initiallyCollapsed: true,
                    animatesFold: true
                ) {
                    ActivityContainerView {
                        ReasoningBlockView(
                            text: Self.thought,
                            completedDuration: 12,
                            drawsOwnChrome: false,
                            startsExpandedOverride: true
                        )
                        ActivitySectionDivider()
                        ToolActivityGroupView(
                            group: Self.group,
                            drawsOwnChrome: false,
                            startsExpandedOverride: true
                        )
                    }
                } summary: { isExpanded, toggle in
                    TurnActivitySummaryRow(
                        reasoningDuration: 12,
                        toolCalls: Self.group.toolCalls,
                        isExpanded: isExpanded,
                        onTap: toggle
                    )
                }

                ForEach(0..<trailingMessages, id: \.self) { index in
                    answer(index + 100)
                }
            }
            .padding(16)
        }
        // Park the viewport on the card so a recording captures the motion
        // rather than the messages above it.
        .onAppear { proxy.scrollTo("card", anchor: .top) }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) {
                    isCollapsed.toggle()
                }
            }
        }
        }
    }

    /// A heavy assistant answer. Distinct leading text per index so frames can
    /// be told apart, but the same bulk so cost is uniform.
    private func answer(_ index: Int) -> some View {
        MarkdownRenderer(
            content: "Answer \(index)\n\n" + Self.longAnswer,
            typographyRole: .assistantResponse
        )
    }

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
                id: "stress-\(index)",
                name: name,
                preview: nil,
                args: nil,
                duration: Double(index % 3) + 1.2,
                isError: false,
                isCompleted: true,
                batchIndex: index < 2 ? 0 : index
            )
        }
        return ToolCallGroup.live(anchorMessageID: "stress-anchor", toolCalls: calls)
    }()

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
        """
        return Array(repeating: block, count: 4).joined(separator: "\n\n")
    }()
}
#endif
