import SwiftUI

/// Every changed file in one scroll: sticky file headers, per-file collapse and viewed
/// state, word-level highlights, syntax colour for the rows on screen, optional line
/// wrap (shared with the source viewer), and line selection that feeds the composer.
/// Diffs load one file at a time (a few in flight) so the first file paints before the
/// rest arrive; each file's rows build once, off the main thread, as its answer lands.
/// Lockfiles, generated output, and huge changes fold once loaded (`ReviewDiffDefaultCollapse`),
/// except the file the user tapped or a single-file review. Folds and viewed marks last as long as
/// the chat (`ReviewProgressStore`), so a reopened review picks up where it was left; a file whose
/// patch changed since it was marked viewed reopens unviewed and unfolded.
struct GitDiffView: View {
    let onAPIError: (Error) -> Void
    /// Receives the selected lines as Markdown. Nil hides "Add to prompt", for hosts
    /// with no composer to add to.
    let onAddToPrompt: ((String) -> Void)?

    /// Nil for a webui session without an ID.
    private let git: (any GitDataClient)?
    private let files: [GitFile]
    private let initialFile: GitFile?
    /// The range `files` were listed in, which each diff reads (#1386).
    private let scope: GitReviewScope

    @State private var rows: [ReviewDiffRow] = []
    @State private var rowsVersion = 0
    @State private var loadGeneration = 0
    @State private var hasLoaded = false
    @State private var isRefreshing = false
    /// Cancelled as the sheet leaves, so a late answer can't reach the chat's review progress.
    @State private var refreshTask: Task<Void, Never>?
    @State private var review: ReviewDiffProgress
    @State private var selection = ReviewDiffSelection()
    @State private var scrollTarget: ReviewDiffScrollTarget?
    @State private var highlights = ReviewDiffHighlightModel()
    @AppStorage(SourceFileSurface.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private static let maxConcurrentDiffLoads = 4

    /// `scope` is the range `files` were listed in, and `base` the merge-base a branch's list was
    /// read against, which keys its review progress apart (`GitDataClient.progressScope`).
    init(
        git: (any GitDataClient)?,
        files: [GitFile],
        initialFile: GitFile? = nil,
        scope: GitReviewScope = .uncommitted,
        base: String? = nil,
        progress: ReviewProgressStore,
        onAPIError: @escaping (Error) -> Void,
        onAddToPrompt: ((String) -> Void)? = nil
    ) {
        self.git = git
        self.files = files
        self.initialFile = initialFile
        self.scope = scope
        self.onAPIError = onAPIError
        self.onAddToPrompt = onAddToPrompt
        _scrollTarget = State(initialValue: initialFile.map { ReviewDiffScrollTarget(fileID: $0.id, token: UUID()) })
        let progressScope = git?.progressScope(scope, base: base)
        _review = State(initialValue: ReviewDiffProgress(files: files, initialFile: initialFile, store: progress, scope: progressScope))
    }

    private var title: String {
        if files.count == 1, let file = files.first { return file.displayPath }
        return String(localized: "\(files.count) files changed")
    }

    private var selectedRowIDs: Set<String> { selection.selectedRowIDs(in: rows) }

    private var highlightAppearance: ReviewDiffHighlightModel.Appearance {
        ReviewDiffHighlightModel.Appearance(isDark: colorScheme == .dark, increasedContrast: colorSchemeContrast == .increased)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        diffActionsMenu
                        Button("Done") { dismiss() }
                    }
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
                .onChange(of: highlightAppearance, initial: true) { highlights.setAppearance(highlightAppearance) }
                .onChange(of: review.collapsedFileIDs, initial: true) { highlights.setCollapsedFileIDs(review.collapsedFileIDs) }
        }
        // On the sheet's root, so only dismissal (not a pushed screen) stops colour.
        .onDisappear {
            refreshTask?.cancel()
            highlights.cancel()
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
                collapsedFileIDs: review.collapsedFileIDs,
                viewedFileIDs: review.viewedFileIDs,
                selectedRowIDs: selectedRowIDs,
                isRefreshing: isRefreshing,
                scrollTarget: scrollTarget,
                wrapsLines: wrapsLines,
                tokensByRowID: highlights.tokensByRowID,
                tokensVersion: highlights.tokensVersion,
                onVisibleRowRangeChange: { highlights.visibleRowRangeChanged($0) },
                onToggleFile: toggleFile,
                onToggleViewed: toggleViewed,
                onLinePress: handleLinePress,
                onRefresh: {
                    refreshTask?.cancel()
                    refreshTask = Task { await refresh() }
                }
            )
        }
    }

    /// Presentation options for the whole sheet, matching the source viewer's menu.
    private var diffActionsMenu: some View {
        Menu {
            Toggle("Wrap Lines", systemImage: "text.justify.leading", isOn: $wrapsLines)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
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
        review.toggleFile(fileID)
        ChatHaptics.disclosureToggled(isEnabled: isHapticsEnabled)
    }

    /// Marking a file viewed also collapses it; un-viewing leaves it collapsed.
    private func toggleViewed(_ fileID: String) {
        review.toggleViewed(fileID)
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
        // A refresh can reuse row ids for different text; colour starts over.
        highlights.reset()
        guard let git else {
            let message = String(localized: "Session ID is missing.")
            publish(files.flatMap { ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: $0, state: .failed(message))) }, patches: [:])
            return
        }
        await ReviewDiffLoader.load(
            files: files,
            firstFile: initialFile,
            maxConcurrent: Self.maxConcurrentDiffLoads,
            fetch: { [scope] file in await Self.fetchDiff(for: file, in: scope, git: git) },
            // A dismissed sheet or a newer load owns the rest.
            isCurrent: { generation == loadGeneration },
            publish: publish,
            onError: onAPIError
        )
    }

    private func publish(_ built: [ReviewDiffRow], patches: [String: Int]) {
        rows = built
        review.apply(built, patches: patches)
        rowsVersion += 1
        highlights.setRows(built)
    }

    /// Nil when the request was cancelled: not a failure to show or report.
    private static func fetchDiff(for file: GitFile, in scope: GitReviewScope,
                                  git: any GitDataClient) async -> ReviewDiffLoader.FileResult? {
        do {
            guard let diff = try await git.diff(for: file, in: scope) else {
                return ReviewDiffLoader.FileResult(fileID: file.id, state: .failed(String(localized: "Could Not Load Changes")), error: nil)
            }
            return ReviewDiffLoader.FileResult(fileID: file.id, state: .loaded(diff), error: nil)
        } catch {
            if isCancellation(error) { return nil }
            return ReviewDiffLoader.FileResult(fileID: file.id, state: .failed(error.localizedDescription), error: error)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }
        return (underlying as? URLError)?.code == .cancelled
    }
}

/// Fetches per-file diffs a few at a time (the first file first) and publishes the
/// flat row list as answers land, with each loaded file's patch fingerprint
/// (`ReviewDiffProgress.patch(for:state:)`). Each file's rows and fingerprint build once,
/// next to its fetch and off the main actor, so a landed answer never re-parses the files
/// before it. The first answer publishes at once; later ones coalesce to one publish per
/// `interval` or per `batch` answers, so a large change set lays out a bounded number of times.
enum ReviewDiffLoader {
    struct FileResult {
        let fileID: String
        let state: ReviewDiffFileState
        let error: Error?
    }

    struct Coalescing {
        var interval: Duration = .milliseconds(150)
        var batch = 4
        /// Waits out the rest of an interval before a trailing publish.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    private enum Event {
        /// Nil when the fetch was cancelled.
        case file(FileResult?, [ReviewDiffRow], patch: Int?)
        /// Carries the token it was scheduled with; a publish in between makes it stale.
        case flush(Int)
    }

    /// Returns when every file has landed, or early once `isCurrent` turns false or the
    /// calling task is cancelled; nothing publishes after that.
    @MainActor
    static func load(
        files: [GitFile],
        firstFile: GitFile?,
        maxConcurrent: Int,
        coalescing: Coalescing = Coalescing(),
        fetch: @escaping @Sendable (GitFile) async -> FileResult?,
        buildRows: @escaping @Sendable (ReviewDiffFileInput) -> [ReviewDiffRow] = { ReviewDiffRowBuilder.rows(for: $0) },
        isCurrent: () -> Bool,
        publish: (_ rows: [ReviewDiffRow], _ patches: [String: Int]) -> Void,
        onError: (Error) -> Void
    ) async {
        var rowsByFileID: [String: [ReviewDiffRow]] = [:]
        for file in files {
            rowsByFileID[file.id] = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: file, state: .loading))
        }
        var patchesByFileID: [String: Int] = [:]
        let clock = ContinuousClock()
        var lastPublish: ContinuousClock.Instant?
        var pending = 0
        var scheduledFlush: Int?
        var flushCount = 0
        func publishRows() {
            publish(files.flatMap { rowsByFileID[$0.id] ?? [] }, patchesByFileID)
            pending = 0
            // Answers after this publish get a fresh interval, not the rest of an old one.
            scheduledFlush = nil
        }
        publishRows()

        var ordered = files
        if let firstFile, let index = ordered.firstIndex(of: firstFile) {
            ordered.remove(at: index)
            ordered.insert(firstFile, at: 0)
        }
        var inFlight = 0
        var reportedError = false
        await withTaskGroup(of: Event.self) { group in
            var queue = ordered.makeIterator()
            func enqueueNext() {
                guard let file = queue.next() else { return }
                inFlight += 1
                group.addTask {
                    guard let result = await fetch(file) else { return .file(nil, [], patch: nil) }
                    let rows = buildRows(ReviewDiffFileInput(file: file, state: result.state))
                    return .file(result, rows, patch: ReviewDiffProgress.patch(for: file, state: result.state))
                }
            }
            for _ in 0..<maxConcurrent { enqueueNext() }
            for await event in group {
                guard !Task.isCancelled, isCurrent() else {
                    group.cancelAll()
                    return
                }
                switch event {
                case .flush(let token):
                    guard token == scheduledFlush else { continue }
                    scheduledFlush = nil
                    if pending > 0 {
                        publishRows()
                        lastPublish = clock.now
                    }
                case .file(let result, let rows, let patch):
                    inFlight -= 1
                    guard let result else { continue }
                    rowsByFileID[result.fileID] = rows
                    patchesByFileID[result.fileID] = patch
                    pending += 1
                    if let error = result.error, !reportedError {
                        reportedError = true
                        onError(error)
                    }
                    enqueueNext()
                    if inFlight == 0 {
                        // Everything landed: paint it now and drop a waiting flush.
                        publishRows()
                        group.cancelAll()
                        continue
                    }
                    let now = clock.now
                    let elapsed = lastPublish.map { $0.duration(to: now) }
                    if let elapsed, elapsed < coalescing.interval, pending < coalescing.batch {
                        guard scheduledFlush == nil else { continue }
                        flushCount += 1
                        let token = flushCount
                        scheduledFlush = token
                        let delay = coalescing.interval - elapsed
                        let sleep = coalescing.sleep
                        group.addTask {
                            try? await sleep(delay)
                            return .flush(token)
                        }
                    } else {
                        publishRows()
                        lastPublish = now
                    }
                }
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
