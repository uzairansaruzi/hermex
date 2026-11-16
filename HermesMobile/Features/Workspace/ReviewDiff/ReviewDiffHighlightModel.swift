import Foundation
import UIKit

/// Syntax colour for the diff sheet's visible rows. The sheet feeds it rows as they
/// load, the collapsed files, the viewport and the appearance; it colours one run of
/// a hunk at a time, at most `maxLinesPerRequest` rows, inside the viewport plus the
/// source viewer's overscan. Each run is tokenized twice: once as the new side
/// (context and additions) and once as the old side (context and deletions), so
/// deletions take the grammar of the file they came from. Rows are tracked as done
/// whatever the answer, so blank, plain and overlong rows never ask again.
@MainActor
@Observable
final class ReviewDiffHighlightModel {
    /// Colours `lines` as one contiguous piece of `language`; nil when the grammar failed.
    typealias Highlight = @Sendable (_ lines: [String], _ language: String, _ isDark: Bool) async -> [[SourceHighlightRun]]?

    /// A line row captured with its id, so an answer lands on that row even if
    /// progressive loading moves it to another index meanwhile.
    typealias SideLine = (rowID: String, line: ReviewDiffLine)

    /// The grammar each side of one file reads in; a rename's old side is the old path's.
    /// Nil for a side whose path has no supported grammar.
    private struct Languages {
        var new: String?
        var old: String?
    }

    struct Appearance: Equatable {
        var isDark = false
        var increasedContrast = false
    }

    private(set) var tokensByRowID: [String: [SourceHighlightRun]] = [:]
    private(set) var tokensVersion = 0
    /// The request in flight, if any; tests await it.
    private(set) var highlightTask: Task<Void, Never>?

    static let maxLinesPerRequest = 200
    /// WCAG AA for body text, measured against a changed row's tint and word highlight.
    static let minimumContrast: CGFloat = 4.5

    private let highlight: Highlight
    private var rows: [ReviewDiffRow] = []
    private var languagesByFileID: [String: Languages] = [:]
    private var collapsedFileIDs: Set<String> = []
    private var visibleRange: ClosedRange<Int>?
    private var requestedRange: ClosedRange<Int>?
    /// Rows already sent, coloured or not. Ids are stable within one load; `reset`
    /// clears them before a refresh can reuse an id for different text.
    private var processedRowIDs: Set<String> = []
    private var failedLanguages: Set<String> = []
    private var appearance = Appearance()
    private var backgrounds = TintedBackgrounds(appearance: Appearance())
    /// Bumped whenever colour starts over; an answer from an older generation is dropped.
    private var generation = 0
    private var isCancelled = false

    init(highlight: @escaping Highlight = { await SourceHighlighter.shared.highlight(lines: $0, language: $1, isDark: $2) }) {
        self.highlight = highlight
    }

    /// The sheet's current rows. Colour already earned by an unchanged row id stays.
    func setRows(_ rows: [ReviewDiffRow]) {
        self.rows = rows
        languagesByFileID = [:]
        for row in rows {
            guard let header = row.fileHeader else { continue }
            let new = SourceHighlightLanguage.resolve(path: header.path, serverLanguage: nil)
            let old = header.previousPath.map { SourceHighlightLanguage.resolve(path: $0, serverLanguage: nil) } ?? new
            guard new != nil || old != nil else { continue }
            languagesByFileID[row.fileID] = Languages(new: new, old: old)
        }
        requestHighlight()
    }

    func setCollapsedFileIDs(_ ids: Set<String>) {
        guard ids != collapsedFileIDs else { return }
        collapsedFileIDs = ids
        requestHighlight()
    }

    func setAppearance(_ appearance: Appearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        backgrounds = TintedBackgrounds(appearance: appearance)
        invalidate()
        requestHighlight()
    }

    /// Before a refresh: the next rows may reuse ids for different text.
    func reset() {
        rows = []
        languagesByFileID = [:]
        invalidate()
    }

    /// On dismissal: drops the answer in flight and never asks again.
    func cancel() {
        isCancelled = true
        generation += 1
        highlightTask?.cancel()
    }

    /// Called by the surface as the viewport moves. Only bookkeeping the view does
    /// not observe changes synchronously, so a report made mid-layout is safe.
    func visibleRowRangeChanged(_ range: ClosedRange<Int>?) {
        visibleRange = range
        guard let range else { return }
        if let requestedRange,
           abs(range.lowerBound - requestedRange.lowerBound) + abs(range.upperBound - requestedRange.upperBound)
               < SourceFileViewModel.rerequestThreshold {
            return
        }
        requestHighlight()
    }

    private func invalidate() {
        generation += 1
        tokensByRowID = [:]
        tokensVersion += 1
        processedRowIDs = []
        failedLanguages = []
        requestedRange = nil
    }

    private func requestHighlight() {
        guard !isCancelled, let visibleRange, !rows.isEmpty else { return }
        requestedRange = visibleRange
        // One request at a time; the answer re-runs this for whatever is still uncoloured.
        guard highlightTask == nil else { return }
        let overscan = SourceFileViewModel.highlightOverscan
        let lower = max(0, visibleRange.lowerBound - overscan)
        let upper = min(rows.count - 1, visibleRange.upperBound + overscan)
        guard lower <= upper, let batch = nextBatch(in: lower...upper) else { return }

        let sides = Self.sides(of: batch.lines)
        let languages = batch.languages
        let requestGeneration = generation
        let isDark = appearance.isDark
        let highlight = highlight
        highlightTask = Task {
            let signpost = reviewDiffSignposter.beginInterval("HighlightDiffRows")
            // A side without a usable grammar stays plain: an empty answer, not a failure.
            func runs(_ side: [SideLine], _ language: String?) async -> [[SourceHighlightRun]]? {
                guard let language, !side.isEmpty else { return [] }
                return await highlight(side.map(\.line.content), language, isDark)
            }
            let newRuns = await runs(sides.new, languages.new)
            let oldRuns = await runs(sides.old, languages.old)
            reviewDiffSignposter.endInterval("HighlightDiffRows", signpost, "rows=\(batch.lines.count)")
            finishHighlight(batch: batch, sides: sides, newRuns: newRuns, oldRuns: oldRuns, generation: requestGeneration)
        }
    }

    private struct Batch {
        /// Each side's grammar, nil where it is missing or failed.
        let languages: Languages
        let lines: [SideLine]
    }

    /// The first uncoloured run of line rows inside `window`: one file and hunk (a hunk
    /// header ends it), capped at `maxLinesPerRequest`. Collapsed files, plain files and
    /// failed grammars are skipped, so a window spanning thousands of collapsed rows
    /// still sends a bounded slice.
    private func nextBatch(in window: ClosedRange<Int>) -> Batch? {
        guard let start = window.first(where: isEligible) else { return nil }
        let fileID = rows[start].fileID
        guard let file = languagesByFileID[fileID] else { return nil }
        let languages = Languages(new: usable(file.new), old: usable(file.old))
        var lines: [SideLine] = []
        var index = start
        while index <= window.upperBound, lines.count < Self.maxLinesPerRequest,
              rows[index].fileID == fileID, let line = rows[index].line,
              !processedRowIDs.contains(rows[index].id) {
            lines.append((rows[index].id, line))
            index += 1
        }
        return Batch(languages: languages, lines: lines)
    }

    /// Whether the row still needs colour its own side's grammar can give.
    private func isEligible(_ index: Int) -> Bool {
        let row = rows[index]
        guard let line = row.line, !line.isNoNewlineMarker,
              !processedRowIDs.contains(row.id),
              !collapsedFileIDs.contains(row.fileID),
              let languages = languagesByFileID[row.fileID] else { return false }
        return usable(line.change == .deletion ? languages.old : languages.new) != nil
    }

    private func usable(_ language: String?) -> String? {
        language.flatMap { failedLanguages.contains($0) ? nil : $0 }
    }

    /// One hunk run split into the text each side of the diff saw. Context goes to
    /// both sides for grammar continuity but takes its colour from the new side.
    /// "No newline" markers belong to neither.
    static func sides(of lines: [SideLine]) -> (new: [SideLine], old: [SideLine]) {
        let content = lines.filter { !$0.line.isNoNewlineMarker }
        let hasDeletion = content.contains { $0.line.change == .deletion }
        let new = content.filter { $0.line.change != .deletion }
        // Without a deletion the old side would only re-colour context.
        let old = hasDeletion ? content.filter { $0.line.change != .addition } : []
        return (new, old)
    }

    private func finishHighlight(
        batch: Batch,
        sides: (new: [SideLine], old: [SideLine]),
        newRuns: [[SourceHighlightRun]]?,
        oldRuns: [[SourceHighlightRun]]?,
        generation: Int
    ) {
        highlightTask = nil
        guard !isCancelled else { return }
        // Whatever the viewport shows now (it may have moved mid-request) gets the next pass.
        defer { requestHighlight() }
        guard generation == self.generation else { return }
        guard let newRuns, let oldRuns else {
            if newRuns == nil, let language = batch.languages.new { failedLanguages.insert(language) }
            if oldRuns == nil, let language = batch.languages.old { failedLanguages.insert(language) }
            return
        }
        processedRowIDs.formUnion(batch.lines.map(\.rowID))
        var changed = false
        for (side, runs) in zip(sides.new, newRuns) {
            changed = store(runs, for: side) || changed
        }
        for (side, runs) in zip(sides.old, oldRuns) where side.line.change == .deletion {
            changed = store(runs, for: side) || changed
        }
        if changed { tokensVersion += 1 }
    }

    private func store(_ runs: [SourceHighlightRun], for side: SideLine) -> Bool {
        let legible = backgrounds.legibleRuns(runs, on: side.line)
        guard !legible.isEmpty else { return false }
        tokensByRowID[side.rowID] = legible
        return true
    }
}

/// Luminance of the addition and deletion tints as the canvas composites them, for
/// dropping syntax colours that would read poorly there. A dropped run draws in the
/// label colour, which the tints were designed around.
private struct TintedBackgrounds {
    private typealias Luminances = (row: CGFloat, word: CGFloat)
    private let addition: Luminances
    private let deletion: Luminances

    init(appearance: ReviewDiffHighlightModel.Appearance) {
        // The diff surface is always presented in a sheet, so the dark background is
        // the elevated one.
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.isDark ? .dark : .light
            traits.userInterfaceLevel = .elevated
            traits.accessibilityContrast = appearance.increasedContrast ? .high : .normal
        }
        let theme = ReviewDiffTheme()
        let background = Self.components(theme.background.resolvedColor(with: traits))
        func luminances(_ tint: UIColor) -> Luminances {
            let tint = Self.components(tint.resolvedColor(with: traits))
            // Matches the canvas: the row tint, then the word highlight drawn over it.
            let row = Self.blend(tint, alpha: 0.14, over: background)
            let word = Self.blend(tint, alpha: 0.28, over: row)
            return (Self.luminance(row), Self.luminance(word))
        }
        addition = luminances(theme.addTint)
        deletion = luminances(theme.deleteTint)
    }

    func legibleRuns(_ runs: [SourceHighlightRun], on line: ReviewDiffLine) -> [SourceHighlightRun] {
        let tint: Luminances
        switch line.change {
        case .context: return runs
        case .addition: tint = addition
        case .deletion: tint = deletion
        }
        let backgrounds = line.wordDiffRanges.isEmpty ? [tint.row] : [tint.row, tint.word]
        return runs.filter { run in
            let foreground = Self.luminance(Self.components(run.color))
            return backgrounds.allSatisfy { background in
                (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
                    >= ReviewDiffHighlightModel.minimumContrast
            }
        }
    }

    private static func components(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { min(max($0, 0), 1) }
    }

    private static func blend(_ color: [CGFloat], alpha: CGFloat, over background: [CGFloat]) -> [CGFloat] {
        zip(color, background).map { $0 * alpha + $1 * (1 - alpha) }
    }

    /// WCAG relative luminance of sRGB components.
    private static func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.039_28 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
