import Foundation

public struct HermexCustomHeader: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var sanitizedName: String {
        name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    public var sanitizedValue: String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    public var isSafeForClient: Bool {
        let normalized = sanitizedName.lowercased()
        guard !normalized.isEmpty, !sanitizedValue.isEmpty else { return false }
        guard normalized.unicodeScalars.allSatisfy({ Self.allowedHeaderNameCharacters.contains($0) }) else { return false }
        guard value.rangeOfCharacter(from: CharacterSet.newlines) == nil else { return false }
        return !Self.forbiddenHeaderNames.contains(normalized)
    }

    private static let forbiddenHeaderNames: Set<String> = [
        "origin",
        "referer",
        "host",
        "content-length"
    ]

    private static let allowedHeaderNameCharacters: CharacterSet = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
}

public extension Sequence where Element == HermexCustomHeader {
    func sanitizedForClient() -> [HermexCustomHeader] {
        filter(\.isSafeForClient)
    }
}
