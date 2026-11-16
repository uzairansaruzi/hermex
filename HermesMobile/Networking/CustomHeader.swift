import Foundation
import os

/// A single user-supplied HTTP request header attached to every outgoing request.
///
/// This exists so self-hosters behind an authenticated reverse proxy (e.g.
/// Authentik) or a token-gated WebUI can reach a deployment the password-only
/// flow can't. The value may be a secret, so the list is persisted in the
/// Keychain (see `KeychainStore.Key.customHeaders`). See issue #255.
///
/// `id` is a transient identity for SwiftUI editor rows only — it is never
/// encoded and is regenerated on decode, so equality and storage compare just
/// the `name`/`value` content.
struct CustomHeader: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case name
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        // Tolerant: a malformed/missing field decodes to empty rather than throwing,
        // so one bad entry can't wipe the whole stored list.
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        value = (try? container.decode(String.self, forKey: .value)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }

    static func == (lhs: CustomHeader, rhs: CustomHeader) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value
    }
}

extension CustomHeader {
    /// Leading/trailing whitespace and newlines trimmed; internal spaces (e.g.
    /// `Bearer <token>`) are preserved.
    var sanitizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var sanitizedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A header is usable when its name is a valid RFC 7230 token (non-empty, only
    /// token characters — so no spaces or colons, which the URL loading system
    /// would silently drop) and its value contains no newline (which would allow
    /// HTTP header injection). Empty or malformed rows — e.g. one the user is
    /// still typing — are simply skipped.
    var isApplicable: Bool {
        let name = sanitizedName
        guard !name.isEmpty else { return false }
        guard name.unicodeScalars.allSatisfy({ Self.headerNameAllowed.contains($0) }) else { return false }
        return value.rangeOfCharacter(from: .newlines) == nil
    }

    /// RFC 7230 `token` characters allowed in a header field name.
    private static let headerNameAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        set.insert(charactersIn: "0"..."9")
        set.insert(charactersIn: "a"..."z")
        set.insert(charactersIn: "A"..."Z")
        return set
    }()
}

extension Array where Element == CustomHeader {
    /// Sets each applicable header on the request. The caller sets built-in
    /// headers (`Accept`/`Content-Type`) *after* calling this so built-ins always
    /// win those keys; any other header (`Authorization`, `X-Api-Key`, …) passes
    /// through. An empty list is a true no-op — the request is left byte-identical.
    func apply(to request: inout URLRequest) {
        for header in self where header.isApplicable {
            request.setValue(header.sanitizedValue, forHTTPHeaderField: header.sanitizedName)
        }
    }

    /// Merges these headers underneath `builtIns` into a single dictionary so
    /// built-ins win on collision, whatever the case of the name. Used for the SSE
    /// stream, whose client takes a header dictionary rather than a `URLRequest`.
    func merged(under builtIns: [String: String]) -> [String: String] {
        let builtInNames = Set(builtIns.keys.map { $0.lowercased() })
        var result: [String: String] = [:]
        for header in self where header.isApplicable && !builtInNames.contains(header.sanitizedName.lowercased()) {
            result[header.sanitizedName] = header.sanitizedValue
        }
        for (key, value) in builtIns {
            result[key] = value
        }
        return result
    }

    /// Drops rows with no usable name (blank/whitespace-only) so half-typed
    /// placeholder rows aren't stored or applied; the rest are kept verbatim.
    func sanitizedForStorage() -> [CustomHeader] {
        filter { !$0.sanitizedName.isEmpty }
    }

    /// JSON string (`[{"name":…,"value":…}]`) for Keychain storage, or `nil` if
    /// the list is empty or can't be encoded.
    func encodedForStorage() -> String? {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes a stored JSON string back into headers. Any failure (nil, garbage,
    /// schema drift) yields an empty list rather than throwing.
    static func decodeFromStorage(_ string: String?) -> [CustomHeader] {
        guard
            let string,
            let data = string.data(using: .utf8),
            let headers = try? JSONDecoder().decode([CustomHeader].self, from: data)
        else {
            return []
        }
        return headers
    }
}

/// Process-wide, thread-safe snapshot of the user's custom headers.
///
/// The app has no dependency-injection container — `APIClient`/`SSEClient` are
/// built ad hoc in ~20 places — so each reads the current headers from here when
/// building a request (at request time, so even long-lived clients pick up an
/// edit immediately). `AuthManager` owns all writes: it loads from the Keychain
/// on launch and replaces the snapshot whenever the user edits headers.
final class CustomHeaderStore: Sendable {
    static let shared = CustomHeaderStore()

    private let storage: OSAllocatedUnfairLock<[CustomHeader]>

    init(headers: [CustomHeader] = []) {
        storage = OSAllocatedUnfairLock(initialState: headers)
    }

    func snapshot() -> [CustomHeader] {
        storage.withLock { $0 }
    }

    func replace(with headers: [CustomHeader]) {
        storage.withLock { $0 = headers }
    }
}
