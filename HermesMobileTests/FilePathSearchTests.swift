import XCTest
@testable import HermesMobile

final class FilePathSearchTests: APIClientTestCase {

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.append(path)
        }

        var listedPaths: [String] {
            lock.lock(); defer { lock.unlock() }
            return paths
        }
    }

    private func entryJSON(_ name: String, path: String, type: String, extra: String = "") -> String {
        #"{"name": "\#(name)", "path": "\#(path)", "type": "\#(type)", "is_dir": \#(type == "dir")\#(extra)}"#
    }

    private func listingJSON(for path: String) -> String? {
        switch path {
        case ".":
            return #"{"path": ".", "entries": [\#(entryJSON("..", path: "..", type: "dir")), \#(entryJSON("escape", path: "escape", type: "symlink", extra: #", "target_outside_workspace": true"#)), \#(entryJSON("src", path: "src", type: "dir")), \#(entryJSON("README.md", path: "README.md", type: "file"))]}"#
        case "src":
            return #"{"path": "src", "entries": [\#(entryJSON("Chat", path: "src/Chat", type: "dir")), \#(entryJSON("chores.md", path: "src/chores.md", type: "file")), \#(entryJSON("Main.swift", path: "src/Main.swift", type: "file")), \#(entryJSON("My File.swift", path: "src/My File.swift", type: "file"))]}"#
        default:
            return nil
        }
    }

    private func listedPath(in request: URLRequest) -> String {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first { $0.name == "path" }?.value ?? "."
    }

    private func makeListingClient(log: RequestLog, failingPaths: Set<String> = []) -> APIClient {
        makeClient { [self] request in
            XCTAssertEqual(request.url?.path, "/api/list")
            let path = listedPath(in: request)
            log.record(path)
            if failingPaths.contains(path) {
                return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
            }
            guard let json = listingJSON(for: path) else {
                return apiTestJSONResponse(#"{"error": "not found"}"#, for: request, status: 404)
            }
            return apiTestJSONResponse(json, for: request)
        }
    }

    @MainActor
    func testAnEmptyQueryListsTheWorkspaceRootFoldersFirst() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search("", sessionID: "s1", apiClient: makeListingClient(log: log))

        XCTAssertEqual(log.listedPaths, ["."])
        XCTAssertEqual(search.matches.map(\.path), ["src", "README.md"])
        XCTAssertEqual(search.matches.first?.isDirectory, true)
        XCTAssertFalse(search.isLoading)
    }

    @MainActor
    func testAPathQueryListsOnlyTheFolderItNamesAndRanksItsEntries() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search("src/Ch", sessionID: "s1", apiClient: makeListingClient(log: log))

        XCTAssertEqual(log.listedPaths, ["src"])
        XCTAssertEqual(search.matches.map(\.path), ["src/Chat", "src/chores.md"])
        XCTAssertEqual(search.matches.first?.parentPath, "src")
    }

    @MainActor
    func testARepeatedFolderIsListedOnlyOnce() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()
        let client = makeListingClient(log: log)

        await search.search("", sessionID: "s1", apiClient: client)
        await search.search("RE", sessionID: "s1", apiClient: client)

        XCTAssertEqual(log.listedPaths, ["."])
        XCTAssertEqual(search.matches.map(\.path), ["README.md"])
    }

    @MainActor
    func testNothingOutsideTheWorkspaceIsEverOffered() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search("", sessionID: "s1", apiClient: makeListingClient(log: log))

        XCTAssertFalse(search.matches.contains { $0.name == ".." })
        XCTAssertFalse(search.matches.contains { $0.name == "escape" })
    }

    @MainActor
    func testAnEntryWhoseNameHoldsASpaceIsNeverOffered() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search("src/", sessionID: "s1", apiClient: makeListingClient(log: log))

        XCTAssertEqual(search.matches.map(\.path), ["src/Chat", "src/chores.md", "src/Main.swift"])
        XCTAssertFalse(search.matches.contains { $0.name == "My File.swift" })
    }

    @MainActor
    func testAQueryThatClimbsOutOfTheWorkspaceIsNeverRequested() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search("../etc/pa", sessionID: "s1", apiClient: makeListingClient(log: log))

        XCTAssertTrue(log.listedPaths.isEmpty)
        XCTAssertTrue(search.matches.isEmpty)
    }

    @MainActor
    func testAFailedListingReadsAsNoMatches() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()

        await search.search(
            "",
            sessionID: "s1",
            apiClient: makeListingClient(log: log, failingPaths: ["."])
        )

        XCTAssertTrue(search.matches.isEmpty)
        XCTAssertFalse(search.isLoading)
    }

    @MainActor
    func testAStaleListingNeverOverwritesANewerQuery() async {
        let log = RequestLog()
        let rootStarted = expectation(description: "root listing started")
        let releaseRoot = DispatchSemaphore(value: 0)

        let client = makeClient { [self] request in
            let path = listedPath(in: request)
            log.record(path)
            if path == "." {
                rootStarted.fulfill()
                releaseRoot.wait()
            }
            return apiTestJSONResponse(listingJSON(for: path) ?? "{}", for: request)
        }

        let search = ComposerFilePathSearch()
        let stale = Task { await search.search("", sessionID: "s1", apiClient: client) }
        await fulfillment(of: [rootStarted], timeout: 2)

        await search.search("src/Ch", sessionID: "s1", apiClient: client)
        XCTAssertEqual(search.matches.map(\.path), ["src/Chat", "src/chores.md"])

        releaseRoot.signal()
        await stale.value

        XCTAssertEqual(search.matches.map(\.path), ["src/Chat", "src/chores.md"])
    }

    @MainActor
    func testAListingThatResolvesAfterAResetIsNeverCached() async throws {
        let log = RequestLog()
        let listingStarted = expectation(description: "root listing started")
        let releaseListing = DispatchSemaphore(value: 0)

        let client = makeClient { [self] request in
            let path = listedPath(in: request)
            log.record(path)
            if log.listedPaths.count == 1 {
                listingStarted.fulfill()
                releaseListing.wait()
            }
            return apiTestJSONResponse(listingJSON(for: path) ?? "{}", for: request)
        }

        let search = ComposerFilePathSearch()
        let inFlight = Task { await search.search("", sessionID: "s1", apiClient: client) }
        await fulfillment(of: [listingStarted], timeout: 5)

        search.reset()
        releaseListing.signal()
        await inFlight.value

        XCTAssertTrue(search.matches.isEmpty)

        await search.search("", sessionID: "s1", apiClient: client)

        XCTAssertEqual(log.listedPaths, [".", "."])
        XCTAssertEqual(search.matches.map(\.path), ["src", "README.md"])
    }

    @MainActor
    func testEntriesThrowsRatherThanAnsweringForAScopeThatMoved() async throws {
        let listingStarted = expectation(description: "listing started")
        let releaseListing = DispatchSemaphore(value: 0)

        let client = makeClient { [self] request in
            listingStarted.fulfill()
            releaseListing.wait()
            return apiTestJSONResponse(listingJSON(for: listedPath(in: request)) ?? "{}", for: request)
        }

        let search = ComposerFilePathSearch()
        let entries = Task { try await search.entries(in: ".", sessionID: "s1", apiClient: client) }
        await fulfillment(of: [listingStarted], timeout: 5)

        search.reset()
        releaseListing.signal()

        do {
            _ = try await entries.value
            XCTFail("A listing taken against a scope that has moved must not answer")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testSwitchingSessionDropsTheCachedListings() async {
        let log = RequestLog()
        let search = ComposerFilePathSearch()
        let client = makeListingClient(log: log)

        await search.search("", sessionID: "s1", apiClient: client)
        await search.search("", sessionID: "s2", apiClient: client)

        XCTAssertEqual(log.listedPaths, [".", "."])
    }
}
