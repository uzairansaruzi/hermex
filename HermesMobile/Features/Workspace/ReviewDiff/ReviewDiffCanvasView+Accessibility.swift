import UIKit

/// VoiceOver for the drawn rows. The canvas is an accessibility container whose
/// elements are created on demand for the visible (non-collapsed) rows, so a 5,000-line
/// diff never materialises 5,000 objects. Labels read line number, change type, and
/// text; headers expose collapse and viewed as actions.
extension ReviewDiffCanvasView {
    // MARK: - Accessibility

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override func accessibilityElementCount() -> Int {
        layout.visibleRowIndices.count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard layout.visibleRowIndices.indices.contains(index) else { return nil }
        let rowIndex = layout.visibleRowIndices[index]
        if let element = accessibilityElementsByRowIndex[rowIndex] { return element }
        let element = ReviewDiffRowAccessibilityElement(canvas: self, rowIndex: rowIndex)
        accessibilityElementsByRowIndex[rowIndex] = element
        return element
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard let element = element as? ReviewDiffRowAccessibilityElement else { return NSNotFound }
        let indices = layout.visibleRowIndices
        var lower = 0
        var upper = indices.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if indices[middle] < element.rowIndex { lower = middle + 1 } else { upper = middle }
        }
        return lower < indices.count && indices[lower] == element.rowIndex ? lower : NSNotFound
    }

    // VoiceOver can hold an element from before a rows rebuild, so every accessor
    // treats an out-of-range index as an empty row instead of trapping.

    func accessibilityLabel(forRowAt rowIndex: Int) -> String {
        guard rows.indices.contains(rowIndex) else { return "" }
        let row = rows[rowIndex]
        switch row.kind {
        case .file(let header):
            var parts = [header.displayPath]
            parts.append(String(localized: "\(header.additions) added"))
            parts.append(String(localized: "\(header.deletions) removed"))
            parts.append(
                collapsedFileIDs.contains(row.fileID)
                    ? String(localized: "Collapsed")
                    : String(localized: "Expanded")
            )
            if viewedFileIDs.contains(row.fileID) { parts.append(String(localized: "Viewed")) }
            return parts.joined(separator: ", ")
        case .hunk(let text), .notice(let text):
            return text
        case .line(let line):
            var parts: [String] = []
            if let number = line.displayLineNumber { parts.append(String(localized: "Line \(number)")) }
            switch line.change {
            case .addition: parts.append(String(localized: "added"))
            case .deletion: parts.append(String(localized: "removed"))
            case .context: break
            }
            parts.append(line.content.isEmpty ? String(localized: "blank") : line.content)
            return parts.joined(separator: ", ")
        }
    }

    func accessibilityTraits(forRowAt rowIndex: Int) -> UIAccessibilityTraits {
        guard rows.indices.contains(rowIndex) else { return .none }
        let row = rows[rowIndex]
        switch row.kind {
        case .file: return [.header, .button]
        case .hunk, .notice: return .staticText
        case .line: return selectedRowIDs.contains(row.id) ? [.staticText, .selected] : .staticText
        }
    }

    func accessibilityCustomActions(forRowAt rowIndex: Int) -> [UIAccessibilityCustomAction] {
        guard rows.indices.contains(rowIndex) else { return [] }
        let row = rows[rowIndex]
        switch row.kind {
        case .file:
            let isViewed = viewedFileIDs.contains(row.fileID)
            return [
                UIAccessibilityCustomAction(
                    name: isViewed ? String(localized: "Mark as not viewed") : String(localized: "Mark as viewed")
                ) { [weak self] _ in
                    self?.onToggleViewed?(row.fileID)
                    return true
                }
            ]
        case .line:
            return [
                UIAccessibilityCustomAction(name: String(localized: "Select line")) { [weak self] _ in
                    self?.onLinePress?(ReviewDiffLinePress(rowID: row.id, fileID: row.fileID, gesture: .tap))
                    return true
                },
                UIAccessibilityCustomAction(name: String(localized: "Start selection here")) { [weak self] _ in
                    self?.onLinePress?(ReviewDiffLinePress(rowID: row.id, fileID: row.fileID, gesture: .longPress))
                    return true
                }
            ]
        case .hunk, .notice:
            return []
        }
    }

    func accessibilityActivate(rowAt rowIndex: Int) -> Bool {
        guard rows.indices.contains(rowIndex) else { return false }
        switch rows[rowIndex].kind {
        case .file, .line:
            activateRow(at: rowIndex, point: nil)
            return true
        case .hunk, .notice:
            return false
        }
    }

    func accessibilityScreenFrame(forRowAt rowIndex: Int) -> CGRect {
        guard let frame = drawnFrame(forRowAt: rowIndex) else { return .null }
        return UIAccessibility.convertToScreenCoordinates(frame, in: self)
    }

    /// Scrolls a focused row into view unless it is already drawn on screen, which
    /// includes the pinned sticky header.
    func revealRowForAccessibility(_ rowIndex: Int) {
        guard let frame = drawnFrame(forRowAt: rowIndex) else { return }
        if frame.minY < 0 || frame.maxY > bounds.height {
            onRevealRow?(rowIndex)
        }
    }
}

/// One VoiceOver element per visible row, created on demand. Every property reads
/// the canvas so collapse, viewed, and selection state are never stale.
final class ReviewDiffRowAccessibilityElement: UIAccessibilityElement {
    let rowIndex: Int
    private weak var canvas: ReviewDiffCanvasView?

    init(canvas: ReviewDiffCanvasView, rowIndex: Int) {
        self.canvas = canvas
        self.rowIndex = rowIndex
        super.init(accessibilityContainer: canvas)
    }

    override var accessibilityLabel: String? {
        get { canvas?.accessibilityLabel(forRowAt: rowIndex) }
        set {}
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { canvas?.accessibilityTraits(forRowAt: rowIndex) ?? .none }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { canvas?.accessibilityCustomActions(forRowAt: rowIndex) }
        set {}
    }

    override var accessibilityFrame: CGRect {
        get { canvas?.accessibilityScreenFrame(forRowAt: rowIndex) ?? .null }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        canvas?.accessibilityActivate(rowAt: rowIndex) ?? false
    }

    override func accessibilityElementDidBecomeFocused() {
        canvas?.revealRowForAccessibility(rowIndex)
    }
}
