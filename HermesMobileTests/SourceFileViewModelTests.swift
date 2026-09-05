import XCTest
@testable import HermesMobile

@MainActor
final class SourceFileViewModelTests: XCTestCase {
    private func loadedModel(lineCount: Int, path: String = "data.json") async -> SourceFileViewModel {
        let model = SourceFileViewModel(path: path, serverLanguage: nil, highlighter: SourceHighlighter())
        let content = (0..<lineCount).map { "{\"n\": \($0)}" }.joined(separator: "\n")
        await model.load(content: content)
        return model
    }

    func testLoadBuildsOneRowPerLineAndKeepsPlainTextOff() async {
        let model = await loadedModel(lineCount: 10_000)
        XCTAssertEqual(model.rows.count, 10_000)
        XCTAssertEqual(model.rowsVersion, 1)
        XCTAssertFalse(model.isPlainText)
        XCTAssertTrue(model.tokensByRowID.isEmpty, "Nothing is coloured before the viewport reports itself.")
    }

    /// Dark mode reports its appearance during the first body pass, while the rows
    /// are still building off the main actor. That must not discard the rows.
    func testAppearanceChangeDuringLoadKeepsTheRows() async {
        let model = SourceFileViewModel(path: "a.json", serverLanguage: nil, highlighter: SourceHighlighter())
        let load = Task { await model.load(content: "{}\n{}\n{}") }
        model.setColorScheme(isDark: true)
        await load.value

        XCTAssertEqual(model.rows.count, 3)
    }

    func testUnsupportedFileIsPlainTextAndNeverRequestsHighlighting() async {
        let model = await loadedModel(lineCount: 5, path: "notes.txt")
        XCTAssertTrue(model.isPlainText)
        model.visibleRowRangeChanged(0...4)
        XCTAssertNil(model.highlightTask)
    }

    func testVisibleRowsAreColouredAndSmallScrollsDoNotReRequest() async throws {
        let model = await loadedModel(lineCount: 500)

        model.visibleRowRangeChanged(0...30)
        await model.highlightTask?.value

        XCTAssertNotNil(model.tokensByRowID["source:line:0"])
        XCTAssertNotNil(model.tokensByRowID["source:line:70"], "Overscan colours rows just past the viewport.")
        XCTAssertNil(model.tokensByRowID["source:line:71"])
        XCTAssertNil(model.tokensByRowID["source:line:400"])
        let version = model.tokensVersion

        model.visibleRowRangeChanged(5...35)
        XCTAssertNil(model.highlightTask, "Moving fewer than twenty rows keeps the last request.")
        XCTAssertEqual(model.tokensVersion, version)

        model.visibleRowRangeChanged(300...330)
        await model.highlightTask?.value
        XCTAssertNotNil(model.tokensByRowID["source:line:300"])
        XCTAssertNotNil(model.tokensByRowID["source:line:0"], "Earlier colour survives later requests.")
        XCTAssertGreaterThan(model.tokensVersion, version)
    }

    func testAppearanceChangeDropsColourAndRecoloursTheViewport() async {
        let model = await loadedModel(lineCount: 50)
        model.visibleRowRangeChanged(0...10)
        await model.highlightTask?.value
        let lightRun = model.tokensByRowID["source:line:0"]?.first

        model.setColorScheme(isDark: true)
        await model.highlightTask?.value

        let darkRun = model.tokensByRowID["source:line:0"]?.first
        XCTAssertNotNil(darkRun)
        XCTAssertNotEqual(lightRun?.color, darkRun?.color, "Dark mode uses a different Highlightr theme.")
    }
}
