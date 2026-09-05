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
