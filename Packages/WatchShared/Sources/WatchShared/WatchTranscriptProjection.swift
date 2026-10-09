import Foundation

/// Maps one server message into watch transcript kinds. Wrist views stay dumb;
/// this is the phone-side projection of chat content the broker already owns.
public enum WatchTranscriptProjection: Sendable {
    public static let maximumCodeCharacters = 1_200
    public static let maximumToolSummaryCharacters = 240
    public static let maximumToolTitleCharacters = 80
    /// Wrist-sized reply. Also stays under the wire cap (`dtoString` text max
    /// is 16_384); a single desktop message was 21k characters and that one
    /// block rejected the whole conversation.
    public static let maximumMessageCharacters = 700

    public static func blocks(for message: WatchPhoneMessageHint) -> [WatchPhoneTranscriptPage.Block] {
        var result: [WatchPhoneTranscriptPage.Block] = []
        var index = 0

        func nextID() -> String {
            defer { index += 1 }
            return index == 0 ? message.id : "\(message.id)-\(index)"
        }

        if message.isToolResult {
            result.append(
                WatchPhoneTranscriptPage.Block(
                    id: nextID(),
                    kind: .tool(
                        title: truncated(message.tools.first?.title ?? "Tool", max: maximumToolTitleCharacters) ?? "Tool",
                        state: message.tools.first?.state ?? "done",
                        summary: truncated(message.text, max: maximumToolSummaryCharacters)
                    )
                )
            )
            return result
        }

        for tool in message.tools {
            result.append(
                WatchPhoneTranscriptPage.Block(
                    id: nextID(),
                    kind: .tool(
                        title: truncated(tool.title, max: maximumToolTitleCharacters) ?? "Tool",
                        state: tool.state,
                        summary: tool.summary.flatMap { truncated($0, max: maximumToolSummaryCharacters) }
                    )
                )
            )
        }

        let displayText = Self.contentWithoutAttachedFilesMarker(in: message.text)
        var seenImagePaths = Set<String>()

        for segment in segments(in: displayText) {
            switch segment {
            case .text(let text):
                let normalized = wristMarkdown(text)
                guard let clipped = truncated(normalized, max: maximumMessageCharacters) else { continue }
                // Only a clipped reply can end mid-token; untouched text may
                // legitimately contain a lone "[" or backtick.
                let wasClipped = normalized.trimmingCharacters(in: .whitespacesAndNewlines).count > clipped.count
                result.append(
                    WatchPhoneTranscriptPage.Block(
                        id: nextID(),
                        kind: .text(
                            role: message.role,
                            text: wasClipped ? repairingTrailingMarkdown(clipped) : clipped
                        )
                    )
                )
            case .code(let language, let text):
                let folded = wristCode(text)
                let clipped = truncated(folded.text, max: maximumCodeCharacters)
                result.append(
                    WatchPhoneTranscriptPage.Block(
                        id: nextID(),
                        kind: .code(
                            language: displayLanguage(language),
                            text: clipped ?? "",
                            isTruncated: folded.didClipLine || (folded.text.count > maximumCodeCharacters)
                        )
                    )
                )
            case .image(let path, let alt):
                let key = normalizedPath(path) ?? path
                seenImagePaths.insert(key)
                result.append(
                    WatchPhoneTranscriptPage.Block(
                        id: nextID(),
                        kind: .image(path: path, mime: mimeForPath(path), alt: nonEmpty(alt))
                    )
                )
            }
        }

        for attachment in message.attachments {
            let key = normalizedPath(attachment.path) ?? normalizedPath(attachment.name)
            if let key, seenImagePaths.contains(key) { continue }
            if attachment.isImage {
                result.append(
                    WatchPhoneTranscriptPage.Block(
                        id: nextID(),
                        kind: .image(
                            path: attachment.path,
                            mime: attachment.mime ?? mimeForPath(attachment.path ?? attachment.name),
                            alt: nonEmpty(attachment.name)
                        )
                    )
                )
            } else {
                let kind = audioKind(attachment) ? "audio" : "file"
                result.append(
                    WatchPhoneTranscriptPage.Block(
                        id: nextID(),
                        kind: .unsupported(
                            kind: kind,
                            summary: nonEmpty(attachment.name) ?? "Open on iPhone"
                        )
                    )
                )
            }
        }

        return result
    }

    public static func contentWithoutAttachedFilesMarker(in content: String) -> String {
        guard let range = content.range(of: "[Attached files:", options: .backwards) else {
            return content
        }
        let afterMarker = content[range.upperBound...]
        guard let close = afterMarker.firstIndex(of: "]") else { return content }
        let afterBracket = afterMarker[afterMarker.index(after: close)...]
        guard afterBracket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return content
        }
        var prefix = content[..<range.lowerBound]
        while let last = prefix.last, last.isWhitespace {
            prefix = prefix.dropLast()
        }
        return String(prefix)
    }

    public static func chatMessageText(draft: String, attachments: [WatchChatAttachment]) -> String {
        let references = attachments
            .map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !references.isEmpty else { return draft }
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "I've uploaded \(references.count) file(s): \(references.joined(separator: ", "))"
        }
        return "\(draft)\n\n[Attached files: \(references.joined(separator: ", "))]"
    }

    private enum Segment {
        case text(String)
        case code(language: String?, text: String)
        case image(path: String, alt: String)
    }

    private static func segments(in text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        var result: [Segment] = []
        var remainder = text[...]

        while !remainder.isEmpty {
            if let fence = firstFence(in: remainder) {
                appendText(String(remainder[..<fence.markerStart]), to: &result)
                result.append(.code(language: fence.language, text: fence.body))
                remainder = remainder[fence.end...]
                continue
            }
            if let image = firstMarkdownImage(in: remainder) {
                appendText(String(remainder[..<image.start]), to: &result)
                result.append(.image(path: image.path, alt: image.alt))
                remainder = remainder[image.end...]
                continue
            }
            if let media = firstMediaToken(in: remainder) {
                appendText(String(remainder[..<media.start]), to: &result)
                result.append(.image(path: media.path, alt: ""))
                remainder = remainder[media.end...]
                continue
            }
            appendText(String(remainder), to: &result)
            break
        }

        return result
    }

    private static func appendText(_ text: String, to segments: inout [Segment]) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = segments.last {
            segments[segments.count - 1] = .text(existing + text)
        } else {
            segments.append(.text(text))
        }
    }

    private static func firstFence(in text: Substring) -> (markerStart: String.Index, language: String?, body: String, end: String.Index)? {
        guard let start = text.range(of: "```") ?? text.range(of: "~~~") else { return nil }
        let marker = text[start]
        let afterOpen = start.upperBound
        let lineEnd = text[afterOpen...].firstIndex(of: "\n") ?? text.endIndex
        let languageRaw = text[afterOpen..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        let language = languageRaw.isEmpty ? nil : languageRaw
        let bodyStart = lineEnd == text.endIndex ? text.endIndex : text.index(after: lineEnd)
        let closeSearch = text[bodyStart...]
        guard let close = closeSearch.range(of: String(marker)) else {
            return (start.lowerBound, language, String(text[bodyStart...]), text.endIndex)
        }
        var body = String(text[bodyStart..<close.lowerBound])
        if body.hasSuffix("\n") { body.removeLast() }
        return (start.lowerBound, language, body, close.upperBound)
    }

    private static func firstMarkdownImage(in text: Substring) -> (start: String.Index, path: String, alt: String, end: String.Index)? {
        guard let bang = text.range(of: "![") else { return nil }
        guard let altClose = text[bang.upperBound...].firstIndex(of: "]") else { return nil }
        let afterAlt = text.index(after: altClose)
        guard afterAlt < text.endIndex, text[afterAlt] == "(" else { return nil }
        let pathStart = text.index(after: afterAlt)
        guard let pathEnd = text[pathStart...].firstIndex(of: ")") else { return nil }
        let alt = String(text[bang.upperBound..<altClose])
        var destination = String(text[pathStart..<pathEnd])
        if let space = destination.firstIndex(of: " ") {
            destination = String(destination[..<space])
        }
        destination = destination.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !destination.isEmpty else { return nil }
        return (bang.lowerBound, destination, alt, text.index(after: pathEnd))
    }

    private static func firstMediaToken(in text: Substring) -> (start: String.Index, path: String, end: String.Index)? {
        guard let marker = text.range(of: "MEDIA:") else { return nil }
        let pathStart = marker.upperBound
        var end = pathStart
        while end < text.endIndex, !text[end].isWhitespace {
            end = text.index(after: end)
        }
        let path = String(text[pathStart..<end])
        guard !path.isEmpty else { return nil }
        return (marker.lowerBound, path, end)
    }

    private static func truncated(_ text: String, max: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }

    private static func mimeForPath(_ path: String?) -> String? {
        guard let path else { return nil }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    private static func audioKind(_ attachment: WatchPhoneAttachmentHint) -> Bool {
        let mime = attachment.mime?.lowercased() ?? ""
        if mime.hasPrefix("audio/") { return true }
        let ext = URL(fileURLWithPath: attachment.path ?? attachment.name).pathExtension.lowercased()
        return ["m4a", "aac", "mp3", "wav", "caf"].contains(ext)
    }
}

// MARK: - Wrist Markdown

/// Phone-side Markdown shaping. The watch cannot link MarkdownUI, and a wrist
/// has no room for raw syntax, so the phone rewrites what is *structural or
/// lossy* (link labels, long URLs, list markers, soft wraps, code line width)
/// and leaves what is purely *visual* (bold, italic, inline code, heading
/// level, quote bar) as canonical Markdown for the watch to style at render
/// time. Everything here runs before the wire clip so the caps still hold.
extension WatchTranscriptProjection {
    /// Widest readable link or URL label on a 45mm screen.
    public static let maximumLinkLabelCharacters = 28
    /// A monospaced code line wider than this wraps into nonsense on the wrist.
    public static let maximumCodeLineCharacters = 48
    /// Widest unbreakable run that still fits one monospaced row on a 45mm
    /// screen. A URL in a code block is shortened to this so it never breaks
    /// inside the hostname.
    public static let maximumCodeTokenCharacters = 21

    /// One normalized Markdown line, classified for the wrist renderer.
    public enum WristLine: Hashable, Sendable {
        case blank
        case heading(level: Int, text: String)
        case quote(text: String)
        case bullet(depth: Int, text: String)
        case ordered(number: String, text: String)
        case paragraph(text: String)
    }

    /// Canonicalizes a message's Markdown for the wrist: soft-wrapped
    /// paragraphs are joined, list markers become bullets, link labels and bare
    /// URLs are shortened to something readable, and thematic breaks are
    /// dropped. Heading, quote, emphasis and inline-code syntax survive so the
    /// watch can turn them into real type styles.
    public static func wristMarkdown(_ text: String) -> String {
        var lines: [String] = []
        var previousWasFoldableParagraph = false

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let expanded = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let line = Substring(expanded)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || isThematicBreak(trimmed) {
                lines.append("")
                previousWasFoldableParagraph = false
                continue
            }
            if let heading = headingPrefix(line) {
                lines.append("\(String(repeating: "#", count: heading.level)) \(rewriteInline(String(heading.body)))")
                previousWasFoldableParagraph = false
                continue
            }
            if let quote = quotePrefix(line) {
                lines.append("> \(rewriteInline(String(quote)))")
                previousWasFoldableParagraph = false
                continue
            }
            if let item = listPrefix(line) {
                let indent = String(repeating: " ", count: min(item.indent, 4))
                let body = rewriteInline(checkboxResolved(String(item.body)))
                lines.append("\(indent)• \(body)")
                previousWasFoldableParagraph = false
                continue
            }
            if let item = orderedPrefix(line) {
                let indent = String(repeating: " ", count: min(item.indent, 4))
                lines.append("\(indent)\(item.number). \(rewriteInline(String(item.body)))")
                previousWasFoldableParagraph = false
                continue
            }
            // A soft-wrapped paragraph is one paragraph: fold it into the
            // previous line unless the author asked for a hard break.
            let rewritten = rewriteInline(trimmed)
            if previousWasFoldableParagraph, let previous = lines.last {
                lines[lines.count - 1] = previous + " " + rewritten
            } else {
                lines.append(rewritten)
            }
            previousWasFoldableParagraph = !endsWithHardBreak(rawLine)
        }

        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty ?? true { continue }
            collapsed.append(line)
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }

    /// Classifies normalized text for the watch renderer. Tolerant of raw
    /// Markdown so blocks built outside `blocks(for:)` still read correctly.
    public static func wristLines(in text: String) -> [WristLine] {
        text.components(separatedBy: "\n").map { rawLine in
            let line = Substring(rawLine)
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
            if let heading = headingPrefix(line) {
                return .heading(level: heading.level, text: String(heading.body))
            }
            if let quote = quotePrefix(line) {
                return .quote(text: String(quote))
            }
            if let item = listPrefix(line) {
                return .bullet(depth: min(item.indent / 2, 2), text: String(item.body))
            }
            if let item = orderedPrefix(line) {
                return .ordered(number: item.number, text: String(item.body))
            }
            return .paragraph(text: rawLine.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Spoken and glanceable form: no syntax, just the words. Used for the
    /// "Listen to the last reply" text and the Now preview line.
    public static func plainText(_ markdown: String) -> String {
        let spoken = wristLines(in: markdown).compactMap { line -> String? in
            switch line {
            case .blank: return nil
            case .heading(_, let text): return strippedEmphasis(text)
            case .quote(let text): return strippedEmphasis(text)
            case .bullet(_, let text): return strippedEmphasis(text)
            case .ordered(let number, let text): return "\(number). " + strippedEmphasis(text)
            case .paragraph(let text): return strippedEmphasis(text)
            }
        }
        return spoken.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` for an untagged fence, or one tagged with a "this is not code"
    /// language, so the watch never prints a literal `text` label.
    public static func displayLanguage(_ raw: String?) -> String? {
        guard let value = nonEmpty(raw)?.lowercased() else { return nil }
        // A fence info string can carry attributes; only the first word names it.
        let name = value.split(separator: " ").first.map(String.init) ?? value
        switch name {
        case "text", "txt", "plain", "plaintext", "none", "output", "console":
            return nil
        default:
            return name
        }
    }

    /// Shortens URLs inside code to the same readable host label prose gets, so
    /// a tailnet URL never breaks inside its hostname, then clips any still
    /// over-wide line at the end. The caller surfaces "More on iPhone" whenever
    /// either happened.
    public static func wristCode(_ text: String) -> (text: String, didClipLine: Bool) {
        var didClip = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var rewritten = shortenedCodeURLs(in: line, didShorten: &didClip)
            if rewritten.count > maximumCodeLineCharacters {
                didClip = true
                rewritten = String(rewritten.prefix(maximumCodeLineCharacters - 1)) + "…"
            }
            return rewritten
        }
        return (lines.joined(separator: "\n"), didClip)
    }

    /// A readable stand-in for a URL: the host, plus `/…` when there is a path.
    /// Long tailnet-style hosts drop their middle labels, keeping the machine
    /// name and the domain, until the whole label fits `max`.
    public static func shortURLLabel(_ urlString: String, max: Int = maximumLinkLabelCharacters) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: schemed(trimmed)), let host = components.host else {
            return middleTruncated(trimmed, max: max)
        }
        let path = components.path
        let hasMore = (!path.isEmpty && path != "/") || components.query != nil || components.fragment != nil
        let suffix = hasMore ? "/…" : ""
        let budget = max - suffix.count

        var label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if label.count > budget {
            let labels = label.split(separator: ".")
            for keptTail in [2, 1] where label.count > budget && labels.count > keptTail {
                let candidate = labels[0] + "…" + labels.suffix(keptTail).joined(separator: ".")
                if candidate.count < label.count { label = String(candidate) }
            }
            if label.count > budget {
                label = middleTruncated(label, max: budget)
            }
        }
        return label + suffix
    }

    /// Rewrites every URL-shaped whitespace-separated token in one code line.
    /// Indentation and surrounding punctuation survive; only the URL changes.
    private static func shortenedCodeURLs(in line: String, didShorten: inout Bool) -> String {
        guard line.contains("://") || line.contains("www.") else { return line }
        let wrappers = CharacterSet(charactersIn: "\"'`(<[{,;:)>]}")
        var result = ""
        var token = ""

        func flushToken() {
            defer { token = "" }
            guard !token.isEmpty else { return }
            let core = token.trimmingCharacters(in: wrappers)
            guard looksLikeURL(core) else {
                result += token
                return
            }
            let label = shortURLLabel(core, max: maximumCodeTokenCharacters)
            guard label != core else {
                result += token
                return
            }
            didShorten = true
            result += token.replacingOccurrences(of: core, with: label)
        }

        for character in line {
            if character.isWhitespace {
                flushToken()
                result.append(character)
            } else {
                token.append(character)
            }
        }
        flushToken()
        return result
    }

    // MARK: Inline rewriting

    private static func rewriteInline(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "`" {
                // Inline code is verbatim; never rewrite inside it.
                let afterTick = text.index(after: index)
                if let close = text[afterTick...].firstIndex(of: "`") {
                    result += text[index...close]
                    index = text.index(after: close)
                    continue
                }
            }
            if character == "!", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "[" {
                // An inline image this far along is already a leftover token.
                result.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "[", let link = parseLink(in: text, from: index) {
                result += link.markdown
                index = link.end
                continue
            }
            if let url = parseBareURL(in: text, from: index) {
                result += url.markdown
                index = url.end
                continue
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func parseLink(in text: String, from start: String.Index) -> (markdown: String, end: String.Index)? {
        let labelStart = text.index(after: start)
        guard let labelEnd = text[labelStart...].firstIndex(of: "]") else { return nil }
        let afterLabel = text.index(after: labelEnd)
        guard afterLabel < text.endIndex, text[afterLabel] == "(" else { return nil }
        let destinationStart = text.index(after: afterLabel)
        guard let destinationEnd = text[destinationStart...].firstIndex(of: ")") else { return nil }

        let label = text[labelStart..<labelEnd].trimmingCharacters(in: .whitespaces)
        var destination = String(text[destinationStart..<destinationEnd]).trimmingCharacters(in: .whitespaces)
        if let space = destination.firstIndex(of: " ") { destination = String(destination[..<space]) }
        let end = text.index(after: destinationEnd)

        guard !destination.isEmpty else {
            return (label, end)
        }
        let display: String
        if label.isEmpty || looksLikeURL(label) {
            display = shortURLLabel(label.isEmpty ? destination : label)
        } else {
            display = middleTruncated(label, max: maximumLinkLabelCharacters * 2)
        }
        return ("[\(display)](\(destination))", end)
    }

    private static func parseBareURL(in text: String, from start: String.Index) -> (markdown: String, end: String.Index)? {
        let remainder = text[start...]
        guard remainder.hasPrefix("http://") || remainder.hasPrefix("https://") || remainder.hasPrefix("www.") else {
            return nil
        }
        // Stop at whitespace and at the delimiters Markdown and prose put
        // around a URL, so `**https://host/**` keeps its emphasis markers.
        let stoppers: Set<Character> = [" ", "\t", "\n", "*", "_", "`", "<", ">", "\"", "'", "|", "[", "]", ")"]
        var end = start
        while end < text.endIndex, !stoppers.contains(text[end]) {
            end = text.index(after: end)
        }
        var url = String(text[start..<end])
        while let last = url.last, ".,;:!?".contains(last) {
            url.removeLast()
            end = text.index(before: end)
        }
        guard url.count > "https://".count else { return nil }
        return ("[\(shortURLLabel(url))](\(schemed(url)))", end)
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("www.")
    }

    private static func schemed(_ value: String) -> String {
        value.hasPrefix("www.") ? "https://" + value : value
    }

    private static func middleTruncated(_ value: String, max: Int) -> String {
        guard value.count > max, max > 4 else { return value }
        let head = (max - 1) / 2
        let tail = max - 1 - head
        return String(value.prefix(head)) + "…" + String(value.suffix(tail))
    }

    private static func strippedEmphasis(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "[", let link = parseLink(in: text, from: index) {
                // Speak the label, not the destination.
                let label = link.markdown.hasPrefix("[")
                    ? String(link.markdown.dropFirst().prefix(while: { $0 != "]" }))
                    : link.markdown
                result += label
                index = link.end
                continue
            }
            if character == "*" || character == "`" || character == "~" {
                index = text.index(after: index)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func repairingClippedMarkdown(_ text: String) -> String {
        repairingTrailingMarkdown(text)
    }

    /// Removes a Markdown token the wire clip cut in half, so a truncated reply
    /// never shows a dangling `](https://…`.
    private static func repairingTrailingMarkdown(_ text: String) -> String {
        var result = text
        if let openBracket = result.lastIndex(of: "["), !result[openBracket...].contains(")") {
            result = String(result[..<openBracket]).trimmingCharacters(in: .whitespaces) + "…"
        }
        if result.filter({ $0 == "`" }).count % 2 == 1, let lastTick = result.lastIndex(of: "`") {
            result = String(result[..<lastTick]).trimmingCharacters(in: .whitespaces) + "…"
        }
        // An unclosed `**` would print literally once the parser gives up on it.
        if result.components(separatedBy: "**").count % 2 == 0,
           let lastBold = result.range(of: "**", options: .backwards) {
            result.removeSubrange(lastBold)
        }
        return result
    }

    // MARK: Line prefixes

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func headingPrefix(_ line: Substring) -> (level: Int, body: Substring)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 7 {
            level += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        guard index == line.endIndex || line[index] == " " else { return nil }
        var body = line[index...].drop(while: { $0 == " " })
        while let last = body.last, last == "#" || last == " " { body = body.dropLast() }
        guard !body.isEmpty else { return nil }
        return (level, body)
    }

    private static func quotePrefix(_ line: Substring) -> Substring? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        guard index < line.endIndex, line[index] == ">" else { return nil }
        while index < line.endIndex, line[index] == ">" || line[index] == " " { index = line.index(after: index) }
        let body = line[index...]
        return body.isEmpty ? nil : body
    }

    private static func listPrefix(_ line: Substring) -> (indent: Int, body: Substring)? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " {
            indent += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex, "-*+•".contains(line[index]) else { return nil }
        let afterMarker = line.index(after: index)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        let body = line[afterMarker...].drop(while: { $0 == " " })
        guard !body.isEmpty else { return nil }
        return (indent, body)
    }

    private static func orderedPrefix(_ line: Substring) -> (indent: Int, number: String, body: Substring)? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == " " {
            indent += 1
            index = line.index(after: index)
        }
        var digits = ""
        while index < line.endIndex, line[index].isNumber, digits.count < 3 {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        let afterMarker = line.index(after: index)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        let body = line[afterMarker...].drop(while: { $0 == " " })
        guard !body.isEmpty else { return nil }
        return (indent, digits, body)
    }

    private static func checkboxResolved(_ body: String) -> String {
        if body.hasPrefix("[ ] ") { return "☐ " + String(body.dropFirst(4)) }
        if body.lowercased().hasPrefix("[x] ") { return "☑ " + String(body.dropFirst(4)) }
        return body
    }

    private static func endsWithHardBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || line.hasSuffix("\\")
    }
}
