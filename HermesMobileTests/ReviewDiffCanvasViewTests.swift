import UIKit
import XCTest
@testable import HermesMobile

@MainActor
final class ReviewDiffCanvasViewTests: XCTestCase {
    private func header(_ fileID: String) -> ReviewDiffRow {
        ReviewDiffRow(
            id: "\(fileID):header",
            fileID: fileID,
            kind: .file(ReviewDiffFileHeader(path: fileID, previousPath: nil, changeKind: .modified, additions: 1, deletions: 0))
        )
    }

    private func line(_ fileID: String, _ index: Int) -> ReviewDiffRow {
        ReviewDiffRow(
            id: "\(fileID):line:\(index)",
            fileID: fileID,
            kind: .line(ReviewDiffLine(content: "line \(index)", change: .addition, oldLineNumber: nil, newLineNumber: index))
        )
    }

    private func makeCanvas(rows: [ReviewDiffRow]) -> ReviewDiffCanvasView {
        let canvas = ReviewDiffCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        canvas.viewportWidth = 390
        canvas.setRows(rows)
        return canvas
    }

    func testStaleAccessibilityElementSurvivesARowsRebuild() throws {
        let canvas = makeCanvas(rows: [header("a")] + (0..<20).map { line("a", $0) })
        let element = try XCTUnwrap(canvas.accessibilityElement(at: 15) as? ReviewDiffRowAccessibilityElement)
        XCTAssertEqual(element.accessibilityLabel, "Line 14, added, line 14")

        canvas.setRows([header("a"), line("a", 0)])

        XCTAssertEqual(element.accessibilityLabel, "")
        XCTAssertEqual(element.accessibilityTraits, .none)
        XCTAssertEqual(element.accessibilityCustomActions?.count, 0)
        XCTAssertFalse(element.accessibilityActivate())
        XCTAssertEqual(canvas.index(ofAccessibilityElement: element), NSNotFound)
    }

    func testWrappingDisablesHorizontalPan() {
        let long = ReviewDiffRow(
            id: "s:0",
            fileID: "s",
            kind: .line(ReviewDiffLine(content: String(repeating: "x", count: 400), change: .context, oldLineNumber: nil, newLineNumber: 1))
        )
        let canvas = ReviewDiffCanvasView(frame: CGRect(x: 0, y: 0, width: 390, height: 300), presentation: .source)
        canvas.viewportWidth = 390
        canvas.setRows([long])
        XCTAssertGreaterThan(canvas.maxHorizontalOffset(for: "s", kind: .code), 0)
        XCTAssertEqual(canvas.style.changeBarWidth, 0, "Source files have no change bar.")

        canvas.wrapsLines = true
        XCTAssertEqual(canvas.maxHorizontalOffset(for: "s", kind: .code), 0)
        XCTAssertGreaterThan(canvas.layout.visualLineCount(forRowAt: 0), 1)
    }

    /// Toggling wrap grows the rows above the viewport; the row at the top must stay put.
    func testWrapToggleKeepsTheTopRowWhereItIs() throws {
        let rows = (0..<60).map { index in
            ReviewDiffRow(
                id: "s:\(index)",
                fileID: "s",
                kind: .line(ReviewDiffLine(content: String(repeating: "x", count: 200), change: .context, oldLineNumber: nil, newLineNumber: index + 1))
            )
        }
        let view = ReviewDiffSurfaceView(presentation: .source)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        view.layoutIfNeeded()
        view.setRows(rows)
        view.scroll(to: .row("s:30"), animated: false)
        let before = view.verticalOffset
        XCTAssertGreaterThan(before, 0)
        // The row under the top edge is the one that must not move.
        let topRow = try XCTUnwrap(view.rows.first { row in
            guard let frame = view.frame(forRowID: row.id) else { return false }
            return frame.minY <= before && before < frame.minY + frame.height
        })
        XCTAssertNotEqual(topRow.id, "s:30", "The target sits 30 % down, so the top row is above it.")
        let screenYBefore = try XCTUnwrap(view.frame(forRowID: topRow.id)).minY - before

        view.wrapsLines = true

        XCTAssertGreaterThan(view.verticalOffset, before, "Wrapped rows above pushed the content down.")
        let screenYAfter = try XCTUnwrap(view.frame(forRowID: topRow.id)).minY - view.verticalOffset
        XCTAssertEqual(screenYAfter, screenYBefore, accuracy: 0.5)
    }

    func testStickyHeaderReportsItsPinnedFrame() {
        let rows = [header("a")] + (0..<40).map { line("a", $0) } + [header("b")] + (0..<5).map { line("b", $0) }
        let canvas = makeCanvas(rows: rows)
        let headerHeight = canvas.style.metrics.fileHeaderHeight

        canvas.verticalOffset = 200
        XCTAssertEqual(canvas.drawnFrame(forRowAt: 0)?.minY, 0, "Scrolled past, the header pins to the top.")
        XCTAssertEqual(canvas.drawnFrame(forRowAt: 0)?.height, headerHeight)
        XCTAssertEqual(canvas.frame(forRowAt: 0)?.minY, -200, "Its row position is still where it scrolled to.")

        canvas.verticalOffset = 0
        XCTAssertEqual(canvas.drawnFrame(forRowAt: 0)?.minY, 0)
        XCTAssertEqual(canvas.drawnFrame(forRowAt: 1)?.minY, headerHeight, "Other rows use their scrolled position.")
    }
}
