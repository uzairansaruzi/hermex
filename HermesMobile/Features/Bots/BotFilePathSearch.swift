import Foundation

/// The file and folder rows the Bot composer's `@` panel draws, read from the
/// direct connection's `complete.path`.
///
/// The host completes against the live session's working directory and does its
/// own ranking and capping, so the phone only translates rows and drops what a
/// `@path` reference cannot name. Template directives (`@diff`, `@url:…`) are
/// not files, and a path with whitespace or `..` could never read back as a
/// reference.
enum BotFilePathSearch {
    /// What one `complete.path` call asks for. The host answers a listing only
    /// for a non-empty word, and `.` is its own spelling for the root.
    static func word(for query: String) -> String {
        query.isEmpty ? "." : query
    }

    /// The panel rows from one `complete.path` reply.
    ///
    /// A path word answers plain relative paths; the host's directive and fuzzy
    /// forms spell the same entries as `@file:` and `@folder:`. Directories end
    /// in `/` and carry `meta: "dir"`.
    static func matches(from reply: BotJSON) -> [ComposerFilePathSearch.Match] {
        guard let items = reply["items"].list else { return [] }

        return items.compactMap { item in
            guard let text = item["text"].text, !text.isEmpty else { return nil }
            var path = text
            for prefix in ["@file:", "@folder:"] where path.hasPrefix(prefix) {
                path.removeFirst(prefix.count)
            }

            guard !path.isEmpty, !path.hasPrefix("@") else { return nil }
            let isDirectory = item["meta"].text == "dir" || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }

            guard !path.isEmpty, !path.hasPrefix("/"),
                  !path.contains(where: \.isWhitespace),
                  !path.split(separator: "/").contains("..")
            else { return nil }

            return ComposerFilePathSearch.Match(
                path: path,
                name: String(path.split(separator: "/").last ?? Substring(path)),
                parentPath: ComposerFilePathSearch.Match.parentPath(of: path),
                isDirectory: isDirectory
            )
        }
    }
}
