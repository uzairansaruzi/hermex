import Highlightr
import MarkdownUI
import OSLog
import Splash
import SwiftUI
import UIKit

struct MarkdownRenderer: View {
    let content: String
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
    }

    /// Keeps the streaming renderer mounted briefly after streaming ends so
    /// the reveal queue's in-flight glyph cascade can finish instead of
    /// snapping to the solid static rendering mid-fade.
    @State private var lingersAfterStreaming = false

    var body: some View {
        Group {
            if isStreaming || lingersAfterStreaming {
                StreamingMarkdownRenderer(content: content)
            } else if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: " ")
            } else if let fallbackReason = MarkdownContentRenderingPolicy.fallbackReason(for: content) {
                PlainMarkdownFallbackView(
                    content: content,
                    reason: fallbackReason
                )
            } else {
                markdownContent
            }
        }
        .onChange(of: isStreaming) { wasStreaming, nowStreaming in
            if wasStreaming, !nowStreaming {
                lingersAfterStreaming = true
            }
        }
        .task(id: isStreaming) {
            guard !isStreaming else { return }
            try? await Task.sleep(for: .seconds(StreamingTextFadeDefaults.framePauseDelay))
            guard !Task.isCancelled else { return }
            lingersAfterStreaming = false
        }
    }

    @ViewBuilder
    private var markdownContent: some View {
        switch MarkdownMathLayoutCache.layout(for: content) {
        case .segmented(let segments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ChatMarkdownView(
                                content: markdown,
                                colorScheme: colorScheme,
                                isStreaming: isStreaming
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
            .responseTextSelectionPolicy()
        case .plain(let markdown):
            ChatMarkdownView(
                content: markdown,
                colorScheme: colorScheme,
                isStreaming: isStreaming
            )
            .responseTextSelectionPolicy()
        }
    }
}

struct StreamingMarkdownRenderer: View {
    let content: String

    @State private var displayedContent: String

    init(content: String) {
        self.content = content
        _displayedContent = State(initialValue: content)
    }

    var body: some View {
        // `content` changes first and `displayedContent` catches up after the
        // yield, so the first body pass of each update hands the child the
        // text it already drew. `.equatable()` skips the child's whole-reply
        // work (trim, fallback policy, math layout) on that pass.
        StreamingMarkdownDisplayedContentView(content: displayedContent)
            .equatable()
            .task(id: content) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard displayedContent != content else { return }
                displayedContent = content
            }
    }
}

/// The streaming reply as `StreamingMarkdownRenderer` currently displays it.
/// Equatable on `content` so a parent pass with unchanged text is free;
/// environment changes (color scheme) still update it.
private struct StreamingMarkdownDisplayedContentView: View, Equatable {
    let content: String

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.content == rhs.content
    }

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(verbatim: " ")
        } else if let fallbackReason = MarkdownContentRenderingPolicy.fallbackReason(for: content) {
            PlainMarkdownFallbackView(
                content: content,
                reason: fallbackReason
            )
        } else {
            streamingMarkdownContent
        }
    }

    @ViewBuilder
    private var streamingMarkdownContent: some View {
        // Streaming text changes on nearly every token, so this deliberately
        // does not memoize; it only avoids the redundant second full-string
        // `replacingInlineMath` pass the no-math branch used to run.
        switch MarkdownMathLayoutCache.uncachedLayout(for: content) {
        case .segmented(let segments):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StreamingMarkdownChunkedView(
                                content: markdown,
                                colorScheme: colorScheme
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
        case .plain(let markdown):
            StreamingMarkdownChunkedView(
                content: markdown,
                colorScheme: colorScheme
            )
        }
    }

}

/// Lets a surface keep the streaming renderer's cost savings without its
/// reveal fade. Bot Chat sets it false: its text arrives in coalesced
/// snapshots, and a whole snapshot fading in leaves the latest edge blank.
struct AllowsStreamedTextAnimationKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var allowsStreamedTextAnimation: Bool {
        get { self[AllowsStreamedTextAnimationKey.self] }
        set { self[AllowsStreamedTextAnimationKey.self] = newValue }
    }
}

private struct StreamingMarkdownChunkedView: View {
    let content: String
    let colorScheme: ColorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.allowsStreamedTextAnimation) private var allowsStreamedTextAnimation
    @AppStorage(StreamedTextAnimationSettings.isEnabledKey) private var isStreamedTextAnimationEnabled = true

    /// First block ordinal still in the fade window. Starts at `Int.max`
    /// (everything solid) until `onAppear` anchors it at the current block,
    /// so text already on screen when the view mounts never fades.
    @State private var firstFadeOrdinal = Int.max
    /// Ordinal of the current block at mount; only blocks created after it
    /// arm their stores (pre-existing blocks take the solid baseline).
    @State private var mountBoundaryCount = Int.max
    @State private var lastBoundaryCount = 0
    @State private var lastTouchedAt: [Int: TimeInterval] = [:]
    @State private var fadesActive = false
    /// One reveal cursor for all fade blocks of this view, so consecutive
    /// blocks (paragraphs, list items) appear in reading order even when a
    /// fast stream backlogs a block's queue toward `maxStampLead`.
    @State private var chain = StreamingTextFadeStampChain()
    /// The active tail as of the last fade-window update, so an append can be
    /// told apart from a replacement without re-splitting the old content.
    @State private var lastActiveMarkdown = ""

    var body: some View {
        // The one whole-reply split per update; the fade-window callbacks
        // below reuse it.
        let segments = StreamingMarkdownBlockSplitter.split(content)
        let blockSplit = StreamingTextFadeTailSplitter.split(
            segments.activeMarkdown,
            firstFadeOrdinal: StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(
                firstFadeOrdinal,
                reduceMotion: reduceMotion,
                isEnabled: isStreamedTextAnimationEnabled && allowsStreamedTextAnimation
            )
        )

        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments.stableChunks) { chunk in
                ChatMarkdownView(
                    content: chunk.text,
                    colorScheme: colorScheme,
                    isStreaming: false
                )
            }

            if !blockSplit.head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatMarkdownView(
                    content: blockSplit.head,
                    colorScheme: colorScheme,
                    isStreaming: true
                )
            }

            if !blockSplit.blocks.isEmpty {
                // One shared frame clock for every fade block. Per frame only
                // the renderer's clock input changes; each block's markdown
                // inputs are untouched, so their bodies (and text layout) are
                // not re-evaluated.
                TimelineView(.animation(minimumInterval: nil, paused: !fadesActive)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(blockSplit.blocks, id: \.ordinal) { block in
                            StreamingFadeBlockView(
                                text: block.text,
                                colorScheme: colorScheme,
                                fadeEnabled: block.fadeEnabled,
                                armOnAppear: block.ordinal > mountBoundaryCount,
                                clock: context.date.timeIntervalSinceReferenceDate,
                                chain: chain
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            anchorFadeWindowAtCurrentBlock(segments.activeMarkdown)
        }
        .onChange(of: content) { _, newContent in
            // This closure comes from the body pass that split `newContent`;
            // re-split only if SwiftUI hands over some other value.
            let newActive = newContent == content
                ? segments.activeMarkdown
                : StreamingMarkdownBlockSplitter.split(newContent).activeMarkdown
            advanceFadeWindow(to: newActive)
        }
        .onChange(of: isStreamedTextAnimationEnabled) { _, isEnabled in
            if isEnabled {
                anchorFadeWindowAtCurrentBlock(segments.activeMarkdown)
            }
        }
        .onChange(of: reduceMotion) { _, reduceMotion in
            if !reduceMotion {
                anchorFadeWindowAtCurrentBlock(segments.activeMarkdown)
            }
        }
        .task(id: content) {
            // Let queued reveals and the newest fade finish, then pause frame
            // updates until more content arrives (e.g. the stream stalls on
            // tool use). A new change cancels this task and restarts it.
            try? await Task.sleep(for: .seconds(StreamingTextFadeDefaults.framePauseDelay))
            guard !Task.isCancelled else { return }
            fadesActive = false
        }
    }

    /// Anchors the fade window at the current block: everything visible now
    /// takes the solid baseline, only text streamed afterwards fades. Used at
    /// mount, and again whenever fading becomes active mid-stream (animation
    /// setting flipped on, Reduce Motion turned off) — the window bookkeeping
    /// keeps advancing while fades route to the head, so without re-anchoring
    /// the reopened window would arm blocks the user is already reading and
    /// visibly re-fade them.
    private func anchorFadeWindowAtCurrentBlock(_ activeMarkdown: String) {
        let split = StreamingTextFadeTailSplitter.split(activeMarkdown, firstFadeOrdinal: 0)
        firstFadeOrdinal = split.boundaryCount
        mountBoundaryCount = split.boundaryCount
        lastBoundaryCount = split.boundaryCount
        lastTouchedAt = [:]
        lastActiveMarkdown = activeMarkdown
    }

    /// Advances the fade window to the new active tail. Called once per
    /// content change with the tail the body already split.
    private func advanceFadeWindow(to newActive: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let oldActive = lastActiveMarkdown
        lastActiveMarkdown = newActive
        let split = StreamingTextFadeTailSplitter.split(newActive, firstFadeOrdinal: firstFadeOrdinal)

        if !newActive.hasPrefix(oldActive) {
            // Replaced content or a sealed stable chunk shifted the active
            // window: ordinals no longer line up, so restart the fade window
            // at the current block (renders solid, then new text fades).
            lastTouchedAt = [:]
            firstFadeOrdinal = split.boundaryCount
            lastBoundaryCount = split.boundaryCount
            chain.reset()
            fadesActive = true
            return
        }

        // Only the current block and any blocks newly created by this append
        // were touched; everything earlier is frozen text aging toward
        // absorption. min() also covers an item boundary vanishing when its
        // nested child arrives (the merged block is current again).
        for block in split.blocks where block.ordinal >= min(lastBoundaryCount, split.boundaryCount) {
            lastTouchedAt[block.ordinal] = now
        }
        lastBoundaryCount = split.boundaryCount

        firstFadeOrdinal = StreamingTextFadeWindow.advanceStart(
            current: min(firstFadeOrdinal, split.boundaryCount),
            boundaryCount: split.boundaryCount,
            lastTouchedAt: lastTouchedAt,
            now: now
        )
        lastTouchedAt = lastTouchedAt.filter { $0.key >= firstFadeOrdinal }
        fadesActive = true
    }
}

/// One block of the streaming fade window, drawn through
/// `StreamingTextFadeRenderer` with its own stamp store so neighbouring
/// blocks' character offsets never collide. The block keeps fading after it
/// completes — it only leaves the window (and joins the solid head) once its
/// cascade is provably finished, which is what prevents end-of-block snaps.
private struct StreamingFadeBlockView: View {
    let text: String
    let colorScheme: ColorScheme
    let fadeEnabled: Bool
    let armOnAppear: Bool
    let clock: TimeInterval

    @State private var store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    init(
        text: String,
        colorScheme: ColorScheme,
        fadeEnabled: Bool,
        armOnAppear: Bool,
        clock: TimeInterval,
        chain: StreamingTextFadeStampChain
    ) {
        self.text = text
        self.colorScheme = colorScheme
        self.fadeEnabled = fadeEnabled
        self.armOnAppear = armOnAppear
        self.clock = clock
        _store = State(initialValue: StreamingTextFadeStampStore(chain: chain))
    }

    var body: some View {
        Group {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if fadeEnabled {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true
                    )
                    .textRenderer(StreamingTextFadeRenderer(clock: clock, store: store))
                } else {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true
                    )
                }
            }
        }
        .onAppear {
            // Blocks appearing after the view mounted are newly streamed text
            // and must fade from their first glyph; blocks present at mount
            // are pre-existing text and take the solid baseline instead.
            if armOnAppear {
                store.rolloverReset()
            }
        }
    }
}

private struct ChatMarkdownView: View {
    let content: String
    let colorScheme: ColorScheme
    let isStreaming: Bool

    var body: some View {
        Markdown(content)
            .markdownTheme(MarkdownUI.Theme.chat(colorScheme: colorScheme, isStreaming: isStreaming))
            .markdownTextStyle {
                ForegroundColor(.primary)
                BackgroundColor(nil)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(SwiftUI.Color(.tertiarySystemGroupedBackground))
            }
            .markdownCodeSyntaxHighlighter(.plainText)
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .markdownMargin(top: 0, bottom: 8)
            }
    }
}

/// Routes a fenced code block to display-math rendering when its language is a
/// math language (`math`/`latex`/`tex`) and the body parses as math; otherwise
/// renders it as a normal syntax-highlighted code block. A math fence whose
/// body SwiftMath can't parse falls back to the code block too, so nothing is
/// lost.
private struct MathFenceOrCodeBlock: View {
    let language: String?
    let content: String
    let isStreaming: Bool

    var body: some View {
        if MathFenceLanguage.matches(language), MathLaTeX.isRenderable(content) {
            DisplayMathView(latex: content)
        } else {
            ChatCodeBlock(
                language: language,
                content: content,
                isStreaming: isStreaming
            )
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let content: String
    let isStreaming: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var highlightedCode: NSAttributedString?
    /// Whether a long settled diff shows every line instead of the first `collapsedLineLimit`.
    @State private var showsAllDiffLines = false

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        let diff = MarkdownDiffFormatter.document(for: content, language: language, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(.subheadline.weight(.semibold))

                if let diff {
                    DiffCountsLabel(additions: diff.additions, deletions: diff.deletions)
                }

                Spacer()

                Button {
                    wrapsCodeBlockLines.toggle()
                } label: {
                    Image(systemName: wrapsCodeBlockLines ? "arrow.turn.down.left" : "arrow.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .buttonStyle(.chatTactile(.icon))
                .foregroundStyle(SwiftUI.Color.primary)
                .accessibilityLabel(wrapsCodeBlockLines ? "Disable code line wrapping" : "Enable code line wrapping")

                ChatCopyButton(
                    label: String(localized: "Copy code"),
                    copiedLabel: String(localized: "Copied code"),
                    size: 36,
                    glyphSize: 18,
                    glyphWeight: .semibold
                ) {
                    UIPasteboard.general.string = content
                    ChatHaptics.copied(isEnabled: isHapticsEnabled)
                }
                .foregroundStyle(SwiftUI.Color.primary)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if let diff {
                diffBody(diff)
            } else if wrapsCodeBlockLines {
                styledCodeText(fixedHorizontal: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    styledCodeText(fixedHorizontal: true)
                }
            }
        }
        .background(codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SwiftUI.Color(.separator).opacity(0.35), lineWidth: 1)
        }
        .task(id: highlightRequest) {
            await updateHighlightedCode(for: highlightRequest)
        }
        // Code (and diff) blocks must never mirror inside an RTL message (#259):
        // the language header, copy/wrap controls, and the source itself stay LTR.
        .forcedLeftToRight()
    }

    private var codeBlockBackground: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.04, green: 0.05, blue: 0.07)
            : SwiftUI.Color(.secondarySystemBackground)
    }

    /// Falls back to a synchronous cache peek so a block that was already highlighted
    /// (reopen, scrolling back, or a sealed stable chunk at the streaming-to-settled swap)
    /// draws highlighted on its first frame, before its task runs.
    @ViewBuilder
    private var codeText: some View {
        if let highlightedCode = highlightedCode
            ?? MarkdownCodeHighlighter.shared.cachedHighlight(for: highlightRequest) {
            HighlightedCodeBlockText(content: highlightedCode, wraps: wrapsCodeBlockLines)
        } else {
            PlainCodeBlockText(content: content, wraps: wrapsCodeBlockLines)
        }
    }

    /// A settled diff: tinted rows, capped at `collapsedLineLimit` lines behind a
    /// full-width Show all row. Copy still copies the whole source.
    @ViewBuilder
    private func diffBody(_ diff: MarkdownDiffDocument) -> some View {
        let lines = diff.visibleLines(showingAll: showsAllDiffLines)

        Group {
            if wrapsCodeBlockLines {
                DiffCodeBlockText(lines: lines, wraps: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DiffCodeBlockScrollBody(lines: lines)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, diff.isCollapsible ? 12 : 16)

        if diff.isCollapsible {
            Button {
                showsAllDiffLines.toggle()
            } label: {
                HStack(spacing: 6) {
                    if showsAllDiffLines {
                        Text("Show first \(MarkdownDiffFormatter.collapsedLineLimit) lines")
                    } else {
                        Text("Show all \(diff.lines.count) lines")
                    }
                    Image(systemName: showsAllDiffLines ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.top, 11)
                .padding(.bottom, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.chatTactile(.compactControl))
            .foregroundStyle(.tint)
            .overlay(alignment: .top) { Divider() }
            .accessibilityHint("Copy includes every line.")
        }
    }

    /// The code body with its shared monospaced styling and padding. `fixedHorizontal`
    /// is `true` inside the horizontal `ScrollView` (each line keeps its natural width)
    /// and `false` when wrapping (lines reflow to the bubble width, growing vertically).
    private func styledCodeText(fixedHorizontal: Bool) -> some View {
        codeText
            .fixedSize(horizontal: fixedHorizontal, vertical: true)
            .relativeLineSpacing(.em(0.18))
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.84))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    private var highlightRequest: MarkdownCodeHighlightRequest {
        MarkdownCodeHighlightRequest(
            code: content,
            language: language,
            colorScheme: colorScheme,
            isStreaming: isStreaming
        )
    }

    /// Seeds from the cache when it can; otherwise shows plain text while the
    /// highlighter works off main, and drops the result if the block moved on.
    @MainActor
    private func updateHighlightedCode(for request: MarkdownCodeHighlightRequest) async {
        // Diff and patch never highlight: `MarkdownDiffFormatter` styles them natively.
        guard !MarkdownDiffFormatter.isDiffLanguage(request.language) else { return }
        let highlighter = MarkdownCodeHighlighter.shared
        if let cached = highlighter.cachedHighlight(for: request) {
            highlightedCode = cached
            return
        }

        highlightedCode = nil
        let result = await highlighter.highlightedCode(for: request)
        guard !Task.isCancelled, request == highlightRequest else { return }

        switch result {
        case .highlighted(let attributedString):
            highlightedCode = attributedString
        case .plain(let reason, let normalizedLanguage):
            highlightedCode = nil
            logFallback(
                reason: reason,
                normalizedLanguage: normalizedLanguage,
                code: request.code
            )
        }
    }

    private var displayLanguage: String {
        guard let name = normalizedLanguage else {
            return String(localized: "Code")
        }

        switch name {
        case "js":
            return "JavaScript"
        case "ts":
            return "TypeScript"
        case "py":
            return "Python"
        default:
            return name.uppercased() == name ? name : name.capitalized
        }
    }

    private var normalizedLanguage: String? {
        language?
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private func logFallback(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?, code: String) {
        guard reason != .empty else { return }

        logger.info(
            "Syntax highlighting fallback reason=\(reason.rawValue, privacy: .public) languageCategory=\(MarkdownHighlightPolicy.languageLogCategory(for: normalizedLanguage), privacy: .public) characters=\(code.count, privacy: .public) lines=\(MarkdownHighlightPolicy.lineCount(in: code), privacy: .public)"
        )
    }
}

private struct PlainCodeBlockText: View {
    let content: String
    /// When `true`, each line's 500-char segments are concatenated into a single
    /// `Text` so SwiftUI soft-wraps the line; when `false`, they stay side by side
    /// in an `HStack` for the horizontal-scroll layout.
    var wraps = false

    private var lines: [MarkdownPlainCodeLine] {
        MarkdownPlainCodeFormatter.lines(in: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines) { line in
                if wraps {
                    combinedText(for: line)
                        .responseSelectableText(line.segments.map(\.text).joined())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(verbatim: segment.text)
                                .responseSelectableText(segment.text, separator: segment.id == line.segments.last?.id ? "\n" : "")
                        }
                    }
                }
            }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(.primary)
    }

    private func combinedText(for line: MarkdownPlainCodeLine) -> Text {
        line.segments.reduce(Text(verbatim: "")) { partial, segment in
            partial + Text(verbatim: segment.text)
        }
    }
}

private struct HighlightedCodeBlockText: View {
    let content: NSAttributedString
    /// See `PlainCodeBlockText.wraps`; the concatenated `Text` preserves each
    /// segment's syntax-highlight attributes.
    var wraps = false

    private var lines: [MarkdownAttributedCodeLine] {
        MarkdownAttributedCodeFormatter.lines(in: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines) { line in
                if wraps {
                    combinedText(for: line)
                        .responseSelectableText(line.segments.map { $0.attributedText.string }.joined())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(AttributedString(segment.attributedText))
                                .responseSelectableText(segment.attributedText.string, separator: segment.id == line.segments.last?.id ? "\n" : "")
                        }
                    }
                }
            }
        }
    }

    private func combinedText(for line: MarkdownAttributedCodeLine) -> Text {
        line.segments.reduce(Text(verbatim: "")) { partial, segment in
            partial + Text(AttributedString(segment.attributedText))
        }
    }
}

struct MarkdownPlainCodeLine: Equatable, Identifiable {
    let id: Int
    let segments: [MarkdownPlainCodeSegment]
}

struct MarkdownPlainCodeSegment: Equatable, Identifiable {
    let id: Int
    let text: String
}

struct MarkdownAttributedCodeLine: Identifiable {
    let id: Int
    let segments: [MarkdownAttributedCodeSegment]
}

struct MarkdownAttributedCodeSegment: Identifiable {
    let id: Int
    let attributedText: NSAttributedString
}

enum MarkdownPlainCodeFormatter {
    static let maxSegmentLength = 500

    static func lines(in code: String) -> [MarkdownPlainCodeLine] {
        rawLines(in: code).enumerated().map { lineIndex, line in
            MarkdownPlainCodeLine(
                id: lineIndex,
                segments: segments(in: line)
            )
        }
    }

    /// The code's lines with CRLF, CR, and Unicode line and paragraph separators
    /// treated as newlines; an empty string is one empty line.
    static func rawLines(in code: String) -> [String] {
        let normalizedCode = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")

        let lines = normalizedCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return lines.isEmpty ? [""] : lines
    }

    /// Splits one line into `maxSegmentLength`-character segments; an empty line is one space.
    static func segments(in line: String) -> [MarkdownPlainCodeSegment] {
        guard !line.isEmpty else {
            return [MarkdownPlainCodeSegment(id: 0, text: " ")]
        }

        var segments: [MarkdownPlainCodeSegment] = []
        var startIndex = line.startIndex
        var segmentID = 0

        while startIndex < line.endIndex {
            let endIndex = line.index(
                startIndex,
                offsetBy: maxSegmentLength,
                limitedBy: line.endIndex
            ) ?? line.endIndex
            segments.append(
                MarkdownPlainCodeSegment(
                    id: segmentID,
                    text: String(line[startIndex..<endIndex])
                )
            )
            startIndex = endIndex
            segmentID += 1
        }

        return segments
    }
}

enum MarkdownAttributedCodeFormatter {
    static let maxSegmentLength = MarkdownPlainCodeFormatter.maxSegmentLength

    static func lines(in attributedCode: NSAttributedString) -> [MarkdownAttributedCodeLine] {
        let string = attributedCode.string as NSString
        guard string.length > 0 else {
            return [
                MarkdownAttributedCodeLine(
                    id: 0,
                    segments: [MarkdownAttributedCodeSegment(id: 0, attributedText: NSAttributedString(string: " "))]
                )
            ]
        }

        var lines: [MarkdownAttributedCodeLine] = []
        var lineStart = 0
        var index = 0

        while index < string.length {
            let character = string.character(at: index)
            if isLineSeparator(character) {
                lines.append(
                    MarkdownAttributedCodeLine(
                        id: lines.count,
                        segments: segments(in: NSRange(location: lineStart, length: index - lineStart), of: attributedCode)
                    )
                )

                if character == 13,
                   index + 1 < string.length,
                   string.character(at: index + 1) == 10 {
                    index += 1
                }
                lineStart = index + 1
            }

            index += 1
        }

        lines.append(
            MarkdownAttributedCodeLine(
                id: lines.count,
                segments: segments(
                    in: NSRange(location: lineStart, length: string.length - lineStart),
                    of: attributedCode
                )
            )
        )

        return lines
    }

    private static func segments(in range: NSRange, of attributedCode: NSAttributedString) -> [MarkdownAttributedCodeSegment] {
        guard range.length > 0 else {
            return [MarkdownAttributedCodeSegment(id: 0, attributedText: NSAttributedString(string: " "))]
        }

        var segments: [MarkdownAttributedCodeSegment] = []
        var location = range.location
        let upperBound = range.location + range.length

        while location < upperBound {
            let length = min(maxSegmentLength, upperBound - location)
            let segmentRange = NSRange(location: location, length: length)
            segments.append(
                MarkdownAttributedCodeSegment(
                    id: segments.count,
                    attributedText: attributedCode.attributedSubstring(from: segmentRange)
                )
            )
            location += length
        }

        return segments
    }

    private static func isLineSeparator(_ character: unichar) -> Bool {
        switch character {
        case 10, 13, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

enum MarkdownContentFallbackReason: String, Equatable {
    case tooManyCharacters
    case tooManyLines
}

enum MarkdownContentRenderingPolicy {
    static let maxMarkdownCharacterCount = 80_000
    static let maxMarkdownLineCount = 2_000

    static func fallbackReason(for content: String) -> MarkdownContentFallbackReason? {
        if content.count > maxMarkdownCharacterCount {
            return .tooManyCharacters
        }

        if MarkdownHighlightPolicy.lineCount(in: content, stoppingAfter: maxMarkdownLineCount) > maxMarkdownLineCount {
            return .tooManyLines
        }

        return nil
    }
}

enum MarkdownHighlightEngine: Equatable {
    case splashSwift
    case highlightr
}

enum MarkdownHighlightFallbackReason: String, Equatable {
    case streaming
    case empty
    case missingLanguage
    case unsupportedLanguage
    case highRiskLanguage
    case tooManyCharacters
    case tooManyLines
    case lineTooLong
    case highlighterUnavailable
    /// The owning block's task was cancelled before the highlight pass ran.
    case cancelled
}

enum MarkdownHighlightDecision: Equatable {
    case highlight(language: String, engine: MarkdownHighlightEngine)
    case plain(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?)
}

enum MarkdownHighlightPolicy {
    static let maxHighlightedCodeCharacterCount = 80_000
    static let maxHighlightedCodeLineCount = 2_000
    static let maxHighlightedCodeLineLength = 4_000

    private static let splashSwiftLanguages: Set<String> = ["swift"]
    private static let highRiskLanguages: Set<String> = [
        "ansi",
        "console",
        "diff",
        "log",
        "logs",
        "output",
        "patch",
        "plain",
        "terminal",
        "text",
        "txt"
    ]
    static let highlightrLanguages: Set<String> = [
        "bash",
        "c",
        "cpp",
        "css",
        "go",
        "html",
        "java",
        "javascript",
        "json",
        "kotlin",
        "markdown",
        "objectivec",
        "python",
        "ruby",
        "rust",
        "scss",
        "sql",
        "toml",
        "typescript",
        "xml",
        "yaml"
    ]
    private static let languageAliases: [String: String] = [
        "c++": "cpp",
        "htm": "html",
        "js": "javascript",
        "jsx": "javascript",
        "jsonc": "json",
        "kt": "kotlin",
        "m": "objectivec",
        "md": "markdown",
        "mm": "objectivec",
        "objc": "objectivec",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "bash",
        "shell": "bash",
        "ts": "typescript",
        "tsx": "typescript",
        "yml": "yaml",
        "zsh": "bash"
    ]

    static func decision(for code: String, language: String?, isStreaming: Bool) -> MarkdownHighlightDecision {
        if isStreaming {
            return .plain(reason: .streaming, normalizedLanguage: normalizedLanguage(from: language))
        }

        if code.isEmpty {
            return .plain(reason: .empty, normalizedLanguage: normalizedLanguage(from: language))
        }

        if code.count > maxHighlightedCodeCharacterCount {
            return .plain(reason: .tooManyCharacters, normalizedLanguage: normalizedLanguage(from: language))
        }

        if lineCount(in: code, stoppingAfter: maxHighlightedCodeLineCount) > maxHighlightedCodeLineCount {
            return .plain(reason: .tooManyLines, normalizedLanguage: normalizedLanguage(from: language))
        }

        if containsLineLongerThan(maxHighlightedCodeLineLength, in: code) {
            return .plain(reason: .lineTooLong, normalizedLanguage: normalizedLanguage(from: language))
        }

        guard let normalizedLanguage = normalizedLanguage(from: language) else {
            return .plain(reason: .missingLanguage, normalizedLanguage: nil)
        }

        if highRiskLanguages.contains(normalizedLanguage) {
            return .plain(reason: .highRiskLanguage, normalizedLanguage: normalizedLanguage)
        }

        if splashSwiftLanguages.contains(normalizedLanguage) {
            return .highlight(language: normalizedLanguage, engine: .splashSwift)
        }

        if highlightrLanguages.contains(normalizedLanguage) {
            return .highlight(language: normalizedLanguage, engine: .highlightr)
        }

        return .plain(reason: .unsupportedLanguage, normalizedLanguage: normalizedLanguage)
    }

    /// Whether a fence language can ever be highlighted. Reads only the language,
    /// so it is a cheap gate before any work that touches the code.
    static func canHighlight(language: String?) -> Bool {
        guard let normalized = normalizedLanguage(from: language) else { return false }
        return splashSwiftLanguages.contains(normalized) || highlightrLanguages.contains(normalized)
    }

    static func normalizedLanguage(from language: String?) -> String? {
        guard let token = language?
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
        else {
            return nil
        }

        return languageAliases[token] ?? token
    }

    static func languageLogCategory(for normalizedLanguage: String?) -> String {
        guard let normalizedLanguage else {
            return "missing"
        }

        if splashSwiftLanguages.contains(normalizedLanguage) {
            return "splashSwift"
        }

        if highlightrLanguages.contains(normalizedLanguage) {
            return "highlightr"
        }

        if highRiskLanguages.contains(normalizedLanguage) {
            return "highRisk"
        }

        return "unsupported"
    }

    static func lineCount(in text: String, stoppingAfter limit: Int? = nil) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 1
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            let nextIndex = text.unicodeScalars.index(after: index)

            if isLineSeparator(scalar) {
                count += 1
                if let limit, count > limit {
                    return count
                }

                if scalar.value == 13,
                   nextIndex < text.unicodeScalars.endIndex,
                   text.unicodeScalars[nextIndex].value == 10 {
                    index = text.unicodeScalars.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
            } else {
                index = nextIndex
            }
        }

        return count
    }

    static func containsLineLongerThan(_ maxLength: Int, in text: String) -> Bool {
        guard maxLength >= 0 else { return true }

        var currentLength = 0
        var index = text.unicodeScalars.startIndex

        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            let nextIndex = text.unicodeScalars.index(after: index)

            if isLineSeparator(scalar) {
                currentLength = 0
                if scalar.value == 13,
                   nextIndex < text.unicodeScalars.endIndex,
                   text.unicodeScalars[nextIndex].value == 10 {
                    index = text.unicodeScalars.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
            } else {
                currentLength += 1
                if currentLength > maxLength {
                    return true
                }
                index = nextIndex
            }
        }

        return false
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 10, 13, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

struct MarkdownCodeHighlightRequest: Equatable {
    let code: String
    let language: String?
    let colorScheme: ColorScheme
    let isStreaming: Bool
}

enum MarkdownCodeHighlightResult {
    case highlighted(NSAttributedString)
    case plain(reason: MarkdownHighlightFallbackReason, normalizedLanguage: String?)
}

/// Highlights settled chat code blocks off the main actor. Highlightr runs
/// highlight.js in a JSContext, so both the context load and each block's pass
/// stay off main. Results are cached by appearance, fence language, and code;
/// a remounted block that was highlighted before (session reopen, scrolling back,
/// or code in a sealed stable chunk at the streaming-to-settled swap) reads its
/// result synchronously through `cachedHighlight(for:)` instead of flashing plain.
/// Code in a reply's unsealed streaming tail is first highlighted at the swap.
actor MarkdownCodeHighlighter {
    static let shared = MarkdownCodeHighlighter()

    /// NSCache is thread-safe, which is what lets the main actor peek it synchronously.
    /// Content-addressed: a hit needs the code itself, so entries never reveal
    /// one server's transcript under another.
    private nonisolated(unsafe) let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        // Cost is the UTF-16 length held by the key and the result, each of which
        // carries the code; the largest highlighted block is 80k characters.
        cache.totalCostLimit = 2_000_000
        return cache
    }()
    private var highlightrsByAppearance: [ColorScheme: Highlightr] = [:]

    /// A fresh instance with its own cache; the app uses `shared`.
    init() {}

    /// The cached highlight for a settled request, or nil when it has not been highlighted yet.
    /// Requests that can never highlight return before building a key from the code.
    nonisolated func cachedHighlight(for request: MarkdownCodeHighlightRequest) -> NSAttributedString? {
        guard !request.isStreaming,
              MarkdownHighlightPolicy.canHighlight(language: request.language) else { return nil }
        return cache.object(forKey: Self.cacheKey(for: request))
    }

    func highlightedCode(for request: MarkdownCodeHighlightRequest) -> MarkdownCodeHighlightResult {
        if let cached = cachedHighlight(for: request) {
            return .highlighted(cached)
        }

        let decision = MarkdownHighlightPolicy.decision(
            for: request.code,
            language: request.language,
            isStreaming: request.isStreaming
        )

        // A block that scrolled away while queued on this actor skips its pass.
        if case .highlight(let normalizedLanguage, _) = decision, Task.isCancelled {
            return .plain(reason: .cancelled, normalizedLanguage: normalizedLanguage)
        }

        let highlighted: NSAttributedString
        switch decision {
        case .highlight(_, .splashSwift):
            highlighted = SplashSwiftCodeHighlighter.highlightedAttributedString(
                for: request.code,
                colorScheme: request.colorScheme
            )
        case .highlight(let normalizedLanguage, .highlightr):
            guard let result = highlightr(for: request.colorScheme)?.highlight(
                request.code,
                as: normalizedLanguage,
                fastRender: true
            ) else {
                return .plain(reason: .highlighterUnavailable, normalizedLanguage: normalizedLanguage)
            }
            highlighted = result
        case .plain(let reason, let normalizedLanguage):
            return .plain(reason: reason, normalizedLanguage: normalizedLanguage)
        }

        // Freeze the result so a cached string never aliases a mutable one.
        let frozen = highlighted.copy() as? NSAttributedString ?? highlighted
        let key = Self.cacheKey(for: request)
        cache.setObject(frozen, forKey: key, cost: key.length + frozen.length)
        return .highlighted(frozen)
    }

    private func highlightr(for colorScheme: ColorScheme) -> Highlightr? {
        if let highlightr = highlightrsByAppearance[colorScheme] {
            return highlightr
        }

        guard let highlightr = Highlightr() else {
            return nil
        }

        highlightr.setTheme(to: colorScheme == .dark ? "github-dark" : "xcode")
        highlightrsByAppearance[colorScheme] = highlightr
        return highlightr
    }

    private static func cacheKey(for request: MarkdownCodeHighlightRequest) -> NSString {
        let scheme = request.colorScheme == .dark ? "dark" : "light"
        // Length-prefix the language so a `|` in it or in the code can't shift the boundary.
        let language = request.language ?? ""
        return "\(scheme)|\(language.utf16.count):\(language)|\(request.code)" as NSString
    }
}

private enum SplashSwiftCodeHighlighter {
    static func highlightedAttributedString(for code: String, colorScheme: ColorScheme) -> NSAttributedString {
        let font = Splash.Font(size: 13)
        let theme = colorScheme == .dark
            ? Splash.Theme.wwdc17(withFont: font)
            : Splash.Theme.presentation(withFont: font)
        let highlighter = SyntaxHighlighter(
            format: AttributedStringOutputFormat(theme: theme)
        )
        return highlighter.highlight(code)
    }
}

private struct PlainMarkdownFallbackView: View {
    let content: String
    let reason: MarkdownContentFallbackReason

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        Text(verbatim: content)
            .responseSelectableText(content)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .responseTextSelectionPolicy()
            .onAppear {
                logger.info(
                    "Markdown plain fallback reason=\(reason.rawValue, privacy: .public) characters=\(content.count, privacy: .public) lines=\(MarkdownHighlightPolicy.lineCount(in: content), privacy: .public)"
                )
            }
    }
}

private extension MarkdownUI.Theme {
    static func chat(colorScheme: ColorScheme, isStreaming: Bool) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(16)
            }
            .paragraph { configuration in
                configuration.label
                    .responseSelectableText(configuration.content.renderPlainText().trimmingCharacters(in: .newlines), separator: "\n\n")
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: 0, bottom: 16)
            }
            .heading1 { SelectableMarkdownHeading(configuration: $0, level: 1, colorScheme: colorScheme) }
            .heading2 { SelectableMarkdownHeading(configuration: $0, level: 2, colorScheme: colorScheme) }
            .heading3 { SelectableMarkdownHeading(configuration: $0, level: 3, colorScheme: colorScheme) }
            .heading4 { SelectableMarkdownHeading(configuration: $0, level: 4, colorScheme: colorScheme) }
            .heading5 { SelectableMarkdownHeading(configuration: $0, level: 5, colorScheme: colorScheme) }
            .heading6 { SelectableMarkdownHeading(configuration: $0, level: 6, colorScheme: colorScheme) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                BackgroundColor(
                    colorScheme == .dark
                        ? SwiftUI.Color(red: 0.08, green: 0.09, blue: 0.12)
                        : SwiftUI.Color(.tertiarySystemGroupedBackground)
                )
            }
            .codeBlock { configuration in
                MathFenceOrCodeBlock(
                    language: configuration.language,
                    content: configuration.content,
                    isStreaming: isStreaming
                )
                .markdownMargin(top: 4, bottom: 12)
            }
            .table { configuration in
                ChatMarkdownTable(
                    label: configuration.label,
                    colorScheme: colorScheme
                )
                .markdownMargin(top: 0, bottom: 16)
            }
            .tableCell { configuration in
                TableCellWidthCap(
                    minWidth: ChatMarkdownTable.cellMinWidth,
                    maxWidth: ChatMarkdownTable.cellMaxWidth
                ) {
                    configuration.label
                        .responseSelectableText(configuration.content.renderPlainText().trimmingCharacters(in: .newlines), separator: "\t", tableColumn: configuration.column)
                        .markdownTextStyle {
                            if configuration.row == 0 {
                                FontWeight(.semibold)
                            }
                            BackgroundColor(nil)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
            }
    }
}

private struct ChatMarkdownTable: View {
    static let cellMinWidth: CGFloat = 96
    static let cellMaxWidth: CGFloat = 260

    let label: MarkdownUI.BlockConfiguration.Label
    let colorScheme: ColorScheme

    var body: some View {
        ScrollView(.horizontal) {
            label
                .fixedSize(horizontal: true, vertical: true)
                .markdownTableBorderStyle(.init(color: borderColor))
                .markdownTableBackgroundStyle(
                    .alternatingRows(backgroundColor, secondaryBackgroundColor)
                )
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private var backgroundColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.094, green: 0.098, blue: 0.114)
            : SwiftUI.Color.white
    }

    private var secondaryBackgroundColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.145, green: 0.149, blue: 0.165)
            : SwiftUI.Color(red: 0.969, green: 0.969, blue: 0.976)
    }

    private var borderColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 0.259, green: 0.267, blue: 0.306)
            : SwiftUI.Color(red: 0.894, green: 0.894, blue: 0.91)
    }
}

/// Single-child layout that caps a table cell's width while reporting the
/// height the content needs *at that capped width*.
///
/// `Grid` sizes table rows from each cell's ideal size. A plain
/// `.frame(maxWidth:)` caps the ideal width but still reports the
/// single-line ideal height, so long cell text wraps at render time without
/// the row growing — rows end up overlapping (issue #233). Measuring the
/// child at the clamped width makes the reported height match what is
/// actually drawn.
struct TableCellWidthCap: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    /// Pure clamp used by `sizeThatFits`: fill the proposed (column) width
    /// when the parent offers one, otherwise fall back to the child's ideal
    /// width, always bounded to `minWidth...maxWidth`.
    static func resolvedWidth(
        idealWidth: CGFloat,
        proposedWidth: CGFloat?,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        min(max(proposedWidth ?? idealWidth, minWidth), maxWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let idealWidth = subview.sizeThatFits(.unspecified).width
        let width = Self.resolvedWidth(
            idealWidth: idealWidth,
            proposedWidth: proposal.width,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Logger {
    static let hermesMarkdownRendering = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "MarkdownRendering"
    )
}

/// Matches MarkdownUI's GitHub heading metrics, registering only the text label.
private struct SelectableMarkdownHeading: View {
    let configuration: BlockConfiguration
    let level: Int
    let colorScheme: ColorScheme

    private var fontScale: Double { [2, 1.5, 1.25, 1, 0.875, 0.85][level - 1] }
    private var tertiaryColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 109 / 255, green: 112 / 255, blue: 125 / 255)
            : SwiftUI.Color(red: 107 / 255, green: 110 / 255, blue: 123 / 255)
    }
    private var dividerColor: SwiftUI.Color {
        colorScheme == .dark
            ? SwiftUI.Color(red: 51 / 255, green: 52 / 255, blue: 56 / 255)
            : SwiftUI.Color(red: 208 / 255, green: 208 / 255, blue: 211 / 255)
    }
    var body: some View {
        if level <= 2 {
            VStack(alignment: .leading, spacing: 0) {
                label.relativePadding(.bottom, length: .em(0.3))
                Divider().overlay(dividerColor)
            }
        } else {
            label
        }
    }
    private var label: some View {
        configuration.label
            .responseSelectableText(configuration.content.renderPlainText().trimmingCharacters(in: .newlines), separator: "\n\n")
            .relativeLineSpacing(.em(0.125))
            .markdownMargin(top: 24, bottom: 16)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(fontScale))
                if level == 6 { ForegroundColor(tertiaryColor) }
            }
    }
}
