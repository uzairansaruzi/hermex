import SwiftUI

struct ReasoningBlockView: View {
    let text: String
    var isStreaming: Bool = false
    /// How long the reasoning step took, when known (wired from
    /// ChatTranscriptView). Drives the "Thought for 3.4s" completed label;
    /// nil keeps the plain "Thought".
    var completedDuration: TimeInterval? = nil
    /// When embedded in a merged activity card the parent owns the container,
    /// so the block must not draw its own.
    var drawsOwnChrome: Bool = true
    /// Transcript call sites opt in so an explicit user expansion grows below
    /// the exact viewport position where its header was tapped. This also
    /// temporarily overrides live follow-bottom; otherwise a large size change
    /// pins the card's bottom and makes the disclosure appear to open upward.
    var preservesViewportOnExpand: Bool = false
    /// Default expansion when the reader has not toggled this block.
    ///
    /// Production always passes nil now — the merged card's sections open as
    /// collapsed pills that follow the user's `thinkingCardsStartExpanded`
    /// setting, the same as standalone blocks. Mounting them open was tried
    /// and reverted: the fold inserts its subtree with an opacity transition,
    /// so a pre-expanded markdown body pops in at full height instead of
    /// revealing inline (the pill's own tap animates correctly because its
    /// clipped frame interpolates). Debug galleries still pass `true` to
    /// render the expanded treatment directly.
    var startsExpandedOverride: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.activityDisclosureViewportHeight) private var availableViewportHeight
    @Environment(\.preserveActivityExpansionPosition) private var preserveActivityExpansionPosition
    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?
    @State private var isFullReaderPresented = false
    @State private var measuredHeaderHeight: CGFloat = 0
    /// The body's intrinsic height is measured while the section is collapsed.
    /// Historical sections exist only while their outer Activity disclosure is
    /// open, so this does not keep every transcript renderer alive.
    @State private var measuredBodyHeight: CGFloat = 0

    private var isExpanded: Bool {
        #if DEBUG
        // Debug motion lab drives expansion on a timer so open/close can be
        // recorded deterministically; nil in every production path.
        if let forced = disclosureLabExpansion { return forced }
        #endif
        return ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpandedOverride ?? startsExpanded
        )
    }

    /// Do not change the header chrome or sibling flow until the persistent
    /// Markdown body has reported one deterministic height. In normal use that
    /// measurement lands while the reader is moving from the outer Activity
    /// summary to this inner disclosure; the guard also makes an immediate tap
    /// wait for a real size instead of animating through transient geometry.
    private var presentsExpandedBody: Bool {
        isExpanded && measuredBodyHeight > 0
    }

    private var inlineChromeReservedHeight: CGFloat {
        measuredHeaderHeight
            + 8
            + ActivityBlockChrome.topPadding
            + ActivityBlockChrome.bottomPadding
    }

    /// Apple advises against nesting same-axis scroll views. The expanded card
    /// therefore shows a non-scrolling preview; overflow moves to a dedicated
    /// reader instead of competing with the transcript for vertical drags.
    private var bodyOverflowsInlinePreview: Bool {
        measuredBodyHeight > ReasoningBodyWindow.height(
            measuredContentHeight: measuredBodyHeight,
            availableHeight: availableViewportHeight,
            reservedHeight: inlineChromeReservedHeight
        ) + 0.5
    }

    /// Short Thoughts retain their exact natural height. Long Thoughts reserve
    /// space for the explicit reader action while keeping the entire expanded
    /// card subordinate to the surrounding conversation.
    private var presentedBodyHeight: CGFloat {
        ReasoningBodyWindow.height(
            measuredContentHeight: measuredBodyHeight,
            availableHeight: availableViewportHeight,
            reservedHeight: inlineChromeReservedHeight
                + (bodyOverflowsInlinePreview ? ReasoningBodyWindow.readerActionReservedHeight : 0)
        )
    }

    /// Settled thoughts pre-mount while their outer Activity disclosure is
    /// open. A collapsed *streaming* thought stays cheap: mounting Markdown on
    /// every incoming reasoning delta would undo the transcript's collapsed-
    /// card performance optimization. Its first explicit open mounts once,
    /// measures, and then reveals.
    private var keepsBodyMounted: Bool {
        !isStreaming || isExpanded
    }

    #if DEBUG
    @Environment(\.disclosureLabExpansion) private var disclosureLabExpansion
    #endif

    var body: some View {
        if let trimmedText {
            let presentedText = ReasoningMarkdownPresentation.formatted(trimmedText)
            VStack(alignment: .leading, spacing: presentsExpandedBody ? 8 : 0) {
                // `isStreaming` is fed from `ChatViewModel.isReasoningPhaseActive`
                // at the live call sites (ChatTranscriptView): the orb/beam
                // animate for the entire reasoning *step* — including long
                // pauses between reasoning deltas — and settle only when the
                // turn semantically moves on (tool call, answer text, or end).
                ActivityCapsuleView(
                    orbState: .thinking,
                    label: String(localized: "Thinking…"),
                    isActive: isStreaming,
                    completedIcon: "brain",
                    completedLabel: completedLabelText,
                    accessory: AnyView(chevron),
                    onTap: toggleExpansion,
                    // Expanded, the block itself is the bordered container, so
                    // the header must not draw a competing pill inside it.
                    chrome: presentsExpandedBody ? .none : .pill
                )
                .accessibilityHint(presentsExpandedBody ? "Double tap to collapse details." : "Double tap to expand details.")
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ReasoningHeaderHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onPreferenceChange(ReasoningHeaderHeightKey.self) { height in
                    guard height > 0 else { return }
                    measuredHeaderHeight = height
                }

                if keepsBodyMounted {
                    reasoningBody(content: presentedText)
                }
            }
            // One container for the whole block when open — same treatment the
            // tool block uses, so thinking and tools read as one family.
            .modifier(ReasoningBlockChrome(
                palette: palette,
                isExpanded: presentsExpandedBody,
                drawsSurface: drawsOwnChrome,
                reduceMotion: reduceMotion
            ))
            // Clip to the animating shape.
            //
            // The body reports its full intrinsic height on the frame it
            // mounts, but the card's height spring is still near zero, so
            // without clipping the text renders at full size *outside* the
            // card and overlaps whatever sits below it. That overspill sliding
            // up into place is the "flying in from the top" artifact — it was
            // masked while the body was plain `Text` (cheap, short) and became
            // obvious once markdown made the body taller and multi-block.
            .clipShape(ActivityBlockChrome.shape())
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $isFullReaderPresented) {
                ReasoningReaderView(
                    title: completedLabelText,
                    content: presentedText,
                    isStreaming: isStreaming
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// A stable, pre-mounted body whose intrinsic height is measured before an
    /// inner disclosure tap. The outer Activity fold still owns lifetime: when
    /// that fold is closed this entire view (including Markdown) is unmounted.
    /// While the fold is open, collapsing Thought only clips this already-laid-
    /// out body to zero, so the tools sibling sees one monotonic height spring
    /// instead of the renderer's mount and measurement phases.
    private func reasoningBody(content: String) -> some View {
        VStack(alignment: .leading, spacing: bodyOverflowsInlinePreview ? 8 : 0) {
            ScrollView(.vertical) {
                reasoningContent(content: content)
                    // Measure the full content inside the disabled scroll
                    // container before its viewport is clamped. Keeping this
                    // container mounted preserves the stable disclosure
                    // geometry while allowing transcript drags to pass through.
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ReasoningBodyHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
            }
            .frame(height: presentsExpandedBody ? presentedBodyHeight : 0, alignment: .top)
            // Preserve the useful live/settled preview anchors without making
            // this a second interactive vertical scrolling region.
            .defaultScrollAnchor(isStreaming ? .bottom : .top, for: .initialOffset)
            .defaultScrollAnchor(isStreaming ? .bottom : .top, for: .sizeChanges)
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .contentShape(Rectangle())
            // The header must not be the only escape hatch from a tall Thought.
            .onTapGesture(perform: collapseExpandedBody)
            .accessibilityElement(children: .contain)

            if bodyOverflowsInlinePreview, presentsExpandedBody {
                Button {
                    isFullReaderPresented = true
                } label: {
                    Label("Read full thought", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .opacity(presentsExpandedBody ? 1 : 0)
        // Scope the delayed content curve to pixels only. Width-compensation
        // below must inherit `cardExpand` with the outer block padding so the
        // two insets cancel frame-for-frame throughout the spring.
        .animation(
            ChatMotion.cardContent(
                reduceMotion: reduceMotion,
                delay: ChatMotion.cardVerticalLeadIn
            ),
            value: presentsExpandedBody
        )
        // Collapsed measurement must use the *expanded* content width. The
        // outer block adds 12pt per side only when presented; applying that
        // inset internally before presentation and removing it atomically when
        // the outer padding arrives gives Markdown the same width in both
        // states, so wrapping cannot force a second late height correction.
        .padding(
            .horizontal,
            presentsExpandedBody ? 0 : ActivityBlockChrome.horizontalPadding
        )
        .clipped()
        .allowsHitTesting(presentsExpandedBody)
        .accessibilityHidden(!presentsExpandedBody)
        .onPreferenceChange(ReasoningBodyHeightKey.self, perform: updateMeasuredBodyHeight)
    }

    private func reasoningContent(content: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(palette.tableRule)
                .frame(width: 2)

            MarkdownRenderer(
                content: content,
                isStreaming: isStreaming,
                typographyRole: .reasoning
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
    }

    private func updateMeasuredBodyHeight(_ height: CGFloat) {
        guard height > 0, abs(height - measuredBodyHeight) > 0.5 else { return }
        let firstMeasurement = measuredBodyHeight == 0
        let animation: Animation? = if firstMeasurement, isExpanded {
            ChatMotion.cardExpand(reduceMotion: reduceMotion)
        } else if isStreaming, presentsExpandedBody {
            ChatMotion.streamingFollow(reduceMotion: reduceMotion)
        } else if presentsExpandedBody {
            ChatMotion.disclosure(reduceMotion: reduceMotion)
        } else {
            nil
        }

        withAnimation(animation) {
            measuredBodyHeight = height
        }
    }

    private func toggleExpansion() {
        let willExpand = !isExpanded
        if willExpand, preservesViewportOnExpand {
            // Capture before committing the height change. The transcript
            // holds this exact content offset through the card spring rather
            // than aligning the header to a different place on screen.
            preserveActivityExpansionPosition()
        }

        withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
            userToggledExpansion = willExpand
        }
    }

    private func collapseExpandedBody() {
        guard isExpanded else { return }
        withAnimation(ChatMotion.cardExpand(reduceMotion: reduceMotion)) {
            userToggledExpansion = false
        }
    }

    private var completedLabelText: String {
        guard let completedDuration else {
            return String(localized: "Thought")
        }
        return String(localized: "Thought for \(ActivityDurationFormat.string(completedDuration))")
    }

    private var palette: ChatPalette {
        ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ActivityExpansionPositionActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct ActivityDisclosureViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var activityDisclosureViewportHeight: CGFloat {
        get { self[ActivityDisclosureViewportHeightKey.self] }
        set { self[ActivityDisclosureViewportHeightKey.self] = newValue }
    }

    var preserveActivityExpansionPosition: () -> Void {
        get { self[ActivityExpansionPositionActionKey.self] }
        set { self[ActivityExpansionPositionActionKey.self] = newValue }
    }
}

/// Pure height policy for a Thinking body's non-scrolling inline preview.
///
/// Production supplies the transcript viewport through the environment. The
/// fallback keeps previews and isolated debug galleries bounded before they
/// have a host viewport. Header/chrome and the overflow action are reserved
/// before calculating the body's ceiling, so Dynamic Type cannot push the
/// whole card beyond its intended share of the conversation.
enum ReasoningBodyWindow {
    static let maximumContainerFraction: CGFloat = 0.4
    static let fallbackAvailableHeight: CGFloat = 600
    static let minimumReadableBodyHeight: CGFloat = 96
    static let readerActionReservedHeight: CGFloat = 36

    static func height(
        measuredContentHeight: CGFloat,
        availableHeight: CGFloat,
        reservedHeight: CGFloat = 0
    ) -> CGFloat {
        guard measuredContentHeight > 0 else { return 0 }
        let available = availableHeight > 0 ? availableHeight : fallbackAvailableHeight
        let reserved = min(max(0, reservedHeight), available)
        let availableBodySpace = max(0, available - reserved)
        let fractionBodySpace = max(
            0,
            available * maximumContainerFraction - reserved
        )
        let minimumReadable = min(minimumReadableBodyHeight, availableBodySpace)
        let ceiling = max(minimumReadable, fractionBodySpace)
        return min(measuredContentHeight, ceiling)
    }
}

/// A focused reading surface for long reasoning. It owns the only interactive
/// vertical scroll view, so gestures are never ambiguous with the transcript.
private struct ReasoningReaderView: View {
    let title: String
    let content: String
    let isStreaming: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                MarkdownRenderer(
                    content: content,
                    isStreaming: isStreaming,
                    typographyRole: .reasoning
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .appSurfaceBackground(.canvas)
        }
    }
}

private struct ReasoningHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReasoningBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Presentation-only normalization for provider reasoning ledgers.
///
/// Several providers emit progress as consecutive standalone `**bold**` lines.
/// CommonMark treats a single newline as a soft break, so those lines collapse
/// into one dense paragraph. Only runs of two or more exact bold-only lines are
/// recognized here: they receive hard line breaks and a thematic rule at the
/// boundary to adjacent prose/ledger blocks. Ordinary emphasis, real headings,
/// lists, and fenced code retain their original Markdown semantics.
enum ReasoningMarkdownPresentation {
    static func formatted(_ content: String) -> String {
        let blocks = markdownBlocks(in: content)
        guard blocks.contains(where: \.isStatusLedger) else { return content }

        return blocks.enumerated().map { index, block in
            let rendered = block.isStatusLedger
                ? block.lines.joined(separator: "  \n")
                : block.lines.joined(separator: "\n")
            guard index > 0 else { return rendered }

            let previous = blocks[index - 1]
            let separator = previous.isStatusLedger || block.isStatusLedger
                ? "\n\n---\n\n"
                : "\n\n"
            return separator + rendered
        }.joined()
    }

    private static func markdownBlocks(in content: String) -> [Block] {
        var blocks: [Block] = []
        var currentLines: [String] = []
        var openFence: Fence?

        func flushCurrentBlock() {
            guard !currentLines.isEmpty else { return }
            blocks.append(Block(lines: currentLines))
            currentLines = []
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = Fence.parse(trimmed) {
                currentLines.append(line)
                if let activeFence = openFence, activeFence.matchesClosing(fence) {
                    openFence = nil
                } else if openFence == nil {
                    openFence = fence
                }
            } else if openFence == nil, trimmed.isEmpty {
                flushCurrentBlock()
            } else {
                currentLines.append(line)
            }
        }
        flushCurrentBlock()
        return blocks
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let hasInfoString: Bool

        static func parse(_ line: String) -> Fence? {
            guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
            let length = line.prefix { $0 == marker }.count
            guard length >= 3 else { return nil }
            return Fence(
                marker: marker,
                length: length,
                hasInfoString: !line.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
            )
        }

        func matchesClosing(_ candidate: Fence) -> Bool {
            candidate.marker == marker
                && candidate.length >= length
                && !candidate.hasInfoString
        }
    }

    private struct Block {
        let lines: [String]

        var isStatusLedger: Bool {
            lines.count >= 2 && lines.allSatisfy(Self.isStandaloneBoldLine)
        }

        private static func isStandaloneBoldLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 4,
                  trimmed.hasPrefix("**"),
                  trimmed.hasSuffix("**")
            else { return false }

            let inner = trimmed.dropFirst(2).dropLast(2)
                .trimmingCharacters(in: .whitespaces)
            return !inner.isEmpty
                && !inner.contains("**")
                && !inner.hasPrefix("*")
                && !inner.hasSuffix("*")
        }
    }
}

/// Shared container geometry for expanded activity blocks (thinking + tools).
///
/// 10pt continuous matches `MarkerMessageCardView` and the timeline accessory
/// surface, so an expanded block reads as the same family of card as the rest
/// of the transcript instead of an oversized pill.
enum ActivityBlockChrome {
    static let cornerRadius: CGFloat = 10

    static func shape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    // MARK: - Header alignment
    //
    // Expanding a block wraps the *same* header in a padded container, so the
    // header would shift down and right by exactly the padding it gained. The
    // two paddings below are chosen to cancel the capsule's own inset, keeping
    // the orb and title pinned while the card grows around them:
    //
    //   collapsed  header x = capsule 14                     = 14
    //   expanded   header x = block 12 + capsule 2           = 14
    //   collapsed  header y = capsule 7                      = 7
    //   expanded   header y = block 7 (top) + capsule 0      = 7
    //
    // Bottom padding is free to be larger — nothing below it needs to align.

    /// Horizontal inset the expanded container adds.
    static let horizontalPadding: CGFloat = 12
    /// Top inset, matched to the collapsed capsule's vertical padding so the
    /// header does not drop when the card opens.
    static let topPadding: CGFloat = 7
    static let bottomPadding: CGFloat = 10

    /// Capsule padding while it is a block header (chrome `.none`), reduced to
    /// absorb the container's inset. See the arithmetic above.
    static let headerCapsuleHorizontalPadding: CGFloat = 2
    static let headerCapsuleVerticalPadding: CGFloat = 0
}

/// One border for an expanded thinking block. Collapsed, the header capsule
/// keeps its own pill chrome and this fades out.
///
/// Deliberately a **single** branch. An `if isEnabled { ... } else { content }`
/// modifier gives SwiftUI two different view identities, so toggling it
/// *replaces* the subtree instead of animating it — which is what produced the
/// ghosted double-capsule during expansion. Here the chrome always wraps the
/// same content and only its values animate.
private struct ReasoningBlockChrome: ViewModifier {
    let palette: ChatPalette
    /// Whether the block is open. Owns the *padding*, which must apply even
    /// when the parent draws the surface: the header capsule sheds its own
    /// 14/7 inset on expand (`.pill` → `.none`), and this padding is what
    /// replaces it. Keying padding to `drawsSurface` instead made the header
    /// jump 12pt left and 7pt up whenever the block was inside a container.
    let isExpanded: Bool
    /// Whether this block draws its own fill and border. False when it is a
    /// section inside `ActivityContainerView`, which owns the surface.
    let drawsSurface: Bool
    /// Phase-1 curve for the chrome itself; the height rides `cardExpand`.
    var reduceMotion: Bool = false

    func body(content: Content) -> some View {
        // Single branch with animatable opacity, never an if/else on the styled
        // view: two identities make SwiftUI replace the subtree rather than
        // animate it.
        let showsSurface = isExpanded && drawsSurface
        content
            .padding(.horizontal, isExpanded ? ActivityBlockChrome.horizontalPadding : 0)
            .padding(.top, isExpanded ? ActivityBlockChrome.topPadding : 0)
            .padding(.bottom, isExpanded ? ActivityBlockChrome.bottomPadding : 0)
            .background(
                ActivityBlockChrome.shape()
                    .fill(palette.surface.opacity(0.8))
                    .opacity(showsSurface ? 1 : 0)
            )
            .overlay(
                ActivityBlockChrome.shape()
                    .strokeBorder(palette.tableRule, lineWidth: 1)
                    .opacity(showsSurface ? 1 : 0)
            )
            // Chrome resolves on the short horizontal curve; the enclosing
            // `withAnimation(cardExpand)` still owns the height.
            .animation(ChatMotion.cardChrome(reduceMotion: reduceMotion), value: showsSurface)
    }
}
