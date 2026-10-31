import SwiftUI

/// Debug-only body-evaluation counter for the SwiftUI bodies whose re-runs a
/// stream tick should not buy (`DEVELOPMENT.md` § Recording signposts). The
/// transcript's `.equatable()` rows promise that settled markdown rows skip
/// every reveal tick; this counts the bodies themselves, so a new non-`Equatable`
/// input or a value handed to every row shows up as settled rows re-evaluating
/// before a long chat janks (#1256 needed hand-added counters to find it).
///
/// Probe lines live at the top of `ChatTranscriptMessageBlock.body`,
/// `MessageBubbleView.body`, `MarkdownRenderer.body`, `ToolActivityGroupView.body`,
/// `ReasoningBlockView.body`, and `ResponseTextSelection.updateUIViewController`
/// (its host updates count separately, keyed by the reply `identity`).
///
/// Counts are per process name and, where a row identity exists, per transcript
/// `renderID`. In memory only, main actor only. Anything leaving the process is
/// static names and totals, never row identities.
@MainActor
enum RenderProbe {
    #if DEBUG
    private static var counts: [String: Int] = [:]
    private static var renderIDCounts: [Key: Int] = [:]

    private struct Key: Hashable {
        let name: String
        let renderID: String
    }

    /// Records one evaluation of the named body.
    static func hit(_ name: StaticString, renderID: String? = nil) {
        counts[String(describing: name), default: 0] += 1
        if let renderID {
            renderIDCounts[Key(name: String(describing: name), renderID: renderID), default: 0] += 1
        }
    }

    /// Zeroes every count, so a measurement window starts clean.
    static func reset() {
        counts = [:]
        renderIDCounts = [:]
    }

    /// A body's evaluation count, keyed by its `renderID` where it has one.
    static func count(_ name: String, renderID: String) -> Int {
        renderIDCounts[Key(name: name, renderID: renderID)] ?? 0
    }

    /// A body's total evaluation count across every row.
    static func count(_ name: String) -> Int {
        counts[name] ?? 0
    }

    /// The whole snapshot for inspection: names to totals.
    static func allCounts() -> [String: Int] {
        counts
    }
    #else
    /// Inlined no-op in Release: no storage, no symbol beyond this stub.
    @inline(__always)
    static func hit(_ name: StaticString, renderID: String? = nil) {}
    #endif
}
