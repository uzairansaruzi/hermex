import XCTest
@testable import HermesMobile

/// Skills on a Hermes host (#1069): `HermesSkillsClient` against a scripted host whose replies
/// are the shapes `scripts/local-hermes` answered at the pin (0.21.5, ca678285).
@MainActor final class HermesSkillsClientTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testTheListIsTheProfilesBareArrayWithEnabledReadAsDisabled() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/skills" ? .json(200, .array([
                .object(["name": .string("apple-notes"), "description": .string("Manage Apple Notes."),
                         "category": .string("apple"), "enabled": .bool(true), "usage": .number(3),
                         "provenance": .string("bundled"), "future_field": .object(["x": .number(1)])]),
                .object(["name": .string("arxiv"), "description": .null, "category": .string("research"),
                         "enabled": .bool(false), "usage": .number(0), "provenance": .string("hub")]),
                .object(["description": .string("A row without a name")])
            ])) : nil
        }

        let response = try await client.skills()
        let skills = try XCTUnwrap(response.skills)

        XCTAssertEqual(skills.map(\.name), ["apple-notes", "arxiv"])
        XCTAssertEqual(skills.map(\.disabled), [false, true])
        XCTAssertEqual(skills.map(\.category), ["apple", "research"])
        XCTAssertEqual(skills.map(\.description), ["Manage Apple Notes.", nil])
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.query, "profile=research")
    }

    func testAListThatIsNotAnArrayIsAFailedReadNotAnEmptyProfile() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/skills" ? .json(200, .object([
                "skills": .array([.object(["name": .string("arxiv"), "enabled": .bool(true)])])
            ])) : nil
        }

        do {
            let response = try await client.skills()
            XCTFail("Expected a failed read, got \(response.skills?.count ?? 0) skills")
        } catch {
            guard case APIError.decoding = error else { return XCTFail("Expected a decoding failure, got \(error)") }
        }
    }

    func testATogglePutsTheNameStateAndProfileInTheBody() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/skills/toggle" && request.httpMethod == "PUT"
                ? .json(200, .object(["ok": .bool(true), "name": .string("arxiv"), "enabled": .bool(false)])) : nil
        }

        let response = try await client.toggleSkill(name: "arxiv", enabled: false)

        XCTAssertEqual(response.enabled, false)
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/skills/toggle")
        XCTAssertNil(request.url?.query, "The body's Profile wins on the host, so it goes only there")
        XCTAssertEqual(HermesCronFixture.body(request), .object([
            "name": .string("arxiv"), "enabled": .bool(false), "profile": .string("research")
        ]))
    }

    func testContentIsTheProfilesSkillMdWithoutTheHostPath() async throws {
        let hostPath = "/Users/someone/.hermes/profiles/research/skills/research/arxiv/SKILL.md"
        let client = Self.client { request in
            request.url?.path == "/api/skills/content" ? .json(200, .object([
                "name": .string("arxiv"), "content": .string("---\nname: arxiv\n---\n# arXiv"), "path": .string(hostPath)
            ])) : nil
        }

        let detail = try await client.skillContent(name: "arxiv", file: nil)

        XCTAssertEqual(detail.content, "---\nname: arxiv\n---\n# arXiv")
        XCTAssertNil(detail.linkedFiles)
        XCTAssertFalse(String(describing: detail).contains(hostPath), "The host path never reaches the screen")
        let request = try XCTUnwrap(HermesHostFixture.requests.last { $0.url?.path == "/api/skills/content" })
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "name", value: "arxiv"), URLQueryItem(name: "profile", value: "research")])
    }

    func testARefusedToggleCarriesTheHostsDetail() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/skills/toggle"
                ? .json(404, .object(["detail": .string("Profile 'research' does not exist.")])) : nil
        }

        do {
            _ = try await client.toggleSkill(name: "arxiv", enabled: false)
            XCTFail("Expected the host's refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server rejected the request: Profile 'research' does not exist.")
        }
    }

    func testAMissingSkillReadsAsNotFound() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/skills/content"
                ? .json(404, .object(["detail": .string("Skill 'arxiv' not found.")])) : nil
        }

        do {
            _ = try await client.skillContent(name: "arxiv", file: nil)
            XCTFail("Expected the host's 404")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server rejected the request: Skill 'arxiv' not found.")
        }
    }

    // MARK: Linked files (#1070)

    func testDetailListsTheSkillFolderTwoLevelsDeepByRelativePath() async throws {
        let folder = Self.folder
        let client = Self.client { request in
            switch (request.url?.path, Self.queryPath(request)) {
            case ("/api/skills/content", _): return Self.skillMd
            case ("/api/fs/list", folder):
                return Self.listing(folder, [("references", true), ("templates", true), ("SKILL.md", false),
                                             ("README.md", false), (".DS_Store", false)])
            case ("/api/fs/list", folder + "/references"):
                return Self.listing(folder + "/references", [("layouts", true), ("api.md", false)])
            case ("/api/fs/list", folder + "/templates"): return Self.listing(folder + "/templates", [("skin.yaml", false)])
            default: return nil
            }
        }

        let detail = try await client.skillContent(name: "arxiv", file: nil)

        XCTAssertEqual(detail.linkedFiles, ["README.md", "references/api.md", "templates/skin.yaml"])
        let listed = HermesHostFixture.requests.filter { $0.url?.path == "/api/fs/list" }.compactMap(Self.queryPath)
        XCTAssertEqual(Set(listed), [folder, folder + "/references", folder + "/templates"],
                       "Built from the content reply's path, never the listing's resolved one; layouts is a third level")
        XCTAssertEqual(listed.count, 3)
    }

    func testAListingThatAnswersAnErrorLeavesTheSkillWithoutFiles() async throws {
        let client = Self.client { request in
            switch request.url?.path {
            case "/api/skills/content": return Self.skillMd
            case "/api/fs/list": return .json(200, .object(["entries": .array([]), "error": .string("EACCES")]))
            default: return nil
            }
        }

        let detail = try await client.skillContent(name: "arxiv", file: nil)

        XCTAssertEqual(detail.content, "# arXiv")
        XCTAssertNil(detail.linkedFiles)
        XCTAssertEqual(HermesHostFixture.count("/api/fs/list"), 1)
    }

    func testAFileReadsItsTextFromTheSkillFolder() async throws {
        let client = Self.client { request in
            switch request.url?.path {
            case "/api/skills/content": return Self.skillMd
            case "/api/fs/read-text":
                return .json(200, .object(["text": .string("# API"), "binary": .bool(false), "truncated": .bool(false),
                                           "byteSize": .number(5), "language": .string("markdown"),
                                           "mimeType": .string("text/markdown"), "path": .string("/private" + Self.folder)]))
            default: return nil
            }
        }

        _ = try await client.skillContent(name: "arxiv", file: nil)
        let file = try await client.skillContent(name: "arxiv", file: "references/c++.md")

        XCTAssertEqual(file.content, "# API")
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/fs/read-text")
        XCTAssertEqual(request.url?.query, "path=\(Self.folder)/references/c%2B%2B.md", "The host reads a query's + as a space")
        XCTAssertEqual(HermesHostFixture.count("/api/skills/content"), 1, "The read reuses the folder the detail found")
    }

    func testABinaryFileHasNoTextAndATruncatedOneSaysSo() async throws {
        let folder = Self.folder
        let client = Self.client { request in
            switch (request.url?.path, Self.queryPath(request)) {
            case ("/api/skills/content", _): return Self.skillMd
            case ("/api/fs/read-text", folder + "/assets/logo.png"):
                return .json(200, .object(["text": .string("\u{FFFD}PNG\r\n"), "binary": .bool(true), "truncated": .bool(false)]))
            case ("/api/fs/read-text", folder + "/references/big.md"):
                return .json(200, .object(["text": .string("# Big"), "binary": .bool(false), "truncated": .bool(true)]))
            default: return nil
            }
        }

        let binary = try await client.skillContent(name: "arxiv", file: "assets/logo.png")
        let big = try await client.skillContent(name: "arxiv", file: "references/big.md")

        XCTAssertEqual([binary.isBinary, binary.isTruncated, big.isBinary, big.isTruncated], [true, false, false, true])
        XCTAssertNil(binary.content, "A binary file's replacement-character text is never shown")
        XCTAssertEqual(big.content, "# Big")
        XCTAssertEqual(HermesHostFixture.count("/api/skills/content"), 1, "A file opened first reads SKILL.md once for its folder")
    }

    func testAFileOutsideTheSkillFolderIsRefusedBeforeAnyRequest() async throws {
        let client = Self.client { request in request.url?.path == "/api/skills/content" ? Self.skillMd : nil }
        _ = try await client.skillContent(name: "arxiv", file: nil)
        let sent = HermesHostFixture.requests.count

        for file in ["../other/SKILL.md", "references/../../secrets.md", "/etc/hosts", "./a.md", "references//a.md",
                     "..\\secrets.md", ""] {
            do {
                _ = try await client.skillContent(name: "arxiv", file: file)
                XCTFail("\(file) leaves the skill folder")
            } catch {
                guard case BotArtifactFailure.unavailable = error else { return XCTFail("\(file): \(error)") }
            }
        }

        XCTAssertEqual(HermesHostFixture.requests.count, sent)
    }

    /// A client for the `research` Profile on a scripted host.
    private static func client(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesSkillsClient {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        return HermesSkillsClient(http: HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script)),
                                  profile: "research")
    }

    /// The skill's folder on the host, which only the content reply names.
    nonisolated private static let folder = "/home/agent/.hermes/profiles/research/skills/research/arxiv"
    nonisolated private static let skillMd = HermesHostFixture.Reply.json(200, .object([
        "name": .string("arxiv"), "content": .string("# arXiv"), "path": .string(folder + "/SKILL.md")
    ]))

    /// `GET /api/fs/list`'s reply for `directory`, each entry's `path` resolved the way the host
    /// resolves it (`/private/…` on a Mac), which the client never reads.
    nonisolated private static func listing(_ directory: String, _ entries: [(String, Bool)]) -> HermesHostFixture.Reply {
        .json(200, .object(["entries": .array(entries.map { name, isDirectory in
            .object(["name": .string(name), "path": .string("/private\(directory)/\(name)"), "isDirectory": .bool(isDirectory)])
        })]))
    }

    /// The host path a request names in its query.
    nonisolated private static func queryPath(_ request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "path" }?.value
    }
}
