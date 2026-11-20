import Foundation
import UIKit

@MainActor
@Observable
final class ReviewDiffHighlightModel {
    typealias Highlight = @Sendable (_ lines: [String], _ language: String, _ isDark: Bool) async -> [[SourceHighlightRun]]?

    typealias SideLine = (rowID: String, line: ReviewDiffLine)

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
    private(set) var highlightTask: Task<Void, Never>?

    static let maxLinesPerRequest = 200
    static let minimumContrast: CGFloat = 4.5

    private let highlight: Highlight
    private var rows: [ReviewDiffRow] = []
    private var languagesByFileID: [String: Languages] = [:]
    private var collapsedFileIDs: Set<String> = []
    private var visibleRange: ClosedRange<Int>?
    private var requestedRange: ClosedRange<Int>?
    private var processedRowIDs: Set<String> = []
    private var failedLanguages: Set<String> = []
    private var appearance = Appearance()
    private var backgrounds = TintedBackgrounds(appearance: Appearance())
    private var generation = 0
    private var isCancelled = false

    init(highlight: @escaping Highlight = { await SourceHighlighter.shared.highlight(lines: $0, language: $1, isDark: $2) }) {
        self.highlight = highlight
    }

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

    func reset() {
        rows = []
        languagesByFileID = [:]
        invalidate()
    }

    func cancel() {
        isCancelled = true
        generation += 1
        highlightTask?.cancel()
    }

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
        let languages: Languages
        let lines: [SideLine]
    }

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

    static func sides(of lines: [SideLine]) -> (new: [SideLine], old: [SideLine]) {
        let content = lines.filter { !$0.line.isNoNewlineMarker }
        let hasDeletion = content.contains { $0.line.change == .deletion }
        let new = content.filter { $0.line.change != .deletion }
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

private struct TintedBackgrounds {
    private typealias Luminances = (row: CGFloat, word: CGFloat)
    private let addition: Luminances
    private let deletion: Luminances

    init(appearance: ReviewDiffHighlightModel.Appearance) {
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = appearance.isDark ? .dark : .light
            traits.userInterfaceLevel = .elevated
            traits.accessibilityContrast = appearance.increasedContrast ? .high : .normal
        }
        let theme = ReviewDiffTheme()
        let background = Self.components(theme.background.resolvedColor(with: traits))
        func luminances(_ tint: UIColor) -> Luminances {
            let tint = Self.components(tint.resolvedColor(with: traits))
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

    private static func luminance(_ rgb: [CGFloat]) -> CGFloat {
        let linear = rgb.map { $0 <= 0.039_28 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
