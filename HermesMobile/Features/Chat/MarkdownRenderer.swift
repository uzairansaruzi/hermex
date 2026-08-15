import Highlightr
import MarkdownUI
import OSLog
import SwiftUI
import UIKit

enum MarkdownTypographyRole {
    case standard
    case assistantResponse
    /// Reasoning text. Renders real markdown but one step quieter than an
    /// answer: caption-scale body, damped headings, secondary foreground. A
    /// thought containing an H1 must not shout louder than the answer it
    /// precedes, which is what `assistantResponse` would do.
    case reasoning

    var usesResponseFontPreference: Bool {
        self == .assistantResponse
    }

}

struct MarkdownRenderer: View {
    let content: String
    let isStreaming: Bool
    let typographyRole: MarkdownTypographyRole

    @Environment(\.colorScheme) private var colorScheme

    init(
        content: String,
        isStreaming: Bool = false,
        typographyRole: MarkdownTypographyRole = .standard
    ) {
        self.content = content
        self.isStreaming = isStreaming
        self.typographyRole = typographyRole
    }

    /// Keeps the streaming renderer mounted briefly after streaming ends so
    /// the reveal queue's in-flight glyph cascade can finish instead of
    /// snapping to the solid static rendering mid-fade.
    @State private var lingersAfterStreaming = false

    var body: some View {
        Group {
            if isStreaming || lingersAfterStreaming {
                StreamingMarkdownRenderer(
                    content: content,
                    typographyRole: typographyRole
                )
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
                                usesResponseFontPreference: typographyRole.usesResponseFontPreference,
                                role: typographyRole
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
                usesResponseFontPreference: typographyRole.usesResponseFontPreference,
                role: typographyRole
            )
            .textSelection(.enabled)
        }
    }
}

struct StreamingMarkdownRenderer: View {
    let content: String
    let typographyRole: MarkdownTypographyRole

    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedContent: String

    init(content: String, typographyRole: MarkdownTypographyRole = .standard) {
        self.content = content
        self.typographyRole = typographyRole
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
                                usesResponseFontPreference: typographyRole.usesResponseFontPreference,
                                role: typographyRole
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
                usesResponseFontPreference: typographyRole.usesResponseFontPreference,
                role: typographyRole
            )
        }
    }

}

private struct StreamingMarkdownChunkedView: View {
    let content: String
    let colorScheme: ColorScheme
    let usesResponseFontPreference: Bool
    var role: MarkdownTypographyRole = .standard

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
                    usesResponseFontPreference: usesResponseFontPreference,
                    role: role
                )
            }

            if !blockSplit.head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ChatMarkdownView(
                    content: blockSplit.head,
                    colorScheme: colorScheme,
                    isStreaming: true,
                    usesResponseFontPreference: usesResponseFontPreference,
                    role: role
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
                                chain: chain,
                                usesResponseFontPreference: usesResponseFontPreference,
                                role: role
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
    let fadeEnabled: Bool
    let armOnAppear: Bool
    let clock: TimeInterval
    let usesResponseFontPreference: Bool
    let role: MarkdownTypographyRole

    @State private var store: StreamingTextFadeStampStore<Text.Layout.CharacterIndex>

    init(
        text: String,
        colorScheme: ColorScheme,
        fadeEnabled: Bool,
        armOnAppear: Bool,
        clock: TimeInterval,
        chain: StreamingTextFadeStampChain,
        usesResponseFontPreference: Bool,
        role: MarkdownTypographyRole = .standard
    ) {
        self.text = text
        self.colorScheme = colorScheme
        self.fadeEnabled = fadeEnabled
        self.armOnAppear = armOnAppear
        self.clock = clock
        self.usesResponseFontPreference = usesResponseFontPreference
        self.role = role
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
                        usesResponseFontPreference: usesResponseFontPreference,
                        role: role
                    )
                    .textRenderer(StreamingTextFadeRenderer(clock: clock, store: store))
                } else {
                    ChatMarkdownView(
                        content: text,
                        colorScheme: colorScheme,
                        isStreaming: true,
                        usesResponseFontPreference: usesResponseFontPreference,
                        role: role
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
    let usesResponseFontPreference: Bool
    var role: MarkdownTypographyRole = .standard

    @AppStorage(ChatBackgroundStyle.storageKey) private var backgroundStyleRawValue = ChatBackgroundStyle.defaultValue.rawValue
    @AppStorage(ChatPaletteTemperature.storageKey) private var paletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @AppStorage(ResponseFontStyle.storageKey) private var responseFontStyleRawValue = ResponseFontStyle.defaultValue.rawValue
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    var body: some View {
        let palette = ChatPalette(
            colorScheme: colorScheme,
            backgroundStyle: ChatBackgroundStyle.storedValue(backgroundStyleRawValue),
            temperature: ChatPaletteTemperature.storedValue(paletteTemperatureRawValue)
        )
        let responseFontStyle = ResponseFontStyle.storedValue(responseFontStyleRawValue)

        Markdown(content)
            .markdownTheme(MarkdownUI.Theme.chat(
                isStreaming: isStreaming,
                palette: palette,
                usesSerif: usesResponseFontPreference && responseFontStyle.usesSerif,
                accentColor: HeaderLogoColor.color(for: headerLogoColorHex),
                role: role
            ))
            .markdownCodeSyntaxHighlighter(.plainText)
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
    let palette: ChatPalette

    var body: some View {
        if MathFenceLanguage.matches(language), MathLaTeX.isRenderable(content) {
            DisplayMathView(latex: content)
        } else {
            ChatCodeBlock(
                language: language,
                content: content,
                isStreaming: isStreaming,
                palette: palette
            )
        }
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let content: String
    let isStreaming: Bool
    let palette: ChatPalette

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatTranscriptDisplaySettings.wrapsCodeBlockLinesKey) private var wrapsCodeBlockLines = false
    @AppStorage(ChatPaletteTemperature.storageKey) private var codePaletteTemperatureRawValue = ChatPaletteTemperature.defaultValue.rawValue
    @State private var didCopy = false
    @State private var highlightedCode: NSAttributedString?

    private let logger = Logger.hermesMarkdownRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(displayLanguage)
                    .font(AppFont.caption2(weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(palette.textTertiary)

                Spacer()

                Button {
                    UIPasteboard.general.string = content
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "square.on.square")
                        .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
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
            }
        }
        .background(palette.codeSlab)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button {
                wrapsCodeBlockLines.toggle()
            } label: {
                Label(
                    wrapsCodeBlockLines ? "Disable Line Wrapping" : "Wrap Long Lines",
                    systemImage: wrapsCodeBlockLines ? "arrow.left.and.right" : "arrow.turn.down.left"
                )
            }
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

    @ViewBuilder
    private var codeText: some View {
        if let highlightedCode {
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
            .relativeLineSpacing(.em(0.2))
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.82))
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
            temperature: ChatPaletteTemperature.storedValue(codePaletteTemperatureRawValue),
            isStreaming: isStreaming
        )
    }

    @MainActor
    private func updateHighlightedCode(for request: MarkdownCodeHighlightRequest) async {
        highlightedCode = nil
        await Task.yield()

        guard !Task.isCancelled else { return }

        let result = MarkdownCodeHighlighter.highlightedCode(for: request)
        guard !Task.isCancelled else { return }

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
        .font(AppFont.mono(style: .footnote))
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
        "swift",
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
    var temperature: ChatPaletteTemperature = .defaultValue
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
        case .highlight(let normalizedLanguage, .highlightr):
            guard let highlighted = StableHighlightrStore.shared.highlight(
                request.code,
                language: normalizedLanguage,
                colorScheme: request.colorScheme,
                temperature: request.temperature
            ) else {
                return .plain(reason: .highlighterUnavailable, normalizedLanguage: normalizedLanguage)
            }

            return .highlighted(highlighted)
        case .plain(let reason, let normalizedLanguage):
            return .plain(reason: reason, normalizedLanguage: normalizedLanguage)
        }
    }
}

@MainActor
private final class StableHighlightrStore {
    static let shared = StableHighlightrStore()

    private struct ThemeKey: Hashable {
        let isDark: Bool
        let temperature: ChatPaletteTemperature

        /// Highlightr CSS theme for this combo. Warm combos use the Atom One
        /// pair (whose neutral grays take the warm post-process well);
        /// standard combos keep the existing github-dark / xcode mapping.
        var themeName: String {
            switch (temperature, isDark) {
            case (.warm, true): "atom-one-dark"
            case (.warm, false): "atom-one-light"
            case (.standard, true): "github-dark"
            case (.standard, false): "xcode"
            }
        }

        /// Theme applied when `themeName` fails to load, matching the store's
        /// pre-palette behavior.
        var fallbackThemeName: String {
            isDark ? "github-dark" : "xcode"
        }
    }

    private var highlightrs: [ThemeKey: Highlightr] = [:]

    private init() {}

    func highlight(
        _ code: String,
        language: String,
        colorScheme: ColorScheme,
        temperature: ChatPaletteTemperature = .defaultValue
    ) -> NSAttributedString? {
        let key = ThemeKey(isDark: colorScheme == .dark, temperature: temperature)
        guard let highlighted = highlightr(for: key)?.highlight(code, as: language, fastRender: true) else {
            return nil
        }
        let stripped = Self.strippingBackgroundAttributes(from: highlighted)
        guard temperature.usesWarmSurfaces else { return stripped }
        return Self.warmingForegroundAttributes(from: stripped, isDark: key.isDark)
    }

    /// Highlightr themes declare a canvas background of their own; if any run in
    /// the attributed output carries `.backgroundColor`, it would paint hard
    /// rectangles over our `palette.codeSlab` surface. Strip them so the slab
    /// always shows through cleanly.
    private static func strippingBackgroundAttributes(from attributed: NSAttributedString) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var hasBackground = false
        attributed.enumerateAttribute(.backgroundColor, in: fullRange) { value, _, stop in
            if value != nil {
                hasBackground = true
                stop.pointee = true
            }
        }

        guard hasBackground else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.removeAttribute(.backgroundColor, range: fullRange)
        return mutable
    }

    /// Warm-palette post-process: near-gray token colors (saturation < 0.15)
    /// are nudged toward a warm hue (~30°, orange) with a touch of saturation
    /// so the code slab reads as part of the warm surface stack instead of a
    /// cool neutral island. In warm-light, brightness is capped at 0.75 so no
    /// token glows against the ivory slab. Colors whose HSB components can't
    /// be extracted are left untouched.
    private static func warmingForegroundAttributes(
        from attributed: NSAttributedString,
        isDark: Bool
    ) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: attributed.length)
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var changed = false

        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? UIColor else { return }

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                return
            }

            var newHue = hue
            var newSaturation = saturation
            var newBrightness = brightness
            var needsUpdate = false

            if saturation < 0.15 {
                // Near-gray: shift toward orange and pick up a whisper of warmth.
                newHue = 30.0 / 360.0
                newSaturation = min(0.12, max(0.08, saturation + 0.08))
                needsUpdate = true
            }

            if !isDark, newBrightness > 0.75 {
                newBrightness = 0.75
                needsUpdate = true
            }

            guard needsUpdate else { return }

            changed = true
            mutable.addAttribute(
                .foregroundColor,
                value: UIColor(hue: newHue, saturation: newSaturation, brightness: newBrightness, alpha: alpha),
                range: range
            )
        }

        return changed ? mutable : attributed
    }

    private func highlightr(for key: ThemeKey) -> Highlightr? {
        if let highlightr = highlightrs[key] {
            return highlightr
        }

        guard let highlightr = Highlightr() else {
            return nil
        }

        if !highlightr.setTheme(to: key.themeName) {
            highlightr.setTheme(to: key.fallbackThemeName)
        }
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
            .font(.body)
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
    static func chat(
        isStreaming: Bool,
        palette: ChatPalette,
        usesSerif: Bool,
        accentColor: SwiftUI.Color,
        role: MarkdownTypographyRole = .standard
    ) -> MarkdownUI.Theme {
        // Reasoning renders the same markdown one step quieter. Headings are
        // compressed toward body size and margins tightened, because a thought
        // is a dense aside inside a card — full answer-scale headings would
        // make it out-shout the answer that follows it.
        let isReasoning = role == .reasoning
        // Reasoning damping lives entirely in this absolute base size. It is
        // deliberately NOT combined with a separate `.em` scale on `.text`:
        // heading `.em` values resolve against the already-scaled base, so
        // damping in both places compounds and drives headings below body size.
        //
        // Caption relative to the *body* size, expressed as an `.em` ratio
        // rather than an absolute point size.
        //
        // An absolute `FontSize(pt)` was tried first and is wrong twice over:
        // `UIFontMetrics.scaledValue(for: preferredFont(...).pointSize)` scales
        // an already-scaled size (43pt → 137pt at AX5, measured), and even the
        // single-scaled absolute value pins the text so MarkdownUI stops
        // wrapping headings at accessibility sizes. A ratio keeps Dynamic Type
        // in charge of the actual metrics, which is what the answer path does.
        let bodyPointSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        let captionPointSize = UIFont.preferredFont(forTextStyle: .caption1).pointSize
        let reasoningScale = captionPointSize / max(bodyPointSize, 1)
        let h1: CGFloat = isReasoning ? 1.12 : 1.45
        let h2: CGFloat = isReasoning ? 1.06 : 1.25
        let h3: CGFloat = isReasoning ? 1.0 : 1.1
        let headingTop: CGFloat = isReasoning ? 12 : 24
        let headingBottom: CGFloat = isReasoning ? 4 : 8
        // h4–h6 share the reasoning margins too; leaving them at answer scale
        // made a thought's minor headings sit further apart than its major ones.
        let minorHeadingTop: CGFloat = isReasoning ? 10 : 16
        let minorHeadingBottom: CGFloat = isReasoning ? 3 : 4
        let paragraphBottom: CGFloat = isReasoning ? 7 : 12
        let thematicBreakMargin: CGFloat = isReasoning ? 8 : 16
        let bodyColor = isReasoning ? palette.textSecondary : palette.textPrimary

        return MarkdownUI.Theme()
            .text {
                // MarkdownUI resolves `.em` against the theme's own base, not
                // the SwiftUI environment font, so an outer `.font()` cannot
                // shrink reasoning text. The base has to be stated here.
                if isReasoning {
                    FontSize(.em(reasoningScale))
                }
                if usesSerif {
                    FontFamily(.system(.serif))
                    // New York runs optically smaller than SF at the same
                    // point size; nudge the body up so both faces read equally.
                    FontSize(.em(1.02))
                }
                ForegroundColor(bodyColor)
                BackgroundColor(nil)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                FontWeight(.medium)
                ForegroundColor(palette.inlineCodeText)
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(accentColor)
            }
            .heading1 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.12))
                    .markdownMargin(top: headingTop, bottom: headingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(h1))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.12))
                    .markdownMargin(top: headingTop, bottom: headingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(h2))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.12))
                    .markdownMargin(top: headingTop, bottom: headingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(h3))
                    }
            }
            .heading4 { configuration in
                configuration.label
                    .markdownMargin(top: minorHeadingTop, bottom: minorHeadingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.0))
                    }
            }
            .heading5 { configuration in
                configuration.label
                    .markdownMargin(top: minorHeadingTop, bottom: minorHeadingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.0))
                        ForegroundColor(palette.textSecondary)
                    }
            }
            .heading6 { configuration in
                configuration.label
                    .markdownMargin(top: minorHeadingTop, bottom: minorHeadingBottom)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.0))
                        ForegroundColor(palette.textSecondary)
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.29))
                    .markdownMargin(top: 0, bottom: paragraphBottom)
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accentColor)
                        .frame(width: 3)

                    configuration.label
                        .markdownTextStyle {
                            ForegroundColor(palette.textSecondary)
                        }
                        .padding(.vertical, 2)
                        .padding(.trailing, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.quoteWash)
                        )
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 4, bottom: 12)
            }
            .codeBlock { configuration in
                MathFenceOrCodeBlock(
                    language: configuration.language,
                    content: configuration.content,
                    isStreaming: isStreaming,
                    palette: palette
                )
                .markdownMargin(top: 4, bottom: 12)
            }
            .table { configuration in
                ChatMarkdownTable(
                    label: configuration.label,
                    palette: palette
                )
                .markdownMargin(top: 0, bottom: 16)
            }
            .tableCell { configuration in
                TableCellWidthCap(
                    minWidth: ChatMarkdownTable.cellMinWidth,
                    maxWidth: ChatMarkdownTable.cellMaxWidth
                ) {
                    configuration.label
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
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.25))
            }
            .thematicBreak {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, palette.tableRule, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .markdownMargin(top: thematicBreakMargin, bottom: thematicBreakMargin)
            }
    }
}

private struct ChatMarkdownTable: View {
    static let cellMinWidth: CGFloat = 96
    static let cellMaxWidth: CGFloat = 260

    let label: MarkdownUI.BlockConfiguration.Label
    let palette: ChatPalette

    var body: some View {
        ScrollView(.horizontal) {
            label
                .fixedSize(horizontal: true, vertical: true)
                .markdownTableBorderStyle(.init(.insideHorizontalBorders, color: palette.tableRule))
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
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
