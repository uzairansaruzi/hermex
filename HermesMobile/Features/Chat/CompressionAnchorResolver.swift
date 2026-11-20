import Foundation

struct CompressionAnchorMetadata: Equatable {
    let visibleIdx: Int?
    let messageKey: CompressionAnchorMessageKey?
    let summary: String?

    init?(from session: SessionDetail?) {
        guard let session else { return nil }
        guard session.compressionAnchorVisibleIdx != nil
            || session.compressionAnchorMessageKey != nil
            || session.compressionAnchorSummary != nil
        else {
            return nil
        }

        visibleIdx = session.compressionAnchorVisibleIdx
        messageKey = session.compressionAnchorMessageKey
        summary = session.compressionAnchorSummary
    }

    init(visibleIdx: Int?, messageKey: CompressionAnchorMessageKey?, summary: String?) {
        self.visibleIdx = visibleIdx
        self.messageKey = messageKey
        self.summary = summary
    }
}

enum CompressionAnchorResolver {
    struct Resolution: Equatable {
        enum Placement: Equatable {
            case afterLoadedMessageIndex(Int)
            case top
        }

        let referenceText: String
        let placement: Placement
    }

    static func resolve(
        messages: [ChatMessage],
        messagesOffset: Int,
        metadata: CompressionAnchorMetadata?
    ) -> Resolution? {
        guard let metadata else { return nil }

        let summary = (metadata.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadata.visibleIdx != nil || metadata.messageKey != nil || !summary.isEmpty else {
            return nil
        }

        let referenceText = referenceText(in: messages, summary: summary)
        guard shouldShowReference(referenceText) else { return nil }

        let candidateIndices = anchorCandidateIndices(in: messages)

        if let anchorKey = metadata.messageKey,
           let matchedIndex = latestMatch(of: anchorKey, in: messages, candidateIndices: candidateIndices) {
            return Resolution(referenceText: referenceText, placement: .afterLoadedMessageIndex(matchedIndex))
        }

        if let visibleIdx = metadata.visibleIdx, !candidateIndices.isEmpty {
            let localIdx = visibleIdx - max(0, messagesOffset)
            guard localIdx >= 0 else {
                return Resolution(referenceText: referenceText, placement: .top)
            }

            let clampedIdx = min(localIdx, candidateIndices.count - 1)
            return Resolution(
                referenceText: referenceText,
                placement: .afterLoadedMessageIndex(candidateIndices[clampedIdx])
            )
        }

        return Resolution(referenceText: referenceText, placement: .top)
    }

    private static func referenceText(in messages: [ChatMessage], summary: String) -> String {
        let normalizedSummary = normalizedWhitespace(summary)

        for message in messages.reversed() {
            guard ChatMarkerMessageClassifier.classify(message) == .contextCompaction else { continue }

            let content = message.content ?? ""
            if normalizedSummary.isEmpty || normalizedWhitespace(content).contains(normalizedSummary) {
                return content
            }
        }

        return summary
    }

    private static func shouldShowReference(_ referenceText: String) -> Bool {
        let trimmed = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return !ChatMarkerMessageClassifier.isContextCompactionText(trimmed)
    }

    private struct CandidateKey {
        let role: String
        let ts: Double?
        let text: String
        let attachments: Int
    }

    private static func anchorCandidateIndices(in messages: [ChatMessage]) -> [Int] {
        messages.indices.filter { index in
            let message = messages[index]
            guard let role = message.role, !role.isEmpty, role != "tool" else { return false }
            guard ChatMarkerMessageClassifier.classify(message) == nil else { return false }

            let hasText = message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasAttachments = message.attachments?.isEmpty == false
            if hasText || hasAttachments {
                return true
            }

            guard role == "assistant" else { return false }
            return message.toolCalls?.isEmpty == false
                || message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private static func candidateKey(for message: ChatMessage) -> CandidateKey? {
        guard let role = message.role, !role.isEmpty, role != "tool" else { return nil }

        let normalizedText = normalizedAnchorText(message.content ?? "")
        let attachments = message.attachments?.count ?? 0
        let ts = message.timestamp
        if normalizedText.isEmpty, attachments == 0, ts == nil {
            return nil
        }

        return CandidateKey(role: role, ts: ts, text: normalizedText, attachments: attachments)
    }

    private static func latestMatch(
        of anchorKey: CompressionAnchorMessageKey,
        in messages: [ChatMessage],
        candidateIndices: [Int]
    ) -> Int? {
        for index in candidateIndices.reversed() {
            guard let candidate = candidateKey(for: messages[index]) else { continue }

            guard candidate.role == (anchorKey.role ?? "") else { continue }
            if let anchorTs = anchorKey.ts, let candidateTs = candidate.ts, anchorTs != candidateTs {
                continue
            }
            guard candidate.text == (anchorKey.text ?? "") else { continue }
            guard candidate.attachments == (anchorKey.attachments ?? 0) else { continue }

            return index
        }

        return nil
    }

    static func normalizedAnchorText(_ text: String) -> String {
        String(normalizedWhitespace(text).prefix(160))
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
