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

    var id: String {
        rawReference
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
    static func segments(in markdown: String) -> [TranscriptMediaSegment] {
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
                appendMediaSegments(in: line, to: &segments)
            }

            index = lineRange.upperBound
        }

        return segments
    }

    private static func appendMediaSegments(in line: String, to segments: inout [TranscriptMediaSegment]) {
        var cursor = line.startIndex
        var textStart = cursor

        while cursor < line.endIndex {
            if line[cursor...].hasPrefix("MEDIA:"),
               let referenceRange = referenceRange(
                   in: line,
                   markerStart: cursor,
                   from: line.index(cursor, offsetBy: 6)
               ) {
                appendText(String(line[textStart..<cursor]), to: &segments)

                let reference = TranscriptMediaReference(rawReference: String(line[referenceRange]))
                segments.append(.media(reference))

                cursor = referenceRange.upperBound
                textStart = cursor
                continue
            }

            cursor = line.index(after: cursor)
        }

        appendText(String(line[textStart..<line.endIndex]), to: &segments)
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
        from start: String.Index
    ) -> Range<String.Index>? {
        guard start < line.endIndex else { return nil }

        var end = start
        while end < line.endIndex, !isReferenceTerminator(line[end]) {
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

        if let delimiter = emphasisDelimiter(in: line, immediatelyBefore: markerStart),
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

    private static func isReferenceTerminator(_ character: Character) -> Bool {
        character.isWhitespace || character == ")" || character == "]"
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
}
