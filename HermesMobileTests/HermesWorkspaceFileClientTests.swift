import XCTest
@testable import HermesMobile

/// A Hermes chat's workspace files (#1112): `HermesWorkspaceFileClient` against a scripted host
/// whose replies are the shapes `hermes_cli/web_routers/files.py` answers at the pin (ca678285).
@MainActor final class HermesWorkspaceFileClientTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    // MARK: Listing

    /// The root lists the chat's folder; a subfolder is the folder plus its relative path, with a
    /// `+` kept as itself. Each child's path is its folder's plus its name: the listing's own
    /// `path` is resolved on the host and never read.
    func testAListingComposesTheHostPathAndBuildsChildPathsFromNames() async throws {
        let client = Self.client { request in
            guard request.url?.path == "/api/fs/list" else { return nil }
            return Self.listing(Self.queryPath(request) ?? "", [("src", true), ("a+b.txt", false)])
        }

        let root = try await client.directoryList(path: FileTree.rootPath)
        let nested = try await client.directoryList(path: "src/c++")

        XCTAssertEqual(Self.fileRequests.map(Self.queryPath), [Self.cwd, Self.cwd + "/src/c++"])
        XCTAssertEqual(root.entries?.map(\.path), ["src", "a+b.txt"])
        XCTAssertEqual(root.entries?.map(\.isBrowsableDirectory), [true, false])
        XCTAssertEqual(nested.entries?.map(\.path), ["src/c++/src", "src/c++/a+b.txt"])
    }

    /// The host's 200 `{entries: [], error}` for a folder it can't read is the folder's failure,
    /// not an empty folder: `ENOENT` and `ENOTDIR` are a missing folder, `EACCES` is not.
    func testAnUnreadableFolderThrowsItsCode() async throws {
        let codes = ["ENOENT": true, "ENOTDIR": true, "EACCES": false]
        for (code, isMissing) in codes {
            let client = Self.client { request in
                request.url?.path == "/api/fs/list" ? .json(200, .object(["entries": .array([]), "error": .string(code)])) : nil
            }
            do {
                _ = try await client.directoryList(path: FileTree.rootPath)
                XCTFail("Expected \(code) to fail the listing")
            } catch let failure as WorkspaceFolderReadFailure {
                XCTAssertEqual(failure.code, code)
                XCTAssertEqual(failure.isMissing, isMissing, code)
            }
        }
    }

    /// A path that is absolute, climbs with `..`, starts at `~` or is empty past the root is
    /// refused before any request.
    func testAPathOutsideTheFolderIsRefusedBeforeAnyRequest() async {
        let client = Self.client { _ in .json(200, .object(["entries": .array([])])) }

        for path in ["/etc", "../outside", "src/../../outside", "~/.ssh", "", "/", "./", "src/..\u{0}"] {
            do {
                _ = try await client.directoryList(path: path)
                XCTFail("Expected \(path.debugDescription) to be refused")
            } catch {
                XCTAssertEqual(error as? BotArtifactFailure, .invalidReference, path.debugDescription)
            }
            do {
                _ = try await client.rawFileData(path: path)
                XCTFail("Expected \(path.debugDescription) to be refused for download")
            } catch {
                XCTAssertEqual(error as? BotArtifactFailure, .invalidReference, path.debugDescription)
            }
        }
        XCTAssertEqual(Self.fileRequests.count, 0)
    }

    // MARK: Reading

    /// A file past 512 KiB previews its first part: it says it is truncated, keeps the host's
    /// full size and has no line count. Its path is the relative one, never the host's.
    func testATruncatedFileKeepsItsTextAndRelativePath() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/fs/read-text" ? .json(200, .object([
                "text": .string("let a = 1\nlet b = 2\n"), "binary": .bool(false), "truncated": .bool(true),
                "byteSize": .number(900_000), "language": .string("swift"), "mimeType": .string("text/x-swift"),
                "path": .string("/private" + Self.cwd + "/Sources/App.swift")
            ])) : nil
        }

        let file = try await client.file(path: "Sources/App.swift")

        XCTAssertEqual(Self.fileRequests.map(Self.queryPath), [Self.cwd + "/Sources/App.swift"])
        XCTAssertEqual(file.content, "let a = 1\nlet b = 2\n")
        XCTAssertEqual(file.path, "Sources/App.swift")
        XCTAssertEqual(file.name, "App.swift")
        XCTAssertEqual(file.language, "swift")
        XCTAssertEqual(file.size, 900_000)
        XCTAssertNil(file.lines)
        XCTAssertTrue(file.isTruncated)
        XCTAssertFalse(file.isBinary)
    }

    /// A binary file has no text, and a whole text file counts its lines.
    func testABinaryFileHasNoTextAndAWholeFileCountsLines() async throws {
        let client = Self.client { request in
            guard request.url?.path == "/api/fs/read-text" else { return nil }
            let binary = Self.queryPath(request)?.hasSuffix(".bin") == true
            return .json(200, .object([
                "text": .string(binary ? "\u{FFFD}\u{FFFD}" : "one\ntwo\nthree"), "binary": .bool(binary),
                "truncated": .bool(false), "byteSize": .number(13), "language": .string("text")
            ]))
        }

        let binary = try await client.file(path: "blob.bin")
        let text = try await client.file(path: "notes.txt")

        XCTAssertTrue(binary.isBinary)
        XCTAssertNil(binary.content)
        XCTAssertEqual(text.content, "one\ntwo\nthree")
        XCTAssertEqual(text.lines, 3)
        XCTAssertFalse(text.isTruncated)
    }

    /// The host decodes text with replacement characters, so the preview is not the file: Save
    /// and Share download the file's own bytes instead of re-encoding the preview.
    func testExportDownloadsTheFileRatherThanItsPreviewText() async throws {
        let client = Self.client { request in
            switch request.url?.path {
            case "/api/fs/read-text": .json(200, .object([
                "text": .string("caf\u{FFFD}\n"), "binary": .bool(false), "truncated": .bool(false), "byteSize": .number(5)
            ]))
            case "/api/fs/download": .json(200, .string("original bytes"))
            default: nil
            }
        }
        let viewModel = FilePreviewViewModel(files: client, path: "notes.txt")

        await viewModel.load()
        let export = try await viewModel.exportPayload()

        XCTAssertEqual(export.data, Data(#""original bytes""#.utf8))
        XCTAssertEqual(Self.fileRequests.map { $0.url?.path }, ["/api/fs/read-text", "/api/fs/download"])
        XCTAssertEqual(Self.fileRequests.last.flatMap(Self.queryPath), "notes.txt")
    }

    /// A symlinked folder lists as a file; opening it is the preview's No Preview state, not a
    /// failed load to retry, whether its name previews as text, an image or through Quick Look.
    func testASymlinkedFolderOpensAsNoPreview() async {
        let client = Self.client { request in
            request.url?.path.hasPrefix("/api/fs/") == true
                ? .json(400, .object(["detail": .string("Path points to a directory")])) : nil
        }
        for (path, route) in [("linked-src", "/api/fs/read-text"), ("linked.png", "/api/fs/download"),
                              ("linked.pdf", "/api/fs/download")] {
            let viewModel = FilePreviewViewModel(files: client, path: path)

            await viewModel.load()

            XCTAssertEqual(Self.fileRequests.last?.url?.path, route, path)
            XCTAssertNil(viewModel.errorMessage, path)
            guard case let .unavailable(message) = viewModel.preview else {
                XCTFail("Expected No Preview for \(path), got \(String(describing: viewModel.preview))")
                continue
            }
            XCTAssertEqual(message, "Preview is not available for this file type.", path)
        }
    }

    /// An empty file previews as empty text and exports as zero bytes; an empty MEDIA download
    /// is still a failed read.
    func testAnEmptyFileExportsZeroBytes() async throws {
        let client = Self.client { request in
            switch request.url?.path {
            case "/api/fs/read-text": .json(200, .object([
                "text": .string(""), "binary": .bool(false), "truncated": .bool(false), "byteSize": .number(0)
            ]))
            case "/api/fs/download": .body(200, Data())
            default: nil
            }
        }
        let viewModel = FilePreviewViewModel(files: client, path: "notes.txt")

        await viewModel.load()
        let export = try await viewModel.exportPayload()

        XCTAssertEqual(export.data, Data())
        XCTAssertEqual(Self.fileRequests.map { $0.url?.path }, ["/api/fs/read-text", "/api/fs/download"])
        do {
            _ = try await client.mediaData(path: "/tmp/empty.png")
            XCTFail("Expected an empty MEDIA download to fail")
        } catch {
            XCTAssertEqual(error as? BotArtifactFailure, .unavailable)
        }
    }

    /// The host's reason for a refusal shows unless it names a path, as an `OSError`'s does.
    func testARefusalThatNamesAHostPathIsNotShown() async {
        let details = [
            "File not found": "The server rejected the request: File not found",
            "[Errno 63] File name too long: '\(Self.cwd)/x'": BotArtifactFailure.unavailable.localizedDescription
        ]
        for (detail, shown) in details {
            let client = Self.client { request in
                request.url?.path == "/api/fs/read-text" ? .json(404, .object(["detail": .string(detail)])) : nil
            }
            do {
                _ = try await client.file(path: "x")
                XCTFail("Expected the read to fail")
            } catch {
                XCTAssertEqual(error.localizedDescription, shown)
                XCTAssertFalse(error.localizedDescription.contains(Self.cwd))
            }
        }
    }

    // MARK: Downloads

    /// A file downloads by its relative path with the Profile and stored key, so the host
    /// resolves it against the session's folder. A MEDIA path is sent as the reply wrote it.
    func testDownloadsSendTheRelativePathProfileAndStoredKey() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/fs/download" ? .json(200, .string("bytes")) : nil
        }

        let file = try await client.rawFileData(path: "out/plot.png")
        let media = try await client.mediaData(path: "/tmp/hermes/screenshot.png")

        XCTAssertEqual(file, Data(#""bytes""#.utf8))
        XCTAssertEqual(media, Data(#""bytes""#.utf8))
        XCTAssertEqual(Self.fileRequests.map(Self.query), [
            [URLQueryItem(name: "path", value: "out/plot.png"), URLQueryItem(name: "profile", value: "research"),
             URLQueryItem(name: "session_id", value: "20261008_101500_abc123")],
            [URLQueryItem(name: "path", value: "/tmp/hermes/screenshot.png"), URLQueryItem(name: "profile", value: "research"),
             URLQueryItem(name: "session_id", value: "20261008_101500_abc123")]
        ])
    }

    /// Image and Quick Look previews stop at 25 MB; Save and Share download the whole file.
    func testOnlyPreviewDownloadsStopAt25MB() async throws {
        let large = String(repeating: "a", count: BotArtifactBuffer.maximumBytes)
        let client = Self.client { request in
            request.url?.path == "/api/fs/download" ? .json(200, .string(large)) : nil
        }

        let export = try await client.rawFileData(path: "archive.zip")
        XCTAssertEqual(export.count, BotArtifactBuffer.maximumBytes + 2)
        do {
            _ = try await client.imagePreviewData(path: "huge.png")
            XCTFail("Expected an image preview past 25 MB to stop")
        } catch {
            XCTAssertEqual(error as? BotArtifactFailure, .tooLarge)
        }
    }

    // MARK: Scope

    /// Two servers, two Profiles, two sessions on one folder, and one session in two folders
    /// each get their own scope.
    func testTheScopeSeparatesServerProfileSessionAndFolder() {
        let http = HermesConnection(connection: Self.record, configuration: .ephemeral)
        let base = Self.context()
        let contexts = [
            base,
            Self.context(server: URL(string: "https://other.example")!),
            Self.context(profile: "default"),
            Self.context(storedKey: "20261008_101600_def456"),
            Self.context(cwd: "/Users/agent/projects/other")
        ]

        let scopes = Set(contexts.map { HermesWorkspaceFileClient(context: $0, http: http).scope })

        XCTAssertEqual(scopes.count, contexts.count)
        XCTAssertEqual(HermesWorkspaceFileClient(context: base, http: http).scope,
                       HermesWorkspaceFileClient(context: Self.context(), http: http).scope)
    }

    // MARK: Fixtures

    nonisolated static let cwd = "/Users/agent/projects/app"
    nonisolated private static let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                                          username: "user", password: "secret")

    nonisolated static func context(server: URL = URL(string: "https://webui.example")!, profile: String = "research",
                        storedKey: String = "20261008_101500_abc123", cwd: String = cwd,
                        terminalBackend: String? = "local") -> HermesWorkspaceContext {
        HermesWorkspaceContext(server: server, profile: profile, storedKey: storedKey, cwd: cwd, terminalBackend: terminalBackend)
    }

    static func client(context: HermesWorkspaceContext = context(),
                       _ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesWorkspaceFileClient {
        HermesWorkspaceFileClient(context: context,
                                  http: HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script)))
    }

    /// `GET /api/fs/list`'s reply for `directory`, each entry's `path` resolved the way the host
    /// resolves it (`/private/…` on a Mac), which the client never reads.
    nonisolated static func listing(_ directory: String, _ entries: [(String, Bool)]) -> HermesHostFixture.Reply {
        .json(200, .object(["entries": .array(entries.map { name, isDirectory in
            .object(["name": .string(name), "path": .string("/private\(directory)/\(name)"), "isDirectory": .bool(isDirectory)])
        })]))
    }

    /// The requests to `/api/fs/*`, without the sign-in's.
    static var fileRequests: [URLRequest] {
        HermesHostFixture.requests.filter { $0.url?.path.hasPrefix("/api/fs/") == true }
    }

    /// The host path a request names in its query.
    nonisolated static func queryPath(_ request: URLRequest) -> String? {
        query(request)?.first { $0.name == "path" }?.value
    }

    nonisolated private static func query(_ request: URLRequest) -> [URLQueryItem]? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
    }
}
