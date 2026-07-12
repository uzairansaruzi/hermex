import SwiftUI

struct GitDiffView: View {
    let onAPIError: (Error) -> Void

    private let session: SessionSummary
    private let file: GitFile
    private let apiClient: APIClient
    @State private var diff: GitDiff?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var collapsedHunks: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    init(session: SessionSummary, server: URL, file: GitFile, onAPIError: @escaping (Error) -> Void) {
        self.session = session
        self.file = file
        self.apiClient = APIClient(baseURL: server)
        self.onAPIError = onAPIError
    }

    var body: some View {
        NavigationStack {
            content
                .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.workspace)
                .navigationTitle(file.displayPath)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
                .task {
                    guard !hasLoaded else { return }
                    hasLoaded = true
                    await load()
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && diff == nil {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if errorMessage != nil && diff == nil {
            ContentUnavailableView {
                Label("Could Not Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                if let errorMessage { Text(errorMessage) }
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else if let diff {
            diffBody(diff)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func diffBody(_ diff: GitDiff) -> some View {
        if diff.binary == true {
            ContentUnavailableView("Binary file changed", systemImage: "doc.badge.gearshape")
        } else if diff.tooLarge == true {
            ContentUnavailableView("Diff too large to show.", systemImage: "doc.badge.exclamationmark")
        } else {
            let hunks = DiffHunk.parse(diff.diff ?? "")
            if hunks.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle")
            } else {
                VStack(spacing: 0) {
                    summary(diff: diff, hunks: hunks)
                    GeometryReader { proxy in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(hunks) { hunk in
                                    hunkHeader(hunk)
                                    if !collapsedHunks.contains(hunk.id) {
                                        ForEach(hunk.lines) { DiffLineRow(line: $0) }
                                    }
                                }
                            }
                            // Pin the content to at least the viewport width so short lines
                            // still get full-width row backgrounds; longer lines scroll.
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                            .textSelection(.enabled)
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
    }

    private func summary(diff: GitDiff, hunks: [DiffHunk]) -> some View {
        HStack(spacing: 10) {
            Text("1 file changed").font(AppFont.subheadline(weight: .semibold))
            DiffCountsLabel(
                additions: diff.additions ?? hunks.reduce(0) { $0 + $1.additions },
                deletions: diff.deletions ?? hunks.reduce(0) { $0 + $1.deletions }
            )
            Spacer()
            Button(collapsedHunks.count == hunks.count ? "Expand All" : "Collapse All") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if collapsedHunks.count == hunks.count {
                        collapsedHunks.removeAll()
                    } else {
                        collapsedHunks = Set(hunks.map(\.id))
                    }
                }
            }
            .font(AppFont.mono(style: .caption))
            .foregroundStyle(.blue)
        }
        .padding(12)
        .background(Color(.systemBackground))
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        let collapsed = collapsedHunks.contains(hunk.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed { collapsedHunks.remove(hunk.id) } else { collapsedHunks.insert(hunk.id) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                Text(hunk.displayLabel)
                    .font(AppFont.mono(style: .caption))
                DiffCountsLabel(additions: hunk.additions, deletions: hunk.deletions)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hunk.displayLabel))
        .accessibilityHint(Text(collapsed ? "Expand section" : "Collapse section"))
    }

    private func load() async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            diff = try await apiClient.gitDiff(
                sessionID: sessionID,
                path: file.displayPath,
                kind: file.preferredDiffKind
            ).diff
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
        isLoading = false
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.gutterLabel)
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 8)
                .background(line.kind.gutterBackground)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .context ? .secondary : .primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 19)
        .background(line.kind.rowBackground)
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

        var rowBackground: Color {
            switch self {
            case .addition: return Color(red: 0.20, green: 0.78, blue: 0.35).opacity(0.16)
            case .deletion: return Color(red: 0.95, green: 0.25, blue: 0.25).opacity(0.16)
            case .context: return Color(.systemBackground)
            }
        }

        var gutterBackground: Color {
            switch self {
            case .addition: return Color(red: 0.20, green: 0.68, blue: 0.32).opacity(0.24)
            case .deletion: return Color(red: 0.86, green: 0.20, blue: 0.20).opacity(0.24)
            case .context: return Color(.secondarySystemBackground)
            }
        }
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?

    var gutterLabel: String {
        let value = kind == .deletion ? oldLineNumber : newLineNumber
        return value.map(String.init) ?? ""
    }
}
