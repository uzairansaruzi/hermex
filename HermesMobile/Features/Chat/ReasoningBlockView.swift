import SwiftUI

struct ReasoningBlockView: View {
    let text: String
    let liveStreamID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        if let trimmedText {
            let summary = summary(for: trimmedText)

            VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
                Button {
                    withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
                        userToggledExpansion = !isExpanded
                    }
                } label: {
                    header(summary: summary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Thinking, \(summary)"))
                .accessibilityHint(isExpanded ? "Double tap to collapse details." : "Double tap to expand details.")

                if isExpanded {
                    reasoningText
                        .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .chatTimelineAccessorySurface(
                fallbackMaterial: .thinMaterial,
                cornerRadius: 10
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usesStackedHeader: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private func header(summary: String) -> some View {
        HStack(alignment: usesStackedHeader ? .top : .center, spacing: 8) {
            Image("LucideBrain")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            if usesStackedHeader {
                VStack(alignment: .leading, spacing: 1) {
                    titleText
                    summaryText(summary, lineLimit: 2)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    summaryText(summary, lineLimit: 1)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var titleText: some View {
        Text("Thinking")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var reasoningText: some View {
        if let liveStreamID {
            LiveReasoningTextView(text: text)
                .id(liveStreamID)
        } else {
            Text(text)
                .font(AppFont.caption())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryText(_ value: String, lineLimit: Int) -> some View {
        Text(value)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
    }

    private var trimmedText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func summary(for value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if oneLine.count <= 80 {
            return oneLine
        }

        return "\(oneLine.prefix(80))..."
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

    /// Prefer a nearby blank line so separate Text views keep paragraph layout.
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

private struct LiveReasoningTextView: View {
    let text: String

    @State private var state: StreamingReasoningTextState

    init(text: String) {
        self.text = text
        _state = State(initialValue: StreamingReasoningTextState(text: text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.stableChunks) { chunk in
                ReasoningTextFragment(text: chunk.text)
                    .equatable()
            }

            if !state.activeTail.isEmpty {
                ReasoningTextFragment(text: state.activeTail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { _, newText in
            state.update(with: newText)
        }
    }
}

private struct ReasoningTextFragment: View, Equatable {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.caption())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
