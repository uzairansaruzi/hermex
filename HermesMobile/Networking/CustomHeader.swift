import Foundation
import os

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
    var sanitizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var sanitizedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isApplicable: Bool {
        let name = sanitizedName
        guard !name.isEmpty else { return false }
        guard name.unicodeScalars.allSatisfy({ Self.headerNameAllowed.contains($0) }) else { return false }
        return value.rangeOfCharacter(from: .newlines) == nil
    }

    private static let headerNameAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        set.insert(charactersIn: "0"..."9")
        set.insert(charactersIn: "a"..."z")
        set.insert(charactersIn: "A"..."Z")
        return set
    }()
}

extension Array where Element == CustomHeader {
    func apply(to request: inout URLRequest) {
        for header in self where header.isApplicable {
            request.setValue(header.sanitizedValue, forHTTPHeaderField: header.sanitizedName)
        }
    }

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

    func sanitizedForStorage() -> [CustomHeader] {
        filter { !$0.sanitizedName.isEmpty }
    }

    func encodedForStorage() -> String? {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

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
