#if DEBUG
import SwiftUI

/// Design mock-up for the proposed turn timeline (thinking → tools → thinking →
/// tools → answer), rendered beside the **current shipping views** so the two
/// can be compared honestly.
///
/// Not wired to live data or animation: it exists so structure, indentation,
/// rails, corner radii, and state glyphs can be reviewed as screenshots before
/// any production view is refactored. The "NOW" panels instantiate the real
/// `ReasoningBlockView` / `ToolActivityGroupView`, so the before side is the
/// actual current design, not a redrawing of it.
///
/// Pages: 5 = same turn now vs proposed · 6 = tool block states ·
/// 7 = end of turn (collapse) · 8 = block corner radius.
struct TurnTimelineMockView: View {
    /// Which comparison page to render. The simulator cannot be scrolled from
    /// the CLI, so each page is sized for one screenshot.
    var page: Int = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch page {
                case 9:
                    pageHeader(
                        "SHIPPED — REAL VIEWS",
                        subtitle: "Production ToolActivityGroupView with a live parallel batch, a finished block, and a failure."
                    )
                    shippedSpecimens
                case 6:
                    pageHeader(
                        "TOOL BLOCK — FINISHED & FAILED",
                        subtitle: "Proposed design only. Shows per-tool result state."
                    )
                    blockStates
                case 7:
                    pageHeader(
                        "END OF TURN",
                        subtitle: "What replaces the blocks once the answer starts."
                    )
                    collapsePage
                case 8:
                    pageHeader(
                        "BLOCK CORNER RADIUS",
                        subtitle: "Same block, three radii. The collapsed row stays a pill either way."
                    )
                    radiusComparison
                default:
                    pageHeader(
                        "ONE TURN — NOW vs PROPOSED",
                        subtitle: "Identical content: thought, then 4 tools (2 of them parallel)."
                    )
                    beforeAfterTurn
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.chatBackground)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var palette: ChatPalette {
        ChatPalette.appChrome(colorScheme: colorScheme)
    }

    // MARK: - Before / after

    /// The real shipping views after the change, so verification looks at what
    /// actually renders rather than at the design mock.
    private var shippedSpecimens: some View {
        VStack(alignment: .leading, spacing: 20) {
            panel("RUNNING", note: "Parallel batch indented under a rail; one orb and one border for the block.") {
                ToolActivityGroupView(group: Self.runningGroup, isPhaseActive: true)
            }
            panel("FINISHED", note: "Per-tool durations and green result marks.") {
                ToolActivityGroupView(group: Self.finishedGroup)
            }
            panel("FAILED", note: "The failure is attributed to its own row.") {
                ToolActivityGroupView(group: Self.failedGroup)
            }
            panel("THINKING — EXPANDED", note: "Opens into the thought inside one container, matching the tool block.") {
                ReasoningBlockView(
                    text: Self.thinkingText,
                    isStreaming: false,
                    completedDuration: 12
                )
            }
            panel("COLLAPSED SUMMARY", note: "What the blocks fold into once the answer starts.") {
                TurnActivitySummaryRow(
                    reasoningDuration: 12,
                    toolCalls: Self.finishedGroup.toolCalls
                )
            }
        }
    }

    /// The same turn twice: current shipping views on top, proposal below.
    private var beforeAfterTurn: some View {
        VStack(alignment: .leading, spacing: 22) {
            panel(
                "NOW",
                note: "Two separate capsules. Parallel tools look identical to sequential ones."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ReasoningBlockView(
                        text: Self.thinkingText,
                        isStreaming: false,
                        completedDuration: 12
                    )
                    ToolActivityGroupView(group: Self.currentGroup)
                }
            }

            panel(
                "PROPOSED",
                note: "Blocks in turn order. Only the running block is bordered. Parallel batch is indented."
            ) {
                liveTurn
            }
        }
    }

    // MARK: - Live turn

    /// The core proposal: alternating thinking / tool blocks in chronological
    /// order, one bordered container per block, one orb per block.
    private var liveTurn: some View {
        VStack(alignment: .leading, spacing: 10) {
            block(
                glyph: "brain",
                title: "Thought for 12s",
                isActive: false,
                showsBorder: false
            ) {
                quietText("Checked the palette tokens and the transcript row structure before deciding where the rails belong.")
            }

            block(
                glyph: "wrench.and.screwdriver",
                title: "Ran 4 tools",
                trailing: "2 running · 2 waiting",
                isActive: true,
                showsBorder: true
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    parallelCluster([
                        .init(name: "skill_view", detail: nil, state: .running),
                        .init(name: "skill_view", detail: nil, state: .running)
                    ])
                    toolRow(.init(name: "read_file", detail: "AGENTS.md", state: .waiting))
                    toolRow(.init(name: "execute_code", detail: nil, state: .waiting))
                }
            }
        }
    }

    // MARK: - Block states

    private var blockStates: some View {
        VStack(alignment: .leading, spacing: 10) {
            block(
                glyph: "wrench.and.screwdriver",
                title: "Ran 4 tools in 8.2s",
                isActive: false,
                showsBorder: false
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    parallelCluster([
                        .init(name: "skill_view", detail: nil, state: .succeeded),
                        .init(name: "skill_view", detail: nil, state: .succeeded)
                    ])
                    toolRow(.init(name: "read_file", detail: "AGENTS.md", state: .succeeded))
                    toolRow(.init(name: "execute_code", detail: nil, state: .succeeded))
                }
            }

            block(
                glyph: "exclamationmark.triangle",
                title: "1 of 4 tools failed",
                isActive: false,
                showsBorder: false,
                isError: true
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    parallelCluster([
                        .init(name: "skill_view", detail: nil, state: .succeeded),
                        .init(name: "skill_view", detail: "Timed out", state: .failed)
                    ])
                    toolRow(.init(name: "read_file", detail: "AGENTS.md", state: .notRun))
                    toolRow(.init(name: "execute_code", detail: nil, state: .notRun))
                }
            }
        }
    }

    // MARK: - Collapsed

    /// After the answer begins streaming, thinking + tool blocks fold into one
    /// capsule-shaped row. Collapsed reads like today's container.
    private var collapsePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            panel(
                "NOW",
                note: "Both capsules stay on screen above the answer, forever."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ReasoningBlockView(
                        text: Self.thinkingText,
                        isStreaming: false,
                        completedDuration: 12
                    )
                    ToolActivityGroupView(group: Self.currentGroup)
                    answerPreview
                }
            }

            panel(
                "PROPOSED · live session",
                note: "Blocks fold into one row when the first confirmed answer token lands. Tap to reopen."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    summaryRow(
                        text: "Thought for 12s · ran 4 tools in 8.2s",
                        glyphs: [.succeeded, .succeeded, .succeeded, .succeeded]
                    )
                    answerPreview
                }
            }

            panel(
                "PROPOSED · reopened after relaunch",
                note: "Durations, per-tool result state and parallel grouping are not saved by the server, so history is deliberately quieter."
            ) {
                summaryRow(text: "Thought · ran 4 tools", glyphs: [], isQuiet: true)
            }
        }
    }

    private var answerPreview: some View {
        Text("Here's what I found in the palette tokens — the rails already exist in the expanded tool card, so the same idiom carries the parallel cluster.")
            .font(AppFont.body())
            .foregroundStyle(palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Radius comparison

    /// The radius question only matters on the tall multi-row block, so this
    /// repeats a real block at each candidate radius instead of showing empty
    /// swatches. The collapsed row is excluded on purpose: at ~40pt tall any
    /// radius >= 20 renders as a pill, so it stays `Capsule()` regardless.
    private var radiusComparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            radiusSpecimen(16, note: "same value as the accessibility-size fallback")
            radiusSpecimen(20, note: "proposed")
            radiusSpecimen(22, note: "exactly the composer's radius")
        }
    }

    private func radiusSpecimen(_ radius: CGFloat, note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("radius \(Int(radius))")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text("· \(note)")
                    .font(AppFont.caption2())
                    .foregroundStyle(palette.textTertiary)
            }
            block(
                glyph: "wrench.and.screwdriver",
                title: "Ran 4 tools",
                trailing: "2 running · 2 waiting",
                isActive: true,
                showsBorder: true,
                cornerRadius: radius
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    parallelCluster([
                        .init(name: "skill_view", detail: nil, state: .running),
                        .init(name: "skill_view", detail: nil, state: .running)
                    ])
                    toolRow(.init(name: "read_file", detail: "AGENTS.md", state: .waiting))
                }
            }
        }
    }

    // MARK: - Building blocks

    /// One turn block. Only the active block carries a border (and, in
    /// production, the animated beam).
    private func block<Content: View>(
        glyph: String,
        title: String,
        trailing: String? = nil,
        isActive: Bool,
        showsBorder: Bool,
        isError: Bool = false,
        cornerRadius: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isError ? Color.red : (isActive ? palette.textPrimary : palette.textSecondary))
                    .frame(width: 18)
                Text(title)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                if let trailing {
                    Spacer(minLength: 8)
                    Text(trailing)
                        .font(AppFont.caption())
                        .foregroundStyle(palette.textTertiary)
                }
                if trailing == nil {
                    Spacer(minLength: 8)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.textTertiary)
            }
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(showsBorder ? palette.surface : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    showsBorder ? palette.textPrimary.opacity(0.22) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    /// Parallel batch: one extra indent level, a rail, nothing deeper.
    private func parallelCluster(_ tools: [MockTool]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(palette.tableRule)
                .frame(width: 1.5)
            VStack(alignment: .leading, spacing: 7) {
                Text("Parallel · \(tools.count)")
                    .font(AppFont.caption2(weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(palette.textTertiary)
                ForEach(tools) { tool in
                    toolRow(tool)
                }
            }
        }
        .padding(.leading, 12)
    }

    private func toolRow(_ tool: MockTool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateGlyph(tool.state)
            Text(tool.name)
                .font(AppFont.footnote())
                .foregroundStyle(
                    tool.state == .notRun ? palette.textTertiary : palette.textPrimary
                )
            if let detail = tool.detail {
                Text(detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(tool.state == .failed ? Color.red : palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if tool.state == .notRun {
                Text("Not run")
                    .font(AppFont.caption2())
                    .foregroundStyle(palette.textTertiary)
            }
        }
    }

    /// The per-tool indicator. In production the `.running` case is drawn by a
    /// single block-level Canvas (three lines sweeping left→right); here it is
    /// a static frame so the layout can be judged.
    @ViewBuilder
    private func stateGlyph(_ state: MockToolState) -> some View {
        switch state {
        case .running:
            HStack(spacing: 3) {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(Color.orange.opacity([1.0, 0.62, 0.3][index]))
                            .frame(width: [9.0, 7.0, 5.0][index], height: 1.5)
                    }
                }
                .frame(width: 9, alignment: .leading)
            }
            .frame(width: 26, alignment: .leading)
        case .waiting:
            Circle()
                .strokeBorder(palette.textTertiary, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .frame(width: 26, alignment: .leading)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.green)
                .frame(width: 26, alignment: .leading)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.red)
                .frame(width: 26, alignment: .leading)
        case .notRun:
            Circle()
                .strokeBorder(palette.textTertiary.opacity(0.5), lineWidth: 1)
                .frame(width: 11, height: 11)
                .frame(width: 26, alignment: .leading)
        }
    }

    private func summaryRow(
        text: String,
        glyphs: [MockToolState],
        isQuiet: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.textSecondary)
            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(isQuiet ? palette.textSecondary : palette.textPrimary)
            if !glyphs.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(glyphs.enumerated()), id: \.offset) { _, state in
                        Circle()
                            .fill(state == .failed ? Color.red : Color.green)
                            .frame(width: 5, height: 5)
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Capsule().fill(palette.surface))
        .overlay(Capsule().strokeBorder(palette.tableRule, lineWidth: 1))
    }

    private func quietText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(palette.textTertiary)
                .frame(width: 3)
            Text(text)
                .font(AppFont.footnote())
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(AppFont.caption2(weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(palette.textTertiary)
    }

    /// Page title plus one sentence saying what the reader is looking at, so a
    /// screenshot is self-explanatory without the surrounding conversation.
    private func pageHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppFont.footnote(weight: .bold))
                .kerning(0.8)
                .foregroundStyle(palette.textPrimary)
            Text(subtitle)
                .font(AppFont.caption2())
                .foregroundStyle(palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A labelled comparison panel: bold NOW / PROPOSED tag, a one-line note on
    /// what to look at, and the specimen itself.
    private func panel<Content: View>(
        _ label: String,
        note: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label)
                    .font(AppFont.caption2(weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(palette.chatBackground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palette.textPrimary.opacity(0.75))
                    )
                Text(note)
                    .font(AppFont.caption2())
                    .foregroundStyle(palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    // MARK: - Fixtures

    fileprivate enum MockToolState {
        case running, waiting, succeeded, failed, notRun
    }

    fileprivate struct MockTool: Identifiable {
        let id = UUID()
        let name: String
        let detail: String?
        let state: MockToolState
    }

    /// Live block: a parallel batch still running plus two queued calls.
    private static let runningGroup = ToolCallGroup(
        anchorMessageID: "mock-run",
        toolCalls: [
            ToolCall(id: "r1", name: "skill_view", preview: nil, args: nil, batchIndex: 0),
            ToolCall(id: "r2", name: "skill_view", preview: nil, args: nil, batchIndex: 0),
            ToolCall(id: "r3", name: "read_file", preview: nil, args: nil, batchIndex: 1),
            ToolCall(id: "r4", name: "execute_code", preview: nil, args: nil, batchIndex: 2)
        ]
    )

    private static let finishedGroup = ToolCallGroup(
        anchorMessageID: "mock-done",
        toolCalls: [
            ToolCall(id: "f1", name: "skill_view", preview: nil, args: nil, duration: 2.1, isCompleted: true, batchIndex: 0),
            ToolCall(id: "f2", name: "skill_view", preview: nil, args: nil, duration: 2.4, isCompleted: true, batchIndex: 0),
            ToolCall(id: "f3", name: "read_file", preview: nil, args: nil, duration: 1.2, isCompleted: true, batchIndex: 1),
            ToolCall(id: "f4", name: "execute_code", preview: nil, args: nil, duration: 2.5, isCompleted: true, batchIndex: 2)
        ]
    )

    private static let failedGroup = ToolCallGroup(
        anchorMessageID: "mock-fail",
        toolCalls: [
            ToolCall(id: "x1", name: "skill_view", preview: nil, args: nil, duration: 2.1, isCompleted: true, batchIndex: 0),
            ToolCall(id: "x2", name: "skill_view", preview: nil, args: nil, duration: 9.9, isError: true, isCompleted: true, batchIndex: 0),
            ToolCall(id: "x3", name: "read_file", preview: nil, args: nil, batchIndex: 1)
        ]
    )

    private static let thinkingText = "Checked the palette tokens and the transcript row structure before deciding where the rails belong."

    /// Fixture for the CURRENT shipping `ToolActivityGroupView`, so the "NOW"
    /// panel is the real view rather than a redrawing of it.
    private static let currentGroup = ToolCallGroup(
        anchorMessageID: "mock-anchor",
        toolCalls: [
            ToolCall(
                id: "mock-1",
                name: "skill_view",
                preview: "design-taste-frontend",
                args: nil,
                duration: 2.1,
                isCompleted: true
            ),
            ToolCall(
                id: "mock-2",
                name: "skill_view",
                preview: "swiftui-animation",
                args: nil,
                duration: 2.4,
                isCompleted: true
            ),
            ToolCall(
                id: "mock-3",
                name: "read_file",
                preview: "AGENTS.md",
                args: nil,
                duration: 1.2,
                isCompleted: true
            ),
            ToolCall(
                id: "mock-4",
                name: "execute_code",
                preview: "xcodebuild",
                args: nil,
                duration: 2.5,
                isCompleted: true
            )
        ]
    )
}
#endif
