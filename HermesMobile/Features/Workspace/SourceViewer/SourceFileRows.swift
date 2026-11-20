import Foundation

enum SourceFileRows {
    static let fileID = "source"

    static func rowID(forLineIndex index: Int) -> String {
        "source:line:\(index)"
    }

    static func lines(in content: String) -> [String] {
        var lines = content.components(separatedBy: "\n").map { line -> String in
            var line = line.replacingOccurrences(of: "\t", with: "    ")
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func rows(for lines: [String]) -> [ReviewDiffRow] {
        lines.enumerated().map { index, line in
            ReviewDiffRow(
                id: rowID(forLineIndex: index),
                fileID: fileID,
                kind: .line(ReviewDiffLine(content: line, change: .context, oldLineNumber: nil, newLineNumber: index + 1))
            )
        }
    }
}
