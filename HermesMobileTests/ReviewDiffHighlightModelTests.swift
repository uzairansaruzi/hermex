import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ReviewDiffHighlightModelTests: XCTestCase {
    /// Answers every request at once with one run per line whose location is the
    /// request's index, so a test can tell which side coloured a row.
    private actor Recorder {
        private(set) var calls: [[String]] = []
        private(set) var languages: [String] = []

        func answer(_ lines: [String], language: String, color: UIColor) -> [[SourceHighlightRun]] {
            let location = calls.count
            calls.append(lines)
            languages.append(language)
            return lines.map { _ in [SourceHighlightRun(range: NSRange(location: location, length: 1), color: color)] }
        }
    }

    /// Holds each request until the test answers it, to race refresh, dismissal and
    /// progressive loading against an answer in flight.
    private struct ScriptedCall: Sendable {
        let lines: [String]
        let isDark: Bool
        let answer: CheckedContinuation<[[SourceHighlightRun]]?, Never>

        func respond(color: UIColor = .black) {
            answer.resume(returning: lines.map { _ in [SourceHighlightRun(range: NSRange(location: 0, length: 1), color: color)] })
        }
    }

    private func scriptedModel() -> (ReviewDiffHighlightModel, AsyncStream<ScriptedCall>.Iterator) {
        let (calls, sink) = AsyncStream.makeStream(of: ScriptedCall.self)
        let model = ReviewDiffHighlightModel { lines, _, isDark in
            await withCheckedContinuation { sink.yield(ScriptedCall(lines: lines, isDark: isDark, answer: $0)) }
        }
        return (model, calls.makeAsyncIterator())
    }

    /// The model's next request, awaited only while it has one in flight, so a model
    /// that stopped asking fails the test instead of hanging it.
    private func nextCall(
        _ model: ReviewDiffHighlightModel,
        _ calls: inout AsyncStream<ScriptedCall>.Iterator
    ) async throws -> ScriptedCall {
        struct StoppedAsking: Error {}
        guard model.highlightTask != nil, let call = await calls.next() else { throw StoppedAsking() }
        return call
    }

    /// Answers the request in flight and waits for the model to take the answer.
    private func respond(to call: ScriptedCall, in model: ReviewDiffHighlightModel, color: UIColor = .black) async {
        let task = model.highlightTask
        call.respond(color: color)
        await task?.value
    }

    private func recordingModel(_ recorder: Recorder, color: UIColor = .black) -> ReviewDiffHighlightModel {
        ReviewDiffHighlightModel { lines, language, _ in await recorder.answer(lines, language: language, color: color) }
    }

    private func drain(_ model: ReviewDiffHighlightModel) async {
        while let task = model.highlightTask { await task.value }
    }

    private func file(
        _ path: String, _ lines: [(String, DiffLine.Kind)], marker: Bool = false, renamedFrom previousPath: String? = nil
    ) -> [ReviewDiffRow] {
        var rows = [
            ReviewDiffRow(
                id: "\(path):header",
                fileID: path,
                kind: .file(ReviewDiffFileHeader(path: path, previousPath: previousPath, changeKind: .modified, additions: 0, deletions: 0))
            ),
            ReviewDiffRow(id: "\(path):hunk:0", fileID: path, kind: .hunk("@@ -1 +1 @@"))
        ]
        for (index, (content, change)) in lines.enumerated() {
            let line = ReviewDiffLine(content: content, change: change, oldLineNumber: index + 1, newLineNumber: index + 1)
            rows.append(ReviewDiffRow(id: "\(path):line:0:\(index)", fileID: path, kind: .line(line)))
        }
        if marker {
            let line = ReviewDiffLine(
                content: "\\ No newline at end of file", change: .context,
                oldLineNumber: nil, newLineNumber: nil, isNoNewlineMarker: true
            )
            rows.append(ReviewDiffRow(id: "\(path):line:0:\(lines.count)", fileID: path, kind: .line(line)))
        }
        return rows
    }

    func testDeletionsTakeOldSideColourAndEverythingElseTheNewSide() async {
        let recorder = Recorder()
        let model = recordingModel(recorder)
        model.setRows(file("a.swift", [("let a = 1", .context), ("let b = 2", .deletion), ("let c = 3", .addition)], marker: true))
        model.visibleRowRangeChanged(0...5)
        await drain(model)

        let calls = await recorder.calls
        XCTAssertEqual(calls, [["let a = 1", "let c = 3"], ["let a = 1", "let b = 2"]])
        XCTAssertEqual(model.tokensByRowID["a.swift:line:0:0"]?.first?.range.location, 0)
        XCTAssertEqual(model.tokensByRowID["a.swift:line:0:1"]?.first?.range.location, 1)
        XCTAssertEqual(model.tokensByRowID["a.swift:line:0:2"]?.first?.range.location, 0)
        XCTAssertNil(model.tokensByRowID["a.swift:line:0:3"], "The no-newline marker is not code.")
    }

    /// A rename's deletions came from the old path, so they take that file's grammar.
    func testRenamedFileReadsDeletionsInTheOldPathsLanguage() async {
        let recorder = Recorder()
        let model = recordingModel(recorder)
        model.setRows(file("b.swift", [("x = 1", .context), ("y = 2", .deletion), ("let y = 2", .addition)], renamedFrom: "a.py"))
        model.visibleRowRangeChanged(0...4)
        await drain(model)

        let languages = await recorder.languages
        XCTAssertEqual(languages, ["swift", "python"])
    }

    func testCollapsedAndUnsupportedFilesNeverRequestHighlighting() {
        let model = ReviewDiffHighlightModel { _, _, _ in XCTFail("No request expected"); return nil }
        model.setCollapsedFileIDs(["b.swift"])
        model.setRows(file("a.txt", [("plain", .addition)]) + file("b.swift", [("let b = 2", .addition)]))
        model.visibleRowRangeChanged(0...5)
        XCTAssertNil(model.highlightTask)
    }

    func testRequestsAreCappedAndAnsweredRowsAreNeverSentAgain() async {
        let recorder = Recorder()
        let model = ReviewDiffHighlightModel { lines, language, _ in
            _ = await recorder.answer(lines, language: language, color: .black)
            return lines.map { _ in [] }
        }
        model.setRows(file("a.swift", (0..<500).map { ("let v\($0) = \($0)", .addition) }))

        // Rows 0...340 with overscan: 339 line rows after the header and hunk.
        model.visibleRowRangeChanged(0...300)
        await drain(model)
        // The window moves to 60...440; only the 100 rows past the last one are new.
        model.visibleRowRangeChanged(100...400)
        await drain(model)

        let calls = await recorder.calls
        XCTAssertEqual(calls.map(\.count), [200, 139, 100])
        XCTAssertTrue(model.tokensByRowID.isEmpty)
    }

    func testRefreshDropsTheAnswerForTheOldText() async throws {
        var (model, calls) = scriptedModel()
        model.setRows(file("a.swift", [("let old = 1", .addition)]))
        model.visibleRowRangeChanged(0...2)
        let stale = try await nextCall(model, &calls)

        // Same row ids, different text: what a refresh after another edit looks like.
        model.reset()
        model.setRows(file("a.swift", [("let new = 2", .addition)]))
        await respond(to: stale, in: model)

        XCTAssertNil(model.tokensByRowID["a.swift:line:0:0"])
        let fresh = try await nextCall(model, &calls)
        XCTAssertEqual(fresh.lines, ["let new = 2"])
        await respond(to: fresh, in: model)
        XCTAssertNotNil(model.tokensByRowID["a.swift:line:0:0"])
    }

    func testAppearanceChangeDropsTheAnswerInFlightAndRecolours() async throws {
        var (model, calls) = scriptedModel()
        model.setRows(file("a.swift", [("let a = 1", .addition)]))
        model.visibleRowRangeChanged(0...2)
        let light = try await nextCall(model, &calls)

        model.setAppearance(.init(isDark: true))
        await respond(to: light, in: model)

        XCTAssertNil(model.tokensByRowID["a.swift:line:0:0"])
        let dark = try await nextCall(model, &calls)
        XCTAssertTrue(dark.isDark)
        await respond(to: dark, in: model, color: .white)
        XCTAssertNotNil(model.tokensByRowID["a.swift:line:0:0"])
    }

    func testDismissalDropsTheAnswerAndStopsAsking() async throws {
        var (model, calls) = scriptedModel()
        model.setRows(file("a.swift", [("let a = 1", .addition)]))
        model.visibleRowRangeChanged(0...2)
        let call = try await nextCall(model, &calls)

        model.cancel()
        await respond(to: call, in: model)

        XCTAssertTrue(model.tokensByRowID.isEmpty)
        XCTAssertNil(model.highlightTask)
    }

    /// Progressive loading inserts a file above the one being coloured; the answer
    /// must land on its own rows, not on whatever now sits at their old indices.
    func testAnswerLandsOnItsRowsAfterRowsAboveThemArrive() async throws {
        var (model, calls) = scriptedModel()
        let swiftFile = file("b.swift", [("let b = 2", .addition)])
        model.setRows(swiftFile)
        model.visibleRowRangeChanged(0...3)
        let call = try await nextCall(model, &calls)

        model.setRows(file("a.txt", [("plain", .addition), ("text", .addition)]) + swiftFile)
        await respond(to: call, in: model)

        XCTAssertEqual(Set(model.tokensByRowID.keys), ["b.swift:line:0:0"])
    }

    func testColourTooFaintForTheChangeTintFallsBackToTheLabel() async {
        let recorder = Recorder()
        let model = recordingModel(recorder, color: .white)
        model.setRows(file("a.swift", [("let a = 1", .addition)]))
        model.visibleRowRangeChanged(0...2)
        await drain(model)

        XCTAssertNil(model.tokensByRowID["a.swift:line:0:0"], "White on a light green row is unreadable.")
    }

    /// The real themes must survive the contrast check on both tints and appearances.
    func testRealHighlighterColoursAdditionsAndDeletionsInBothAppearances() async {
        for isDark in [false, true] {
            let model = ReviewDiffHighlightModel(highlight: { await SourceHighlighter().highlight(lines: $0, language: $1, isDark: $2) })
            model.setAppearance(.init(isDark: isDark))
            model.setRows(file("a.swift", [("let removed = \"old\"", .deletion), ("let added = \"new\"", .addition)]))
            model.visibleRowRangeChanged(0...3)
            await drain(model)

            XCTAssertNotNil(model.tokensByRowID["a.swift:line:0:0"], "deletion, isDark: \(isDark)")
            XCTAssertNotNil(model.tokensByRowID["a.swift:line:0:1"], "addition, isDark: \(isDark)")
        }
    }
}
