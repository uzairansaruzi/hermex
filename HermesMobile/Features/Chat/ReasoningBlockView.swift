import SwiftUI
import UIKit

/// A turn's reasoning as the same dense log row tool calls use: brain icon,
/// bold `Thinking`, dim one-line summary, chevron, and an empty status slot so
/// the labels line up. Tap reveals the reasoning under the row; long-press
/// copies it. Live thinking streams through `LiveReasoningTextView`; settled
/// text is selectable. "Expand Thinking by Default" decides the initial state.
struct ReasoningBlockView: View {
    let text: String
    let liveStreamID: String?

    @AppStorage(ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    init(text: String, liveStreamID: String? = nil) {
        self.text = text
        self.liveStreamID = liveStreamID
    }

    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    var body: some View {
        if let displayText = ReasoningBlockContent.displayText(from: text) {
            let summary = ReasoningSummaryFormatter.summary(for: displayText)

            TranscriptLogRowView(
                summary: String(localized: "Thinking"),
                detail: summary,
                isExpanded: isExpanded,
                accessibilityLabel: String(localized: "Thinking, \(summary)"),
                copyText: { displayText },
                toggleExpansion: { userToggledExpansion = !isExpanded }
            ) {
                Image("LucideBrain")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            } status: {
                EmptyView()
            } expandedBody: {
                reasoningText(displayText)
            }
        }
    }

    @ViewBuilder
    private func reasoningText(_ displayText: String) -> some View {
        if let liveStreamID {
            LiveReasoningTextView(text: displayText)
                .id(liveStreamID)
        } else {
            Text(displayText)
                .font(AppFont.caption())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum ReasoningBlockContent {
    static func displayText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct StreamingReasoningChunk: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct StreamingReasoningTextState: Equatable {
    static let targetChunkCharacterCount = 1_000
    static let maximumActiveTailCharacterCount = 1_500

    private(set) var stableChunks: [StreamingReasoningChunk] = []
    private(set) var activeTail = ""
    private(set) var sourceText = ""
    private var nextChunkID = 0

    init(text: String = "") {
        reset(with: text)
    }

    var reconstructedText: String {
        stableChunks.map(\.text).joined() + activeTail
    }

    mutating func update(with text: String) {
        guard text != sourceText else { return }

        guard text.utf8.starts(with: sourceText.utf8) else {
            reset(with: text)
            return
        }

        let appendedBytes = text.utf8.dropFirst(sourceText.utf8.count)
        activeTail.append(String(decoding: appendedBytes, as: UTF8.self))
        sourceText = text
        sealStableChunks()
    }

    mutating func reset(with text: String) {
        stableChunks = []
        activeTail = text
        sourceText = text
        nextChunkID = 0
        sealStableChunks()
    }

    private mutating func sealStableChunks() {
        while activeTail.count > Self.maximumActiveTailCharacterCount {
            let boundary = stableChunkBoundary(in: activeTail)
            let chunkText = String(activeTail[..<boundary])
            stableChunks.append(
                StreamingReasoningChunk(id: nextChunkID, text: chunkText)
            )
            nextChunkID += 1
            activeTail.removeSubrange(..<boundary)
        }
    }

    /// Prefer a nearby blank line so stable chunk identity follows content structure.
    /// The character-count fallback also bounds a paragraph with no line breaks.
    private func stableChunkBoundary(in text: String) -> String.Index {
        let target = text.index(
            text.startIndex,
            offsetBy: Self.targetChunkCharacterCount,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let searchStart = text.index(
            text.startIndex,
            offsetBy: Self.targetChunkCharacterCount / 2,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let searchEnd = text.index(
            text.startIndex,
            offsetBy: Self.maximumActiveTailCharacterCount,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        var candidates: [String.Index] = []
        var searchCursor = searchStart
        while searchCursor < searchEnd,
              let range = text.range(
                  of: "\n\n",
                  range: searchCursor..<searchEnd
              ) {
            candidates.append(range.upperBound)
            searchCursor = range.upperBound
        }

        return candidates.min { lhs, rhs in
            abs(text.distance(from: target, to: lhs))
                < abs(text.distance(from: target, to: rhs))
        } ?? target
    }
}

enum StreamingReasoningTextStorageUpdate: Equatable {
    case unchanged
    case append(String)
    case replace(String)

    static func make(renderedText: String, newText: String) -> Self {
        guard renderedText != newText else { return .unchanged }
        guard newText.utf8.starts(with: renderedText.utf8) else {
            return .replace(newText)
        }

        let appendedBytes = newText.utf8.dropFirst(renderedText.utf8.count)
        return .append(String(decoding: appendedBytes, as: UTF8.self))
    }
}

private struct LiveReasoningTextView: View {
    let text: String

    @State private var state: StreamingReasoningTextState

    init(text: String) {
        self.text = text
        _state = State(initialValue: StreamingReasoningTextState(text: text))
    }

    var body: some View {
        StreamingReasoningTextView(state: state)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .onChange(of: text) { _, newText in
            state.update(with: newText)
        }
    }
}

private struct StreamingReasoningTextView: UIViewRepresentable {
    let state: StreamingReasoningTextState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = TailPinnedTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.isAccessibilityElement = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let textColor = UIColor.label
        let layoutDirection = context.environment.layoutDirection

        context.coordinator.update(
            textView,
            to: state,
            font: font,
            textColor: textColor
        )
        textView.textAlignment = layoutDirection == .rightToLeft ? .right : .left
        textView.accessibilityLabel = state.sourceText
    }

    /// Reports at most the row body cap. Past it the text view scrolls itself
    /// and `TailPinnedTextView` keeps the newest chunk in view, so the SwiftUI
    /// window around it never needs to scroll for live thinking.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let layout = TranscriptLogRowBodyWindowLayout.resolve(
            contentHeight: ceil(size.height),
            cap: TranscriptLogRowMetrics.bodyWindowHeight
        )
        if uiView.isScrollEnabled != layout.scrolls {
            uiView.isScrollEnabled = layout.scrolls
        }
        return CGSize(width: width, height: layout.frameHeight)
    }

    /// A text view that stays scrolled to its last line whenever it scrolls,
    /// so streaming thinking shows the newest text. It is never interactive
    /// while live, so there is no user offset to respect.
    final class TailPinnedTextView: UITextView {
        override func layoutSubviews() {
            super.layoutSubviews()
            guard isScrollEnabled else { return }

            let tailOffset = max(0, contentSize.height + adjustedContentInset.bottom - bounds.height)
            if abs(contentOffset.y - tailOffset) > 0.5 {
                contentOffset = CGPoint(x: contentOffset.x, y: tailOffset)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private static let chunkIDAttribute = NSAttributedString.Key(
            "HermexStreamingReasoningChunkID"
        )

        private var renderedText = ""
        private var stableChunkIDs: [Int] = []
        private var stableUTF16Length = 0
        private var font: UIFont?
        private var textColor: UIColor?

        func update(
            _ textView: UITextView,
            to state: StreamingReasoningTextState,
            font: UIFont,
            textColor: UIColor
        ) {
            let storageUpdate = StreamingReasoningTextStorageUpdate.make(
                renderedText: renderedText,
                newText: state.sourceText
            )

            switch storageUpdate {
            case .unchanged:
                break
            case .append(let suffix):
                textView.textStorage.append(
                    NSAttributedString(
                        string: suffix,
                        attributes: [.font: font, .foregroundColor: textColor]
                    )
                )
            case .replace(let replacement):
                textView.attributedText = NSAttributedString(
                    string: replacement,
                    attributes: [.font: font, .foregroundColor: textColor]
                )
                stableChunkIDs = []
                stableUTF16Length = 0
            }

            renderedText = state.sourceText
            markNewStableChunks(in: textView.textStorage, from: state)
            updateAppearance(
                in: textView,
                font: font,
                textColor: textColor
            )

            if storageUpdate != .unchanged {
                textView.invalidateIntrinsicContentSize()
            }
        }

        private func markNewStableChunks(
            in textStorage: NSTextStorage,
            from state: StreamingReasoningTextState
        ) {
            let retainedIDs = state.stableChunks.prefix(stableChunkIDs.count).map(\.id)
            guard Array(retainedIDs) == stableChunkIDs else {
                stableChunkIDs = []
                stableUTF16Length = 0
                textStorage.removeAttribute(
                    Self.chunkIDAttribute,
                    range: NSRange(location: 0, length: textStorage.length)
                )
                markNewStableChunks(in: textStorage, from: state)
                return
            }

            for chunk in state.stableChunks.dropFirst(stableChunkIDs.count) {
                let length = chunk.text.utf16.count
                textStorage.addAttribute(
                    Self.chunkIDAttribute,
                    value: chunk.id,
                    range: NSRange(location: stableUTF16Length, length: length)
                )
                stableChunkIDs.append(chunk.id)
                stableUTF16Length += length
            }
        }

        private func updateAppearance(
            in textView: UITextView,
            font: UIFont,
            textColor: UIColor
        ) {
            guard self.font != font || self.textColor != textColor else { return }

            self.font = font
            self.textColor = textColor
            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            textView.textStorage.addAttributes(
                [.font: font, .foregroundColor: textColor],
                range: fullRange
            )
            textView.typingAttributes[.font] = font
            textView.typingAttributes[.foregroundColor] = textColor
        }
    }
}
