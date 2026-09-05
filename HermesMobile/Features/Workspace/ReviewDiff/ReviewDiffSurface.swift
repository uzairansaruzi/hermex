import SwiftUI

/// One-shot scroll request; a new token scrolls again even to the same file.
struct ReviewDiffScrollTarget: Equatable {
    let fileID: String
    let token: UUID
}

/// SwiftUI face of the review surface. The host owns every piece of state (rows,
/// collapse, viewed, selection, refresh) and this bridge pushes only what changed.
struct ReviewDiffSurface: UIViewRepresentable {
    let rows: [ReviewDiffRow]
    /// Bumped by the host whenever `rows` is replaced, so the bridge never compares
    /// thousands of rows to notice a change.
    let rowsVersion: Int
    let collapsedFileIDs: Set<String>
    let viewedFileIDs: Set<String>
    let selectedRowIDs: Set<String>
    let isRefreshing: Bool
    let scrollTarget: ReviewDiffScrollTarget?
    let onToggleFile: (String) -> Void
    let onToggleViewed: (String) -> Void
    let onLinePress: (ReviewDiffLinePress) -> Void
    let onRefresh: () -> Void

    final class Coordinator {
        var onToggleFile: (String) -> Void = { _ in }
        var onToggleViewed: (String) -> Void = { _ in }
        var onLinePress: (ReviewDiffLinePress) -> Void = { _ in }
        var onRefresh: () -> Void = {}
        var appliedRowsVersion = -1
        var appliedScrollToken: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ReviewDiffSurfaceView {
        let view = ReviewDiffSurfaceView()
        let coordinator = context.coordinator
        view.onToggleFile = { coordinator.onToggleFile($0) }
        view.onToggleViewed = { coordinator.onToggleViewed($0) }
        view.onLinePress = { coordinator.onLinePress($0) }
        view.onPullToRefresh = { coordinator.onRefresh() }
        return view
    }

    func updateUIView(_ view: ReviewDiffSurfaceView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onToggleFile = onToggleFile
        coordinator.onToggleViewed = onToggleViewed
        coordinator.onLinePress = onLinePress
        coordinator.onRefresh = onRefresh

        if coordinator.appliedRowsVersion != rowsVersion {
            coordinator.appliedRowsVersion = rowsVersion
            view.setRows(rows)
        }
        view.setCollapsedFileIDs(collapsedFileIDs)
        if view.viewedFileIDs != viewedFileIDs { view.viewedFileIDs = viewedFileIDs }
        if view.selectedRowIDs != selectedRowIDs { view.selectedRowIDs = selectedRowIDs }
        view.setRefreshing(isRefreshing)

        if let scrollTarget, coordinator.appliedScrollToken != scrollTarget.token {
            coordinator.appliedScrollToken = scrollTarget.token
            view.scrollToFile(scrollTarget.fileID, animated: false)
        }
    }
}
