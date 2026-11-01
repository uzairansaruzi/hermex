import SwiftUI
import UIKit

/// A workspace file on the review surface: line gutter, optional wrap, syntax colour
/// for the rows on screen, tap-to-select with Copy (and Comment… when the host has a
/// chat draft), and an initial line placed 30 % down the viewport and highlighted.
struct SourceFileSurface: View {
    static let wrapsLinesKey = "workspace.sourceViewer.wrapsLines"

    let content: String
    let targetLine: Int?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    /// Appends a comment and its quoted lines to the chat draft. Nil hides Comment….
    let onAddToPrompt: ((String) -> Void)?
    /// Closes back to the chat once a comment was added; nil where ordinary back
    /// navigation does that.
    let onReturnToChat: (() -> Void)?

    private let path: String
    private let serverLanguage: String?
    @State private var viewModel: SourceFileViewModel
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
        onRefresh: @escaping () -> Void = {},
        onAddToPrompt: ((String) -> Void)? = nil,
        onReturnToChat: (() -> Void)? = nil
    ) {
        self.content = content
        self.targetLine = targetLine
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.onAddToPrompt = onAddToPrompt
        self.onReturnToChat = onReturnToChat
        self.path = path
        self.serverLanguage = serverLanguage
        _viewModel = State(initialValue: SourceFileViewModel(path: path, serverLanguage: serverLanguage))
    }

    private var selectedRowIDs: Set<String> { viewModel.selection.selectedRowIDs(in: viewModel.rows) }

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
            if !selected.isEmpty {
                selectionBar(count: selected.count)
            } else if viewModel.commentComposer.addedCount > 0 {
                ReviewCommentStatusBar(addedCount: viewModel.commentComposer.addedCount, onReturnToChat: onReturnToChat)
            }
        }
        .sheet(item: $viewModel.commentComposer.context) { context in
            ReviewCommentSheet(context: context, onAdd: addComment)
        }
        // A refresh may renumber the lines (the model drops them again when new rows land).
        .onChange(of: isRefreshing) {
            if isRefreshing { viewModel.dropSelection() }
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
            Button("Clear") { viewModel.selection.clear() }
                .font(AppFont.footnote())
            if onAddToPrompt != nil {
                Button(action: copySelection) {
                    Text("Copy")
                        .font(AppFont.footnote(weight: .semibold))
                }
                .buttonStyle(.bordered)
                prominentButton("Comment…") {
                    let language = SourceHighlightLanguage.resolve(path: path, serverLanguage: serverLanguage)
                    viewModel.commentComposer.context = viewModel.selection.sourceCommentContext(in: viewModel.rows, path: path, language: language)
                }
            } else {
                prominentButton("Copy", action: copySelection)
            }
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    /// A label-coloured pill needs a background-coloured title, or dark mode draws
    /// white on white.
    private func prominentButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color(.systemBackground))
        }
        .buttonStyle(.borderedProminent)
    }

    /// The requested line is selected and scrolled to once, when the rows first exist.
    private func seedTargetLineIfNeeded() {
        guard let targetLine, scrollTarget == nil, viewModel.selection.isEmpty,
              targetLine >= 1, targetLine <= viewModel.rows.count else { return }
        let rowID = SourceFileRows.rowID(forLineIndex: targetLine - 1)
        viewModel.selection.tap(rowID: rowID, fileID: SourceFileRows.fileID)
        scrollTarget = ReviewDiffScrollTarget(anchor: .row(rowID), token: UUID())
    }

    private func handleLinePress(_ press: ReviewDiffLinePress) {
        switch press.gesture {
        case .tap: viewModel.selection.tap(rowID: press.rowID, fileID: press.fileID)
        case .longPress: viewModel.selection.longPress(rowID: press.rowID, fileID: press.fileID)
        }
        ChatHaptics.diffLineSelected(isEnabled: isHapticsEnabled)
    }

    private func addComment(_ comment: String) {
        guard let markdown = viewModel.commentComposer.add(comment: comment) else { return }
        onAddToPrompt?(markdown)
        ChatHaptics.addedToPrompt(isEnabled: isHapticsEnabled)
        viewModel.selection.clear()
    }

    /// Copies the selected lines, blank ones included, so a selection always answers.
    private func copySelection() {
        let selected = viewModel.selection.selectedRows(in: viewModel.rows)
        guard !selected.isEmpty else { return }
        UIPasteboard.general.string = selected.compactMap { $0.line?.content }.joined(separator: "\n")
        ChatHaptics.copied(isEnabled: isHapticsEnabled)
        viewModel.selection.clear()
    }
}
