import XCTest
@testable import HermesMobile

/// Lazy loading, expansion memory, selection reveal, and preview prefetch for the file tree, on
/// webui's session routes and on a Hermes chat's folder (#1112).
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
        HermesHostFixture.reset()
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
            files: WebUIWorkspaceFileClient(session: try session(workspace: workspace), server: try XCTUnwrap(URL(string: server)),
                                            apiClient: client),
            defaults: defaults
        )
    }

    /// Saves the open folders of the webui workspace `makeViewModel` opens by default.
    private func saveWebUIExpansion(_ paths: Set<String>) throws {
        let files = WebUIWorkspaceFileClient(sessionID: "s1", workspace: "/tmp/ws", server: try XCTUnwrap(URL(string: "https://example.test")))
        FileTreeExpansionStore(scope: files.scope, defaults: defaults).save(paths)
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
        try saveWebUIExpansion([])
        let viewModel = try makeViewModel(client: client)
        await viewModel.loadInitialRootIfNeeded()

        let slowOpen = Task { await viewModel.toggleDirectory("src") }
        await fulfillment(of: [slowListingStarted], timeout: 1)
        await viewModel.refresh()
        await slowOpen.value

        XCTAssertFalse(viewModel.tree.isLoaded("src"), "The folder vanished from the root while its listing was in flight")
        XCTAssertFalse(viewModel.isLoading("src"), "A dropped listing must not leave its spinner behind")

        await viewModel.retryRoot()

        XCTAssertEqual(viewModel.childCount(of: "src"), 1, "A folder that comes back is listed again, not served from the orphaned listing")
        XCTAssertEqual(log.listedPaths.filter { $0 == "src" }.count, 2)
    }

    @MainActor
    func testFolderRemovedAndRecreatedDuringAnInFlightListingDropsTheOldResponse() async throws {
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
        try saveWebUIExpansion([])
        let viewModel = try makeViewModel(client: client)
        await viewModel.loadInitialRootIfNeeded()

        let slowOpen = Task { await viewModel.toggleDirectory("src") }
        await fulfillment(of: [slowListingStarted], timeout: 1)
        await viewModel.toggleDirectory("src")
        XCTAssertFalse(viewModel.isExpanded("src"), "Collapsed while the listing is still in flight")
        await viewModel.refresh()
        XCTAssertNil(viewModel.tree.node(at: "src"), "Second root listing dropped the folder")
        await viewModel.retryRoot()
        XCTAssertNotNil(viewModel.tree.node(at: "src"), "Third root listing brought it back, collapsed, so nothing re-listed it")
        await slowOpen.value

        XCTAssertFalse(viewModel.tree.isLoaded("src"), "The listing from before the folder was recreated is stale and must not be stored")
        XCTAssertFalse(viewModel.isLoading("src"), "The recreated folder must not show a spinner with no listing in flight")
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
        try saveWebUIExpansion([])
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
        for path in ["report.pdf", "notes.rtf", "archive.zip"] {
            viewModel.prefetchFile(at: path)
            XCTAssertNil(viewModel.prefetchedFile(at: path), "\(path) opens in Quick Look or No Preview, never as text")
        }

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

    // MARK: - Hermes (#1112)

    /// A Hermes tree lists the chat's folder and builds every row from the folder's relative path
    /// plus the entry's name, though the host answers with resolved `/private/…` paths.
    @MainActor
    func testAHermesTreeListsTheChatFolderAndNamesChildrenRelatively() async throws {
        let cwd = HermesWorkspaceFileClientTests.cwd
        let files = HermesWorkspaceFileClientTests.client { request in
            switch HermesWorkspaceFileClientTests.queryPath(request) {
            case cwd: HermesWorkspaceFileClientTests.listing(cwd, [("src", true), ("README.md", false)])
            case cwd + "/src": HermesWorkspaceFileClientTests.listing(cwd + "/src", [("Chat", true), ("main.swift", false)])
            default: nil
            }
        }
        let viewModel = FileBrowserViewModel(files: files, defaults: defaults)

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertEqual(HermesWorkspaceFileClientTests.fileRequests.map(HermesWorkspaceFileClientTests.queryPath),
                       [cwd, cwd + "/src"])
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), ["src", "src/Chat", "src/main.swift", "README.md"])
        XCTAssertNil(viewModel.errorMessage)
    }

    /// A chat folder that is gone shows the folder-missing state with no rows, as when it was
    /// deleted after the tree loaded, and reports no error. A missing subfolder fails only its row.
    @MainActor
    func testAMissingHermesFolderShowsItsStateAndAMissingSubfolderFailsItsRow() async throws {
        let cwd = HermesWorkspaceFileClientTests.cwd
        let rootGone = RequestLog()
        let missing = HermesHostFixture.Reply.json(200, .object(["entries": .array([]), "error": .string("ENOENT")]))
        let files = HermesWorkspaceFileClientTests.client { request in
            switch HermesWorkspaceFileClientTests.queryPath(request) {
            case cwd: rootGone.shouldFail(cwd) ? missing : HermesWorkspaceFileClientTests.listing(cwd, [("src", true)])
            case cwd + "/src": missing
            default: nil
            }
        }
        let viewModel = FileBrowserViewModel(files: files, defaults: defaults)

        await viewModel.loadInitialRootIfNeeded()

        XCTAssertEqual(viewModel.loadFailure(for: "src"), "This folder is no longer on the server.")
        XCTAssertNil(viewModel.errorMessage, "A missing subfolder is not the root's failure")
        XCTAssertNil(viewModel.takeLastError())

        rootGone.setFailing([cwd])
        await viewModel.refresh()

        XCTAssertEqual(viewModel.errorMessage, "This folder is no longer on the server.")
        XCTAssertFalse(viewModel.tree.isRootLoaded, "No rows from the folder that is gone")
        XCTAssertNil(viewModel.takeLastError(), "The host's answer about the folder is not a failed request")
    }

    /// A folder's first listing still in flight when the chat's folder disappears never lands
    /// once the folder is back, even after the folder was closed and the root listed again (#188).
    @MainActor
    func testAFirstListingInFlightWhenTheFolderDisappearsNeverLands() async throws {
        let cwd = HermesWorkspaceFileClientTests.cwd
        let parked = expectation(description: "src's first listing is in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        var rootIsGone = false
        var srcParks = true
        let files = HermesWorkspaceFileClientTests.client { request in
            switch HermesWorkspaceFileClientTests.queryPath(request) {
            case cwd: return rootIsGone ? .json(200, .object(["entries": .array([]), "error": .string("ENOENT")]))
                : HermesWorkspaceFileClientTests.listing(cwd, [("src", true)])
            case cwd + "/src": return srcParks ? .park : HermesWorkspaceFileClientTests.listing(cwd + "/src", [("new.swift", false)])
            default: return nil
            }
        }
        FileTreeExpansionStore(scope: files.scope, defaults: defaults).save([])
        let viewModel = FileBrowserViewModel(files: files, defaults: defaults)
        await viewModel.loadInitialRootIfNeeded()
        let staleOpen = Task { await viewModel.toggleDirectory("src") }
        await fulfillment(of: [parked], timeout: 5)
        await viewModel.toggleDirectory("src")

        HermesHostFixture.script { rootIsGone = true }
        await viewModel.refresh()
        HermesHostFixture.script { rootIsGone = false; srcParks = false }
        await viewModel.refresh()
        HermesHostFixture.releaseParked(HermesWorkspaceFileClientTests.listing(cwd + "/src", [("old.swift", false)]))
        await staleOpen.value

        XCTAssertFalse(viewModel.tree.isLoaded("src"), "The listing from before the folder disappeared is stale")
        await viewModel.toggleDirectory("src")
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), ["src", "src/new.swift"])
    }

    /// The chat's folder moving drops the tree, the expansion and the prefetches, and lists the
    /// new folder with its own expansion. A listing of the old folder still in flight never lands
    /// in the new tree, even in a folder of the same name that nothing has listed (#188).
    @MainActor
    func testAFolderChangeDropsTheOldTreeAndAStaleListing() async throws {
        let old = HermesWorkspaceFileClientTests.cwd
        let new = "/Users/agent/projects/moved"
        let parked = expectation(description: "the old folder's src listing is in flight")
        HermesHostFixture.onPark = { parked.fulfill() }
        let script: (URLRequest) -> HermesHostFixture.Reply? = { request in
            if request.url?.path == "/api/fs/read-text" { return .json(200, .object(["text": .string("hi")])) }
            switch HermesWorkspaceFileClientTests.queryPath(request) {
            case old: return HermesWorkspaceFileClientTests.listing(old, [("src", true), ("notes.txt", false)])
            case old + "/src": return .park
            case new: return HermesWorkspaceFileClientTests.listing(new, [("src", true)])
            case new + "/src": return HermesWorkspaceFileClientTests.listing(new + "/src", [("new.swift", false)])
            default: return nil
            }
        }
        let oldFiles = HermesWorkspaceFileClientTests.client(script)
        let newFiles = HermesWorkspaceFileClientTests.client(context: HermesWorkspaceFileClientTests.context(cwd: new), script)
        FileTreeExpansionStore(scope: oldFiles.scope, defaults: defaults).save([])
        FileTreeExpansionStore(scope: newFiles.scope, defaults: defaults).save([])
        let viewModel = FileBrowserViewModel(files: oldFiles, defaults: defaults)
        await viewModel.loadInitialRootIfNeeded()
        viewModel.prefetchFile(at: "notes.txt")
        let prefetch = try XCTUnwrap(viewModel.prefetchedFile(at: "notes.txt"))
        let staleOpen = Task { await viewModel.toggleDirectory("src") }
        await fulfillment(of: [parked], timeout: 5)

        await viewModel.switchWorkspace(to: newFiles)
        HermesHostFixture.releaseParked(HermesWorkspaceFileClientTests.listing(old + "/src", [("old.swift", false)]))
        await staleOpen.value

        XCTAssertTrue(prefetch.isCancelled)
        XCTAssertNil(viewModel.prefetchedFile(at: "notes.txt"))
        XCTAssertEqual(viewModel.expandedPaths, [], "The new folder's own expansion, not the old one's")
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), ["src"])
        XCTAssertFalse(viewModel.tree.isLoaded("src"), "The old folder's src listing is stale")
        XCTAssertFalse(viewModel.isLoading("src"))

        await viewModel.toggleDirectory("src")
        XCTAssertEqual(viewModel.visibleNodes(matching: "").map(\.node.path), ["src", "src/new.swift"])
    }

    /// Expansion is kept per server, Profile, session and folder: two chats on one folder never
    /// share it.
    @MainActor
    func testHermesExpansionIsKeptPerServerProfileAndSession() async throws {
        let cwd = HermesWorkspaceFileClientTests.cwd
        let script: (URLRequest) -> HermesHostFixture.Reply? = { request in
            guard request.url?.path == "/api/fs/list" else { return nil }
            return HermesWorkspaceFileClientTests.queryPath(request) == cwd
                ? HermesWorkspaceFileClientTests.listing(cwd, [("src", true)]) : .json(200, .object(["entries": .array([])]))
        }
        let first = FileBrowserViewModel(files: HermesWorkspaceFileClientTests.client(script), defaults: defaults)
        await first.loadInitialRootIfNeeded()
        await first.toggleDirectory("src")
        XCTAssertEqual(first.expandedPaths, [])

        let others = [
            HermesWorkspaceFileClientTests.context(storedKey: "20261008_101600_def456"),
            HermesWorkspaceFileClientTests.context(profile: "default"),
            HermesWorkspaceFileClientTests.context(server: URL(string: "https://other.example")!)
        ]
        for context in others {
            let other = FileBrowserViewModel(files: HermesWorkspaceFileClientTests.client(context: context, script), defaults: defaults)
            await other.loadInitialRootIfNeeded()
            XCTAssertEqual(other.expandedPaths, ["src"], "\(context) starts from the default expansion")
        }
        let same = FileBrowserViewModel(files: HermesWorkspaceFileClientTests.client(script), defaults: defaults)
        await same.loadInitialRootIfNeeded()
        XCTAssertEqual(same.expandedPaths, [], "The same chat and folder remembers its layout")
    }
}
