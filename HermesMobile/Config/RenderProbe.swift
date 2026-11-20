@MainActor
enum RenderProbe {
    enum Name: String {
        case transcriptMessageBlock = "ChatTranscriptMessageBlock"
        case transcriptMessageBlockUnequal = "ChatTranscriptMessageBlock.unequal"
        case transcriptMessageBlockCompared = "ChatTranscriptMessageBlock.compared"
        case messageBubble = "MessageBubbleView"
        case markdownRenderer = "MarkdownRenderer"
        case toolActivityGroup = "ToolActivityGroupView"
        case reasoningBlock = "ReasoningBlockView"
        case responseSelectionUpdate = "ResponseTextSelection.update"
    }

    #if DEBUG
    private static var counts: [Name: Int] = [:]
    private static var renderIDCounts: [String: Int] = [:]

    static func hit(_ name: Name, renderID: String? = nil) {
        counts[name, default: 0] += 1
        if let renderID {
            renderIDCounts[renderID, default: 0] += 1
        }
    }

    static func reset() {
        counts = [:]
        renderIDCounts = [:]
    }

    static func count(_ name: Name) -> Int {
        counts[name] ?? 0
    }

    static func count(renderID: String) -> Int {
        renderIDCounts[renderID] ?? 0
    }

    static var snapshot: [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }
    #else
    @inline(__always)
    static func hit(_ name: Name, renderID: String? = nil) {}
    #endif
}
