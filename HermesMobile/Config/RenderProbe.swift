/// Counts SwiftUI body evaluations of the transcript's heavy views, so a test can
/// check that a stream tick re-renders only the row it changed
/// (`ChatTranscriptRenderBudgetTests`). Each probed view calls `hit` once at the
/// top of its `body` (or, for `ResponseTextSelection`, its host update), and
/// `ChatTranscriptMessageBlock.==` counts each comparison that finds a change.
///
/// Debug builds keep the counts in memory only, by name and by transcript row
/// `renderID`; nothing is logged or sent anywhere. Release builds compile `hit` to an
/// empty inlined function and keep no storage. Inspect the counts from lldb, for
/// example `po RenderProbe.snapshot`, after `RenderProbe.reset()` and a stream.
@MainActor
enum RenderProbe {
    /// The probed bodies. Static names only: a row's identity is a separate key.
    enum Name: String {
        case transcriptMessageBlock = "ChatTranscriptMessageBlock"
        /// A `ChatTranscriptMessageBlock.==` that returned false: a row whose inputs
        /// changed, as opposed to an equal row SwiftUI re-ran anyway.
        case transcriptMessageBlockUnequal = "ChatTranscriptMessageBlock.unequal"
        case messageBubble = "MessageBubbleView"
        case markdownRenderer = "MarkdownRenderer"
        case toolActivityGroup = "ToolActivityGroupView"
        case reasoningBlock = "ReasoningBlockView"
        case responseSelectionUpdate = "ResponseTextSelection.update"
    }

    #if DEBUG
    private static var counts: [Name: Int] = [:]
    private static var renderIDCounts: [String: Int] = [:]

    /// Records one evaluation of `name`, and of the transcript row `renderID` when given.
    static func hit(_ name: Name, renderID: String? = nil) {
        counts[name, default: 0] += 1
        if let renderID {
            renderIDCounts[renderID, default: 0] += 1
        }
    }

    /// Clears every count; call before the window you want to measure.
    static func reset() {
        counts = [:]
        renderIDCounts = [:]
    }

    static func count(_ name: Name) -> Int {
        counts[name] ?? 0
    }

    /// Evaluations of the transcript row with this `renderID` since the last reset.
    static func count(renderID: String) -> Int {
        renderIDCounts[renderID] ?? 0
    }

    /// Every named total since the last reset, keyed by static name.
    static var snapshot: [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }
    #else
    @inline(__always)
    static func hit(_ name: Name, renderID: String? = nil) {}
    #endif
}
