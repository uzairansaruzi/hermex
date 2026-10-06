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
    /// What a Hermes host's files add (#1073); webui sends none of it, so its screen is
    /// unchanged. The sections the host's config turns off, each section's character limit,
    /// and the sections shown but not editable here: a file too large to read whole, or not text.
    var hiddenSections: Set<MemorySection> = []
    var characterLimits: [MemorySection: Int] = [:]
    var readOnlySections: Set<MemorySection> = []

    /// A Hermes host's sections, which come with no paths, times or project context.
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
        // Upstream (routes.py @ 312d3fab, verified live 2026-07-03) returns a *list* of
        // shadowed-file objects here; the API docs describe a boolean flag. Accept both:
        // `true` or a non-empty list means the active document shadows another file.
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

    /// A save a Hermes host confirmed (#1073).
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


/// A Hermes memory file (MEMORY.md, USER.md) in the agent's own format (#1073), so a save
/// never trips its drift check (`_detect_external_drift` in `tools/memory_tool_store.py`): the
/// agent refuses to replace or remove entries in a file whose trimmed text isn't the join of
/// its parsed entries. The host's file routes and `HermesMemoryClient` call it before a write.
enum MemoryCanonicalizer {
    /// What the agent writes between entries.
    static let separator = "\n§\n"

    /// `text` as the agent would write it: one leading BOM dropped, `\r\n` and `\r` read as
    /// `\n`, and every line that trims to `§` a separator. Each entry is trimmed as Python's
    /// `str.strip` trims, empty ones dropped and repeats dropped in order, then they are joined
    /// by `separator` with no trailing newline. The result is unchanged by a second pass.
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

    /// What the host counts against a limit: Python's `len`, Unicode scalars, so an emoji
    /// with a skin tone is 2 where Swift's `count` sees 1.
    static func scalarCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// `scalars` without the leading and trailing characters Python's `str.isspace()` matches,
    /// which adds U+001C-U+001F to Foundation's whitespace and newlines.
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

/// A Hermes memory editor's count against the host's limit (#1073): the scalars the agent
/// would store for `draft`, which is how the host counts.
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

/// A save that found the section's file changed on the host since its editor opened (#1073).
/// Nothing was written; the editor keeps its draft and offers Reload.
struct MemoryConflict: Error, Equatable {}
