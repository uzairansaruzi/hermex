import Foundation
import OSLog

/// Rows and syntax colour for one workspace file. Rows build off the main actor;
/// colour arrives per visible window from `SourceHighlighter`, one contiguous
/// uncoloured run at a time so a row is never tokenized twice, and a new window is
/// requested only once the viewport has moved twenty rows past the last request.
@MainActor
@Observable
final class SourceFileViewModel {
    private(set) var rows: [ReviewDiffRow] = []
    private(set) var rowsVersion = 0
    private(set) var tokensByRowID: [String: [SourceHighlightRun]] = [:]
    private(set) var tokensVersion = 0
    /// True when this file draws without colour: no grammar, or Highlightr gave up.
    private(set) var isPlainText: Bool

    /// Rows either side of the viewport tokenized along with it.
    static let highlightOverscan = 40
    static let rerequestThreshold = 20

    private let highlighter: SourceHighlighter
    private var language: String?
    private var lines: [String] = []
    private var highlightedLines: [Bool] = []
    private var visibleRange: ClosedRange<Int>?
    private var requestedRange: ClosedRange<Int>?
    private var isDark = false
    /// Bumped per `load`; a slower, older build never replaces newer rows.
    private var loadGeneration = 0
    /// Bumped whenever colour must start over (new rows, new appearance); a
    /// highlight result from an older generation is dropped.
    private var highlightGeneration = 0
    /// The request in flight, if any; tests await it.
    private(set) var highlightTask: Task<Void, Never>?

    init(path: String, serverLanguage: String?, highlighter: SourceHighlighter = .shared) {
        self.highlighter = highlighter
        let language = SourceHighlightLanguage.resolve(path: path, serverLanguage: serverLanguage)
        self.language = language
        isPlainText = language == nil
    }

    /// Replaces the file text. Rows build off the main actor; an older build that
    /// lands after a newer one is dropped.
    func load(content: String) async {
        loadGeneration += 1
        let buildGeneration = loadGeneration
        let built = await Task.detached(priority: .userInitiated) {
            let state = reviewDiffSignposter.beginInterval("BuildSourceRows")
            let lines = SourceFileRows.lines(in: content)
            let rows = SourceFileRows.rows(for: lines)
            reviewDiffSignposter.endInterval("BuildSourceRows", state, "rows=\(rows.count)")
            return (lines, rows)
        }.value
        guard buildGeneration == loadGeneration, !Task.isCancelled else { return }
        lines = built.0
        rows = built.1
        rowsVersion += 1
        resetHighlighting()
    }

    func setColorScheme(isDark: Bool) {
        guard isDark != self.isDark else { return }
        self.isDark = isDark
        resetHighlighting()
    }

    /// Called by the surface as the viewport moves. Only bookkeeping the view does
    /// not observe changes synchronously, so a report made mid-layout is safe.
    func visibleRowRangeChanged(_ range: ClosedRange<Int>?) {
        visibleRange = range
        guard let range, language != nil else { return }
        if let requestedRange,
           abs(range.lowerBound - requestedRange.lowerBound) + abs(range.upperBound - requestedRange.upperBound)
               < Self.rerequestThreshold {
            return
        }
        requestHighlight()
    }

    private func resetHighlighting() {
        highlightGeneration += 1
        tokensByRowID = [:]
        tokensVersion += 1
        highlightedLines = Array(repeating: false, count: lines.count)
        requestedRange = nil
        requestHighlight()
    }

    private func requestHighlight() {
        guard let language, let visibleRange, !lines.isEmpty else { return }
        requestedRange = visibleRange
        // One request at a time; the answer re-runs this for whatever is still uncoloured.
        guard highlightTask == nil else { return }

        // The first uncoloured run inside the padded window. Rows already coloured
        // (an earlier window the reader scrolled past) are never sent again.
        var lower = max(0, visibleRange.lowerBound - Self.highlightOverscan)
        let windowEnd = min(lines.count - 1, visibleRange.upperBound + Self.highlightOverscan)
        while lower <= windowEnd, highlightedLines[lower] { lower += 1 }
        guard lower <= windowEnd else { return }
        var upper = lower
        while upper < windowEnd, !highlightedLines[upper + 1] { upper += 1 }

        let slice = Array(lines[lower...upper])
        let requestGeneration = highlightGeneration
        let isDark = isDark
        highlightTask = Task {
            let result = await highlighter.highlight(lines: slice, language: language, isDark: isDark)
            finishHighlight(result, range: lower...upper, generation: requestGeneration)
        }
    }

    private func finishHighlight(_ result: [[SourceHighlightRun]]?, range: ClosedRange<Int>, generation: Int) {
        highlightTask = nil
        // Whatever the viewport shows now (it may have moved mid-request) gets the next pass.
        defer { requestHighlight() }
        guard generation == highlightGeneration else { return }
        guard let result else {
            language = nil
            isPlainText = true
            return
        }
        for (offset, runs) in result.enumerated() {
            let index = range.lowerBound + offset
            highlightedLines[index] = true
            if !runs.isEmpty {
                tokensByRowID[SourceFileRows.rowID(forLineIndex: index)] = runs
            }
        }
        tokensVersion += 1
    }
}
