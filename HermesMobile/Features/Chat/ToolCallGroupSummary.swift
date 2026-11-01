import Foundation

/// What a tool group's hidden rows did, for the collapsed toggle: up to two
/// leading kinds of work plus a count of every other hidden call, and how many
/// hidden calls failed. Structured so tests assert meaning; `sentence` and
/// `accessibilityLabel(title:)` turn it into localized copy.
struct ToolCallGroupSummary: Equatable {
    enum Part: Equatable {
        /// Distinct paths across successful writes that named them and landed.
        case changedFiles(Int)
        case commands(Int)
        case delegatedTasks(Int)
        case searches(Int)
        /// Distinct paths, when every read succeeded and named one.
        case readFiles(Int)
        case readActions(Int)
        case webPages(Int)
    }

    /// At most two, in priority order: write, shell, delegate, search, read, web.
    let parts: [Part]
    /// Hidden calls no part describes: lower-priority kinds, other tools, and
    /// writes that failed, changed nothing, never finished, or named no path.
    let otherActionCount: Int
    let failedCount: Int

    init(entries: [ToolCallLogEntry]) {
        var changedPaths = Set<String>()
        var writeCalls = 0
        var commands = 0
        var delegatedTasks = 0
        var searches = 0
        var readPaths = Set<String>()
        var readCalls = 0
        var everyReadNamesAFile = true
        var webPages = 0
        var other = 0
        var failed = 0

        for entry in entries {
            let status = entry.row.status
            let args = entry.toolCall.args ?? [:]
            if status == .failure { failed += 1 }

            switch ToolCallSummaryFormatter.kind(forToolNamed: entry.toolCall.name) {
            case .write:
                // Only a finished, successful write whose result shows it landed changed anything.
                let landed = status == .success && !ToolCallDiff.resultReportsNoChange(for: entry.toolCall)
                let paths = landed ? ToolCallSummaryFormatter.changedPaths(args: args) : []
                if paths.isEmpty {
                    other += 1
                } else {
                    changedPaths.formUnion(paths)
                    writeCalls += 1
                }
            case .read:
                readCalls += 1
                if status == .success, let path = ToolCallSummaryFormatter.readPath(args: args) {
                    readPaths.insert(path)
                } else {
                    everyReadNamesAFile = false
                }
            case .shell: commands += 1
            case .delegate: delegatedTasks += 1
            case .search: searches += 1
            case .web:
                // The row says "Checked" for every web tool, but web_search
                // fetched no page, so the summary counts it as a search.
                if (entry.toolCall.name ?? "").lowercased().contains("search") {
                    searches += 1
                } else {
                    webPages += 1
                }
            case .list, .skill, .memory, .unknown: other += 1
            }
        }

        // Each candidate pairs its part with the calls it stands for, so the
        // calls behind an omitted part still land in `otherActionCount`.
        let candidates: [(part: Part, calls: Int)] = [
            (.changedFiles(changedPaths.count), writeCalls),
            (.commands(commands), commands),
            (.delegatedTasks(delegatedTasks), delegatedTasks),
            (.searches(searches), searches),
            (everyReadNamesAFile ? .readFiles(readPaths.count) : .readActions(readCalls), readCalls),
            (.webPages(webPages), webPages)
        ].filter { $0.calls > 0 }

        parts = candidates.prefix(2).map(\.part)
        otherActionCount = other + candidates.dropFirst(2).reduce(0) { $0 + $1.calls }
        failedCount = failed
    }

    /// "Changed 2 files and ran 4 commands", or `nil` when no part names the
    /// work and the caller keeps its plain count.
    var sentence: String? {
        guard !parts.isEmpty else { return nil }
        var phrases = parts.map(\.phrase)
        if otherActionCount > 0 {
            phrases.append(String(localized: "\(otherActionCount) other actions"))
        }
        // Only the first grapheme is cased, so names and later words keep theirs.
        let list = phrases.formatted(.list(type: .and))
        return String(list.prefix(1)).localizedUppercase + list.dropFirst()
    }

    /// `title` plus the hidden failure count VoiceOver reads after it.
    func accessibilityLabel(title: String) -> String {
        guard failedCount > 0 else { return title }
        return "\(title), \(String(localized: "\(failedCount) failed"))"
    }
}

private extension ToolCallGroupSummary.Part {
    /// The lowercase list item; `sentence` cases the first one.
    var phrase: String {
        switch self {
        case .changedFiles(let count): String(localized: "changed \(count) files")
        case .commands(let count): String(localized: "ran \(count) commands")
        case .delegatedTasks(let count): String(localized: "delegated \(count) tasks")
        case .searches(let count): String(localized: "searched \(count) times")
        case .readFiles(let count): String(localized: "read \(count) files")
        case .readActions(let count): String(localized: "\(count) read actions")
        case .webPages(let count): String(localized: "fetched \(count) pages")
        }
    }
}
