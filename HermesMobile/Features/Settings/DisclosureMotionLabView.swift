#if DEBUG
import SwiftUI

/// Debug-only harness that drives the activity cards' expand/collapse on a
/// timer, so the disclosure motion can be screen-recorded deterministically.
///
/// The simulator cannot be tapped from the CLI, so a hand-driven comparison
/// would not be reproducible between a "before" and "after" build. This toggles
/// every card on a fixed cadence instead, making two recordings directly
/// comparable frame for frame.
///
/// Reachable via `--surface-gallery --surface-gallery-page 10`.
struct DisclosureMotionLabView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("DISCLOSURE MOTION")
                    .font(AppFont.footnote(weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(palette.textPrimary)
                Text("Cards auto-toggle every 2.2s.")
                    .font(AppFont.caption2())
                    .foregroundStyle(palette.textTertiary)

                label("THINKING")
                ReasoningBlockView(
                    text: Self.thinkingText,
                    isStreaming: false,
                    completedDuration: 12
                )

                label("TOOL BLOCK · 6 ROWS")
                ToolActivityGroupView(group: Self.toolGroup)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.chatBackground)
        .environment(\.disclosureLabExpansion, isExpanded)
        .task {
            // Drive the cards open and closed forever while recording.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                // Animate the driving value the same way a tap would, so the
                // recorded motion matches production instead of a hard swap.
                withAnimation(ChatMotion.cardExpand(reduceMotion: false)) {
                    isExpanded.toggle()
                }
            }
        }
    }

    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ChatPalette {
        ChatPalette.appChrome(colorScheme: colorScheme)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(palette.textTertiary)
    }

    /// Contains markdown deliberately. The reasoning body is a markdown
    /// renderer now, and its multi-block layout is what makes the reveal
    /// misbehave — a plain-prose fixture cannot reproduce that.
    private static let thinkingText = """
    **Checking the palette tokens**

    Checked the palette tokens and the transcript row structure before deciding where the rails belong.

    - `ChatPalette.surface` is already warm in both schemes
    - `tableRule` is the only hairline used by activity blocks

    **Deciding the container**

    That keeps thinking and tools reading as one family of surface.
    """

    private static let toolGroup = ToolCallGroup(
        anchorMessageID: "lab",
        toolCalls: [
            ToolCall(id: "l1", name: "skill_view", preview: nil, args: nil, duration: 2.1, isCompleted: true, batchIndex: 0),
            ToolCall(id: "l2", name: "skill_view", preview: nil, args: nil, duration: 2.4, isCompleted: true, batchIndex: 0),
            ToolCall(id: "l3", name: "read_file", preview: nil, args: nil, duration: 1.2, isCompleted: true, batchIndex: 1),
            ToolCall(id: "l4", name: "execute_code", preview: nil, args: nil, duration: 2.5, isCompleted: true, batchIndex: 2),
            ToolCall(id: "l5", name: "search_files", preview: nil, args: nil, duration: 0.8, isCompleted: true, batchIndex: 3),
            ToolCall(id: "l6", name: "web_search", preview: nil, args: nil, duration: 3.1, isCompleted: true, batchIndex: 4),
            // Sequential + still running: keeps the live indicator on screen at
            // a row's leading edge, where the ring stroke used to clip.
            ToolCall(id: "l7", name: "read_file", preview: nil, args: nil, batchIndex: 5)
        ]
    )
}

/// Forces the debug lab's cards into a given expansion state without the user
/// tapping. Production views ignore this; only the lab sets it.
private struct DisclosureLabExpansionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var disclosureLabExpansion: Bool? {
        get { self[DisclosureLabExpansionKey.self] }
        set { self[DisclosureLabExpansionKey.self] = newValue }
    }
}
#endif
