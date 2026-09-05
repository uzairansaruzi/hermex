import SwiftUI

/// Every changed file in one scroll: sticky file headers, per-file collapse and viewed
/// state, word-level highlights, and line selection that feeds the composer. Diffs
/// load one file at a time (a few in flight) so the first file paints before the rest
/// arrive; rows rebuild off the main thread as each answer lands.
struct GitDiffView: View {
    let onAPIError: (Error) -> Void
    /// Receives the selected lines as Markdown. Nil hides "Add to prompt", for hosts
    /// with no composer to add to.
    let onAddToPrompt: ((String) -> Void)?

    private let session: SessionSummary
    private let files: [GitFile]
    private let initialFile: GitFile?
    private let apiClient: APIClient

    @State private var statesByFileID: [String: ReviewDiffFileState] = [:]
    @State private var rows: [ReviewDiffRow] = []
    @State private var rowsVersion = 0
    @State private var rowsBuildGeneration = 0
    @State private var loadGeneration = 0
    @State private var hasLoaded = false
    @State private var isRefreshing = false
    @State private var collapsedFileIDs: Set<String> = []
    @State private var viewedFileIDs: Set<String> = []
    @State private var selection = ReviewDiffSelection()
    @State private var scrollTarget: ReviewDiffScrollTarget?
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dismiss) private var dismiss

    private static let maxConcurrentDiffLoads = 4

    init(
        session: SessionSummary,
        server: URL,
        files: [GitFile],
        initialFile: GitFile? = nil,
        onAPIError: @escaping (Error) -> Void,
        onAddToPrompt: ((String) -> Void)? = nil
    ) {
        self.session = session
        self.files = files
        self.initialFile = initialFile
        self.apiClient = APIClient(baseURL: server)
        self.onAPIError = onAPIError
        self.onAddToPrompt = onAddToPrompt
        _scrollTarget = State(initialValue: initialFile.map { ReviewDiffScrollTarget(fileID: $0.id, token: UUID()) })
    }

    private var title: String {
        if files.count == 1, let file = files.first { return file.displayPath }
        return String(localized: "\(files.count) files changed")
    }

    private var selectedRowIDs: Set<String> { selection.selectedRowIDs(in: rows) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
                .safeAreaInset(edge: .bottom) {
                    let selected = selectedRowIDs
                    if !selected.isEmpty { selectionBar(count: selected.count) }
                }
                .task {
                    guard !hasLoaded else { return }
                    hasLoaded = true
                    await load()
                }
        }
        .presentationDetents([.medium, .large])
        .adaptivePagePresentation()
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
        } else {
            ReviewDiffSurface(
                rows: rows,
                rowsVersion: rowsVersion,
                collapsedFileIDs: collapsedFileIDs,
                viewedFileIDs: viewedFileIDs,
                selectedRowIDs: selectedRowIDs,
                isRefreshing: isRefreshing,
                scrollTarget: scrollTarget,
                onToggleFile: toggleFile,
                onToggleViewed: toggleViewed,
                onLinePress: handleLinePress,
                onRefresh: { Task { await refresh() } }
            )
        }
    }

    private func selectionBar(count: Int) -> some View {
        HStack(spacing: 12) {
            Text(count == 1 ? String(localized: "1 line selected") : String(localized: "\(count) lines selected"))
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Clear") { selection.clear() }
                .font(AppFont.footnote())
            if onAddToPrompt != nil {
                Button("Add to prompt", action: addToPrompt)
                    .font(AppFont.footnote(weight: .semibold))
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Interaction

    private func toggleFile(_ fileID: String) {
        if collapsedFileIDs.contains(fileID) {
            collapsedFileIDs.remove(fileID)
        } else {
            collapsedFileIDs.insert(fileID)
        }
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
    }

    /// Marking a file viewed also collapses it; un-viewing leaves it collapsed.
    private func toggleViewed(_ fileID: String) {
        if viewedFileIDs.contains(fileID) {
            viewedFileIDs.remove(fileID)
        } else {
            viewedFileIDs.insert(fileID)
            collapsedFileIDs.insert(fileID)
        }
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
    }

    private func handleLinePress(_ press: ReviewDiffLinePress) {
        switch press.gesture {
        case .tap: selection.tap(rowID: press.rowID, fileID: press.fileID)
        case .longPress: selection.longPress(rowID: press.rowID, fileID: press.fileID)
        }
        ChatHaptics.diffLineSelected(isEnabled: isHapticsEnabled)
    }

    private func addToPrompt() {
        guard let snippet = selection.snippet(in: rows) else { return }
        onAddToPrompt?(snippet)
        ChatHaptics.addedToPrompt(isEnabled: isHapticsEnabled)
        selection.clear()
    }

    // MARK: - Loading

    private func refresh() async {
        isRefreshing = true
        selection.clear()
        await load()
        isRefreshing = false
    }

    @MainActor
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let sessionID = session.sessionId else {
            let message = String(localized: "Session ID is missing.")
            for file in files { statesByFileID[file.id] = .failed(message) }
            rebuildRows()
            return
        }
        for file in files { statesByFileID[file.id] = .loading }
        rebuildRows()

        // The file the reader asked for loads first; the rest follow a few at a time.
        var ordered = files
        if let initialFile, let index = ordered.firstIndex(of: initialFile) {
            ordered.remove(at: index)
            ordered.insert(initialFile, at: 0)
        }
        var reportedError = false
        await withTaskGroup(of: FileDiffResult.self) { group in
            var pending = ordered.makeIterator()
            func enqueueNext() {
                guard let file = pending.next() else { return }
                let client = apiClient
                group.addTask { await Self.fetchDiff(for: file, sessionID: sessionID, apiClient: client) }
            }
            for _ in 0..<Self.maxConcurrentDiffLoads { enqueueNext() }
            for await result in group {
                guard generation == loadGeneration else {
                    group.cancelAll()
                    return
                }
                statesByFileID[result.fileID] = result.state
                if let error = result.error, !reportedError {
                    reportedError = true
                    onAPIError(error)
                }
                rebuildRows()
                enqueueNext()
            }
        }
    }

    private struct FileDiffResult {
        let fileID: String
        let state: ReviewDiffFileState
        let error: Error?
    }

    private static func fetchDiff(for file: GitFile, sessionID: String, apiClient: APIClient) async -> FileDiffResult {
        do {
            let diff = try await apiClient.gitDiff(
                sessionID: sessionID,
                path: file.displayPath,
                kind: file.preferredDiffKind
            ).diff
            guard let diff else {
                return FileDiffResult(fileID: file.id, state: .failed(String(localized: "Could Not Load Changes")), error: nil)
            }
            return FileDiffResult(fileID: file.id, state: .loaded(diff), error: nil)
        } catch {
            return FileDiffResult(fileID: file.id, state: .failed(error.localizedDescription), error: error)
        }
    }

    /// Rows build off the main thread; a newer build supersedes an older one.
    private func rebuildRows() {
        rowsBuildGeneration += 1
        let generation = rowsBuildGeneration
        let inputs = files.map { ReviewDiffFileInput(file: $0, state: statesByFileID[$0.id] ?? .loading) }
        Task.detached(priority: .userInitiated) {
            let built = ReviewDiffRowBuilder.rows(for: inputs)
            await MainActor.run {
                guard generation == rowsBuildGeneration else { return }
                rows = built
                rowsVersion += 1
            }
        }
    }
}

struct DiffHunk: Identifiable, Equatable {
    let id: Int
    let header: String
    let lines: [DiffLine]
    let isSynthetic: Bool
    let patchNumber: Int
    let patchCount: Int
    let newStart: Int?
    let newCount: Int?

    var additions: Int { lines.filter { $0.kind == .addition }.count }
    var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    var displayLabel: String {
        if isSynthetic { return "Patch \(patchNumber) of \(patchCount)" }
        guard let start = newStart else { return header }
        let count = max(newCount ?? 1, 1)
        return count == 1 ? "Line \(start)" : "Lines \(start)-\(start + count - 1)"
    }

    static func parse(_ raw: String) -> [DiffHunk] {
        guard !raw.isEmpty else { return [] }
        let allLines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerIndexes = allLines.indices.filter { allLines[$0].hasPrefix("@@") }

        if headerIndexes.isEmpty {
            var groups: [[String]] = []
            var current: [String] = []
            for line in allLines {
                if line.hasPrefix("diff --git") {
                    if !current.isEmpty { groups.append(current) }
                    current = []
                } else if isPatchLine(line) {
                    current.append(line)
                }
            }
            if !current.isEmpty { groups.append(current) }
            guard !groups.isEmpty else { return [] }
            return groups.enumerated().map { index, lines in
                makeHunk(
                    id: index,
                    header: "",
                    rawLines: lines,
                    synthetic: true,
                    patchNumber: index + 1,
                    patchCount: groups.count
                )
            }
        }

        return headerIndexes.enumerated().map { offset, index in
            let end = offset + 1 < headerIndexes.count ? headerIndexes[offset + 1] : allLines.endIndex
            return makeHunk(
                id: offset,
                header: allLines[index],
                rawLines: Array(allLines[(index + 1)..<end]),
                synthetic: false,
                patchNumber: offset + 1,
                patchCount: headerIndexes.count
            )
        }
    }

    private static func makeHunk(
        id: Int,
        header: String,
        rawLines: [String],
        synthetic: Bool,
        patchNumber: Int,
        patchCount: Int
    ) -> DiffHunk {
        let range = parseRange(header)
        var oldLine = range.oldStart
        var newLine = range.newStart
        let lines = rawLines.enumerated().map { offset, rawLine -> DiffLine in
            let kind = DiffLine.Kind(rawLine)
            let isMarker = rawLine.hasPrefix("\\")
            let line = DiffLine(
                id: offset,
                kind: kind,
                text: rawLine,
                oldLineNumber: isMarker || kind == .addition ? nil : oldLine,
                newLineNumber: isMarker || kind == .deletion ? nil : newLine
            )
            if !isMarker, kind != .addition { oldLine = oldLine.map { $0 + 1 } }
            if !isMarker, kind != .deletion { newLine = newLine.map { $0 + 1 } }
            return line
        }
        return DiffHunk(
            id: id,
            header: header,
            lines: lines,
            isSynthetic: synthetic,
            patchNumber: patchNumber,
            patchCount: patchCount,
            newStart: range.newStart,
            newCount: range.newCount
        )
    }

    private static func parseRange(_ header: String) -> (oldStart: Int?, newStart: Int?, newCount: Int?) {
        let pieces = header.split(separator: " ")
        guard pieces.count >= 3 else { return (nil, nil, nil) }
        func values(_ token: Substring) -> (Int?, Int?) {
            let cleaned = token.dropFirst()
            let values = cleaned.split(separator: ",", maxSplits: 1).compactMap { Int($0) }
            return (values.first, values.count > 1 ? values[1] : 1)
        }
        let old = values(pieces[1])
        let new = values(pieces[2])
        return (old.0, new.0, new.1)
    }

    private static func isPatchLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if line.hasPrefix("+++ b/") || line == "+++ /dev/null" { return false }
        if line.hasPrefix("--- a/") || line == "--- /dev/null" { return false }
        return first == "+" || first == "-" || first == " " || first == "\\"
    }
}

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case addition, deletion, context

        init(_ line: String) {
            switch line.first {
            case "+": self = .addition
            case "-": self = .deletion
            default: self = .context
            }
        }
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}
