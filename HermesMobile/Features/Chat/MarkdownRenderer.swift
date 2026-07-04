import Highlightr
import MarkdownUI
import OSLog
import Splash
import SwiftUI
import UIKit

struct MarkdownRenderer: View {
    let content: String
    let isStreaming: Bool
    let onOpenWikiRoute: ((WikiRoute) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        content: String,
        isStreaming: Bool = false,
        onOpenWikiRoute: ((WikiRoute) -> Void)? = nil
    ) {
        self.content = content
        self.isStreaming = isStreaming
        self.onOpenWikiRoute = onOpenWikiRoute
    }

    /// Keeps the streaming renderer mounted briefly after streaming ends so
    /// the reveal queue's in-flight glyph cascade can finish instead of
    /// snapping to the solid static rendering mid-fade.
    @State private var lingersAfterStreaming = false

    var body: some View {
        Group {
            if isStreaming || lingersAfterStreaming {
                StreamingMarkdownRenderer(content: content, onOpenWikiRoute: onOpenWikiRoute)
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
        let segments = MarkdownMathSegmenter.segments(in: content)

        if segments.containsMath {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ChatMarkdownView(
                                content: markdown,
                                colorScheme: colorScheme,
                                isStreaming: isStreaming,
                                onOpenWikiRoute: onOpenWikiRoute
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            ChatMarkdownView(
                content: MarkdownMathFormatter.replacingInlineMath(in: content),
                colorScheme: colorScheme,
                isStreaming: isStreaming,
                onOpenWikiRoute: onOpenWikiRoute
            )
            .textSelection(.enabled)
        }
    }
}

struct StreamingMarkdownRenderer: View {
    let content: String
    let onOpenWikiRoute: ((WikiRoute) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedContent: String

    init(content: String, onOpenWikiRoute: ((WikiRoute) -> Void)? = nil) {
        self.content = content
        self.onOpenWikiRoute = onOpenWikiRoute
        _displayedContent = State(initialValue: content)
    }

    var body: some View {
        Group {
            if displayedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: " ")
            } else if let fallbackReason = MarkdownContentRenderingPolicy.fallbackReason(for: displayedContent) {
                PlainMarkdownFallbackView(
                    content: displayedContent,
                    reason: fallbackReason
                )
            } else {
                streamingMarkdownContent
            }
        }
        .task(id: content) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard displayedContent != content else { return }
            displayedContent = content
        }
    }

    @ViewBuilder
    private var streamingMarkdownContent: some View {
        let segments = MarkdownMathSegmenter.segments(in: displayedContent)

        if segments.containsMath {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            StreamingMarkdownChunkedView(
                                content: markdown,
                                colorScheme: colorScheme,
                                onOpenWikiRoute: onOpenWikiRoute
                            )
                        }
                    case .displayMath(let latex):
                        DisplayMathView(latex: latex)
                    }
                }
            }
        } else {
            StreamingMarkdownChunkedView(
                content: MarkdownMathFormatter.replacingInlineMath(in: displayedContent),
                colorScheme: colorScheme,
                onOpenWikiRoute: onOpenWikiRoute
            )
        }
    }

}

private struct StreamingMarkdownChunkedView: View {
    let content: String
    let colorScheme: ColorScheme
    let onOpenWikiRoute: ((WikiRoute) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var segments: StreamingMarkdownBlockSegments {
        StreamingMarkdownBlockSplitter.split(content)
    }

    var body: some View {
        let blockSplit = StreamingTextFadeTailSplitter.split(
            segments.activeMarkdown,
            firstFadeOrdinal: StreamedTextAnimationSettings.effectiveFirstFadeOrdinal(
                firstFadeOrdinal,
                reduceMotion: reduceMotion,
                isEnabled: isStreamedTextAnimationEnabled
            )
        )

        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments.stableChunks) { chunk in
                ChatMarkdownView(
                    content: chunk.text,
                    colorScheme: colorScheme,
                    isStreaming: false,
                    onOpenWikiRoute: onOpenWikiRoute
                )
            }

            if !blockSplit.head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatMarkdownView(
                    content: blockSplit.head,
                    colorScheme: colorScheme,
                    isStreaming: true,
                    onOpenWikiRoute: onOpenWikiRoute
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
                                onOpenWikiRoute: onOpenWikiRoute,
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
            anchorFadeWindowAtCurrentBlock()
        }
        .onChange(of: content) { oldContent, newContent in
            advanceFadeWindow(from: oldContent, to: newContent)
        }
        .onChange(of: isStreamedTextAnimationEnabled) { _, isEnabled in
            if isEnabled {
                anchorFadeWindowAtCurrentBlock()
            }
        }
        .onChange(of: reduceMotion) { _, reduceMotion in
            if !reduceMotion {
                anchorFadeWindowAtCurrentBlock()
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
    private func anchorFadeWindowAtCurrentBlock() {
        let split = StreamingTextFadeTailSplitter.split(segments.activeMarkdown, firstFadeOrdinal: 0)
        firstFadeOrdinal = split.boundaryCount
        mountBoundaryCount = split.boundaryCount
        lastBoundaryCount = split.boundaryCount
        lastTouchedAt = [:]
    }

    private func advanceFadeWindow(from oldContent: String, to newContent: String) {
        let now = Date().timeIntervalSinceReferenceDate
        let oldActive = StreamingMarkdownBlockSplitter.split(oldContent).activeMarkdown
        let newActive = StreamingMarkdownBlockSplitter.split(newContent).activeMarkdown
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
    let onOpenWikiRoute: ((WikiRoute) -> Void)?
    let fadeEnabled: Bool
    let armOnAppear: Bool
    let clock: TimeInterval

    @State private var store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    init(
        text: String,
        colorScheme: ColorScheme,
        onOpenWikiRoute: ((WikiRoute) -> Void)? = nil,
        fadeEnabled: Bool,
        armOnAppear: Bool,
        clock: TimeInterval,
        chain: StreamingTextFadeStampChain
    ) {
        self.text = text
        self.colorScheme = colorScheme
        self.onOpenWikiRoute = onOpenWikiRoute
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
                        isStreaming: true,
                        onOpenWikiRoute: onOpenWikiRoute
                    )
                    .textRenderer(StreamingTextFadeRenderer(clock: clock, store: store))
                } else {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true,
                        onOpenWikiRoute: onOpenWikiRoute
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
    let onOpenWikiRoute: ((WikiRoute) -> Void)?

    private var displayContent: String {
        WikiWikilinkPreprocessor.replacingWikilinks(in: content)
    }

    var body: some View {
        Markdown(displayContent)
            .markdownTheme(MarkdownUI.Theme.chat(colorScheme: colorScheme, isStreaming: isStreaming))
            .markdownTextStyle {
                ForegroundColor(.primary)
                BackgroundColor(nil)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(ZoraBrand.foreground)
                BackgroundColor(ZoraBrand.inlineCodeFill)
            }
            .markdownCodeSyntaxHighlighter(.plainText)
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(AppFont.voiceRelativeLineSpacing))
                    .padding(.bottom, ChatTranscriptSpacing.markdownBlock)
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(ZoraBrand.coral.opacity(0.55))
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    configuration.label
                        .relativeLineSpacing(.em(0.16))
                        .markdownTextStyle {
                            ForegroundColor(ZoraBrand.secondaryForeground)
                            FontStyle(.italic)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, ChatTranscriptSpacing.turnBlock)
                .padding(.bottom, ChatTranscriptSpacing.markdownBlock)
            }
            .environment(\.openURL, OpenURLAction { url in
                guard let route = WikiLinkResolver.resolve(url) else {
                    return .systemAction
                }
                onOpenWikiRoute?(route)
                return .handled
            })
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
    private let wrapsCodeBlockLines = false
    @State private var didCopy = false
    @State private var highlightedCode: NSAttributedString?
    @State private var highlightedRequest: MarkdownCodeHighlightRequest?

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(AppFont.subheadline(weight: .semibold))

                Spacer()

                Button {
                    UIPasteboard.general.string = content
                    didCopy = true
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "square.on.square")
                        .font(AppFont.title3(weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SwiftUI.Color.primary)
                .accessibilityLabel(didCopy ? "Copied code" : "Copy code")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if wrapsCodeBlockLines {
                styledCodeText(fixedHorizontal: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    styledCodeText(fixedHorizontal: true)
                }
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [codeBlockBackground.opacity(0), codeBlockBackground],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 44)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(ZoraBrand.codeBlockStroke, lineWidth: 1)
        }
        .onChange(of: content) { _, _ in
            didCopy = false
        }
        .task(id: highlightRequest) {
            await updateHighlightedCode(for: highlightRequest)
        }
        // Code (and diff) blocks must never mirror inside an RTL message (#259):
        // the language header, copy/wrap controls, and the source itself stay LTR.
        .forcedLeftToRight()
    }

    private var codeBlockBackground: SwiftUI.Color {
        ZoraBrand.codeBlockFill
    }

    @ViewBuilder
    private var codeText: some View {
        if let highlightedCode, highlightedRequest == highlightRequest {
            HighlightedCodeBlockText(content: highlightedCode, wraps: wrapsCodeBlockLines)
        } else {
            PlainCodeBlockText(content: content, wraps: wrapsCodeBlockLines)
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

    @MainActor
    private func updateHighlightedCode(for request: MarkdownCodeHighlightRequest) async {
        if highlightedRequest == request, highlightedCode != nil {
            return
        }

        guard !Task.isCancelled else { return }

        let result = MarkdownCodeHighlighter.highlightedCode(for: request)
        guard !Task.isCancelled else { return }

        switch result {
        case .highlighted(let attributedString):
            highlightedRequest = request
            highlightedCode = attributedString
        case .plain(let reason, let normalizedLanguage):
            highlightedRequest = nil
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
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(verbatim: segment.text)
                        }
                    }
                }
            }
        }
        .font(AppFont.mono(style: .caption))
        .foregroundStyle(ZoraBrand.paper.opacity(0.88))
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
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(line.segments) { segment in
                            Text(AttributedString(segment.attributedText))
                        }
                    }
                }
            }
        }
        .font(AppFont.mono(style: .caption))
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
        let normalizedCode = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")

        let rawLines = normalizedCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let renderedLines = rawLines.isEmpty ? [""] : rawLines

        return renderedLines.enumerated().map { lineIndex, line in
            MarkdownPlainCodeLine(
                id: lineIndex,
                segments: segments(in: line)
            )
        }
    }

    private static func segments(in line: String) -> [MarkdownPlainCodeSegment] {
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
    private static let highlightrLanguages: Set<String> = [
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

enum MarkdownCodeHighlighter {
    @MainActor
    static func highlightedCode(for request: MarkdownCodeHighlightRequest) -> MarkdownCodeHighlightResult {
        let decision = MarkdownHighlightPolicy.decision(
            for: request.code,
            language: request.language,
            isStreaming: request.isStreaming
        )

        switch decision {
        case .highlight(_, .splashSwift):
            let highlighted = SplashSwiftCodeHighlighter.highlightedAttributedString(
                for: request.code,
                colorScheme: request.colorScheme
            )
            return .highlighted(MarkdownCodePalette.normalized(highlighted))
        case .highlight(let normalizedLanguage, .highlightr):
            guard let highlighted = StableHighlightrStore.shared.highlight(
                request.code,
                language: normalizedLanguage,
                colorScheme: request.colorScheme
            ) else {
                return .plain(reason: .highlighterUnavailable, normalizedLanguage: normalizedLanguage)
            }

            return .highlighted(MarkdownCodePalette.normalized(highlighted))
        case .plain(let reason, let normalizedLanguage):
            return .plain(reason: reason, normalizedLanguage: normalizedLanguage)
        }
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

private enum MarkdownCodePalette {
    static func normalized(_ attributedString: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: output.length)

        output.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            let opacity = opacity(from: value as? UIColor)
            output.addAttribute(.foregroundColor, value: creamColor(opacity: opacity), range: range)
        }
        output.removeAttribute(.backgroundColor, range: fullRange)
        output.removeAttribute(.font, range: fullRange)

        return output
    }

    private static func opacity(from color: UIColor?) -> CGFloat {
        guard let color else { return 0.88 }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return 0.88
        }

        // Preserve a hint of token hierarchy from the original syntax theme, but
        // collapse all hue into the cream/ink palette requested by the style guide.
        let luma = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return min(0.96, max(0.58, (0.58 + (luma * 0.32)) * alpha))
    }

    private static func creamColor(opacity: CGFloat) -> UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    red: 254.0 / 255.0,
                    green: 240.0 / 255.0,
                    blue: 219.0 / 255.0,
                    alpha: opacity
                )
            }

            return UIColor(
                red: 34.0 / 255.0,
                green: 25.0 / 255.0,
                blue: 20.0 / 255.0,
                alpha: opacity
            )
        }
    }
}

@MainActor
private final class StableHighlightrStore {
    static let shared = StableHighlightrStore()

    private enum ThemeKey: Hashable {
        case light
        case dark
    }

    private var highlightrs: [ThemeKey: Highlightr] = [:]

    private init() {}

    func highlight(_ code: String, language: String, colorScheme: ColorScheme) -> NSAttributedString? {
        return highlightr(for: colorScheme)?.highlight(code, as: language, fastRender: true)
    }

    private func highlightr(for colorScheme: ColorScheme) -> Highlightr? {
        let key: ThemeKey = colorScheme == .dark ? .dark : .light
        if let highlightr = highlightrs[key] {
            return highlightr
        }

        guard let highlightr = Highlightr() else {
            return nil
        }

        highlightr.setTheme(to: key == .dark ? "github-dark" : "xcode")
        highlightrs[key] = highlightr
        return highlightr
    }
}

private struct PlainMarkdownFallbackView: View {
    let content: String
    let reason: MarkdownContentFallbackReason

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        Text(verbatim: content)
            .font(AppFont.voice())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
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
                FontFamily(.system(.serif))
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(ZoraBrand.paper.opacity(0.85))
                UnderlineStyle(.single)
            }
            .code {
                FontFamily(.system(.default))
                FontFamilyVariant(.monospaced)
                FontStyle(.normal)
                FontSize(.em(0.88))
                ForegroundColor(ZoraBrand.foreground)
                BackgroundColor(ZoraBrand.inlineCodeFill)
            }
            .heading1 { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    configuration.label
                        .relativePadding(.bottom, length: .em(0.3))
                        .relativeLineSpacing(.em(0.125))
                        .markdownTextStyle {
                            FontFamily(.system(.default))
                            FontStyle(.normal)
                            FontWeight(.semibold)
                            FontSize(.em(2))
                        }
                    Divider().overlay(ZoraBrand.codeBlockStroke)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .heading2 { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    configuration.label
                        .relativePadding(.bottom, length: .em(0.3))
                        .relativeLineSpacing(.em(0.125))
                        .markdownTextStyle {
                            FontFamily(.system(.default))
                            FontStyle(.normal)
                            FontWeight(.semibold)
                            FontSize(.em(1.5))
                        }
                    Divider().overlay(ZoraBrand.codeBlockStroke)
                }
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .heading3 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .markdownTextStyle {
                        FontFamily(.system(.default))
                        FontStyle(.normal)
                        FontWeight(.semibold)
                        FontSize(.em(1.25))
                    }
            }
            .heading4 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .markdownTextStyle {
                        FontFamily(.system(.default))
                        FontStyle(.normal)
                        FontWeight(.semibold)
                    }
            }
            .heading5 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .markdownTextStyle {
                        FontFamily(.system(.default))
                        FontStyle(.normal)
                        FontWeight(.semibold)
                        FontSize(.em(0.875))
                    }
            }
            .heading6 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .markdownTextStyle {
                        FontFamily(.system(.default))
                        FontStyle(.normal)
                        FontWeight(.semibold)
                        FontSize(.em(0.85))
                        ForegroundColor(SwiftUI.Color.secondary)
                    }
            }
            .codeBlock { configuration in
                MathFenceOrCodeBlock(
                    language: configuration.language,
                    content: configuration.content,
                    isStreaming: isStreaming
                )
                .padding(.top, ChatTranscriptSpacing.turnBlock)
                .padding(.bottom, ChatTranscriptSpacing.markdownRichBlock)
            }
            .table { configuration in
                ChatMarkdownTable(
                    label: configuration.label,
                    colorScheme: colorScheme
                )
                .padding(.bottom, ChatTranscriptSpacing.markdownRichBlock)
            }
            .listItem { configuration in
                configuration.label
                    .padding(.top, 4)
            }
            .thematicBreak {
                Divider()
                    .relativeFrame(height: .em(0.25))
                    .overlay(ZoraBrand.codeBlockStroke)
                    .padding(.vertical, ChatTranscriptSpacing.markdownRichBlock)
            }
            .tableCell { configuration in
                TableCellWidthCap(
                    minWidth: ChatMarkdownTable.cellMinWidth,
                    maxWidth: ChatMarkdownTable.cellMaxWidth
                ) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamily(.system(.default))
                            FontStyle(.normal)
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
                .background(configuration.row == 0 ? ZoraBrand.cardFillStrong : Color.clear)
            }
    }
}

private struct ChatMarkdownTable: View {
    static let cellMinWidth: CGFloat = 96
    static let cellMaxWidth: CGFloat = 260

    let label: MarkdownUI.BlockConfiguration.Label
    let colorScheme: ColorScheme

    private let cornerRadius: CGFloat = 18

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tableContent
                .tableContainerChrome(cornerRadius: cornerRadius)

            ScrollView(.horizontal) {
                tableContent
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .tableContainerChrome(cornerRadius: cornerRadius)
        }
    }

    private var tableContent: some View {
        label
            .fixedSize(horizontal: true, vertical: true)
            .markdownTableBorderStyle(.init(color: ZoraBrand.surfaceHairline))
            .markdownTableBackgroundStyle(
                .alternatingRows(ZoraBrand.codeBlockFill, ZoraBrand.subtleFill)
            )
    }
}

private extension View {
    func tableContainerChrome(cornerRadius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ZoraBrand.codeBlockStroke, lineWidth: 0.5)
            )
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
