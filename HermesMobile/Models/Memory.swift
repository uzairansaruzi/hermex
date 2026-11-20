import Foundation

enum MemorySection: String, CaseIterable, Decodable, Encodable, Equatable, Identifiable {
    case memory
    case user
    case soul

    var id: String { rawValue }
}

struct MemoryResponse: Decodable, Equatable {
    let memory: String?
    let user: String?
    let soul: String?
    let memoryPath: String?
    let userPath: String?
    let soulPath: String?
    let memoryMtime: Double?
    let userMtime: Double?
    let soulMtime: Double?
    let projectContext: String?
    let projectContextName: String?
    let projectContextPath: String?
    let projectContextWorkspace: String?
    let projectContextMtime: Double?
    let projectContextShadowed: Bool?
    let externalNotesEnabled: Bool?
    var hiddenSections: Set<MemorySection> = []
    var characterLimits: [MemorySection: Int] = [:]
    var readOnlySections: Set<MemorySection> = []

    init(memory: String?, user: String?, soul: String?) {
        self.memory = memory
        self.user = user
        self.soul = soul
        memoryPath = nil
        userPath = nil
        soulPath = nil
        memoryMtime = nil
        userMtime = nil
        soulMtime = nil
        projectContext = nil
        projectContextName = nil
        projectContextPath = nil
        projectContextWorkspace = nil
        projectContextMtime = nil
        projectContextShadowed = nil
        externalNotesEnabled = nil
    }

    enum CodingKeys: String, CodingKey {
        case memory
        case user
        case soul
        case memoryPath
        case userPath
        case soulPath
        case memoryMtime
        case userMtime
        case soulMtime
        case projectContext
        case projectContextName
        case projectContextPath
        case projectContextWorkspace
        case projectContextMtime
        case projectContextShadowed
        case externalNotesEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memory = try container.decodeIfPresent(String.self, forKey: .memory)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        soul = try container.decodeIfPresent(String.self, forKey: .soul)
        memoryPath = try container.decodeIfPresent(String.self, forKey: .memoryPath)
        userPath = try container.decodeIfPresent(String.self, forKey: .userPath)
        soulPath = try container.decodeIfPresent(String.self, forKey: .soulPath)
        memoryMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .memoryMtime)
        userMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .userMtime)
        soulMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .soulMtime)
        projectContext = try container.decodeIfPresent(String.self, forKey: .projectContext)
        projectContextName = try container.decodeIfPresent(String.self, forKey: .projectContextName)
        projectContextPath = try container.decodeIfPresent(String.self, forKey: .projectContextPath)
        projectContextWorkspace = try container.decodeIfPresent(
            String.self,
            forKey: .projectContextWorkspace
        )
        projectContextMtime = try container.decodeFlexibleDoubleIfPresent(forKey: .projectContextMtime)
        if let flag = try? container.decode(Bool.self, forKey: .projectContextShadowed) {
            projectContextShadowed = flag
        } else if let list = try? container.nestedUnkeyedContainer(forKey: .projectContextShadowed) {
            projectContextShadowed = (list.count ?? 0) > 0
        } else {
            projectContextShadowed = nil
        }
        externalNotesEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .externalNotesEnabled)) ?? nil
    }
}

struct MemoryWriteResponse: Decodable, Equatable {
    let ok: Bool?
    let section: MemorySection?
    let path: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case section
        case path
        case error
    }

    init(saved section: MemorySection) {
        ok = true
        self.section = section
        path = nil
        error = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        if let rawSection = try container.decodeIfPresent(String.self, forKey: .section) {
            section = MemorySection(rawValue: rawSection)
        } else {
            section = nil
        }
        path = try container.decodeIfPresent(String.self, forKey: .path)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}


enum MemoryCanonicalizer {
    static let separator = "\n§\n"

    static func canonical(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var entries: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var line: [Unicode.Scalar] = []
        func endLine() {
            if trimmed(line[...]).elementsEqual(["§"]) {
                entries.append(current)
                current = []
            } else {
                if !current.isEmpty { current.append("\n") }
                current += line
            }
            line = []
        }
        var index = 0
        while index < scalars.count {
            switch scalars[index] {
            case "\r":
                if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                endLine()
            case "\n": endLine()
            default: line.append(scalars[index])
            }
            index += 1
        }
        endLine()
        entries.append(current)

        var seen: Set<[Unicode.Scalar]> = []
        var output = String.UnicodeScalarView()
        for entry in entries {
            let kept = Array(trimmed(entry[...]))
            guard !kept.isEmpty, seen.insert(kept).inserted else { continue }
            if !output.isEmpty { output.append(contentsOf: separator.unicodeScalars) }
            output.append(contentsOf: kept)
        }
        return String(output)
    }

    static func scalarCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    private static func trimmed(_ scalars: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
        guard let first = scalars.firstIndex(where: { !isPythonSpace($0) }),
              let last = scalars.lastIndex(where: { !isPythonSpace($0) }) else { return [] }
        return scalars[first...last]
    }

    private static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}

struct MemoryCharacterCount: Equatable {
    let count: Int
    let limit: Int

    init(draft: String, limit: Int) {
        count = MemoryCanonicalizer.scalarCount(MemoryCanonicalizer.canonical(draft))
        self.limit = limit
    }

    var isOver: Bool { count > limit }
    var overBy: Int { max(0, count - limit) }
}

struct MemoryConflict: Error, Equatable {}
