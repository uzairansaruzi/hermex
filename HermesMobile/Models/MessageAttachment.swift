import Foundation

struct MessageAttachment: Codable, Equatable {
    let name: String?
    let path: String?
    let mime: String?
    let size: Int?
    let isImage: Bool?

    init(
        name: String? = nil,
        path: String? = nil,
        mime: String? = nil,
        size: Int? = nil,
        isImage: Bool? = nil
    ) {
        self.name = name
        self.path = path
        self.mime = mime
        self.size = size
        self.isImage = isImage
    }

    init(from decoder: Decoder) throws {
        // Tolerant decoding: upstream may store bare filenames (legacy) or
        // objects with unexpected field names / types. Never crash the parent
        // ChatMessage decode because of one malformed attachment.

        // Some old server data stores attachments as bare strings.
        if let bareName = try? decoder.singleValueContainer().decode(String.self) {
            self.name = bareName
            self.path = nil
            self.mime = nil
            self.size = nil
            self.isImage = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.decodeLossyStringIfPresent(forKey: .name)
            ?? container.decodeLossyStringIfPresent(forKey: .filename)
        self.path = container.decodeLossyStringIfPresent(forKey: .path)
        self.mime = container.decodeLossyStringIfPresent(forKey: .mime)
        self.size = container.decodeLossyIntIfPresent(forKey: .size)
        self.isImage = container.decodeLossyBoolIfPresent(forKey: .isImage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(mime, forKey: .mime)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(isImage, forKey: .isImage)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case filename
        case path
        case mime
        case size
        case isImage
    }
}

extension MessageAttachment {
    /// Stable identity for matching the *same* attachment across two
    /// representations — e.g. an optimistic local bubble against its
    /// server-reloaded copy. Uses the lowercased last path component (basename)
    /// of the first non-empty `name`/`path`, NOT the raw value: the server
    /// returns an attachment's `path` inconsistently on reload — usually a bare
    /// filename, occasionally the full upload path — so comparing raw values
    /// fails to match an optimistic bubble (full upload path) against its
    /// reloaded copy (bare filename). Voice notes are the live case: #330
    /// dropped their `[Attached files: <path>]` marker, which had silently
    /// backfilled the path on reload, so basename matching is now the only
    /// reliable key. Returns `nil` when the attachment carries no usable
    /// name or path.
    var identityKey: String? {
        let raw = [name, path]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }
        let lastComponent = URL(fileURLWithPath: raw).lastPathComponent
        let value = (lastComponent.isEmpty ? raw : lastComponent).lowercased()
        return value.isEmpty ? nil : value
    }
}

extension MessageAttachment {
    static func inferredFromAttachedFilesMarker(in content: String?) -> [MessageAttachment]? {
        guard let content,
              let marker = attachedFilesMarker(in: content)
        else {
            return nil
        }

        let inferredDirectory = marker.references
            .first(where: { $0.contains("/") })
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }

        let attachments = marker.references.map { reference in
            let name = displayName(for: reference)
            let path = inferredPath(for: reference, fallbackDirectory: inferredDirectory)
            return MessageAttachment(
                name: name,
                path: path,
                mime: nil,
                size: nil,
                isImage: isImageReference(reference)
            )
        }

        return attachments.isEmpty ? nil : attachments
    }

    /// Returns the message text with the trailing `[Attached files: …]` marker
    /// (and the blank-line separator it was appended after) removed, for the
    /// display layer to render. Reuses the same parser as attachment inference
    /// so the two can never disagree about what counts as a marker. The sent
    /// payload is built elsewhere and is unaffected by this display transform.
    static func contentWithoutAttachedFilesMarker(in content: String) -> String {
        guard let marker = attachedFilesMarker(in: content) else {
            return content
        }

        // The parser rejects any non-whitespace after the closing bracket, so
        // the marker is always a suffix; everything before it is the user's
        // typed message. Drop the trailing separator whitespace as well.
        var prefix = content[..<marker.range.lowerBound]
        while let last = prefix.last, last.isWhitespace {
            prefix = prefix.dropLast()
        }
        return String(prefix)
    }

    private static func attachedFilesMarker(
        in content: String
    ) -> (range: Range<String.Index>, references: [String])? {
        guard let markerRange = content.range(of: "[Attached files:", options: .backwards) else {
            return nil
        }

        let afterMarker = content[markerRange.upperBound...]
        guard let closeBracket = afterMarker.firstIndex(of: "]") else {
            return nil
        }

        let afterBracket = afterMarker[afterMarker.index(after: closeBracket)...]
        guard afterBracket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let references = afterMarker[..<closeBracket]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let markerEnd = afterMarker.index(after: closeBracket)
        return (markerRange.lowerBound..<markerEnd, references)
    }

    /// A Hermes session's user text as its transcript shows it (#1012), and the chips it
    /// names. Each `\n\n` block that is a reference a Hermex send appends becomes a chip:
    /// Hermes's vision-tool instruction pair (`BotAttachmentUpload.imageReference`) or a
    /// lone `@file:` token, plain or quoted (`file.attach`'s `ref_text`). The footer the
    /// host saves after a prompt's `@file:` tokens (`--- Context Warnings ---` and
    /// `--- Attached Context ---`, with the text or path it inlines) is dropped. Each
    /// attachment carries its display name and the host path the reference names, which
    /// Bot Chat (#1017) and a Hermes session's chips (#1030) download through; neither shows it.
    /// Text with neither comes back as it is. The webui marker rule above is separate and
    /// never reads these.
    static func hermesReferences(in content: String) -> (text: String, attachments: [MessageAttachment]) {
        guard content.contains("@file:") || content.contains("[The user attached an image: ")
                || content.contains(" Context ---") || content.contains("--- Context Warnings ---")
        else { return (content, []) }
        // Hermes's text-mode image line pair, whose first line names the stored file and second
        // its POSIX or Windows path (`BotAttachmentUpload.isHostAbsolute`), and an `@file:`
        // token as `file.attach` quotes it: backticks, double or single quotes, or bare.
        let imageReference =
            /\[The user attached an image: ([^\n]*)\]\n\[Examine it with the vision_analyze tool using image_url: ((?:\/|[A-Za-z]:[\\\/])[^\n]*)\]/
        let fileReference = /@file:(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|(\S+))/
        var text = content
        let footer = text.firstRange(of: /(?:^|\n)--- (?:Context Warnings|Attached Context) ---[ \t]*(?:\n|$)/)
        if let footer { text = String(text[..<footer.lowerBound]) }
        var kept: [String] = []
        var attachments: [MessageAttachment] = []
        for block in text.components(separatedBy: "\n\n") {
            let line = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if let image = line.wholeMatch(of: imageReference) {
                attachments.append(MessageAttachment(name: hermesImageName(image.1), path: String(image.2), isImage: true))
            } else if let file = line.wholeMatch(of: fileReference),
                      let path = file.1 ?? file.2 ?? file.3 ?? file.4 {
                attachments.append(MessageAttachment(name: hermesFileName(path), path: String(path), isImage: false))
            } else {
                kept.append(block)
            }
        }
        guard footer != nil || !attachments.isEmpty else { return (content, []) }
        var shown = Substring(kept.joined(separator: "\n\n"))
        while shown.last?.isWhitespace == true { shown = shown.dropLast() }
        return (String(shown), attachments)
    }

    /// A Hermes session's title or `preview` as a session row and the chat header show it
    /// (#1046). The reference lines a Hermex send appends (`hermesReferences`) are dropped, as
    /// saved or flattened onto one line as `preview` has them, and so is one the host cut off
    /// at the end of a short title (48 characters and `…`) or a `preview` (60 and `...`). With
    /// no typed text left, the first attachment's name stands in; nil when there is none,
    /// such as a reference cut before its name, so the caller falls back. Display only:
    /// nothing is written to the host, and text without a reference comes back as it is.
    static func hermesTitle(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Every reference, and every cut one, opens with `[` or `@`.
        guard text.contains("[") || text.contains("@") else { return text }
        let saved = hermesReferences(in: text)
        var names = saved.attachments.compactMap(\.name)
        var line = saved.text.replacing(/\s+/, with: " ")
        let cut = ["...", "…"].first { line.hasSuffix($0) }
        if let cut { line.removeLast(cut.count) }
        let reference = /\[The user attached an image: ([^\]]*)\]|\[Examine it with the vision_analyze tool using image_url: [^\]]*\]|@file:(?:`([^`]+)`|"([^"]+)"|'([^']+)'|(\S+))/
        let matches = line.matches(of: reference)
        // A token that runs into the cut is not whole, so neither is its name.
        var cutInsideReference = cut != nil && matches.last?.range.upperBound == line.endIndex
        for match in matches where !(cutInsideReference && match.range == matches.last?.range) {
            if let image = match.output.1 {
                names.append(hermesImageName(image))
            } else if let path = match.output.2 ?? match.output.3 ?? match.output.4 ?? match.output.5 {
                names.append(hermesFileName(path))
            }
        }
        for match in matches.reversed() { line.removeSubrange(match.range) }
        // A reference the cut ended inside its opening words, or before its closing bracket.
        if cut != nil, let start = line.lastIndex(where: { $0 == "[" || $0 == "@" }) {
            let tail = String(line[start...])
            let markers = ["[The user attached an image: ", "[Examine it with the vision_analyze tool using image_url: ", "@file:"]
            if markers.contains(where: { $0.hasPrefix(tail) || tail.hasPrefix($0) }) {
                line.removeSubrange(start...)
                cutInsideReference = true
            }
        }
        guard !matches.isEmpty || cutInsideReference || !saved.attachments.isEmpty || saved.text != text else { return text }
        let typed = line.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed + (cutInsideReference ? "" : cut ?? "") }
        return names.first
    }

    /// An image reference's file name without the `dashboard_<date>_<time>_<hex>_` prefix the
    /// host's upload gave it.
    private static func hermesImageName(_ name: Substring) -> String {
        String(name).replacing(/^dashboard_\d{8}_\d{6}_[0-9a-f]{8}_/, with: "")
    }

    /// An `@file:` path's file name without the UUID prefix `file.attach` gave it.
    private static func hermesFileName(_ path: Substring) -> String {
        URL(fileURLWithPath: String(path)).lastPathComponent
            .replacing(/^[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}-/, with: "")
    }

    private static func displayName(for reference: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: reference).lastPathComponent
        return lastPathComponent.isEmpty ? reference : lastPathComponent
    }

    private static func inferredPath(for reference: String, fallbackDirectory: String?) -> String? {
        if reference.contains("/") {
            return reference
        }

        guard isImageReference(reference),
              let fallbackDirectory,
              !fallbackDirectory.isEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: fallbackDirectory)
            .appendingPathComponent(reference)
            .path
    }

    private static func isImageReference(_ reference: String) -> Bool {
        let ext = URL(fileURLWithPath: reference).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext)
    }
}
