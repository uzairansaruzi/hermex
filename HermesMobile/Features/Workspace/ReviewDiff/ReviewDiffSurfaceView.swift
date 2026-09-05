import UIKit

/// Scroll host for `ReviewDiffCanvasView`. The canvas is exactly one viewport tall and
/// rides along with the content offset, so scrolling repaints rows instead of laying
/// out views. Also owns pull-to-refresh, scroll-to-file, and the scroll anchor that
/// keeps the file under the reader still when rows above it change height.
final class ReviewDiffSurfaceView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let canvas = ReviewDiffCanvasView()
    private let refreshControl = UIRefreshControl()
    private var pendingScrollFileID: String?
    private var pendingScrollAnimated = false

    var onPullToRefresh: (() -> Void)?
    var onToggleFile: ((String) -> Void)? {
        get { canvas.onToggleFile }
        set { canvas.onToggleFile = newValue }
    }
    var onToggleViewed: ((String) -> Void)? {
        get { canvas.onToggleViewed }
        set { canvas.onToggleViewed = newValue }
    }
    var onLinePress: ((ReviewDiffLinePress) -> Void)? {
        get { canvas.onLinePress }
        set { canvas.onLinePress = newValue }
    }

    var rows: [ReviewDiffRow] { canvas.rows }
    var collapsedFileIDs: Set<String> { canvas.collapsedFileIDs }
    var viewedFileIDs: Set<String> {
        get { canvas.viewedFileIDs }
        set { canvas.viewedFileIDs = newValue }
    }
    var selectedRowIDs: Set<String> {
        get { canvas.selectedRowIDs }
        set { canvas.selectedRowIDs = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = canvas.theme.background

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.clipsToBounds = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = canvas.theme.background
        refreshControl.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
        scrollView.refreshControl = refreshControl
        addSubview(scrollView)
        scrollView.addSubview(canvas)

        canvas.onContentHeightChange = { [weak self] in self?.updateContentMetrics() }
        canvas.onRevealRow = { [weak self] rowIndex in self?.revealRow(at: rowIndex) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if canvas.viewportWidth != bounds.width {
            canvas.viewportWidth = bounds.width
        }
        updateContentMetrics()
    }

    // MARK: - Inputs

    /// Replaces the rows, keeping the file at the top of the viewport where it was.
    func setRows(_ rows: [ReviewDiffRow]) {
        let anchor = currentAnchor()
        canvas.setRows(rows)
        restore(anchor)
        applyPendingScrollIfNeeded()
    }

    /// Collapsing one file keeps its header where it is drawn (pinned at the top when
    /// sticky), so the reader is not thrown to a different file.
    func setCollapsedFileIDs(_ collapsedFileIDs: Set<String>) {
        let changed = canvas.collapsedFileIDs.symmetricDifference(collapsedFileIDs)
        var anchor: Anchor?
        if changed.count == 1, let fileID = changed.first, let screenY = canvas.scrollAnchorScreenY(forFileID: fileID) {
            anchor = Anchor(fileID: fileID, screenY: screenY)
        }
        canvas.setCollapsedFileIDs(collapsedFileIDs)
        restore(anchor)
    }

    func scrollToFile(_ fileID: String, animated: Bool) {
        pendingScrollFileID = fileID
        pendingScrollAnimated = animated
        applyPendingScrollIfNeeded()
    }

    /// The host owns the spinner: it stays until the reload finishes, not until the
    /// gesture ends.
    func setRefreshing(_ refreshing: Bool) {
        if refreshing {
            if !refreshControl.isRefreshing { refreshControl.beginRefreshing() }
        } else if refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
    }

    @objc private func handlePullToRefresh() {
        onPullToRefresh?()
    }

    // MARK: - Scroll anchoring

    private struct Anchor {
        let fileID: String
        /// Header top relative to the viewport top; negative while scrolled into the file.
        let screenY: CGFloat
    }

    private func currentAnchor() -> Anchor? {
        let offset = scrollView.contentOffset.y
        guard offset > 0.5,
              let fileID = canvas.layout.visibleFileID(atVerticalOffset: offset),
              let headerOffset = canvas.layout.fileHeaderOffset(forFileID: fileID) else { return nil }
        return Anchor(fileID: fileID, screenY: headerOffset - offset)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let headerOffset = canvas.layout.fileHeaderOffset(forFileID: anchor.fileID) else { return }
        setVerticalOffset(headerOffset - anchor.screenY, animated: false)
    }

    private func applyPendingScrollIfNeeded() {
        guard let fileID = pendingScrollFileID, bounds.height > 0 else { return }
        guard let headerOffset = canvas.layout.fileHeaderOffset(forFileID: fileID) else {
            if !rows.isEmpty { pendingScrollFileID = nil }
            return
        }
        pendingScrollFileID = nil
        setVerticalOffset(headerOffset, animated: pendingScrollAnimated)
    }

    private func setVerticalOffset(_ target: CGFloat, animated: Bool) {
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let clamped = min(max(target, 0), maxOffset)
        let shouldAnimate = animated && abs(scrollView.contentOffset.y - clamped) > 0.5
        scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: shouldAnimate)
        if !shouldAnimate { updateViewportFrame() }
    }

    private func revealRow(at rowIndex: Int) {
        guard let frame = canvas.layout.frame(forRowAt: rowIndex) else { return }
        scrollView.scrollRectToVisible(CGRect(x: 0, y: frame.minY, width: 1, height: frame.height), animated: false)
        updateViewportFrame()
    }

    // MARK: - Viewport

    private func updateContentMetrics() {
        scrollView.contentSize = CGSize(width: bounds.width, height: max(bounds.height, canvas.contentHeight))
        updateViewportFrame()
        applyPendingScrollIfNeeded()
    }

    private func updateViewportFrame() {
        canvas.frame = CGRect(
            x: 0,
            y: scrollView.contentOffset.y,
            width: max(bounds.width, 1),
            height: max(bounds.height, 1)
        )
        canvas.verticalOffset = scrollView.contentOffset.y
        canvas.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateViewportFrame()
    }
}
