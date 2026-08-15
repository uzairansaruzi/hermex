#if DEBUG
import SwiftUI

/// Debug-only gallery of the surfaces touched by the palette work, rendered
/// with fixture data so they can be inspected without a server. Reachable via
/// the `--surface-gallery` launch argument.
///
/// Each section deliberately composes the same primitives the production
/// screens use, so a screenshot of this gallery reflects real surface colors
/// rather than a mock-up.
struct SurfaceGalleryView: View {
    var body: some View {
        // Page 5 is the standalone turn-timeline design mock-up; it owns its
        // own scroll view and padding, so it short-circuits the shared stack.
        if page == 10 {
            DisclosureMotionLabView()
        } else if let page, (11...13).contains(page) {
            PlanTimelineGalleryView(page: page)
        } else if page == 15 {
            PlanTimelineGalleryView(page: 15)
        } else if page == 20 {
            PlanTimelineGalleryView(page: 20)
        } else if page == 14 {
            ActivityFoldGalleryView(page: 14)
        } else if page == 16 {
            ActivityFoldGalleryView(page: 16)
        } else if page == 21 {
            ActivityFoldGalleryView(page: 21)
        } else if page == 22 {
            ActivityFoldGalleryView(page: 22)
        } else if page == 23 {
            PlanTimelineGalleryView(page: 23)
        } else if page == 24 {
            ThinkingMarkdownGalleryView(isStreaming: false)
        } else if page == 25 {
            ThinkingMarkdownGalleryView(isStreaming: true)
        } else if page == 26 {
            LiveThinkingRevealProbeView()
        } else if page == 27 {
            PlanDismissalChatFixture()
        } else if page == 28 {
            GoalLongStressGalleryView()
        } else if page == 29 {
            GoalStatusRailGalleryView()
        } else if page == 17 {
            TranscriptStressLabView()
        } else if page == 19 {
            OrbGalleryView()
        } else if page == 18 {
            TranscriptStressLabView(showsBothCompositions: true)
        } else if let page, (5...9).contains(page) {
            TurnTimelineMockView(page: page)
        } else {
            galleryBody
        }
    }

    private var galleryBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if page == nil || page == 1 {
                section("Assistant markdown") {
                    MarkdownRenderer(
                        content: Self.markdownSpecimen,
                        typographyRole: .assistantResponse
                    )
                }
                }

                if page == nil || page == 2 {
                section("Transcript cards") {
                    MessageBubbleView(message: Self.userMessage)
                    ReasoningBlockView(text: Self.reasoningText)
                    ToolCallCardView(toolCall: Self.toolCall)
                    MarkerMessageCardView(
                        kind: .contextCompaction,
                        content: Self.markerText
                    )
                }

                section("Activity capsules") {
                    VStack(alignment: .leading, spacing: 10) {
                        ActivityCapsuleView(
                            orbState: .thinking,
                            label: "Thinking…",
                            isActive: true
                        )
                        ActivityCapsuleView(
                            orbState: .searching,
                            label: "Reading ChatPalette.swift",
                            isActive: true
                        )
                        ActivityCapsuleView(
                            orbState: .working,
                            label: "Working · xcodebuild",
                            isActive: true
                        )
                        ActivityCapsuleView(
                            orbState: .writing,
                            label: "Writing MarkdownRenderer.swift",
                            isActive: true
                        )
                        ActivityCapsuleView(
                            orbState: .connecting,
                            label: "Connecting · hermes-webui",
                            isActive: true
                        )
                        ActivityCapsuleView(
                            orbState: .thinking,
                            label: "Thinking…",
                            isActive: false,
                            completedIcon: "brain",
                            completedLabel: "Thought for 12s"
                        )
                        ForEach(ActivityBeamStyle.allCases) { style in
                            beamStyleRow(style)
                        }
                    }
                }

                section("Status pills") {
                    HStack(spacing: 10) {
                        TranscriptStatusPill(text: "Running", color: .secondary)
                        TranscriptStatusPill(text: "Failed", color: .red)
                        TranscriptStatusPill(text: "Completed", color: .green)
                    }
                }

                }

                // Page 4 isolates the review surfaces that otherwise sit below
                // the fold on page 2, so screen recordings frame them without
                // depending on scroll position.
                if page == nil || page == 4 {
                section("History rail") {
                    VStack(alignment: .leading, spacing: 18) {
                        ActivityHistoryRailView(
                            steps: Self.historyRailSteps,
                            totalDuration: 40
                        )
                        ActivityHistoryRailView(
                            steps: Self.historyRailSteps,
                            totalDuration: 40,
                            showsEndpoints: true
                        )
                    }
                }

                section("Code themes") {
                    VStack(alignment: .leading, spacing: 12) {
                        codeThemeCell(title: "Warm Dark", scheme: .dark, temperature: .warm)
                        codeThemeCell(title: "Warm Light", scheme: .light, temperature: .warm)
                        codeThemeCell(title: "Standard Dark", scheme: .dark, temperature: .standard)
                        codeThemeCell(title: "Standard Light", scheme: .light, temperature: .standard)
                    }
                }
                }

                if page == nil || page == 2 {
                section("Voice recording bar") {
                    ComposerVoiceRecordingBar(
                        elapsed: 12,
                        isCancelArmed: false,
                        onStop: {},
                        onCancel: {}
                    )
                }
                }

                if page == nil || page == 3 {
                section("Settings card") {
                    galleryCard(title: "Appearance") {
                        galleryRow(icon: "circle.lefthalf.filled", title: "Theme", value: "System")
                        galleryDivider()
                        galleryRow(icon: "paintpalette", title: "Chat Palette", value: "Warm")
                        galleryDivider()
                        galleryRow(icon: "textformat", title: "Serif Responses", value: "Off")
                    }
                }

                section("Session row") {
                    VStack(spacing: 0) {
                        sessionRow(title: "Chat theme v2", subtitle: "12 messages · 2h ago")
                        sessionRow(title: "Palette consistency sweep", subtitle: "48 messages · now")
                    }
                    .background(galleryPalette.chatBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                section("File browser rows") {
                    VStack(spacing: 0) {
                        fileRow(name: "HermesMobile", isDirectory: true)
                        fileRow(name: "ChatPalette.swift", isDirectory: false)
                    }
                    .padding(.vertical, 4)
                    .background(galleryPalette.chatBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                section("Diff rows") {
                    VStack(spacing: 0) {
                        diffRow(gutter: "42", text: "  let palette = ChatPalette(", kind: .context)
                        diffRow(gutter: "43", text: "+     temperature: .warm", kind: .addition)
                        diffRow(gutter: "44", text: "-     Color(.secondarySystemBackground)", kind: .deletion)
                        diffRow(gutter: "45", text: "  )", kind: .context)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                section("Inset chips & cards") {
                    HStack(spacing: 10) {
                        chip("Sonnet 4.5")
                        chip("Coding")
                        chip("main")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("File changes")
                            .font(AppFont.caption(weight: .semibold))
                        Text("3 files · +48 −12")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appSurfaceBackground(.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                }
            }
            .padding(16)
        }
        .background(galleryPalette.chatBackground)
        .navigationTitle("Surface Gallery")
        .navigationBarTitleDisplayMode(.inline)
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Optional page filter so every comparison panel is framed identically
    /// instead of depending on scroll position.
    private var page: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--surface-gallery-page"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1])
        else {
            return nil
        }
        return value
    }


    private var galleryPalette: ChatPalette {
        ChatPalette.appChrome(colorScheme: colorScheme)
    }

    /// One code-theme preview cell with the palette combo pinned explicitly.
    /// The highlight request is constructed directly (bypassing `@AppStorage`)
    /// so all four combos render side by side regardless of the stored
    /// setting; the slab color comes from a palette built with the same
    /// explicit combo.
    private func codeThemeCell(
        title: String,
        scheme: ColorScheme,
        temperature: ChatPaletteTemperature
    ) -> some View {
        let palette = ChatPalette(
            colorScheme: scheme,
            backgroundStyle: .warm,
            temperature: temperature
        )
        let request = MarkdownCodeHighlightRequest(
            code: Self.codeThemeSnippet,
            language: "swift",
            colorScheme: scheme,
            temperature: temperature,
            isStreaming: false
        )

        return VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(AppFont.caption2(weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)

            Group {
                switch MarkdownCodeHighlighter.highlightedCode(for: request) {
                case .highlighted(let attributed):
                    Text(AttributedString(attributed))
                case .plain:
                    Text(Self.codeThemeSnippet)
                        .foregroundStyle(palette.textPrimary)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.codeSlab)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, scheme)
        }
    }

    /// One live capsule per beam style so palette review can eyeball every
    /// option in light+dark. `ActivityCapsuleView` reads the user's stored
    /// beam preference, so these rows compose the same capsule primitives
    /// directly with each style pinned.
    private func beamStyleRow(_ style: ActivityBeamStyle) -> some View {
        let beam = style.resolved(
            palette: galleryPalette,
            colorScheme: colorScheme,
            accent: HeaderLogoColor.color(
                for: UserDefaults.standard.string(forKey: HeaderLogoColor.storageKey)
                    ?? HeaderLogoColor.defaultHex
            )
        )
        return HStack(spacing: 8) {
            ThinkingOrbView(
                state: .working,
                size: ActivityOrbMetrics.capsuleGlyphSize,
                color: .secondary
            )
            Text("Beam · \(style.title)")
                .font(AppFont.subheadline())
                .foregroundStyle(galleryPalette.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(galleryPalette.surface.opacity(0.8)))
        .overlay(Capsule().strokeBorder(galleryPalette.tableRule, lineWidth: 1))
        .borderBeam(
            style: BeamStyle(resolved: beam),
            shape: Capsule(),
            active: beam.isVisible
        )
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(AppFont.caption2(weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func galleryCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurfaceBackground(.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func galleryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(AppFont.subheadline())
    }

    private func galleryDivider() -> some View {
        Rectangle()
            .fill(galleryPalette.tableRule)
            .frame(height: 0.5)
    }

    private func sessionRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.subheadline(weight: .semibold))
                Text(subtitle).font(AppFont.caption()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func fileRow(name: String, isDirectory: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDirectory ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(isDirectory ? galleryPalette.surfaceInset : galleryPalette.surface)
                )
            Text(name).font(AppFont.subheadline())
            Spacer()
            if isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private enum GalleryDiffKind {
        case addition, deletion, context
    }

    private func diffRow(gutter: String, text: String, kind: GalleryDiffKind) -> some View {
        let rowFill: Color = {
            switch kind {
            case .addition: Color(red: 0.20, green: 0.78, blue: 0.35).opacity(0.16)
            case .deletion: Color(red: 0.95, green: 0.25, blue: 0.25).opacity(0.16)
            case .context: galleryPalette.codeSlab
            }
        }()
        let gutterFill: Color = {
            switch kind {
            case .addition: Color(red: 0.20, green: 0.68, blue: 0.32).opacity(0.24)
            case .deletion: Color(red: 0.86, green: 0.20, blue: 0.20).opacity(0.24)
            case .context: galleryPalette.surface
            }
        }()

        return HStack(spacing: 0) {
            Text(gutter)
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)
                .background(gutterFill)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(kind == .context ? .secondary : .primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 19)
        .background(rowFill)
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .appSurfaceBackground(.inset, opacity: 0.5, in: Capsule())
    }

    // MARK: - Fixtures

    private static let markdownSpecimen = """
    # Heading one

    Running prose with **bold**, *italic*, ~~strikethrough~~, `inline code`, and an \
    [accent link](https://get-hermes.ai) so every inline style is visible at once.

    ## Heading two

    > A blockquote showing the accent bar and secondary text treatment.

    ### Heading three

    - Unordered item
      - Nested item that wraps
    - [x] Completed task
    - [ ] Open task

    1. Ordered item
       1. Nested ordered item
    2. Second ordered item

    ---

    | Element | Treatment |
    | --- | --- |
    | Prose | Dynamic body type |
    | Code | Warm inset slab |
    | Rule | Hairline |

    ```swift
    let palette = ChatPalette(
        colorScheme: colorScheme,
        temperature: .warm
    )
    ```

    Inline math $a^2 + b^2 = c^2$ and display math:

    $$E = mc^2$$
    """

    private static let userMessage = ChatMessage(
        role: "user",
        content: "Show me every surface in one pass.",
        timestamp: 1_750_000_000,
        messageId: "surface-gallery-user"
    )

    private static let reasoningText = "Checked each surface against the palette tokens and confirmed the roles resolve consistently."

    private static let historyRailSteps: [ActivityHistoryRailView.Step] = [
        .init(orbState: .thinking, completedLabel: "Thought for 12s", icon: "brain"),
        .init(orbState: .searching, completedLabel: "Read 3 files", icon: "doc.text.magnifyingglass"),
        .init(orbState: .writing, completedLabel: "Wrote patch", icon: "pencil"),
        .init(orbState: .working, completedLabel: "Ran tests", icon: "checkmark.circle.fill")
    ]

    private static let codeThemeSnippet = """
    struct Greeter {
        let name: String // label
        func greet() -> String {
            "Hello, \\(name)! Count: \\(42)"
        }
    }
    """

    private static let toolCall = ToolCall(
        id: "surface-gallery-tool",
        name: "read_file",
        preview: "Loaded ChatPalette.swift",
        args: ["path": .string("HermesMobile/Config/ChatPalette.swift")],
        duration: 0.6,
        isCompleted: true,
        startedAt: 1_750_000_010
    )

    private static let markerText = "[Context compaction] Earlier transcript context remains available through the session summary."
}

/// Field-reproduction fixture for provider reasoning that arrives as a ledger
/// of standalone bold status lines followed by prose. Page 24 deliberately
/// uses the real `ReasoningBlockView`, so before/after screenshots exercise the
/// production markdown path rather than a design mock.
private struct ThinkingMarkdownGalleryView: View {
    let isStreaming: Bool

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isStreaming ? "THINKING MARKDOWN · LIVE" : "THINKING MARKDOWN · COMPLETED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    ReasoningBlockView(
                        text: Self.providerReasoning,
                        isStreaming: isStreaming,
                        completedDuration: isStreaming ? nil : 18.4,
                        startsExpandedOverride: true
                    )
                }
                .padding(16)
            }
            .environment(\.activityDisclosureViewportHeight, viewport.size.height)
        }
    }

    private static let providerReasoning = """
    **Refining arm and delt exercise selection**
    **Adjusting Push and Pull workout structure**
    **Planning exercise rotation across passes**

    I’ve confirmed the source already has the right skeleton: each original week contains an A strength lineage and a B pump lineage. The key is to rehome most direct arm work instead of stacking two huge arm days on top; otherwise the apparent specialization becomes mostly junk volume and weakens the following pull/push sessions.

    **Recommending 8-day rolling workout split**
    **Defining strength and hypertrophy session roles**
    **Planning flexible rest days in workout sequence**

    **Adjusting workout sequencing and fatigue management**
    **Evaluating 12-day training cycle feasibility**
    **Planning 4-week mesocycle rotations**

    The next pass checks the plan against recovery constraints rather than only
    counting sets. Shoulder flexion, elbow extension, and upper-back fatigue
    overlap across several sessions, so each movement needs a clear purpose and
    a predictable place in the rotation.

    **Checking recovery between pressing sessions**
    **Balancing direct and indirect arm volume**
    **Preserving progression across the full cycle**

    This makes the sequence easier to run in real life: demanding work stays
    early, optional isolation work stays removable, and rest days can slide by
    one day without breaking the intended order.

    **Reviewing exercise substitutions**
    **Confirming fatigue-aware progression rules**
    **Preparing the final recommendation**

    The final recommendation will keep the original training goals intact while
    reducing redundant volume and explaining exactly when to add load, repeat a
    session, or take an extra recovery day.
    """
}

/// Reproduces the live transcript's bottom-follow pressure while exercising an
/// explicit Thought-header tap. The position preserver must win for the short
/// disclosure transaction so the header remains planted and the preview grows
/// down toward the following response instead of pushing the transcript up.
private struct LiveThinkingRevealProbeView: View {
    @State private var disclosurePositionPreserver = ChatScrollPositionPreserver()

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: 560)
                        .accessibilityHidden(true)

                    Text("LIVE THINKING · EXPANSION DIRECTION")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    ReasoningBlockView(
                        text: Self.longReasoning,
                        isStreaming: true,
                        preservesViewportOnExpand: true,
                        startsExpandedOverride: false
                    )

                    Text("Following transcript content")
                        .font(.body)
                        .accessibilityIdentifier("gallery.thinking-following-content")
                }
                .padding(16)
                .background {
                    ChatScrollPositionPreserverView(controller: disclosurePositionPreserver)
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .environment(\.activityDisclosureViewportHeight, viewport.size.height)
            .environment(\.preserveActivityExpansionPosition) {
                disclosurePositionPreserver.preserveCurrentVerticalOffset(for: 1.25)
            }
        }
    }

    private static let longReasoning = Array(
        repeating: "Reasoning continues with enough detail to exceed the compact inline preview.",
        count: 24
    ).joined(separator: "\n\n")
}

/// Uses the production `ChatView` gesture stack so XCUITest can verify that a
/// tap on the actual conversation canvas dismisses a pinned expanded plan.
private struct PlanDismissalChatFixture: View {
    private let state = TodoState(todos: [
        TodoItem(rawID: "1", content: "Inspect all branches for missing intended changes", status: .completed),
        TodoItem(rawID: "2", content: "Port the compact plan-card interaction without replaying obsolete history", status: .inProgress),
        TodoItem(rawID: "3", content: "Run simulator and adversarial verification before release", status: .pending),
        TodoItem(rawID: "4", content: "Push the personal fork master checkpoint", status: .pending),
        TodoItem(rawID: "5", content: "Upload Craft-Hermex to internal TestFlight", status: .pending),
        TodoItem(rawID: "6", content: "Preserve branches that still back open upstream pull requests", status: .pending)
    ])

    var body: some View {
        ChatView(
            session: SessionSummary(
                sessionId: "plan-dismissal-fixture",
                title: "Plan dismissal fixture",
                messageCount: 0
            ),
            server: URL(string: "http://127.0.0.1:9")!,
            onAPIError: { _ in },
            loadsInitialMessages: false,
            initialPlanStateForTesting: state
        )
    }
}
#endif
