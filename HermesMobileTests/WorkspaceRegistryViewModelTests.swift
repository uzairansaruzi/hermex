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

        // Confirming with nothing staged is a no-op.
        let noPending = await model.confirmPendingRemoval()
        XCTAssertFalse(noPending)
        XCTAssertEqual(removeCallCount, 0)

        // Only stage + confirm performs the removal.
        model.requestRemoval(of: beta)
        let succeeded = await model.confirmPendingRemoval()
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

        model.requestRemoval(of: try XCTUnwrap(model.rows.first))
        let succeeded = await model.confirmPendingRemoval()

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
