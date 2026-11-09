import Foundation

struct TranscriptLinkPreviewSnapshot: Equatable {
    let title: String?
    let displayURL: URL?
    let imageData: Data?

    init(title: String? = nil, displayURL: URL? = nil, imageData: Data? = nil) {
        self.title = Self.nonEmpty(title)
        self.displayURL = displayURL
        self.imageData = imageData
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

actor TranscriptLinkPreviewCache {
    static let shared = TranscriptLinkPreviewCache()

    private let maximumEntryCount: Int
    private var entries: [String: TranscriptLinkPreviewSnapshot] = [:]
    private var recency: [String] = []

    init(maximumEntryCount: Int = 96) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func snapshot(for url: URL) -> TranscriptLinkPreviewSnapshot? {
        guard let key = Self.cacheKey(for: url),
              let snapshot = entries[key]
        else {
            return nil
        }

        markRecentlyUsed(key)
        return snapshot
    }

    func store(_ snapshot: TranscriptLinkPreviewSnapshot, for url: URL) {
        guard let key = Self.cacheKey(for: url) else { return }

        entries[key] = snapshot
        markRecentlyUsed(key)
        evictIfNeeded()
    }

    static func cacheKey(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.fragment = nil

        if scheme == "http", components.port == 80 {
            components.port = nil
        } else if scheme == "https", components.port == 443 {
            components.port = nil
        }

        return components.url?.absoluteString
    }

    private func markRecentlyUsed(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount, let oldestKey = recency.first {
            recency.removeFirst()
            entries.removeValue(forKey: oldestKey)
        }
    }
}
