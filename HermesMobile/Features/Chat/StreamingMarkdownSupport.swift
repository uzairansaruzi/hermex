import Foundation

struct StreamingMarkdownChunk: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct StreamingMarkdownBlockSegments: Equatable {
    let stableChunks: [StreamingMarkdownChunk]
    let activeMarkdown: String
}

/// Seals the settled front of a streaming reply into stable chunks so only
/// the active tail re-parses per token. Runs over the whole reply on every
/// streaming update, so it walks the text once without allocating per line.
enum StreamingMarkdownBlockSplitter {
    /// Measured in UTF-8 bytes, which native strings count in O(1).
    static let stableChunkTargetUTF8Count = 6_000

    static func split(_ text: String) -> StreamingMarkdownBlockSegments {
        var lineStart = text.startIndex
        var chunkStart = text.startIndex
        var openFence: FenceRun?
        var stableChunks: [StreamingMarkdownChunk] = []

        while lineStart < text.endIndex {
            let lineEnd = lineEnd(in: text, from: lineStart)
            let nextLineStart = lineEnd < text.endIndex ? text.utf8.index(after: lineEnd) : text.endIndex
            let hasLineBreak = lineEnd < text.endIndex
            let trimmedLine = trimmed(text[lineStart..<lineEnd])

            var stableBoundary: String.Index?
            if let fence = openFence {
                if fence.isClosed(by: trimmedLine) {
                    openFence = nil
                    stableBoundary = nextLineStart
                }
            } else if let fence = FenceRun(openingLine: trimmedLine) {
                openFence = fence
            } else if hasLineBreak {
                if trimmedLine.isEmpty || isStableSingleLineBlock(trimmedLine) {
                    stableBoundary = nextLineStart
                }
            }

            if let stableBoundary,
               shouldSealChunk(in: text, from: chunkStart, to: stableBoundary) {
                appendChunk(in: text, from: chunkStart, to: stableBoundary, into: &stableChunks)
                chunkStart = stableBoundary
            }

            lineStart = nextLineStart
        }

        return StreamingMarkdownBlockSegments(
            stableChunks: stableChunks,
            activeMarkdown: String(text[chunkStart...])
        )
    }

    /// The `\n` ending the line that starts at `start`, found by byte. A
    /// `\r\n` pair is one Character, which the Character search this replaced
    /// never matched, so it does not end a line here either.
    private static func lineEnd(in text: String, from start: String.Index) -> String.Index {
        let utf8 = text.utf8
        var searchStart = start
        while let newline = utf8[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline == start || utf8[utf8.index(before: newline)] != UInt8(ascii: "\r") {
                return newline
            }
            searchStart = utf8.index(after: newline)
        }
        return text.endIndex
    }

    private static func shouldSealChunk(
        in text: String,
        from start: String.Index,
        to boundary: String.Index
    ) -> Bool {
        guard boundary < text.endIndex else { return false }
        return text.utf8.distance(from: start, to: boundary) >= stableChunkTargetUTF8Count
    }

    private static func appendChunk(
        in text: String,
        from start: String.Index,
        to end: String.Index,
        into chunks: inout [StreamingMarkdownChunk]
    ) {
        guard start < end else { return }
        guard !trimmed(text[start..<end]).isEmpty else { return }
        chunks.append(
            StreamingMarkdownChunk(
                id: chunks.count,
                text: String(text[start..<end])
            )
        )
    }

    /// `trimmingCharacters(in: .whitespacesAndNewlines)` as a view into
    /// `line` rather than a new string.
    private static func trimmed(_ line: Substring) -> Substring {
        let scalars = line.unicodeScalars
        let isContent: (Unicode.Scalar) -> Bool = { !whitespacesAndNewlines.contains($0) }
        guard let first = scalars.firstIndex(where: isContent),
              let last = scalars.lastIndex(where: isContent)
        else { return "" }
        return Substring(scalars[first...last])
    }

    private static let whitespacesAndNewlines = CharacterSet.whitespacesAndNewlines

    /// The opening run of a fenced code block. Per CommonMark, only a line of the same
    /// character, at least as long, with no info string closes it, so a ```` fence can
    /// hold ``` lines and a ~~~ fence can hold ``` lines.
    private struct FenceRun {
        let character: Character
        let length: Int

        init?(openingLine: Substring) {
            guard let first = openingLine.first, first == "`" || first == "~" else { return nil }
            let length = openingLine.prefix(while: { $0 == first }).count
            guard length >= 3 else { return nil }
            character = first
            self.length = length
        }

        func isClosed(by trimmedLine: Substring) -> Bool {
            let run = trimmedLine.prefix(while: { $0 == character }).count
            return run >= length && run == trimmedLine.count
        }
    }

    private static func isStableSingleLineBlock(_ trimmedLine: Substring) -> Bool {
        let headingMarkerCount = trimmedLine.prefix(while: { $0 == "#" }).count
        let isHeading = (1...6).contains(headingMarkerCount)
            && trimmedLine.dropFirst(headingMarkerCount).first?.isWhitespace == true
        return isHeading || trimmedLine == "---" || trimmedLine == "***"
    }
}
