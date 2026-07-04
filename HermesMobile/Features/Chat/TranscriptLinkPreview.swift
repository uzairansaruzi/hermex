import Foundation

enum TranscriptLinkPreviewExtractor {
    static func firstWebURL(in text: String) -> URL? {
        for segment in searchableSegments(in: text) {
            if let url = firstWebURL(inSearchableSegment: segment) {
                return url
            }
        }

        return nil
    }

    private static func searchableSegments(in markdown: String) -> [String] {
        guard !markdown.isEmpty else { return [] }

        var segments: [String] = []
        var index = markdown.startIndex
        var isInFence = false
        var fenceCharacter: Character?

        while index < markdown.endIndex {
            let lineRange = markdown.lineRange(for: index..<index)
            let line = String(markdown[lineRange])

            if isInFence {
                if fenceMarker(in: line) == fenceCharacter {
                    isInFence = false
                    fenceCharacter = nil
                }
            } else if let marker = fenceMarker(in: line) {
                isInFence = true
                fenceCharacter = marker
            } else if !shouldSkipLine(line) {
                segments.append(contentsOf: nonInlineCodeSegments(in: line))
            }

            index = lineRange.upperBound
        }

        return segments
    }

    private static func firstWebURL(inSearchableSegment segment: String) -> URL? {
        guard let linkDetector else { return nil }

        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        let matches = linkDetector.matches(in: segment, options: [], range: range)

        for match in matches {
            guard let url = match.url,
                  isWebURL(url)
            else {
                continue
            }

            return url
        }

        return nil
    }

    private static func nonInlineCodeSegments(in line: String) -> [String] {
        var segments: [String] = []
        var cursor = line.startIndex
        var textStart = cursor

        while cursor < line.endIndex {
            guard line[cursor] == "`" else {
                cursor = line.index(after: cursor)
                continue
            }

            let openingRange = backtickRun(in: line, at: cursor)
            guard let closingRange = closingBacktickRun(
                matching: line.distance(from: openingRange.lowerBound, to: openingRange.upperBound),
                in: line,
                from: openingRange.upperBound
            ) else {
                cursor = openingRange.upperBound
                continue
            }

            if textStart < openingRange.lowerBound {
                segments.append(String(line[textStart..<openingRange.lowerBound]))
            }

            cursor = closingRange.upperBound
            textStart = cursor
        }

        if textStart < line.endIndex {
            segments.append(String(line[textStart..<line.endIndex]))
        }

        return segments
    }

    private static func shouldSkipLine(_ line: String) -> Bool {
        guard line.range(of: #"https?://"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }

        if isIndentedCodeLine(line) {
            return true
        }

        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if isLikelyJSONLine(trimmed) {
            return true
        }

        return matchesAnyCodeOrLogPattern(trimmed)
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
    }

    private static func isLikelyJSONLine(_ trimmedLine: String) -> Bool {
        if trimmedLine.hasPrefix("{") || trimmedLine.hasPrefix("}") {
            return true
        }

        if trimmedLine.hasPrefix("[") && trimmedLine.contains("\"") {
            return true
        }

        return matches(#"^"[^"]+"\s*:\s*"#, in: trimmedLine)
    }

    private static func matchesAnyCodeOrLogPattern(_ trimmedLine: String) -> Bool {
        let patterns = [
            #"^(\$|%)\s+.*https?://"#,
            #"^(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|NOTICE)\b.*https?://"#,
            #"^\d{4}-\d{2}-\d{2}[T\s].*https?://"#,
            #"^(\d{2}:\d{2}:\d{2}|\[\d{2}:\d{2}:\d{2}\]).*https?://"#,
            #"^(at\s+\S+|#\d+\s+|Thread\s+\d+|Caused by:|Traceback\b|File\s+"[^"]+",\s+line\s+\d+).*https?://"#,
            #"^(let|var|const|final|static|private|public|return)\b.*https?://"#,
            #"^[A-Za-z_][A-Za-z0-9_.<>]*\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*.*https?://"#,
            #"^(curl|wget|git|ssh|scp)\b.*https?://"#
        ]

        return patterns.contains { pattern in
            matches(pattern, in: trimmedLine)
        }
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func backtickRun(in line: String, at start: String.Index) -> Range<String.Index> {
        var end = start
        while end < line.endIndex, line[end] == "`" {
            end = line.index(after: end)
        }
        return start..<end
    }

    private static func closingBacktickRun(
        matching count: Int,
        in line: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start

        while cursor < line.endIndex {
            guard line[cursor] == "`" else {
                cursor = line.index(after: cursor)
                continue
            }

            let candidate = backtickRun(in: line, at: cursor)
            if line.distance(from: candidate.lowerBound, to: candidate.upperBound) == count {
                return candidate
            }

            cursor = candidate.upperBound
        }

        return nil
    }

    private static func fenceMarker(in line: String) -> Character? {
        var index = line.startIndex
        var leadingSpaces = 0

        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }

        guard leadingSpaces <= 3, index < line.endIndex else { return nil }
        if line[index...].hasPrefix("```") {
            return "`"
        }
        if line[index...].hasPrefix("~~~") {
            return "~"
        }
        return nil
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }

        return url.host?.isEmpty == false
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
}

enum TranscriptLinkPreviewEligibility {
    static func previewURL(for message: ChatMessage, isStreaming: Bool) -> URL? {
        guard !isStreaming,
              isPreviewableRole(message.role),
              let content = message.content
        else {
            return nil
        }

        return TranscriptLinkPreviewExtractor.firstWebURL(in: content)
    }

    static func shouldReservePreviewSpace(for message: ChatMessage, isStreaming: Bool) -> Bool {
        guard isStreaming,
              isPreviewableRole(message.role),
              let content = message.content
        else {
            return false
        }

        return TranscriptLinkPreviewExtractor.firstWebURL(in: content) != nil
    }

    private static func isPreviewableRole(_ role: String?) -> Bool {
        role == "user" || role == "assistant"
    }
}
