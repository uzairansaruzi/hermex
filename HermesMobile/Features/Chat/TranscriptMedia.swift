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

    let altText: String?

    init(rawReference: String, altText: String? = nil) {
        self.rawReference = rawReference
        self.altText = altText
    }

    var id: String {
        rawReference
    }

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

    var isVideoCandidate: Bool {
        mediaKind == .video
    }

    var isExtensionlessRemoteMediaCandidate: Bool {
        if case .remoteURL = source, pathExtension.isEmpty {
            return true
        }
        return false
    }

    var isHermesDocumentCandidate: Bool {
        guard mediaKind == .unsupported else { return false }
        let path: String
        switch source {
        case let .localPath(value): path = value
        case let .remoteURL(url): path = url.path
        }
        return BinaryFilePreview(path: path) == .quickLook
    }

    var isHTMLReportCandidate: Bool {
        mediaKind == .unsupported && ["html", "htm"].contains(pathExtension)
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

enum TranscriptMediaSegmentCache {
    private static let storage: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 240
        return cache
    }()

    private final class Key: NSObject {
        let markdown: String
        let workspaceRoot: String?
        let resolvesBarePaths: Bool

        init(markdown: String, workspaceRoot: String?, resolvesBarePaths: Bool) {
            self.markdown = markdown
            self.workspaceRoot = workspaceRoot
            self.resolvesBarePaths = resolvesBarePaths
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(markdown)
            hasher.combine(workspaceRoot)
            hasher.combine(resolvesBarePaths)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return markdown == other.markdown && workspaceRoot == other.workspaceRoot
                && resolvesBarePaths == other.resolvesBarePaths
        }
    }

    private final class Box {
        let segments: [TranscriptMediaSegment]
        init(_ segments: [TranscriptMediaSegment]) { self.segments = segments }
    }

    static func segments(in markdown: String, workspaceRoot: String?, resolvesBarePaths: Bool = false,
                         isStreaming: Bool) -> [TranscriptMediaSegment] {
        guard !isStreaming else {
            return TranscriptMediaParser.segments(in: markdown, workspaceRoot: workspaceRoot, resolvesBarePaths: resolvesBarePaths)
        }

        let key = Key(markdown: markdown, workspaceRoot: workspaceRoot, resolvesBarePaths: resolvesBarePaths)
        if let cached = storage.object(forKey: key) {
            return cached.segments
        }

        let segments = TranscriptMediaParser.segments(in: markdown, workspaceRoot: workspaceRoot,
                                                      resolvesBarePaths: resolvesBarePaths)
        storage.setObject(Box(segments), forKey: key)
        return segments
    }

    static func removeAll() {
        storage.removeAllObjects()
    }

    static func hasCachedSegments(in markdown: String, workspaceRoot: String?) -> Bool {
        storage.object(forKey: Key(markdown: markdown, workspaceRoot: workspaceRoot, resolvesBarePaths: false)) != nil
    }
}

enum TranscriptMediaParser {
    static func segments(in markdown: String, workspaceRoot: String? = nil,
                         resolvesBarePaths: Bool = false) -> [TranscriptMediaSegment] {
        guard !markdown.isEmpty else { return [] }
        guard mayContainMedia(markdown) else {
            return [.text(markdown)]
        }

        var segments = SegmentBuilder()
        var index = markdown.startIndex
        var isInFence = false
        var fenceCharacter: Character?

        while index < markdown.endIndex {
            let lineRange = markdown.lineRange(for: index..<index)
            let line = String(markdown[lineRange])

            if isInFence {
                segments.appendText(line)
                if fenceMarker(in: line) == fenceCharacter {
                    isInFence = false
                    fenceCharacter = nil
                }
            } else if let marker = fenceMarker(in: line) {
                segments.appendText(line)
                isInFence = true
                fenceCharacter = marker
            } else if mayContainMedia(line) {
                appendMediaSegments(in: line, to: &segments, workspaceRoot: workspaceRoot, resolvesBarePaths: resolvesBarePaths)
            } else {
                segments.appendText(line)
            }

            index = lineRange.upperBound
        }

        return segments.finish()
    }

    private static func appendMediaSegments(
        in line: String,
        to segments: inout SegmentBuilder,
        workspaceRoot: String?,
        resolvesBarePaths: Bool
    ) {
        var cursor = line.startIndex
        var textStart = cursor
        let inlineCodeRanges = inlineCodeRanges(in: line)

        while cursor < line.endIndex {
            if line[cursor...].hasPrefix(markdownImageMarker),
               !inlineCodeRanges.contains(where: { $0.contains(cursor) }),
               let image = markdownImage(in: line, from: cursor),
               let reference = markdownImageReference(for: image, workspaceRoot: workspaceRoot,
                                                      resolvesBarePaths: resolvesBarePaths) {
                segments.appendText(line[textStart..<cursor])
                segments.appendMedia(reference)

                cursor = image.end
                textStart = cursor
                continue
            }

            if line[cursor] == "`",
               let span = inlineCodeRanges.first(where: { $0.lowerBound == cursor }),
               let rawReference = codeWrappedMediaReference(in: line[span]) {
                segments.appendText(line[textStart..<cursor])
                segments.appendMedia(TranscriptMediaReference(rawReference: rawReference))

                cursor = span.upperBound
                textStart = cursor
                continue
            }

            if line[cursor...].hasPrefix("MEDIA:"),
               !inlineCodeRanges.contains(where: { $0.contains(cursor) }),
               let referenceRange = referenceRange(
                   in: line,
                   markerStart: cursor,
                   from: line.index(cursor, offsetBy: 6),
                   syntax: .mediaToken
               ) {
                segments.appendText(line[textStart..<cursor])

                let reference = TranscriptMediaReference(rawReference: String(line[referenceRange]))
                segments.appendMedia(reference)

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
                segments.appendText(line[textStart..<cursor])

                let rawURL = String(line[cursor..<pathRange.upperBound])
                let reference = TranscriptMediaReference(
                    rawReference: normalizedLocalPath(fromFileURL: rawURL)
                )
                segments.appendMedia(reference)

                cursor = pathRange.upperBound
                textStart = cursor
                continue
            }

            cursor = line.index(after: cursor)
        }

        segments.appendText(line[textStart..<line.endIndex])
    }

    private struct MarkdownImage {
        let alt: String
        let destination: String
        let end: String.Index
    }

    private static func markdownImage(in line: String, from start: String.Index) -> MarkdownImage? {
        guard let altOpen = line.index(start, offsetBy: line[start] == "!" ? 1 : 0, limitedBy: line.endIndex),
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

    private static func unescaped(_ destination: String) -> String {
        guard destination.contains("\\") else { return destination }

        var result = ""
        var isEscaped = false
        for character in destination {
            if isEscaped {
                if !escapablePunctuation.contains(character) {
                    result.append("\\")
                }
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

    private static let escapablePunctuation = Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)

    private static func markdownImageReference(
        for image: MarkdownImage,
        workspaceRoot: String?,
        resolvesBarePaths: Bool
    ) -> TranscriptMediaReference? {
        guard let path = FileReference.absoluteMediaPath(
            image.destination,
            workspaceRoot: workspaceRoot,
            resolvesBarePaths: resolvesBarePaths
        ) else { return nil }

        let reference = TranscriptMediaReference(
            rawReference: path,
            altText: image.alt.isEmpty ? nil : image.alt
        )
        return reference.isRasterImageCandidate ? reference : nil
    }

    private struct SegmentBuilder {
        private var segments: [TranscriptMediaSegment] = []
        private var pendingText = ""

        mutating func appendText(_ text: some StringProtocol) {
            pendingText.append(contentsOf: text)
        }

        mutating func appendMedia(_ reference: TranscriptMediaReference) {
            flushText()
            segments.append(.media(reference))
        }

        mutating func finish() -> [TranscriptMediaSegment] {
            flushText()
            return segments
        }

        private mutating func flushText() {
            guard !pendingText.isEmpty else { return }
            segments.append(.text(pendingText))
            pendingText = ""
        }
    }

    private static func mayContainMedia(_ markdown: String) -> Bool {
        var markdown = markdown
        return markdown.withUTF8 { bytes in
            let mediaToken = Array("MEDIA:".utf8)
            let fileURL = Array(fileURLMarker.utf8)

            func hasPrefix(_ marker: [UInt8], at offset: Int) -> Bool {
                guard bytes.count - offset >= marker.count else { return false }
                return marker.indices.allSatisfy { bytes[offset + $0] == marker[$0] }
            }

            for offset in bytes.indices {
                switch bytes[offset] {
                case UInt8(ascii: "["):
                    if offset > 0 && bytes[offset - 1] == UInt8(ascii: "!") {
                        return true
                    }
                case UInt8(ascii: "M"):
                    if hasPrefix(mediaToken, at: offset) { return true }
                case UInt8(ascii: "f"):
                    if hasPrefix(fileURL, at: offset) { return true }
                default:
                    break
                }
            }
            return false
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

    private static func codeWrappedMediaReference(in span: Substring) -> String? {
        let content = span.dropFirst().dropLast()
        guard content.hasPrefix("MEDIA:") else { return nil }

        let reference = content.dropFirst("MEDIA:".count)
        guard !reference.contains(where: \.isWhitespace) else { return nil }

        let isWindowsPath = reference.first?.isLetter == true
            && (reference.dropFirst().hasPrefix(":/") || reference.dropFirst().hasPrefix(":\\"))
        guard isWindowsPath || ["/", "~/", "http://", "https://"].contains(where: reference.hasPrefix)
        else { return nil }

        return String(reference)
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
