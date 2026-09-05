// Ported from t3code's `T3ReviewDiffView.swift` (apps/mobile/modules/t3-review-diff).
//
// MIT License
//
// Copyright (c) 2026 T3 Tools Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import OSLog
import UIKit

struct ReviewDiffLinePress: Equatable {
    enum Gesture: Equatable {
        case tap
        case longPress
    }

    let rowID: String
    let fileID: String
    let gesture: Gesture
}

let reviewDiffSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
    category: "ReviewDiff"
)

/// The drawing surface. It is sized to the viewport and slid along with the scroll
/// offset by `ReviewDiffSurfaceView`, so every draw pass paints only the rows that
/// intersect the visible bounds (plus a four-row overscan). Rows are never views:
/// a 5,000-line diff is one `draw(_:)` of ~40 rows.
///
/// Owns hit testing and the per-file horizontal pan with display-link deceleration.
/// Drawing lives in `ReviewDiffCanvasView+Drawing`, VoiceOver in `+Accessibility`.
final class ReviewDiffCanvasView: UIView, UIGestureRecognizerDelegate {
    enum HorizontalPanKind {
        case code
        case fileHeaderPath
    }

    private(set) var layout: ReviewDiffLayout
    private(set) var style: ReviewDiffStyle
    let theme = ReviewDiffTheme()
    let presentation: ReviewDiffPresentation

    var viewedFileIDs: Set<String> = [] {
        didSet { setNeedsDisplay() }
    }
    var selectedRowIDs: Set<String> = [] {
        didSet { setNeedsDisplay() }
    }
    var viewportWidth: CGFloat = 0 {
        didSet {
            guard viewportWidth != oldValue else { return }
            if wrapsLines {
                rebuildLayout(rows: layout.rows, collapsedFileIDs: layout.collapsedFileIDs)
            } else {
                clampHorizontalOffsets()
                setNeedsDisplay()
            }
        }
    }
    /// Wrap long lines on the character grid instead of panning them horizontally.
    var wrapsLines = false {
        didSet {
            guard wrapsLines != oldValue else { return }
            rebuildLayout(rows: layout.rows, collapsedFileIDs: layout.collapsedFileIDs)
        }
    }
    /// Syntax colour runs by row id, filled in for visible rows as the highlighter
    /// answers; rows without an entry draw in the plain text colour.
    var tokensByRowID: [String: [SourceHighlightRun]] = [:] {
        didSet { setNeedsDisplay() }
    }
    /// Scroll offset of the host; row `y` in canvas coordinates is `offset - verticalOffset`.
    var verticalOffset: CGFloat = 0

    var onToggleFile: ((String) -> Void)?
    var onToggleViewed: ((String) -> Void)?
    var onLinePress: ((ReviewDiffLinePress) -> Void)?
    /// The layout height changed (rows, collapse, Dynamic Type); the host resizes content.
    var onContentHeightChange: (() -> Void)?
    /// VoiceOver focused a row that is off screen; the host scrolls it into view.
    var onRevealRow: ((Int) -> Void)?

    private(set) var contentWidthsByFileID: [String: CGFloat] = [:]
    private var horizontalOffsetsByFileID: [String: CGFloat] = [:]
    private var headerPathOffsetsByFileID: [String: CGFloat] = [:]
    private var panStartHorizontalOffset: CGFloat = 0
    private var activePanFileID: String?
    private var activePanKind: HorizontalPanKind?
    private var decelerationDisplayLink: CADisplayLink?
    private var deceleratingFileID: String?
    private var horizontalVelocity: CGFloat = 0
    private var lastDecelerationTimestamp: CFTimeInterval = 0
    /// VoiceOver elements created on demand; cleared whenever the layout rebuilds.
    var accessibilityElementsByRowIndex: [Int: ReviewDiffRowAccessibilityElement] = [:]

    var rows: [ReviewDiffRow] { layout.rows }
    var collapsedFileIDs: Set<String> { layout.collapsedFileIDs }
    var contentHeight: CGFloat { layout.contentHeight }

    private lazy var horizontalPanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    private lazy var tapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    private lazy var longPressGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        gesture.minimumPressDuration = 0.28
        return gesture
    }()

    init(frame: CGRect, presentation: ReviewDiffPresentation = .diff) {
        let style = ReviewDiffStyle.resolve(for: UITraitCollection.current, presentation: presentation)
        self.style = style
        self.presentation = presentation
        layout = ReviewDiffLayout(rows: [], collapsedFileIDs: [], metrics: style.metrics)
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = theme.background
        addGestureRecognizer(horizontalPanGesture)
        addGestureRecognizer(tapGesture)
        addGestureRecognizer(longPressGesture)
        tapGesture.require(toFail: longPressGesture)

        // Dynamic Type resizes every row; appearance changes only need a repaint.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: Self, _) in
            view.style = ReviewDiffStyle.resolve(for: view.traitCollection, presentation: view.presentation)
            view.rebuildLayout(rows: view.layout.rows, collapsedFileIDs: view.layout.collapsedFileIDs)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: Self, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        stopHorizontalDeceleration()
    }

    // MARK: - Inputs

    /// Rows arrive file by file while loading, so a pan the reader already made on a
    /// loaded file survives the rebuild; offsets are clamped to the new widths.
    func setRows(_ rows: [ReviewDiffRow]) {
        stopHorizontalDeceleration()
        activePanFileID = nil
        activePanKind = nil
        rebuildLayout(rows: rows, collapsedFileIDs: layout.collapsedFileIDs)
    }

    func setCollapsedFileIDs(_ collapsedFileIDs: Set<String>) {
        guard collapsedFileIDs != layout.collapsedFileIDs else { return }
        rebuildLayout(rows: layout.rows, collapsedFileIDs: collapsedFileIDs)
    }

    private func rebuildLayout(rows: [ReviewDiffRow], collapsedFileIDs: Set<String>) {
        let state = reviewDiffSignposter.beginInterval("RebuildLayout")
        layout = ReviewDiffLayout(rows: rows, collapsedFileIDs: collapsedFileIDs, metrics: style.metrics, wrapColumns: wrapColumns)
        contentWidthsByFileID = layout.maxColumnCountsByFileID.mapValues { columns in
            let measured = ceil(CGFloat(columns) * style.codeCharacterWidth) + style.codePadding * 2
            return max(0, min(style.maxContentWidth, measured))
        }
        accessibilityElementsByRowIndex.removeAll()
        clampHorizontalOffsets()
        reviewDiffSignposter.endInterval("RebuildLayout", state, "rows=\(rows.count)")
        onContentHeightChange?()
        setNeedsDisplay()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    /// Characters that fit between the gutter and the viewport edge, when wrapping.
    private var wrapColumns: Int? {
        guard wrapsLines else { return nil }
        let available = viewportWidth - style.codeStartX - style.codePadding
        return max(8, Int(available / max(style.codeCharacterWidth, 1)))
    }

    // MARK: - Geometry

    /// Row frame in canvas coordinates (viewport space).
    func frame(forRowAt index: Int) -> CGRect? {
        guard let frame = layout.frame(forRowAt: index) else { return nil }
        return CGRect(x: 0, y: frame.minY - verticalOffset, width: max(bounds.width, viewportWidth), height: frame.height)
    }

    /// Where a row is drawn right now: the pinned rect for the sticky header, the
    /// scrolled position for everything else. VoiceOver frames use this.
    func drawnFrame(forRowAt index: Int) -> CGRect? {
        if let sticky = stickyHeaderTarget(), sticky.rowIndex == index {
            return sticky.rect
        }
        return frame(forRowAt: index)
    }

    func stickyHeaderTarget() -> (rowIndex: Int, rect: CGRect)? {
        guard let sticky = layout.stickyHeader(atVerticalOffset: verticalOffset) else { return nil }
        let rect = CGRect(x: 0, y: sticky.y, width: max(bounds.width, viewportWidth), height: style.metrics.fileHeaderHeight)
        return (sticky.rowIndex, rect)
    }

    private func rowIndex(atCanvasPoint point: CGPoint) -> Int? {
        layout.rowIndex(at: verticalOffset + point.y)
    }

    /// Where the header is currently drawn: pinned at the top when sticky, in place otherwise.
    func scrollAnchorScreenY(forFileID fileID: String) -> CGFloat? {
        if let sticky = stickyHeaderTarget(), rows[sticky.rowIndex].fileID == fileID {
            return 0
        }
        return layout.fileHeaderOffset(forFileID: fileID).map { $0 - verticalOffset }
    }

    // MARK: - Gestures

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalPanGesture else { return true }

        let velocity = horizontalPanGesture.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) * 1.25 else { return false }
        guard let target = horizontalPanTarget(at: horizontalPanGesture.location(in: self)) else { return false }

        let currentOffset = horizontalOffset(for: target.fileID, kind: target.kind)
        if velocity.x > 0, currentOffset <= 0.5 { return false }
        return maxHorizontalOffset(for: target.fileID, kind: target.kind) > 0
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        if let sticky = stickyHeaderTarget(), sticky.rect.contains(point) {
            handleFileHeaderTap(rowIndex: sticky.rowIndex, rect: sticky.rect, point: point)
            return
        }
        guard let rowIndex = rowIndex(atCanvasPoint: point) else { return }
        activateRow(at: rowIndex, point: point)
    }

    /// Tap behaviour for a row, shared with VoiceOver activation (no point).
    func activateRow(at rowIndex: Int, point: CGPoint?) {
        let row = rows[rowIndex]
        switch row.kind {
        case .line:
            onLinePress?(ReviewDiffLinePress(rowID: row.id, fileID: row.fileID, gesture: .tap))
        case .file:
            guard let rect = frame(forRowAt: rowIndex) else { return }
            handleFileHeaderTap(rowIndex: rowIndex, rect: rect, point: point)
        case .hunk, .notice:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        if let sticky = stickyHeaderTarget(), sticky.rect.contains(point) { return }
        guard let rowIndex = rowIndex(atCanvasPoint: point), let row = rows[safe: rowIndex], row.line != nil else { return }
        onLinePress?(ReviewDiffLinePress(rowID: row.id, fileID: row.fileID, gesture: .longPress))
    }

    /// The checkbox toggles viewed; anywhere else on the header toggles collapse.
    private func handleFileHeaderTap(rowIndex: Int, rect: CGRect, point: CGPoint?) {
        let fileID = rows[rowIndex].fileID
        if let point, fileHeaderInteractiveRects(cardRect: rect).checkbox.contains(point) {
            onToggleViewed?(fileID)
            return
        }
        onToggleFile?(fileID)
    }

    @objc private func handleHorizontalPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopHorizontalDeceleration()
            let target = horizontalPanTarget(at: gesture.location(in: self))
            activePanFileID = target?.fileID
            activePanKind = target?.kind
            panStartHorizontalOffset = horizontalOffset(for: target?.fileID, kind: target?.kind ?? .code)
        case .changed, .ended, .cancelled:
            guard let fileID = activePanFileID, let kind = activePanKind else { return }
            let translation = gesture.translation(in: self)
            setHorizontalOffset(
                min(max(panStartHorizontalOffset - translation.x, 0), maxHorizontalOffset(for: fileID, kind: kind)),
                for: fileID,
                kind: kind
            )
            guard gesture.state != .changed else { return }
            activePanFileID = nil
            activePanKind = nil
            if gesture.state == .ended, kind == .code {
                startHorizontalDeceleration(fileID: fileID, velocity: -gesture.velocity(in: self).x)
            }
        default:
            break
        }
    }

    private func horizontalPanTarget(at point: CGPoint) -> (fileID: String, kind: HorizontalPanKind)? {
        if let sticky = stickyHeaderTarget(), sticky.rect.contains(point) {
            return (rows[sticky.rowIndex].fileID, .fileHeaderPath)
        }
        guard let rowIndex = rowIndex(atCanvasPoint: point) else { return nil }
        let row = rows[rowIndex]
        return (row.fileID, row.isFileHeader ? .fileHeaderPath : .code)
    }

    // MARK: - Horizontal offsets

    func horizontalOffset(for fileID: String?, kind: HorizontalPanKind = .code) -> CGFloat {
        guard let fileID else { return 0 }
        switch kind {
        case .code: return horizontalOffsetsByFileID[fileID] ?? 0
        case .fileHeaderPath: return headerPathOffsetsByFileID[fileID] ?? 0
        }
    }

    private func setHorizontalOffset(_ offset: CGFloat, for fileID: String, kind: HorizontalPanKind) {
        switch kind {
        case .code: horizontalOffsetsByFileID[fileID] = offset
        case .fileHeaderPath: headerPathOffsetsByFileID[fileID] = offset
        }
        setNeedsDisplay()
    }

    private func clampHorizontalOffsets() {
        for (fileID, offset) in horizontalOffsetsByFileID {
            horizontalOffsetsByFileID[fileID] = min(offset, maxHorizontalOffset(for: fileID, kind: .code))
        }
        for (fileID, offset) in headerPathOffsetsByFileID {
            headerPathOffsetsByFileID[fileID] = min(offset, maxHorizontalOffset(for: fileID, kind: .fileHeaderPath))
        }
    }

    func contentWidth(for fileID: String) -> CGFloat {
        contentWidthsByFileID[fileID] ?? min(style.maxContentWidth, max(viewportWidth, 0))
    }

    func maxHorizontalOffset(for fileID: String, kind: HorizontalPanKind) -> CGFloat {
        switch kind {
        case .fileHeaderPath:
            guard let header = rows.first(where: { $0.fileID == fileID && $0.isFileHeader })?.fileHeader else { return 0 }
            return maxHeaderPathOffset(for: header)
        case .code:
            guard !wrapsLines else { return 0 }
            return max(0, contentWidth(for: fileID) - max(0, viewportWidth - style.codeStartX))
        }
    }

    func maxHeaderPathOffset(for header: ReviewDiffFileHeader) -> CGFloat {
        let cardRect = CGRect(x: 0, y: 0, width: max(bounds.width, viewportWidth), height: style.metrics.fileHeaderHeight)
        let pathRect = fileHeaderPathRect(for: header, cardRect: cardRect)
        return max(0, textWidth(header.displayPath, font: style.fileHeaderFont) - pathRect.width)
    }

    private func startHorizontalDeceleration(fileID: String, velocity: CGFloat) {
        guard abs(velocity) > 80 else { return }
        let currentOffset = horizontalOffset(for: fileID)
        let maxOffset = maxHorizontalOffset(for: fileID, kind: .code)
        if (currentOffset <= 0 && velocity < 0) || (currentOffset >= maxOffset && velocity > 0) { return }

        stopHorizontalDeceleration()
        deceleratingFileID = fileID
        horizontalVelocity = velocity
        lastDecelerationTimestamp = 0
        let displayLink = CADisplayLink(target: self, selector: #selector(stepHorizontalDeceleration(_:)))
        displayLink.add(to: .main, forMode: .common)
        decelerationDisplayLink = displayLink
    }

    @objc private func stepHorizontalDeceleration(_ displayLink: CADisplayLink) {
        guard let fileID = deceleratingFileID else {
            stopHorizontalDeceleration()
            return
        }
        if lastDecelerationTimestamp == 0 {
            lastDecelerationTimestamp = displayLink.timestamp
            return
        }
        let dt = max(0, displayLink.timestamp - lastDecelerationTimestamp)
        lastDecelerationTimestamp = displayLink.timestamp

        let maxOffset = maxHorizontalOffset(for: fileID, kind: .code)
        let next = min(max(horizontalOffset(for: fileID) + horizontalVelocity * CGFloat(dt), 0), maxOffset)
        setHorizontalOffset(next, for: fileID, kind: .code)

        // UIScrollView deceleration rates are expressed per millisecond.
        horizontalVelocity *= CGFloat(pow(Double(UIScrollView.DecelerationRate.normal.rawValue), dt * 1000))
        if abs(horizontalVelocity) < 20 || next <= 0 || next >= maxOffset {
            stopHorizontalDeceleration()
        }
    }

    private func stopHorizontalDeceleration() {
        decelerationDisplayLink?.invalidate()
        decelerationDisplayLink = nil
        deceleratingFileID = nil
        horizontalVelocity = 0
        lastDecelerationTimestamp = 0
    }

    func textWidth(_ text: String, font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font, .ligature: 0]).width)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
