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
    /// Which question one `complete.path` call asks the host.
    enum Word {
        /// The `@` panel's search (`panelWord`): a name finds matches in any folder.
        case panel
        /// One folder's entries starting with a name (`listingWord`), which is what
        /// confirms a known `@path`.
        case listing
    }

    /// The `@` panel's word for a query (#1388). A name of two or more characters
    /// asks the host's fuzzy search over the whole working folder as `@file:name`,
    /// which ranks files and folders alike and skips Profile mentions. A path with
    /// `/`, a single character and the bare trigger keep the one-folder listing, so
    /// `@src/` lists `src` and `@s` still offers the root's folders.
    static func panelWord(for query: String) -> String {
        guard searchesEveryFolder(query) else { return listingWord(for: query) }
        return "@file:" + query
    }

    /// Whether `panelWord` asks the whole-folder search for `query`: a name of two or more
    /// characters with no `/` or line break; spaces are fine. Files' workspace search (#1389)
    /// asks the host only then.
    static func searchesEveryFolder(_ query: String) -> Bool {
        !query.contains("/") && !query.contains(where: \.isNewline) && query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// A one-folder listing's word: the folder the query names, filtered to entries
    /// starting with its last component. The host answers only a non-empty word, and
    /// `.` is its own spelling for the root.
    static func listingWord(for query: String) -> String {
        query.isEmpty ? "." : query
    }

    /// The panel rows from one `complete.path` reply.
    ///
    /// A listing word answers plain relative paths; the panel's fuzzy word answers
    /// the same root-relative paths spelled `@file:` and `@folder:`. Directories end
    /// in `/` and carry `meta: "dir"`. `browsing` keeps a path with whitespace, which
    /// Files opens rather than inserts as a reference (#1389).
    static func matches(from reply: BotJSON, browsing: Bool = false) -> [ComposerFilePathSearch.Match] {
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
                  browsing || !path.contains(where: \.isWhitespace),
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
