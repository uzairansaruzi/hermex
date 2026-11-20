import Foundation

enum BotFilePathSearch {
    enum Word {
        case panel
        case listing
    }

    static func panelWord(for query: String) -> String {
        guard searchesEveryFolder(query) else { return listingWord(for: query) }
        return "@file:" + query
    }

    static func searchesEveryFolder(_ query: String) -> Bool {
        !query.contains("/") && !query.contains(where: \.isNewline) && query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    static func listingWord(for query: String) -> String {
        query.isEmpty ? "." : query
    }

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
