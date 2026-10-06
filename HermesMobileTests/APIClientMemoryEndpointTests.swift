import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientMemoryEndpointTests: APIClientTestCase {
    func testMemoryBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes\\n\\n- Prefer SwiftUI",
              "user": "# Profile\\n\\n- Name: Developer",
              "soul": "# Agent Soul\\n\\n- Be concise",
              "memory_path": "/Users/test/.hermes/memories/MEMORY.md",
              "user_path": "/Users/test/.hermes/memories/USER.md",
              "soul_path": "/Users/test/.hermes/SOUL.md",
              "memory_mtime": 1770000000,
              "user_mtime": 1770000100,
              "soul_mtime": "1770000200",
              "project_context": "# Project\\n\\n- Ship it",
              "project_context_name": "AGENTS.md",
              "project_context_path": "/Users/test/workspace/AGENTS.md",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_mtime": 1770000300,
              "project_context_shadowed": [
                {
                  "name": "PROJECT.md",
                  "path": "/Users/test/PROJECT.md",
                  "shadowed_by": "AGENTS.md"
                }
              ],
              "external_notes_enabled": true
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.memory, "# Notes\n\n- Prefer SwiftUI")
        XCTAssertEqual(response.user, "# Profile\n\n- Name: Developer")
        XCTAssertEqual(response.soul, "# Agent Soul\n\n- Be concise")
        XCTAssertEqual(response.memoryPath, "/Users/test/.hermes/memories/MEMORY.md")
        XCTAssertEqual(response.userPath, "/Users/test/.hermes/memories/USER.md")
        XCTAssertEqual(response.soulPath, "/Users/test/.hermes/SOUL.md")
        XCTAssertEqual(response.memoryMtime, 1_770_000_000)
        XCTAssertEqual(response.userMtime, 1_770_000_100)
        XCTAssertEqual(response.soulMtime, 1_770_000_200)
        XCTAssertEqual(response.projectContext, "# Project\n\n- Ship it")
        XCTAssertEqual(response.projectContextName, "AGENTS.md")
        XCTAssertEqual(response.projectContextPath, "/Users/test/workspace/AGENTS.md")
        XCTAssertEqual(response.projectContextWorkspace, "/Users/test/workspace")
        XCTAssertEqual(response.projectContextMtime, 1_770_000_300)
        XCTAssertEqual(response.projectContextShadowed, true)
        XCTAssertEqual(response.externalNotesEnabled, true)
    }

    func testMemoryToleratesMissingFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "",
              "user": null
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.memory, "")
        XCTAssertNil(response.user)
        XCTAssertNil(response.soul)
        XCTAssertNil(response.memoryMtime)
        XCTAssertNil(response.userMtime)
        XCTAssertNil(response.soulMtime)
        XCTAssertNil(response.projectContext)
        XCTAssertNil(response.projectContextName)
        XCTAssertNil(response.projectContextPath)
        XCTAssertNil(response.projectContextWorkspace)
        XCTAssertNil(response.projectContextMtime)
        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testMemoryDecodesProjectContextShadowedBooleanShape() async throws {
        // The API docs describe project_context_shadowed as a boolean flag even though
        // upstream currently sends a list; both shapes must decode.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": true
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.projectContext, "# Project")
        XCTAssertEqual(response.projectContextShadowed, true)
    }

    func testMemoryDecodesEmptyShadowedListAsNotShadowed() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": []
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertEqual(response.projectContextShadowed, false)
    }

    func testMemoryToleratesNullAndUnexpectedShadowedShapes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "project_context": "# Project",
              "project_context_shadowed": null,
              "external_notes_enabled": "yes"
            }
            """, for: request)
        }

        let response = try await client.memory()

        XCTAssertNil(response.projectContextShadowed)
        XCTAssertNil(response.externalNotesEnabled)
    }

    func testMemoryWriteBuildsExpectedPathBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory/write")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["section"] as? String, "user")
            XCTAssertEqual(body?["content"] as? String, "# Profile\n\n- Updated from iOS")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "section": "user",
              "path": "/Users/test/.hermes/memories/USER.md",
              "unexpected": "ignored"
            }
            """, for: request)
        }

        let response = try await client.writeMemory(section: .user, content: "# Profile\n\n- Updated from iOS")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.section, .user)
        XCTAssertEqual(response.path, "/Users/test/.hermes/memories/USER.md")
    }

    func testMemoryWriteToleratesMissingFieldsAndUnknownSection() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory/write")

            return apiTestJSONResponse("""
            {
              "section": "future"
            }
            """, for: request)
        }

        let response = try await client.writeMemory(section: .soul, content: "# Soul")

        XCTAssertNil(response.ok)
        XCTAssertNil(response.section)
        XCTAssertNil(response.path)
    }
}

/// A Hermes memory file as Hermex saves it (#1073): every output is what the agent itself
/// would write, so its drift check (`AgentMemoryDrift`) never refuses to edit it afterwards.
final class MemoryCanonicalizerTests: XCTestCase {
    private static let inputs = [
        "",
        " \n\t\n",
        "Uzair prefers short PR descriptions.\n§\nHermex builds in Swift 5 mode.",
        "a\n\n§\n\nb\n",
        "§\n§\n  a  \n§\n\n§",
        "a\n§\nb\n§\na",
        "a\r\n§\r\nb\r\nline two\rline three",
        "\u{FEFF}a\n§\nb",
        "a\n  §  \nb\n\t§\nc",
        "a § b\n§§\nc",
        "first\u{1C}\n§\n\u{2028}second\u{3000}",
        "one\n§\n§\n§\ntwo",
        "👍🏽 thumbs\n§\nfamily 👨‍👩‍👧"
    ]

    func testTheAgentsOwnFileIsUnchanged() {
        let agentWritten = "Uzair prefers short PR descriptions.\n§\nHermex builds in Swift 5 mode.\n§\n- a list\n- inside one entry"

        XCTAssertEqual(MemoryCanonicalizer.canonical(agentWritten), agentWritten)
    }

    func testBlankLinesEmptyEntriesAndDuplicatesAreDropped() {
        XCTAssertEqual(MemoryCanonicalizer.canonical("a\n\n§\n\nb\n"), "a\n§\nb")
        XCTAssertEqual(MemoryCanonicalizer.canonical("§\n§\n  a  \n§\n\n§"), "a")
        XCTAssertEqual(MemoryCanonicalizer.canonical("a\n§\nb\n§\na"), "a\n§\nb")
        XCTAssertEqual(MemoryCanonicalizer.canonical(" \n\t\n"), "")
    }

    func testLineEndingsAndAByteOrderMarkAreTheAgents() {
        XCTAssertEqual(MemoryCanonicalizer.canonical("a\r\n§\r\nb\r\nline two\rline three"), "a\n§\nb\nline two\nline three")
        XCTAssertEqual(MemoryCanonicalizer.canonical("\u{FEFF}a\n§\nb"), "a\n§\nb")
    }

    func testASpacedSectionSignLineSeparatesAndAnInlineOneIsText() {
        XCTAssertEqual(MemoryCanonicalizer.canonical("a\n  §  \nb\n\t§\nc"), "a\n§\nb\n§\nc")
        XCTAssertEqual(MemoryCanonicalizer.canonical("a § b\n§§\nc"), "a § b\n§§\nc")
    }

    /// Python's `str.strip` also trims separators such as U+001C and U+3000, which Foundation's
    /// whitespace set keeps; the agent's parse strips them, so the saved text must not keep them.
    func testEntriesAreTrimmedAsTheAgentTrimsThem() {
        XCTAssertEqual(MemoryCanonicalizer.canonical("first\u{1C}\n§\n\u{2028}second\u{3000}"), "first\n§\nsecond")
    }

    func testEveryOutputIsStableAndPassesTheAgentsDriftCheck() {
        for input in Self.inputs {
            let output = MemoryCanonicalizer.canonical(input)
            XCTAssertEqual(MemoryCanonicalizer.canonical(output), output, "Not idempotent for \(input.debugDescription)")
            XCTAssertFalse(AgentMemoryDrift.detects(output, limit: 2200), "Drift for \(input.debugDescription) → \(output.debugDescription)")
        }
    }

    /// The host counts Python `len`: Unicode scalars, not the characters Swift's `count` sees.
    func testTheCountIsUnicodeScalars() {
        XCTAssertEqual(MemoryCanonicalizer.scalarCount("👍🏽"), 2)
        XCTAssertEqual(MemoryCanonicalizer.scalarCount("👨‍👩‍👧"), 5)
        XCTAssertEqual(MemoryCanonicalizer.scalarCount("e\u{301}"), 2)
        XCTAssertEqual(MemoryCanonicalizer.scalarCount("a\n§\nb"), 5)
    }
}

/// A Swift port of the agent's drift check, `MemoryStore._detect_external_drift`
/// (`tools/memory_tool_store.py` at `HERMES_AGENT_TESTED_SHA`), reading the file as the agent
/// does (`utf-8-sig`, universal newlines). Drift means the agent refuses to replace or remove
/// entries: the text is not the join of its parsed entries, or one entry is over the limit.
enum AgentMemoryDrift {
    /// `str.isspace()` in CPython, listed rather than borrowed from the code under test.
    private static let pythonWhitespace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000
    ]
    private static let delimiter = Array("\n§\n".unicodeScalars).map(\.value)

    static func detects(_ written: String, limit: Int) -> Bool {
        let raw = read(written)
        let stripped = strip(raw)
        guard !stripped.isEmpty else { return false }
        let parsed = split(raw).map(strip).filter { !$0.isEmpty }
        var joined: [UInt32] = []
        for (index, entry) in parsed.enumerated() {
            if index > 0 { joined += delimiter }
            joined += entry
        }
        return !(stripped == joined && (parsed.map(\.count).max() ?? 0) <= limit)
    }

    /// `read_text(encoding="utf-8-sig")`: one leading BOM dropped, `\r\n` and `\r` read as `\n`.
    private static func read(_ text: String) -> [UInt32] {
        var scalars = Array(text.unicodeScalars).map(\.value)
        if scalars.first == 0xFEFF { scalars.removeFirst() }
        var out: [UInt32] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == 0x0D {
                out.append(0x0A)
                if index + 1 < scalars.count, scalars[index + 1] == 0x0A { index += 1 }
            } else {
                out.append(scalars[index])
            }
            index += 1
        }
        return out
    }

    private static func strip(_ scalars: [UInt32]) -> [UInt32] {
        guard let first = scalars.firstIndex(where: { !pythonWhitespace.contains($0) }),
              let last = scalars.lastIndex(where: { !pythonWhitespace.contains($0) }) else { return [] }
        return Array(scalars[first...last])
    }

    /// `str.split(delimiter)`: left to right, non-overlapping.
    private static func split(_ scalars: [UInt32]) -> [[UInt32]] {
        var pieces: [[UInt32]] = []
        var current: [UInt32] = []
        var index = 0
        while index < scalars.count {
            if index + delimiter.count <= scalars.count, Array(scalars[index..<index + delimiter.count]) == delimiter {
                pieces.append(current)
                current = []
                index += delimiter.count
            } else {
                current.append(scalars[index])
                index += 1
            }
        }
        pieces.append(current)
        return pieces
    }
}

/// Memory on a Hermes host (#1073): `HermesMemoryClient` on a scripted host whose routes answer
/// as `scripts/local-hermes` did at the pin (0.21.5, ca678285), for the `research` Profile.
@MainActor final class HermesMemoryClientTests: XCTestCase {
    private static let home = "/Users/someone/.hermes/profiles/research"
    private static let notes = home + "/memories/MEMORY.md"
    private static let user = home + "/memories/USER.md"

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testLoadReadsTheProfilesFilesFromItsListRowAndTheHostsLimits() async throws {
        let host = MemoryHost(files: [Self.notes: "Prefers short PRs\n§\nBuilds in Swift 5"], soul: "Be direct.")
        host.config = ["memory_char_limit": .string("3000"), "user_char_limit": .number(900)]

        let response = try await client(host).memory()

        XCTAssertEqual(response.memory, "Prefers short PRs\n§\nBuilds in Swift 5")
        XCTAssertEqual(response.user, "", "A Profile without USER.md has an empty user profile")
        XCTAssertEqual(response.soul, "Be direct.")
        XCTAssertEqual(response.characterLimits, [.memory: 3000, .user: 900])
        XCTAssertEqual(response.hiddenSections, [])
        XCTAssertEqual(response.readOnlySections, [])
        XCTAssertNil(response.memoryPath)
        XCTAssertNil(response.memoryMtime)
        XCTAssertEqual(Set(host.reads()), [Self.notes, Self.user], "Only the row's own memories folder is read")
        XCTAssertEqual(HermesHostFixture.requests.first { $0.url?.path == "/api/config" }?.url?.query, "profile=research")
    }

    func testAPlusInTheProfilesPathIsSentAsAPlus() async throws {
        let home = "/Users/a+b/.hermes"
        let host = MemoryHost(files: [home + "/memories/MEMORY.md": "kept"])

        let response = try await client(host, rows: [Self.row("research", path: home)]).memory()

        XCTAssertEqual(response.memory, "kept")
        XCTAssertEqual(Set(host.reads()), [home + "/memories/MEMORY.md", home + "/memories/USER.md"])
    }

    func testASectionTheConfigTurnsOffIsHiddenAndUnread() async throws {
        for (value, hidden) in [(BotJSON.string("no"), true), (.string(" On "), false), (.string("0"), true),
                                (.number(0), true), (.number(2), false), (.bool(false), true), (.null, false)] {
            HermesHostFixture.reset()
            let host = MemoryHost()
            host.config = ["user_profile_enabled": value]

            let response = try await client(host).memory()

            XCTAssertEqual(response.hiddenSections, hidden ? [.user] : [], "user_profile_enabled: \(value)")
            XCTAssertEqual(response.user, hidden ? nil : "", "user_profile_enabled: \(value)")
            XCTAssertEqual(host.reads().contains(Self.user), !hidden, "user_profile_enabled: \(value)")
        }
    }

    func testAMemoryConfigThatIsNotAnObjectReadsAsTheDefaults() async throws {
        let host = MemoryHost()
        host.configMemory = .string("off")

        let response = try await client(host).memory()

        XCTAssertEqual(response.hiddenSections, [])
        XCTAssertEqual(response.characterLimits, [.memory: 2200, .user: 1375])
    }

    func testAFileTheHostCanOnlyPreviewIsReadOnly() async throws {
        let host = MemoryHost(files: [Self.notes: "the first 512 KiB"])
        host.truncated = [Self.notes]

        let response = try await client(host).memory()

        XCTAssertEqual(response.readOnlySections, [.memory])
    }

    func testSaveWritesTheAgentsFormatOnceTheFileIsUnchanged() async throws {
        let host = MemoryHost(files: [Self.notes: "Prefers short PRs"])

        let saved = try await client(host).saveMemory(section: .memory, content: "Prefers short PRs\n\n§\n\n  New entry  \n",
                                                      loaded: "Prefers short PRs")

        XCTAssertEqual(saved.ok, true)
        XCTAssertEqual(host.files[Self.notes], "Prefers short PRs\n§\nNew entry")
        XCTAssertEqual(host.calls(), ["GET /api/fs/read-text", "POST /api/fs/write-text", "GET /api/fs/read-text"])
    }

    func testSaveRefusesAFileChangedOnTheHostAndWritesNothing() async throws {
        let host = MemoryHost(files: [Self.notes: "Prefers short PRs\n§\nAdded by the agent"])

        do {
            _ = try await client(host).saveMemory(section: .memory, content: "My edit", loaded: "Prefers short PRs")
            XCTFail("Expected a conflict")
        } catch {
            XCTAssertEqual(error as? MemoryConflict, MemoryConflict())
        }
        XCTAssertEqual(host.files[Self.notes], "Prefers short PRs\n§\nAdded by the agent")
        XCTAssertFalse(host.calls().contains("POST /api/fs/write-text"))
    }

    /// A save that landed but whose reply or refresh was lost leaves the editor open on its old
    /// text; saving again finds the host already holding the draft, which overwrites nothing.
    func testARetryAfterASaveThatLandedIsNotAConflict() async throws {
        let host = MemoryHost(files: [Self.notes: "Prefers short PRs\n§\nNew entry"], soul: "Mine")
        let client = client(host)

        _ = try await client.saveMemory(section: .memory, content: "Prefers short PRs\n\n§\nNew entry\n",
                                        loaded: "Prefers short PRs")
        _ = try await client.saveMemory(section: .soul, content: "Mine", loaded: "Be direct.")

        XCTAssertEqual(host.files[Self.notes], "Prefers short PRs\n§\nNew entry")
        XCTAssertEqual(host.soul, "Mine")
        XCTAssertEqual(host.calls().filter { $0.hasPrefix("POST") || $0.hasPrefix("PUT") },
                       ["POST /api/fs/write-text", "PUT /api/profiles/research/soul"])
    }

    func testAMissingMemoriesFolderIsCreatedOnceAndTheWriteRetried() async throws {
        let host = MemoryHost()
        host.folders = []

        _ = try await client(host).saveMemory(section: .user, content: "Name: Uzair", loaded: "")

        XCTAssertEqual(host.files[Self.user], "Name: Uzair")
        XCTAssertEqual(host.mkdirs, [Self.home + "/memories"])
        XCTAssertEqual(host.calls(), ["GET /api/fs/read-text", "POST /api/fs/write-text", "POST /api/files/mkdir",
                                      "POST /api/fs/write-text", "GET /api/fs/read-text"])
    }

    func testAHostRefusalShowsItsReasonUnlessItNamesAPath() async throws {
        let host = MemoryHost()
        host.writeRefusal = (403, "File is not writable")

        do {
            _ = try await client(host).saveMemory(section: .memory, content: "x", loaded: "")
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server rejected the request: File is not writable")
        }

        HermesHostFixture.reset()
        host.writeRefusal = (400, "[Errno 63] File name too long: '\(Self.notes)'")
        do {
            _ = try await client(host).saveMemory(section: .memory, content: "x", loaded: "")
            XCTFail("Expected a refusal")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(Self.home), error.localizedDescription)
        }
    }

    func testSoulIsReadAndWrittenThroughTheProfilesSoulRouteAfterTheSameCheck() async throws {
        let host = MemoryHost(soul: "Be direct.")
        let client = client(host)

        _ = try await client.saveMemory(section: .soul, content: "Be direct.\n\n", loaded: "Be direct.")

        XCTAssertEqual(host.soul, "Be direct.\n\n", "The soul is written as it is")
        XCTAssertEqual(host.calls(), ["GET /api/profiles/research/soul", "PUT /api/profiles/research/soul"])

        do {
            _ = try await client.saveMemory(section: .soul, content: "Mine", loaded: "Be direct.")
            XCTFail("Expected a conflict")
        } catch {
            XCTAssertEqual(error as? MemoryConflict, MemoryConflict())
        }
        XCTAssertEqual(host.soul, "Be direct.\n\n")
    }

    func testAProfileTheHostNoLongerListsIsNeitherReadNorWritten() async throws {
        let host = MemoryHost(files: [Self.notes: "x"])

        do {
            _ = try await client(host, rows: [Self.row("default", path: "/Users/someone/.hermes")])
                .saveMemory(section: .memory, content: "y", loaded: "x")
            XCTFail("Expected the Profile to be missing")
        } catch {
            XCTAssertEqual(error as? HermesMemoryProfileMissing, HermesMemoryProfileMissing())
        }
        XCTAssertEqual(host.calls(), [])
    }

    // MARK: - Host

    private static func row(_ name: String, path: String) -> BotJSON {
        .object(["name": .string(name), "path": .string(path), "is_default": .bool(name == "default"),
                 "model": .string("hermex-stub"), "skill_count": .number(0)])
    }

    /// `research` on a host whose `profiles.list` answers `rows` (the default Profile's, then
    /// research's with a trailing slash) and whose REST routes are `host`'s.
    private func client(_ host: MemoryHost, rows: [BotJSON]? = nil) -> HermesMemoryClient {
        let rows = rows ?? [Self.row("default", path: "/Users/someone/.hermes"), Self.row("research", path: Self.home + "/")]
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration(host.answer),
                                    gateway: .init(socketFactory: { _ in
                                        let socket = BotScriptedSocket()
                                        socket.reply = { request in
                                            .object(["id": request["id"], "result": .object(["profiles": .array(rows)])])
                                        }
                                        return socket
                                    }))
        return HermesMemoryClient(http: http, profile: "research")
    }
}

/// A Hermes host's file, config and soul routes over an in-memory disk. It runs under
/// `HermesHostFixture`'s lock.
private final class MemoryHost: @unchecked Sendable {
    var files: [String: String]
    var folders: Set<String> = ["/Users/someone/.hermes/memories", "/Users/someone/.hermes/profiles/research/memories",
                                "/Users/a+b/.hermes/memories"]
    var truncated: Set<String> = []
    var soul: String
    var config: [String: BotJSON] = [:]
    /// Replaces `config` as the whole `memory` section when set.
    var configMemory: BotJSON?
    var mkdirs: [String] = []
    var writeRefusal: (Int, String)?

    init(files: [String: String] = [:], soul: String = "") {
        self.files = files
        self.soul = soul
    }

    /// The memory routes the host saw, as method and path.
    func calls() -> [String] {
        HermesHostFixture.requests.compactMap { request in
            guard let path = request.url?.path, path.hasPrefix("/api/fs") || path.hasPrefix("/api/files")
                || path.hasPrefix("/api/profiles") else { return nil }
            return "\(request.httpMethod ?? "GET") \(path)"
        }
    }

    /// The paths read through `fs/read-text`.
    func reads() -> [String] {
        HermesHostFixture.requests.filter { $0.url?.path == "/api/fs/read-text" }.compactMap(Self.queryPath)
    }

    /// A request's `?path=` as the host decodes it, reading `+` as a space.
    private static func queryPath(_ request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedQueryItems?
            .first { $0.name == "path" }?.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    func answer(_ request: URLRequest) -> HermesHostFixture.Reply? {
        let body = apiTestBodyData(from: request).flatMap { try? JSONDecoder().decode(BotJSON.self, from: $0) } ?? .null
        switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
        case ("GET", "/api/config"):
            return .json(200, .object(["memory": configMemory ?? .object(config),
                                       "delegation": .object(["api_key": .string("sk-secret")])]))
        case ("GET", "/api/profiles/research/soul"):
            return .json(200, .object(["content": .string(soul), "exists": .bool(!soul.isEmpty)]))
        case ("PUT", "/api/profiles/research/soul"):
            soul = body["content"].text ?? ""
            return .json(200, .object(["ok": .bool(true)]))
        case ("GET", "/api/fs/read-text"):
            guard let path = Self.queryPath(request), let text = files[path] else { return .json(404, .object(["detail": .string("File not found")])) }
            return .json(200, .object(["text": .string(text), "binary": .bool(false), "truncated": .bool(truncated.contains(path)),
                                       "byteSize": .number(Double(text.utf8.count)), "path": .string(path)]))
        case ("POST", "/api/fs/write-text"):
            if let (status, detail) = writeRefusal { return .json(status, .object(["detail": .string(detail)])) }
            guard let path = body["path"].text, let content = body["content"].text else { return .json(422, .null) }
            guard folders.contains((path as NSString).deletingLastPathComponent) else {
                return .json(400, .object(["detail": .string("Parent directory does not exist")]))
            }
            files[path] = content
            return .json(200, .object(["ok": .bool(true), "path": .string(path), "byteSize": .number(Double(content.utf8.count))]))
        case ("POST", "/api/files/mkdir"):
            guard let path = body["path"].text else { return .json(422, .null) }
            mkdirs.append(path)
            folders.insert(path)
            return .json(200, .object(["ok": .bool(true)]))
        default:
            return nil
        }
    }
}
