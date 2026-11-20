import Foundation

struct ToolCallGroupSummary: Equatable {
    enum Part: Equatable {
        case changedFiles(Int)
        case commands(Int)
        case delegatedTasks(Int)
        case searches(Int)
        case readFiles(Int)
        case readActions(Int)
        case webPages(Int)
    }

    let parts: [Part]
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
                if (entry.toolCall.name ?? "").lowercased().contains("search") {
                    searches += 1
                } else {
                    webPages += 1
                }
            case .list, .skill, .memory, .unknown: other += 1
            }
        }

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

    var sentence: String? {
        guard !parts.isEmpty else { return nil }
        var phrases = parts.map(\.phrase)
        if otherActionCount > 0 {
            phrases.append(String(localized: "\(otherActionCount) other actions"))
        }
        let list = phrases.formatted(.list(type: .and))
        return String(list.prefix(1)).localizedUppercase + list.dropFirst()
    }

    func accessibilityLabel(title: String) -> String {
        guard failedCount > 0 else { return title }
        return "\(title), \(String(localized: "\(failedCount) failed"))"
    }
}

private extension ToolCallGroupSummary.Part {
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
