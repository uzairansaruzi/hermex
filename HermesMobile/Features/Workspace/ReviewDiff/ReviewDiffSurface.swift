import SwiftUI

struct ReviewDiffScrollTarget: Equatable {
    enum Anchor: Equatable {
        case fileHeader(String)
        case row(String)
    }

    let anchor: Anchor
    let token: UUID

    init(anchor: Anchor, token: UUID) {
        self.anchor = anchor
        self.token = token
    }

    init(fileID: String, token: UUID) {
        self.init(anchor: .fileHeader(fileID), token: token)
    }
}

struct ReviewDiffSurface: UIViewRepresentable {
    let rows: [ReviewDiffRow]
    let rowsVersion: Int
    let collapsedFileIDs: Set<String>
    let viewedFileIDs: Set<String>
    let selectedRowIDs: Set<String>
    let isRefreshing: Bool
    let scrollTarget: ReviewDiffScrollTarget?
    var presentation: ReviewDiffPresentation = .diff
    var wrapsLines = false
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?
    var tokensByRowID: [String: [SourceHighlightRun]] = [:]
    var tokensVersion = 0
    var onVisibleRowRangeChange: ((ClosedRange<Int>?) -> Void)? = nil
    let onToggleFile: (String) -> Void
    let onToggleViewed: (String) -> Void
    let onLinePress: (ReviewDiffLinePress) -> Void
    let onRefresh: () -> Void

    final class Coordinator {
        var onToggleFile: (String) -> Void = { _ in }
        var onToggleViewed: (String) -> Void = { _ in }
        var onLinePress: (ReviewDiffLinePress) -> Void = { _ in }
        var onRefresh: () -> Void = {}
        var onVisibleRowRangeChange: ((ClosedRange<Int>?) -> Void)?
        var appliedRowsVersion = -1
        var appliedTokensVersion = -1
        var appliedScrollToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ReviewDiffSurfaceView {
        let view = ReviewDiffSurfaceView(presentation: presentation)
        let coordinator = context.coordinator
        view.onToggleFile = { coordinator.onToggleFile($0) }
        view.onToggleViewed = { coordinator.onToggleViewed($0) }
        view.onLinePress = { coordinator.onLinePress($0) }
        view.onPullToRefresh = { coordinator.onRefresh() }
        view.onVisibleRowRangeChange = { coordinator.onVisibleRowRangeChange?($0) }
        return view
    }

    func updateUIView(_ view: ReviewDiffSurfaceView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleFile = onToggleFile
        coordinator.onToggleViewed = onToggleViewed
        coordinator.onLinePress = onLinePress
        coordinator.onRefresh = onRefresh
        coordinator.onVisibleRowRangeChange = onVisibleRowRangeChange

        if coordinator.appliedRowsVersion != rowsVersion {
            coordinator.appliedRowsVersion = rowsVersion
            view.setRows(rows)
        }
        if view.wrapsLines != wrapsLines { view.wrapsLines = wrapsLines }
        view.customCodeSize = customCodeSize.map { CGFloat($0) }
        view.fontFamily = AppFontSettings.shared.family
        if coordinator.appliedTokensVersion != tokensVersion {
            coordinator.appliedTokensVersion = tokensVersion
            view.tokensByRowID = tokensByRowID
        }
        view.setCollapsedFileIDs(collapsedFileIDs)
        if view.viewedFileIDs != viewedFileIDs { view.viewedFileIDs = viewedFileIDs }
        if view.selectedRowIDs != selectedRowIDs { view.selectedRowIDs = selectedRowIDs }
        view.setRefreshing(isRefreshing)

        if let scrollTarget, coordinator.appliedScrollToken != scrollTarget.token {
            coordinator.appliedScrollToken = scrollTarget.token
            view.scroll(to: scrollTarget.anchor, animated: false)
        }
    }
}
