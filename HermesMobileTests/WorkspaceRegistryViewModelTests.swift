import XCTest
@testable import HermesMobile

final class WorkspaceRegistryViewModelTests: APIClientTestCase {
    private static let twoWorkspacesJSON = """
    {
      "workspaces": [
        {"path": "/Users/test/alpha", "name": "Alpha"},
        {"path": "/Users/test/beta", "name": "Beta"}
      ],
      "last": "/Users/test/alpha"
    }
    """

    @MainActor
    func testLoadFetchesWorkspaces() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")
            return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
        }
        let model = WorkspaceRegistryViewModel(client: client)

        await model.load()

        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha", "/Users/test/beta"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testLoadFailureSurfacesError() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
        let model = WorkspaceRegistryViewModel(client: client)

        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.managementUnavailable)
    }

    @MainActor
    func testAddWorkspaceTrimsInputAndUsesReturnedList() async throws {
        var addBody: [String: Any] = [:]
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces/add":
                addBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/alpha", "name": "Alpha"},
                    {"path": "/Users/test/gamma", "name": "Gamma"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)

        let succeeded = await model.addWorkspace(path: "  /Users/test/gamma  ", name: "   ", create: false)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(addBody["path"] as? String, "/Users/test/gamma")
        XCTAssertNil(addBody["name"], "Blank names must be omitted so the server derives one from the path.")
        XCTAssertNil(addBody["create"], "create is opt-in and omitted when false.")
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha", "/Users/test/gamma"])
        XCTAssertTrue(model.didMutateRegistry)
    }

    @MainActor
    func testAddWorkspaceFailureSurfacesServerErrorString() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error": "Path points to a system directory: /etc"}"#.utf8))
        }
        let model = WorkspaceRegistryViewModel(client: client)

        let succeeded = await model.addWorkspace(path: "/etc", name: nil, create: false)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(model.errorMessage?.contains("Path points to a system directory: /etc") == true)
        XCTAssertFalse(model.didMutateRegistry)
    }

    @MainActor
    func testRemovalIsConfirmationGated() async throws {
        var removeCallCount = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/remove":
                removeCallCount += 1
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["path"] as? String, "/Users/test/beta")
                return apiTestJSONResponse("""
                {"ok": true, "workspaces": [{"path": "/Users/test/alpha", "name": "Alpha"}]}
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()
        let beta = try XCTUnwrap(model.rows.last)

        // Staging then cancelling must never hit the network.
        model.requestRemoval(of: beta)
        XCTAssertEqual(model.pendingRemoval?.path, "/Users/test/beta")
        model.cancelPendingRemoval()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(removeCallCount, 0)
        XCTAssertEqual(model.rows.count, 2)

        // Confirming a pathless workspace is a no-op.
        let pathless = try JSONDecoder().decode(WorkspaceRoot.self, from: Data("{}".utf8))
        let noPath = await model.confirmRemoval(of: pathless)
        XCTAssertFalse(noPath)
        XCTAssertEqual(removeCallCount, 0)

        // Confirm performs the removal even after the presentation binding
        // already cleared the staged state (the dialog-dismissal race the
        // first review round caught): the confirmed workspace is passed
        // explicitly, so removal must not depend on `pendingRemoval`.
        model.requestRemoval(of: beta)
        model.cancelPendingRemoval()
        let succeeded = await model.confirmRemoval(of: beta)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(removeCallCount, 1)
        XCTAssertNil(model.pendingRemoval)
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha"])
    }

    @MainActor
    func testRenameWorkspaceUpdatesListFromResponse() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/rename":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["path"] as? String, "/Users/test/beta")
                XCTAssertEqual(body["name"] as? String, "Beta Renamed")
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/alpha", "name": "Alpha"},
                    {"path": "/Users/test/beta", "name": "Beta Renamed"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.renameWorkspace(path: "/Users/test/beta", to: "  Beta Renamed  ")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.rows.last?.name, "Beta Renamed")
    }

    @MainActor
    func testRenameRejectsBlankNameWithoutNetworkCall() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/workspaces")
            return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.renameWorkspace(path: "/Users/test/beta", to: "   ")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.rows.last?.name, "Beta")
    }

    @MainActor
    func testMoveWorkspacesSendsFullOrder() async throws {
        var reorderBody: [String: Any] = [:]
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/reorder":
                reorderBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/beta", "name": "Beta"},
                    {"path": "/Users/test/alpha", "name": "Alpha"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.moveWorkspaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(reorderBody["paths"] as? [String], ["/Users/test/beta", "/Users/test/alpha"])
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/beta", "/Users/test/alpha"])
    }

    @MainActor
    func testMoveWorkspacesAppliesOffsetsToVisibleRowsWhenPathlessEntriesExist() async throws {
        var reorderBody: [String: Any] = [:]
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                // A pathless entry (tolerant decoding) is hidden from the UI,
                // so move offsets are relative to the two visible rows.
                return apiTestJSONResponse("""
                {
                  "workspaces": [
                    {"path": "/Users/test/alpha", "name": "Alpha"},
                    {"name": "Ghost"},
                    {"path": "/Users/test/beta", "name": "Beta"}
                  ]
                }
                """, for: request)
            case "/api/workspaces/reorder":
                reorderBody = try apiTestJSONBody(from: request)
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha", "/Users/test/beta"])

        // Move the second *visible* row (beta) to the front. With offsets
        // applied to the raw list this would move the pathless ghost instead.
        let succeeded = await model.moveWorkspaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(reorderBody["paths"] as? [String], ["/Users/test/beta", "/Users/test/alpha"])
    }

    @MainActor
    func testMoveWorkspacesRefetchesOnFailure() async throws {
        var workspacesLoadCount = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                workspacesLoadCount += 1
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/reorder":
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
                )!
                return (response, Data("{}".utf8))
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.moveWorkspaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(workspacesLoadCount, 2, "A failed reorder must refetch so local order matches the server.")
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha", "/Users/test/beta"])
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testMutationOkFalseIsTreatedAsFailure() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/add":
                // HTTP 200, but the body reports failure. Upstream uses non-2xx
                // for failures today, yet the routes are undocumented — an
                // explicit `ok: false` must never be presented as a success.
                return apiTestJSONResponse(
                    #"{"ok": false, "error": "Workspace already in list"}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.addWorkspace(path: "/Users/test/alpha", name: nil, create: false)

        XCTAssertFalse(succeeded)
        XCTAssertFalse(model.didMutateRegistry)
        XCTAssertTrue(model.errorMessage?.contains("Workspace already in list") == true)
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha", "/Users/test/beta"])
        XCTAssertFalse(model.isMutating)
    }

    @MainActor
    func testStaleReorderResponseDoesNotClobberNewerOrder() async throws {
        let threeWorkspacesJSON = """
        {
          "workspaces": [
            {"path": "/Users/test/alpha", "name": "Alpha"},
            {"path": "/Users/test/beta", "name": "Beta"},
            {"path": "/Users/test/gamma", "name": "Gamma"}
          ]
        }
        """
        // First reorder ([beta, gamma, alpha]) is held back so the second one
        // ([gamma, alpha, beta]) supersedes it before its stale echo lands.
        // Whether the hold ends via the signal or the bounded timeout (the mock
        // URL loading may serialize the two requests), the stale echo is always
        // processed after the newer reorder began — the generation guard must
        // ignore it.
        let firstReorderStarted = expectation(description: "first reorder request in flight")
        let releaseFirstReorder = DispatchSemaphore(value: 0)
        var reorderCallCount = 0

        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(threeWorkspacesJSON, for: request)
            case "/api/workspaces/reorder":
                reorderCallCount += 1
                if reorderCallCount == 1 {
                    firstReorderStarted.fulfill()
                    _ = releaseFirstReorder.wait(timeout: .now() + 2)
                    return apiTestJSONResponse("""
                    {
                      "ok": true,
                      "workspaces": [
                        {"path": "/Users/test/beta", "name": "Beta"},
                        {"path": "/Users/test/gamma", "name": "Gamma"},
                        {"path": "/Users/test/alpha", "name": "Alpha"}
                      ]
                    }
                    """, for: request)
                }
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/gamma", "name": "Gamma"},
                    {"path": "/Users/test/alpha", "name": "Alpha"},
                    {"path": "/Users/test/beta", "name": "Beta"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        // Move 1: alpha to the end → [beta, gamma, alpha]; response is held.
        let firstMove = Task { @MainActor in
            await model.moveWorkspaces(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        }
        await fulfillment(of: [firstReorderStarted], timeout: 2)
        XCTAssertTrue(model.isMutating)

        // Move 2 (overlapping): beta to the end → [gamma, alpha, beta];
        // completes while move 1 is still awaiting its response.
        let secondSucceeded = await model.moveWorkspaces(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(
            model.rows.map(\.path),
            ["/Users/test/gamma", "/Users/test/alpha", "/Users/test/beta"]
        )

        // Release the stale first response; it must not overwrite the order.
        releaseFirstReorder.signal()
        let firstSucceeded = await firstMove.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertEqual(
            model.rows.map(\.path),
            ["/Users/test/gamma", "/Users/test/alpha", "/Users/test/beta"],
            "A stale reorder echo must not clobber a newer ordering."
        )
        XCTAssertFalse(model.isMutating, "isMutating must stay true until the last overlapping mutation settles, then clear.")
        XCTAssertTrue(model.didMutateRegistry)
    }

    @MainActor
    func testStaleRenameResponseDoesNotResurrectRemovedWorkspace() async throws {
        // The rename of alpha is held back so an overlapping removal of beta
        // supersedes it. The stale rename echo still contains beta; the
        // generation guard must ignore it instead of resurrecting the removed
        // row. (As above: whether the hold ends via the signal or the bounded
        // timeout, the stale echo is always processed after the removal began.)
        let renameStarted = expectation(description: "rename request in flight")
        let releaseRename = DispatchSemaphore(value: 0)

        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/rename":
                renameStarted.fulfill()
                _ = releaseRename.wait(timeout: .now() + 2)
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/alpha", "name": "Renamed Alpha"},
                    {"path": "/Users/test/beta", "name": "Beta"}
                  ]
                }
                """, for: request)
            case "/api/workspaces/remove":
                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "workspaces": [
                    {"path": "/Users/test/alpha", "name": "Renamed Alpha"}
                  ]
                }
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        // Rename alpha; the response is held while the removal overlaps it.
        let renameTask = Task { @MainActor in
            await model.renameWorkspace(path: "/Users/test/alpha", to: "Renamed Alpha")
        }
        await fulfillment(of: [renameStarted], timeout: 2)
        XCTAssertTrue(model.isMutating)

        let beta = try XCTUnwrap(model.rows.first { $0.path == "/Users/test/beta" })
        let removalSucceeded = await model.confirmRemoval(of: beta)
        XCTAssertTrue(removalSucceeded)
        XCTAssertEqual(model.rows.map(\.path), ["/Users/test/alpha"])

        // Release the stale rename response; it must not restore beta.
        releaseRename.signal()
        let renameSucceeded = await renameTask.value
        XCTAssertTrue(renameSucceeded)
        XCTAssertEqual(
            model.rows.map(\.path),
            ["/Users/test/alpha"],
            "A stale rename echo must not resurrect a removed workspace."
        )
        XCTAssertFalse(model.isMutating)
        XCTAssertTrue(model.didMutateRegistry)
    }

    @MainActor
    func testMutationWithoutWorkspacesEchoRefetchesList() async throws {
        var workspacesLoadCount = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                workspacesLoadCount += 1
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/remove":
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let target = try XCTUnwrap(model.rows.first)
        model.requestRemoval(of: target)
        let succeeded = await model.confirmRemoval(of: target)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(workspacesLoadCount, 2, "A mutation response without a workspaces echo must refetch.")
    }

    @MainActor
    func testMutation404MarksManagementUnavailable() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/workspaces":
                return apiTestJSONResponse(Self.twoWorkspacesJSON, for: request)
            case "/api/workspaces/add":
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
                )!
                return (response, Data("Not Found".utf8))
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = WorkspaceRegistryViewModel(client: client)
        await model.load()

        let succeeded = await model.addWorkspace(path: "/Users/test/gamma", name: nil, create: false)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(model.managementUnavailable)
        XCTAssertNotNil(model.errorMessage)
        // The registry list itself must keep working.
        XCTAssertEqual(model.rows.count, 2)
    }
}
