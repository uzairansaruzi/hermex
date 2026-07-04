import Foundation

struct WikiSettings {
    static let baseURLKey = "wiki.baseURL"
    static let defaultBaseURLString = "https://wiki.sourcebottle.dev"

    static var defaultBaseURL: URL {
        URL(string: defaultBaseURLString)!
    }

    static func baseURL(from storedValue: String) -> URL {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return defaultBaseURL
        }
        return url
    }
}

struct WikiRoute: Hashable, Identifiable {
    enum Kind: Hashable {
        case page(path: String, title: String?)
        case app(path: String)
        case web(URL)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .page(let path, let title):
            return "page:\(path):\(title ?? "")"
        case .app(let path):
            return "app:\(path)"
        case .web(let url):
            return "web:\(url.absoluteString)"
        }
    }

    var title: String {
        switch kind {
        case .page(let path, let title):
            return title ?? Self.displayTitle(for: path)
        case .app(let path):
            return path == "/apps" ? String(localized: "Wiki Apps") : Self.displayTitle(for: path)
        case .web(let url):
            return url.host ?? String(localized: "Wiki")
        }
    }

    var prefersNativeRendering: Bool {
        if case .page = kind { return true }
        return false
    }

    func webURL(baseURL: URL) -> URL {
        switch kind {
        case .page(let path, _):
            return WikiURLBuilder.url(forWikiPath: path, baseURL: baseURL, preferredExtension: nil)
        case .app(let path):
            return WikiURLBuilder.url(forWikiPath: path, baseURL: baseURL, preferredExtension: nil)
        case .web(let url):
            return url
        }
    }

    static func displayTitle(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let withoutExtension = last.replacingOccurrences(of: ".md", with: "")
        let spaced = withoutExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return spaced.isEmpty ? String(localized: "Wiki") : spaced
    }
}

enum WikiLinkResolver {
    static let deepLinkHost = "wiki"
    static let routeQueryItem = "route"
    static let pathQueryItem = "path"
    static let titleQueryItem = "title"
    static let urlQueryItem = "url"

    static func deepLink(for route: WikiRoute) -> URL? {
        var components = URLComponents()
        components.scheme = HermesDeepLink.scheme
        components.host = deepLinkHost

        switch route.kind {
        case .page(let path, let title):
            var queryItems = [
                URLQueryItem(name: routeQueryItem, value: "page"),
                URLQueryItem(name: pathQueryItem, value: path)
            ]
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queryItems.append(URLQueryItem(name: titleQueryItem, value: title))
            }
            components.queryItems = queryItems
        case .app(let path):
            components.queryItems = [
                URLQueryItem(name: routeQueryItem, value: "app"),
                URLQueryItem(name: pathQueryItem, value: path)
            ]
        case .web(let url):
            components.queryItems = [
                URLQueryItem(name: routeQueryItem, value: "web"),
                URLQueryItem(name: urlQueryItem, value: url.absoluteString)
            ]
        }

        return components.url
    }

    static func resolve(_ url: URL, wikiBaseURL: URL = WikiSettings.defaultBaseURL) -> WikiRoute? {
        if url.scheme?.lowercased() == HermesDeepLink.scheme,
           url.host?.lowercased() == deepLinkHost {
            return resolveHermesWikiURL(url)
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        guard hostsMatch(url.host, wikiBaseURL.host) else {
            return nil
        }

        let path = url.path.isEmpty ? "/" : url.path
        if path == "/apps" || path.hasPrefix("/apps/") {
            return WikiRoute(kind: .app(path: path))
        }

        return WikiRoute(kind: .web(url))
    }

    private static func resolveHermesWikiURL(_ url: URL) -> WikiRoute? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let route = queryValue(routeQueryItem, in: items)?.lowercased()

        switch route {
        case "page":
            guard let path = normalizedWikiPath(queryValue(pathQueryItem, in: items)) else { return nil }
            return WikiRoute(kind: .page(path: path, title: queryValue(titleQueryItem, in: items)))
        case "app":
            guard let path = normalizedAppPath(queryValue(pathQueryItem, in: items)) else { return nil }
            return WikiRoute(kind: .app(path: path))
        case "web":
            guard let rawURL = queryValue(urlQueryItem, in: items), let url = URL(string: rawURL) else { return nil }
            return WikiRoute(kind: .web(url))
        default:
            return nil
        }
    }

    private static func normalizedWikiPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("..") else { return nil }
        return trimmed
    }

    private static func normalizedAppPath(_ raw: String?) -> String? {
        guard let raw else { return "/apps" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/apps" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        guard prefixed == "/apps" || prefixed.hasPrefix("/apps/") else {
            return "/apps/\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        }
        return prefixed
    }

    private static func queryValue(_ name: String, in items: [URLQueryItem]) -> String? {
        guard let value = items.first(where: { $0.name == name })?.value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hostsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        lhs?.lowercased() == rhs?.lowercased()
    }
}

enum WikiWikilinkPreprocessor {
    static func replacingWikilinks(in content: String) -> String {
        guard content.contains("[[") else { return content }

        var output = ""
        var index = content.startIndex
        var isInFence = false
        var fenceMarker: String?
        var isInInlineCode = false
        var isAtLineStart = true

        while index < content.endIndex {
            if isAtLineStart, let marker = fenceMarkerStarting(at: index, in: content) {
                if isInFence, marker == fenceMarker {
                    isInFence = false
                    fenceMarker = nil
                } else if !isInFence {
                    isInFence = true
                    fenceMarker = marker
                }
                appendCurrentCharacter(from: content, at: &index, to: &output, isAtLineStart: &isAtLineStart)
                continue
            }

            if !isInFence, content[index] == "`" {
                isInInlineCode.toggle()
                appendCurrentCharacter(from: content, at: &index, to: &output, isAtLineStart: &isAtLineStart)
                continue
            }

            if !isInFence,
               !isInInlineCode,
               content[index...].hasPrefix("[["),
               let closeRange = content[index...].range(of: "]]") {
                let innerStart = content.index(index, offsetBy: 2)
                let rawInner = String(content[innerStart..<closeRange.lowerBound])
                if let replacement = markdownLink(forRawWikilink: rawInner) {
                    output += replacement
                    index = closeRange.upperBound
                    isAtLineStart = false
                    continue
                }
            }

            appendCurrentCharacter(from: content, at: &index, to: &output, isAtLineStart: &isAtLineStart)
        }

        return output
    }

    static func markdownLink(forRawWikilink rawInner: String) -> String? {
        let parts = rawInner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawPath = parts.first else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n"), !path.contains("..") else { return nil }

        let title: String
        if parts.count > 1 {
            title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = WikiRoute.displayTitle(for: path)
        }
        let displayTitle = title.isEmpty ? WikiRoute.displayTitle(for: path) : title
        let route = WikiRoute(kind: .page(path: path, title: displayTitle))
        guard let url = WikiLinkResolver.deepLink(for: route) else { return nil }
        return "[\(escapeMarkdownLinkText(displayTitle))](\(url.absoluteString))"
    }

    private static func fenceMarkerStarting(at index: String.Index, in content: String) -> String? {
        let suffix = content[index...]
        if suffix.hasPrefix("```") { return "```" }
        if suffix.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func appendCurrentCharacter(
        from content: String,
        at index: inout String.Index,
        to output: inout String,
        isAtLineStart: inout Bool
    ) {
        let character = content[index]
        output.append(character)
        isAtLineStart = character == "\n"
        index = content.index(after: index)
    }

    private static func escapeMarkdownLinkText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

enum WikiURLBuilder {
    static func url(forWikiPath path: String, baseURL: URL, preferredExtension: String?) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath = cleanPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { encodePathComponent(String($0)) }
            .joined(separator: "/")

        var combined = [basePath, encodedPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        if let preferredExtension,
           !preferredExtension.isEmpty,
           !combined.lowercased().hasSuffix(".\(preferredExtension.lowercased())") {
            combined += ".\(preferredExtension)"
        }

        components.percentEncodedPath = "/\(combined)"
        return components.url ?? baseURL
    }

    static func markdownCandidateURLs(for path: String, baseURL: URL) -> [URL] {
        var candidates: [URL] = []
        candidates.append(url(forWikiPath: path, baseURL: baseURL, preferredExtension: "md"))
        candidates.append(url(forWikiPath: path, baseURL: baseURL, preferredExtension: nil))

        let indexPath = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .appending("/index")
        candidates.append(url(forWikiPath: indexPath, baseURL: baseURL, preferredExtension: "md"))

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func encodePathComponent(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}

enum WikiMarkdownDocumentFormatter {
    static func displayMarkdown(from raw: String, title: String) -> String {
        var markdown = raw
        if markdown.hasPrefix("---\n"),
           let closing = markdown.dropFirst(4).range(of: "\n---\n") {
            markdown.removeSubrange(markdown.startIndex..<closing.upperBound)
        }

        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#") else { return trimmed }
        return "# \(title)\n\n\(trimmed)"
    }
}
