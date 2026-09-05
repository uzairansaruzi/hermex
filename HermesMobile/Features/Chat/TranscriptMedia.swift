import Foundation

enum TranscriptMediaSource: Equatable {
    case localPath(String)
    case remoteURL(URL)
}

enum TranscriptMediaKind: Equatable {
    case image
    case audio
    case video
    case unsupported
}

struct TranscriptMediaReference: Equatable, Identifiable {
    let rawReference: String

    /// The alt text of the `![alt](path)` this came from. `MEDIA:` tokens and bare
    /// `file://` URLs have none, so they fall back to the file name.
    let altText: String?

    init(rawReference: String, altText: String? = nil) {
        self.rawReference = rawReference
        self.altText = altText
    }

    var id: String {
        rawReference
    }

    /// What VoiceOver should call this image: the author's alt text when there is one,
    /// otherwise the file name.
    var accessibilityName: String {
        guard let altText = altText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !altText.isEmpty
        else {
            return displayName
        }
        return altText
    }

    var source: TranscriptMediaSource {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remoteURL(url)
        }

        return .localPath(trimmed)
    }

    var displayName: String {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Media") }

        switch source {
        case let .remoteURL(url):
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? String(localized: "Image") : name
        case .localPath:
            let name = URL(fileURLWithPath: trimmed).lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? trimmed : name
        }
    }

    var mediaKind: TranscriptMediaKind {
        let ext = pathExtension
        if Self.rasterImageExtensions.contains(ext) {
            return .image
        }

        if Self.audioExtensions.contains(ext) {
            return .audio
        }

        if Self.videoExtensions.contains(ext) {
            return .video
        }

        if case .remoteURL = source, ext.isEmpty {
            return .image
        }

        return .unsupported
    }

    var isRasterImageCandidate: Bool {
        mediaKind == .image
    }

    var isAudioCandidate: Bool {
        mediaKind == .audio
    }

    var isVideoCandidate: Bool {
        mediaKind == .video
    }

    var isExtensionlessRemoteMediaCandidate: Bool {
        if case .remoteURL = source, pathExtension.isEmpty {
            return true
        }
        return false
    }

    private var pathExtension: String {
        switch source {
        case let .remoteURL(url):
            return url.pathExtension.lowercased()
        case let .localPath(path):
            return URL(fileURLWithPath: path).pathExtension.lowercased()
        }
    }

    private static let rasterImageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "ico", "jpg", "jpeg", "png", "tif", "tiff", "webp"
    ]

    private static let audioExtensions: Set<String> = [
        "aac", "caf", "m4a", "mp3", "wav"
    ]

    private static let videoExtensions: Set<String> = [
        "m4v", "mov", "mp4"
    ]
}

enum TranscriptMediaSegment: Equatable {
    case text(String)
    case media(TranscriptMediaReference)
}

enum TranscriptMediaParser {
    /// Splits an assistant message into text and media. `workspaceRoot` only resolves the
    /// relative forms of `![alt](path)`; an absolute path or a `file:` URL needs no root,
    /// and the server's `/api/media` allow-list decides what is actually served.
    static func segments(
        in markdown: String,
        workspaceRoot: String? = nil
    ) -> [TranscriptMediaSegment] {
        guard !markdown.isEmpty else { return [] }

        var segments: [TranscriptMediaSegment] = []
        var index = markdown.startIndex
        var isInFence = false
        var fenceCharacter: Character?

        while index < markdown.endIndex {
            let lineRange = markdown.lineRange(for: index..<index)
            let line = String(markdown[lineRange])

            if isInFence {
                appendText(line, to: &segments)
                if fenceMarker(in: line) == fenceCharacter {
                    isInFence = false
                    fenceCharacter = nil
                }
            } else if let marker = fenceMarker(in: line) {
                appendText(line, to: &segments)
                isInFence = true
                fenceCharacter = marker
            } else {
                appendMediaSegments(in: line, to: &segments, workspaceRoot: workspaceRoot)
            }

            index = lineRange.upperBound
        }

        return segments
    }

    private static func appendMediaSegments(
        in line: String,
        to segments: inout [TranscriptMediaSegment],
        workspaceRoot: String?
    ) {
        var cursor = line.startIndex
        var textStart = cursor
        let inlineCodeRanges = inlineCodeRanges(in: line)

        while cursor < line.endIndex {
            if line[cursor...].hasPrefix(markdownImageMarker),
               !inlineCodeRanges.contains(where: { $0.contains(cursor) }),
               let image = markdownImage(in: line, from: cursor),
               let reference = markdownImageReference(for: image, workspaceRoot: workspaceRoot) {
                appendText(String(line[textStart..<cursor]), to: &segments)
                segments.append(.media(reference))

                cursor = image.end
                textStart = cursor
                continue
            }

            if line[cursor...].hasPrefix("MEDIA:"),
               let referenceRange = referenceRange(
                   in: line,
                   markerStart: cursor,
                   from: line.index(cursor, offsetBy: 6),
                   syntax: .mediaToken
               ) {
                appendText(String(line[textStart..<cursor]), to: &segments)

                let reference = TranscriptMediaReference(rawReference: String(line[referenceRange]))
                segments.append(.media(reference))

                cursor = referenceRange.upperBound
                textStart = cursor
                continue
            }

            if line[cursor...].hasPrefix(fileURLMarker),
               isBareFileURLStart(cursor, in: line),
               !inlineCodeRanges.contains(where: { $0.contains(cursor) }),
               let pathRange = referenceRange(
                   in: line,
                   markerStart: cursor,
                   from: line.index(cursor, offsetBy: fileURLMarker.count),
                   syntax: .fileURL
               ) {
                appendText(String(line[textStart..<cursor]), to: &segments)

                let rawURL = String(line[cursor..<pathRange.upperBound])
                let reference = TranscriptMediaReference(
                    rawReference: normalizedLocalPath(fromFileURL: rawURL)
                )
                segments.append(.media(reference))

                cursor = pathRange.upperBound
                textStart = cursor
                continue
            }

            cursor = line.index(after: cursor)
        }

        appendText(String(line[textStart..<line.endIndex]), to: &segments)
    }

    /// One `![alt](destination "title")` occurrence, already split apart.
    private struct MarkdownImage {
        let alt: String
        let destination: String
        let end: String.Index
    }

    /// Reads a Markdown image starting at `![`. Brackets and parentheses nest and can be
    /// backslash-escaped, so `![Build (1)](/tmp/build(1)/shot.png)` reads as one image
    /// rather than being cut at the first `)`. A reference-style image, which has no
    /// destination at all, stays ordinary Markdown.
    private static func markdownImage(in line: String, from start: String.Index) -> MarkdownImage? {
        guard let altOpen = line.index(start, offsetBy: 1, limitedBy: line.endIndex),
              altOpen < line.endIndex,
              let altEnd = balancedEnd(in: line, after: altOpen, open: "[", close: "]")
        else { return nil }

        let openParenthesis = line.index(after: altEnd)
        guard openParenthesis < line.endIndex, line[openParenthesis] == "(" else { return nil }
        guard let closeParenthesis = balancedEnd(
            in: line,
            after: openParenthesis,
            open: "(",
            close: ")"
        ) else { return nil }

        let body = String(line[line.index(after: openParenthesis)..<closeParenthesis])
        guard let destination = destination(inLinkBody: body) else { return nil }

        return MarkdownImage(
            alt: String(line[line.index(after: altOpen)..<altEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            destination: destination,
            end: line.index(after: closeParenthesis)
        )
    }

    /// The index of the delimiter closing the run opened at `openIndex`, counting nesting
    /// and skipping backslash-escaped characters the way CommonMark does. Nil when the
    /// run never closes on this line.
    private static func balancedEnd(
        in line: String,
        after openIndex: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 1
        var index = line.index(after: openIndex)

        while index < line.endIndex {
            switch line[index] {
            case "\\":
                index = line.index(after: index)
            case open:
                depth += 1
            case close:
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }

            guard index < line.endIndex else { break }
            index = line.index(after: index)
        }

        return nil
    }

    /// The destination out of a link body, dropping any `"title"`. An angle-bracketed
    /// destination keeps its spaces; a bare one ends at the first space.
    private static func destination(inLinkBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("<") {
            guard let close = trimmed.firstIndex(of: ">") else { return nil }
            return unescaped(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
        }

        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return unescaped(trimmed) }
        return unescaped(String(trimmed[..<space]))
    }

    /// Drops the backslashes CommonMark uses to escape punctuation, so a path written as
    /// `/tmp/a\)b.png` reaches the server as `/tmp/a)b.png`.
    private static func unescaped(_ destination: String) -> String {
        guard destination.contains("\\") else { return destination }

        var result = ""
        var isEscaped = false
        for character in destination {
            if isEscaped {
                result.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        if isEscaped { result.append("\\") }
        return result
    }

    /// A Markdown image becomes transcript media when its destination names a raster
    /// image on the server's filesystem, which `/api/media` then decides whether to
    /// serve. Remote URLs and bare relative paths keep whatever the Markdown renderer
    /// already does with them.
    private static func markdownImageReference(
        for image: MarkdownImage,
        workspaceRoot: String?
    ) -> TranscriptMediaReference? {
        guard let path = FileReference.absoluteMediaPath(
            image.destination,
            workspaceRoot: workspaceRoot
        ) else { return nil }

        let reference = TranscriptMediaReference(
            rawReference: path,
            altText: image.alt.isEmpty ? nil : image.alt
        )
        return reference.isRasterImageCandidate ? reference : nil
    }

    private static func appendText(_ text: String, to segments: inout [TranscriptMediaSegment]) {
        guard !text.isEmpty else { return }

        if case let .text(existing) = segments.last {
            segments[segments.count - 1] = .text(existing + text)
        } else {
            segments.append(.text(text))
        }
    }

    private static func referenceRange(
        in line: String,
        markerStart: String.Index,
        from start: String.Index,
        syntax: ReferenceSyntax
    ) -> Range<String.Index>? {
        guard start < line.endIndex else { return nil }

        var end = start
        while end < line.endIndex, !isReferenceTerminator(line[end], syntax: syntax) {
            end = line.index(after: end)
        }

        var trimmedEnd = end
        while trimmedEnd > start {
            let previous = line.index(before: trimmedEnd)
            if trailingPunctuation.contains(line[previous]) {
                trimmedEnd = previous
            } else {
                break
            }
        }

        if syntax == .mediaToken,
           let delimiter = emphasisDelimiter(in: line, immediatelyBefore: markerStart),
           line[start..<trimmedEnd].hasSuffix(delimiter) {
            trimmedEnd = line.index(trimmedEnd, offsetBy: -delimiter.count)
        }

        guard trimmedEnd > start else { return nil }
        return start..<trimmedEnd
    }

    private static func emphasisDelimiter(
        in line: String,
        immediatelyBefore index: String.Index
    ) -> String? {
        for delimiter in ["***", "___", "**", "__", "*", "_"] {
            guard let delimiterStart = line.index(
                index,
                offsetBy: -delimiter.count,
                limitedBy: line.startIndex
            ) else {
                continue
            }

            if line[delimiterStart..<index] == delimiter {
                return delimiter
            }
        }

        return nil
    }

    private static func isReferenceTerminator(
        _ character: Character,
        syntax: ReferenceSyntax
    ) -> Bool {
        if character.isWhitespace || character == ")" || character == "]" {
            return true
        }

        return syntax == .fileURL && fileURLTerminators.contains(character)
    }

    private static func isBareFileURLStart(_ index: String.Index, in line: String) -> Bool {
        index == line.startIndex || line[line.index(before: index)].isWhitespace
    }

    private static func normalizedLocalPath(fromFileURL rawURL: String) -> String {
        if let components = URLComponents(string: rawURL) {
            let encodedPath = components.percentEncodedPath
            if !encodedPath.isEmpty {
                return encodedPath.removingPercentEncoding ?? encodedPath
            }
        }

        let schemeStripped = String(rawURL.dropFirst(fileURLMarker.count))
        return schemeStripped.removingPercentEncoding ?? schemeStripped
    }

    private static func inlineCodeRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = line.startIndex

        while cursor < line.endIndex {
            guard line[cursor] == "`" else {
                cursor = line.index(after: cursor)
                continue
            }

            let openingStart = cursor
            let openingEnd = backtickRunEnd(in: line, from: cursor)
            let delimiterLength = line.distance(from: openingStart, to: openingEnd)
            var search = openingEnd
            var closingEnd: String.Index?

            while search < line.endIndex {
                guard line[search] == "`" else {
                    search = line.index(after: search)
                    continue
                }

                let candidateEnd = backtickRunEnd(in: line, from: search)
                if line.distance(from: search, to: candidateEnd) == delimiterLength {
                    closingEnd = candidateEnd
                    break
                }
                search = candidateEnd
            }

            guard let closingEnd else { break }
            ranges.append(openingStart..<closingEnd)
            cursor = closingEnd
        }

        return ranges
    }

    private static func backtickRunEnd(in line: String, from start: String.Index) -> String.Index {
        var end = start
        while end < line.endIndex, line[end] == "`" {
            end = line.index(after: end)
        }
        return end
    }

    private static func fenceMarker(in line: String) -> Character? {
        var index = line.startIndex
        var leadingSpaces = 0

        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }

        guard leadingSpaces <= 3 else { return nil }
        if line[index...].hasPrefix("```") {
            return "`"
        }
        if line[index...].hasPrefix("~~~") {
            return "~"
        }
        return nil
    }

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
    private static let fileURLTerminators: Set<Character> = ["<", ">", "\"", "'"]
    private static let fileURLMarker = "file://"
    private static let markdownImageMarker = "!["

    private enum ReferenceSyntax {
        case mediaToken
        case fileURL
    }
}
