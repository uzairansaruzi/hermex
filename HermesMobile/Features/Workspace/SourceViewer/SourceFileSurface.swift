import SwiftUI
import UIKit

/// A workspace file on the review surface: line gutter, optional wrap, syntax colour
/// for the rows on screen, tap-to-select with Copy, and an initial line placed 30 %
/// down the viewport and highlighted.
struct SourceFileSurface: View {
    static let wrapsLinesKey = "workspace.sourceViewer.wrapsLines"

    let content: String
    let targetLine: Int?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var viewModel: SourceFileViewModel
    @State private var selection = ReviewDiffSelection()
    @State private var scrollTarget: ReviewDiffScrollTarget?
    @AppStorage(SourceFileSurface.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    init(
        content: String,
        path: String,
        serverLanguage: String?,
        targetLine: Int? = nil,
        isRefreshing: Bool = false,
        onRefresh: @escaping () -> Void = {}
    ) {
        self.content = content
        self.targetLine = targetLine
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        _viewModel = State(initialValue: SourceFileViewModel(path: path, serverLanguage: serverLanguage))
    }

    private var selectedRowIDs: Set<String> { selection.selectedRowIDs(in: viewModel.rows) }

    var body: some View {
        ReviewDiffSurface(
            rows: viewModel.rows,
            rowsVersion: viewModel.rowsVersion,
            collapsedFileIDs: [],
            viewedFileIDs: [],
            selectedRowIDs: selectedRowIDs,
            isRefreshing: isRefreshing,
            scrollTarget: scrollTarget,
            presentation: .source,
            wrapsLines: wrapsLines,
            tokensByRowID: viewModel.tokensByRowID,
            tokensVersion: viewModel.tokensVersion,
            onVisibleRowRangeChange: { viewModel.visibleRowRangeChanged($0) },
            onToggleFile: { _ in },
            onToggleViewed: { _ in },
            onLinePress: handleLinePress,
            onRefresh: onRefresh
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if viewModel.isPlainText { plainTextChip }
        }
        .safeAreaInset(edge: .bottom) {
            let selected = selectedRowIDs
            if !selected.isEmpty { selectionBar(count: selected.count) }
        }
        .task(id: content) {
            await viewModel.load(content: content)
            seedTargetLineIfNeeded()
        }
        .onChange(of: colorScheme, initial: true) {
            viewModel.setColorScheme(isDark: colorScheme == .dark)
        }
    }

    /// Quiet notice that this file has no syntax colour; sits in the surface's top inset.
    private var plainTextChip: some View {
        HStack {
            Spacer()
            Text("Plain text")
                .font(AppFont.caption2(weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
    }

    private func selectionBar(count: Int) -> some View {
        HStack(spacing: 12) {
            Text(count == 1 ? String(localized: "1 line selected") : String(localized: "\(count) lines selected"))
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clear") { selection.clear() }
                .font(AppFont.footnote())
            // A label-coloured pill needs a background-coloured title, or dark mode
            // draws white on white.
            Button(action: copySelection) {
                Text("Copy")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(Color(.systemBackground))
            }
            .buttonStyle(.borderedProminent)
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    /// The requested line is selected and scrolled to once, when the rows first exist.
    private func seedTargetLineIfNeeded() {
        guard let targetLine, scrollTarget == nil, selection.isEmpty,
              targetLine >= 1, targetLine <= viewModel.rows.count else { return }
        let rowID = SourceFileRows.rowID(forLineIndex: targetLine - 1)
        selection.tap(rowID: rowID, fileID: SourceFileRows.fileID)
        scrollTarget = ReviewDiffScrollTarget(anchor: .row(rowID), token: UUID())
    }

    private func handleLinePress(_ press: ReviewDiffLinePress) {
        switch press.gesture {
        case .tap: selection.tap(rowID: press.rowID, fileID: press.fileID)
        case .longPress: selection.longPress(rowID: press.rowID, fileID: press.fileID)
        }
        ChatHaptics.diffLineSelected(isEnabled: isHapticsEnabled)
    }

    /// Copies the selected lines, blank ones included, so a selection always answers.
    private func copySelection() {
        let selected = selection.selectedRows(in: viewModel.rows)
        guard !selected.isEmpty else { return }
        UIPasteboard.general.string = selected.compactMap { $0.line?.content }.joined(separator: "\n")
        ChatHaptics.copied(isEnabled: isHapticsEnabled)
        selection.clear()
    }
}
