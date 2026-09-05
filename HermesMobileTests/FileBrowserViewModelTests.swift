import XCTest
@testable import HermesMobile

/// Lazy loading, expansion memory, selection reveal, and preview prefetch for the file tree.
final class FileBrowserViewModelTests: APIClientTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FileBrowserViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Records every `/api/list` path the model asked for, in call order, and names the
    /// paths whose listing should currently fail.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var failing: Set<String>

        init(failing: Set<String> = []) {
            self.failing = failing
        }

        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.append(path)
        }

        func shouldFail(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failing.contains(path)
        }

        func setFailing(_ paths: Set<String>) {
            lock.lock(); defer { lock.unlock() }
            failing = paths
        }

        var listedPaths: [String] {
            lock.lock(); defer { lock.unlock() }
            return paths
        }
    }

    private func session(id: String = "s1", workspace: String = "/tmp/ws") throws -> SessionSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "\#(id)", "title": "T", "workspace": "\#(workspace)"}"#.utf8)
        )
    }

    private func entryJSON(_ name: String, path: String, isDirectory: Bool) -> String {
        #"{"name": "\#(name)", "path": "\#(path)", "type": "\#(isDirectory ? "dir" : "file")", "is_dir": \#(isDirectory)}"#
    }

    /// `.git/{HEAD}`, `src/{Chat/{ChatView.swift}}`, `README.md`.
    private func listingJSON(for path: String) -> String? {
        switch path {
        case ".":
            return #"{"path": ".", "entries": [\#(entryJSON(".git", path: ".git", isDirectory: true)), \#(entryJSON("src", path: "src", isDirectory: true)), \#(entryJSON("README.md", path: "README.md", isDirectory: false))]}"#
        case ".git":
            return #"{"path": ".git", "entries": [\#(entryJSON("HEAD", path: ".git/HEAD", isDirectory: false))]}"#
        case "src":
            return #"{"path": "src", "entries": [\#(entryJSON("Chat", path: "src/Chat", isDirectory: true))]}"#
        case "src/Chat":
            return #"{"path": "src/Chat", "entries": [\#(entryJSON("ChatView.swift", path: "src/Chat/ChatView.swift", isDirectory: false))]}"#
        default:
            return nil
        }
    }

    private func listedPath(in request: URLRequest) -> String {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first { $0.name == "path" }?.value ?? "."
    }

    private func makeListingClient(log: RequestLog) -> APIClient {
        makeClient { [self] request in
            XCTAssertEqual(request.url?.path, "/api/list")
            let path = listedPath(in: request)
            log.record(path)
            if log.shouldFail(path) {
                return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
            }
            guard let json = listingJSON(for: path) else {
                return apiTestJSONResponse(#"{"error": "not found"}"#, for: request, status: 404)
            }
            return apiTestJSONResponse(json, for: request)
        }
    }

    @MainActor
    private func makeViewModel(
        client: APIClient,
        server: String = "https://example.test",
        workspace: String = "/tmp/ws"
    ) throws -> FileBrowserViewModel {
        FileBrowserViewModel(
            session: try session(workspace: workspace),
            server: try XCTUnwrap(URL(string: server)),
            apiClient: client,
            defaults: defaults
        )
    }

    // MARK: - Loading

    @MainActor
    func testFirstLoadOpensVisibleTopLevelFoldersAndSkipsHiddenOnes() async throws {
        let log = RequestLog()
        let viewModel = try makeViewModel(client: makeListingClient(log: log))

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertEqual(log.listedPaths, [".", "src"])
        XCTAssertEqual(viewModel.expandedPaths, ["src"])
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), [".git", "src", "src/Chat", "README.md"])
        XCTAssertEqual(viewModel.childCount(of: "src"), 1)
        XCTAssertNil(viewModel.childCount(of: ".git"))
        XCTAssertFalse(viewModel.isLoadingRoot)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testOpeningAFolderListsItOnceAndClosingKeepsItsChildren() async throws {
        let log = RequestLog()
        let viewModel = try makeViewModel(client: makeListingClient(log: log))
        await viewModel.loadInitialRootIfNeeded()

        await viewModel.toggleDirectory(".git")
        XCTAssertTrue(viewModel.isExpanded(".git"))
        XCTAssertTrue(viewModel.visibleNodes(matching: "").map(\.node.path).contains(".git/HEAD"))

        await viewModel.toggleDirectory(".git")
        XCTAssertFalse(viewModel.isExpanded(".git"))
        XCTAssertFalse(viewModel.visibleNodes(matching: "").map(\.node.path).contains(".git/HEAD"))

        await viewModel.toggleDirectory(".git")
        XCTAssertEqual(log.listedPaths.filter { $0 == ".git" }.count, 1)
    }

    @MainActor
    func testFailedFolderListingIsRecordedAndTappingRetries() async throws {
        let log = RequestLog(failing: ["src"])
        let viewModel = try makeViewModel(client: makeListingClient(log: log))

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertNotNil(viewModel.loadFailure(for: "src"))
        XCTAssertTrue(viewModel.isExpanded("src"))
        XCTAssertNil(viewModel.errorMessage, "A folder failure must not read as a root failure")

        log.setFailing([])
        await viewModel.toggleDirectory("src")

        XCTAssertNil(viewModel.loadFailure(for: "src"))
        XCTAssertTrue(viewModel.isExpanded("src"))
        XCTAssertEqual(viewModel.childCount(of: "src"), 1)
        XCTAssertNil(viewModel.takeLastError(), "A recovered folder must not re-report the old failure")
    }

    @MainActor
    func testLastErrorIsHandedOverOnce() async throws {
        let log = RequestLog(failing: ["src"])
        let viewModel = try makeViewModel(client: makeListingClient(log: log))

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertNotNil(viewModel.takeLastError())
        XCTAssertNil(viewModel.takeLastError())
    }

    @MainActor
    func testFolderRemovedDuringAnInFlightListingIsNotKeptAsLoaded() async throws {
        let slowListingStarted = expectation(description: "slow src listing started")
        let log = RequestLog()
        let client = makeClient { [self] request in
            let path = listedPath(in: request)
            log.record(path)
            switch path {
            case ".":
                let rootCalls = log.listedPaths.filter { $0 == "." }.count
                let entries = rootCalls == 2 ? "" : entryJSON("src", path: "src", isDirectory: true)
                return apiTestJSONResponse(#"{"path": ".", "entries": [\#(entries)]}"#, for: request)
            case "src":
                if log.listedPaths.filter({ $0 == "src" }).count == 1 {
                    slowListingStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return apiTestJSONResponse(#"{"path": "src", "entries": [\#(entryJSON("a.txt", path: "src/a.txt", isDirectory: false))]}"#, for: request)
            default:
                return apiTestJSONResponse(#"{"error": "not found"}"#, for: request, status: 404)
            }
        }
        FileTreeExpansionStore(server: try XCTUnwrap(URL(string: "https://example.test")), workspace: "/tmp/ws", defaults: defaults).save([])
        let viewModel = try makeViewModel(client: client)
        await viewModel.loadInitialRootIfNeeded()

        let slowOpen = Task { await viewModel.toggleDirectory("src") }
        await fulfillment(of: [slowListingStarted], timeout: 1)
        await viewModel.refresh()
        await slowOpen.value

        XCTAssertFalse(viewModel.tree.isLoaded("src"), "The folder vanished from the root while its listing was in flight")

        await viewModel.retryRoot()

        XCTAssertEqual(viewModel.childCount(of: "src"), 1, "A folder that comes back is listed again, not served from the orphaned listing")
        XCTAssertEqual(log.listedPaths.filter { $0 == "src" }.count, 2)
    }

    @MainActor
    func testRefreshRelistsRootAndOpenFoldersOnly() async throws {
        let log = RequestLog()
        let viewModel = try makeViewModel(client: makeListingClient(log: log))
        await viewModel.loadInitialRootIfNeeded()
        await viewModel.toggleDirectory("src/Chat")
        await viewModel.toggleDirectory("src")

        let before = log.listedPaths.count
        await viewModel.refresh()

        XCTAssertEqual(Array(log.listedPaths.dropFirst(before)), ["."], "Collapsed folders are not re-listed")
        XCTAssertEqual(viewModel.expandedPaths, ["src/Chat"])
    }

    // MARK: - Selection

    @MainActor
    func testSelectingAFileOpensAndListsEveryAncestor() async throws {
        let log = RequestLog()
        FileTreeExpansionStore(server: try XCTUnwrap(URL(string: "https://example.test")), workspace: "/tmp/ws", defaults: defaults).save([])
        let viewModel = try makeViewModel(client: makeListingClient(log: log))
        await viewModel.loadInitialRootIfNeeded()
        XCTAssertEqual(log.listedPaths, ["."])

        await viewModel.select(path: "src/Chat/ChatView.swift")

        XCTAssertEqual(viewModel.selectedPath, "src/Chat/ChatView.swift")
        XCTAssertEqual(log.listedPaths, [".", "src", "src/Chat"])
        XCTAssertEqual(viewModel.expandedPaths, ["src", "src/Chat"])
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), [".git", "src", "src/Chat", "src/Chat/ChatView.swift", "README.md"])
    }

    // MARK: - Persistence

    @MainActor
    func testExpansionIsRememberedPerServerAndWorkspace() async throws {
        let log = RequestLog()
        let first = try makeViewModel(client: makeListingClient(log: log))
        await first.loadInitialRootIfNeeded()
        await first.toggleDirectory("src")
        await first.toggleDirectory(".git")
        XCTAssertEqual(first.expandedPaths, [".git"])

        let sameServer = try makeViewModel(client: makeListingClient(log: log))
        await sameServer.loadInitialRootIfNeeded()
        XCTAssertEqual(sameServer.expandedPaths, [".git"])

        let otherServer = try makeViewModel(client: makeListingClient(log: log), server: "https://other.test")
        await otherServer.loadInitialRootIfNeeded()
        XCTAssertEqual(otherServer.expandedPaths, ["src"], "Another server starts from the default expansion")

        let otherWorkspace = try makeViewModel(client: makeListingClient(log: log), workspace: "/tmp/other")
        await otherWorkspace.loadInitialRootIfNeeded()
        XCTAssertEqual(otherWorkspace.expandedPaths, ["src"], "Another workspace on the same server starts from the default expansion")
    }

    // MARK: - Prefetch

    @MainActor
    func testPressDownPrefetchesTextFilesAndOpeningKeepsOnlyThatFile() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/file")
            return apiTestJSONResponse(#"{"path": "README.md", "content": "hi"}"#, for: request)
        }
        let viewModel = try makeViewModel(client: client)

        viewModel.prefetchFile(at: "logo.png")
        XCTAssertNil(viewModel.prefetchedFile(at: "logo.png"), "Images are not fetched as text")

        viewModel.prefetchFile(at: "notes.txt")
        let stale = try XCTUnwrap(viewModel.prefetchedFile(at: "notes.txt"))
        viewModel.prefetchFile(at: "README.md")
        XCTAssertTrue(stale.isCancelled, "A newer press-down replaces the older prefetch")
        XCTAssertNil(viewModel.prefetchedFile(at: "notes.txt"))

        let handedOver = try XCTUnwrap(viewModel.takePrefetch(for: "README.md"))
        let file = try await handedOver.value
        XCTAssertEqual(file.content, "hi")
        XCTAssertNil(viewModel.prefetchedFile(at: "README.md"), "A handed-over prefetch leaves the table")

        viewModel.prefetchFile(at: "README.md")
        let fresh = try XCTUnwrap(viewModel.prefetchedFile(at: "README.md"))
        XCTAssertNotEqual(fresh, handedOver, "Reopening the same file starts a new fetch instead of reusing the old response")
        _ = try await fresh.value
    }

    // MARK: - Races and cancellation

    @MainActor
    func testStaleRootListingNeverOverwritesANewerOne() async throws {
        let slowRequestStarted = expectation(description: "slow root request started")
        let calls = RequestLog()
        let client = makeClient { request in
            calls.record(".")
            if calls.listedPaths.count == 1 {
                slowRequestStarted.fulfill()
                Thread.sleep(forTimeInterval: 0.3)
                return apiTestJSONResponse(#"{"path": ".", "entries": [{"name": "old.txt", "path": "old.txt", "type": "file"}]}"#, for: request)
            }
            return apiTestJSONResponse(#"{"path": ".", "entries": [{"name": "new.txt", "path": "new.txt", "type": "file"}]}"#, for: request)
        }
        let viewModel = try makeViewModel(client: client)

        let slowLoad = Task { await viewModel.loadInitialRootIfNeeded() }
        await fulfillment(of: [slowRequestStarted], timeout: 1)
        let latestLoad = Task { await viewModel.refresh() }

        await latestLoad.value
        await slowLoad.value

        XCTAssertEqual(viewModel.tree.rootNodes.map(\.name), ["new.txt"])
        XCTAssertFalse(viewModel.isLoadingRoot)
    }

    @MainActor
    func testCancelledRootRequestDoesNotSurfaceAnError() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let viewModel = try makeViewModel(client: client)

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertFalse(viewModel.isLoadingRoot)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }
}
