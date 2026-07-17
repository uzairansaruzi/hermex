import XCTest
@testable import HermesMobile

final class APIClientKanbanTests: APIClientTestCase {
    func testCompatibilityHandshakeUsesOnlyVerifiedGETRequests() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertNil(request.httpBody)

            switch request.url?.path {
            case "/api/kanban/config":
                XCTAssertNil(request.url?.query)
                return apiTestJSONResponse(Self.configurationJSON, for: request)
            case "/api/kanban/boards":
                XCTAssertNil(request.url?.query)
                return apiTestJSONResponse(Self.boardsJSON, for: request)
            case "/api/kanban/board":
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "main board")])
                return apiTestJSONResponse(Self.boardJSON, for: request)
            case "/api/kanban/stats":
                XCTAssertEqual(request.url?.query, "board=main%20board")
                return apiTestJSONResponse(Self.statsJSON, for: request)
            case "/api/kanban/assignees":
                XCTAssertEqual(request.url?.query, "board=main%20board")
                return apiTestJSONResponse(#"{"assignees":["work","review"]}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        _ = try await client.kanbanConfiguration()
        _ = try await client.kanbanBoards()
        let board = try await client.kanbanBoard(KanbanBoardRequest(board: "main board"))
        let stats = try await client.kanbanStats(board: "main board")
        let history = try await client.kanbanAssignees(board: "main board")

        XCTAssertEqual(board.changed, true)
        XCTAssertEqual(board.columns?.first?.cards?.first?.cardID, "card-1")
        XCTAssertEqual(stats.byStatus?["ready"], 2)
        XCTAssertEqual(history.assignees, ["work", "review"])
    }

    func testBoardReadUsesOnlyVerifiedFiltersAndCursor() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(components?.path, "/api/kanban/board")
            XCTAssertEqual(components?.queryItems, [
                URLQueryItem(name: "board", value: "release"),
                URLQueryItem(name: "tenant", value: "mobile"),
                URLQueryItem(name: "assignee", value: "review profile"),
                URLQueryItem(name: "include_archived", value: "true"),
                URLQueryItem(name: "only_mine", value: "true"),
                URLQueryItem(name: "since", value: "42")
            ])
            return apiTestJSONResponse(#"{"changed":false,"latest_event_id":42,"read_only":false}"#, for: request)
        }

        let snapshot = try await client.kanbanBoard(KanbanBoardRequest(
            board: "release",
            tenant: "mobile",
            assignee: "review profile",
            includeArchived: true,
            onlyMine: true,
            since: 42
        ))

        XCTAssertEqual(snapshot.changed, false)
        XCTAssertNil(snapshot.columns)
        XCTAssertEqual(snapshot.latestEventID, 42)
    }

    func testEventPollingUsesVerifiedCursorEnvelopeAndBounds() async throws {
        let client = makeClient { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(components?.path, "/api/kanban/events")
            XCTAssertEqual(components?.queryItems, [
                URLQueryItem(name: "board", value: "release board"),
                URLQueryItem(name: "since", value: "0"),
                URLQueryItem(name: "limit", value: "200")
            ])
            return apiTestJSONResponse("""
            {
              "events": [{
                "id": "8", "task_id": "CARD-8", "run_id": null,
                "kind": "future_event_kind", "payload": {"secret":"not retained"},
                "created_at": "1700000000", "future_field": true
              }],
              "cursor": "8", "latest_event_id": 8, "read_only": false,
              "future_envelope_field": {"nested": true}
            }
            """, for: request)
        }

        let envelope = try await client.kanbanEvents(
            KanbanEventsRequest(board: "release board", since: -4, limit: 999)
        )

        XCTAssertEqual(envelope.cursor, 8)
        XCTAssertEqual(envelope.latestEventID, 8)
        XCTAssertEqual(envelope.events?.first?.eventID, 8)
        XCTAssertEqual(envelope.events?.first?.cardID, "CARD-8")
        XCTAssertEqual(envelope.events?.first?.kind, "future_event_kind")
    }

    func testEventStreamURLPinsBoardAndResumeCursor() throws {
        let client = APIClient(baseURL: try XCTUnwrap(URL(string: "https://example.test/root")))
        let url = client.kanbanEventsStreamURL(
            KanbanEventsStreamRequest(board: "release board", since: 42)
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.path, "/root/api/kanban/events/stream")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "board", value: "release board"),
            URLQueryItem(name: "since", value: "42")
        ])
    }

    func testCardIdentifiersRemainOneEncodedPathSegment() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.test/root"))
        let cardID = "../CARD/1?#"
        let expectedPrefix = "/root/api/kanban/tasks/%2E%2E%2FCARD%2F1%3F%23"
        let endpoints: [(Endpoint, String, [URLQueryItem])] = [
            (
                .kanbanCardDetail(KanbanCardDetailRequest(cardID: cardID, board: "main")),
                "",
                [URLQueryItem(name: "board", value: "main")]
            ),
            (
                .kanbanWorkerLog(KanbanWorkerLogRequest(cardID: cardID, board: "main")),
                "/log",
                [URLQueryItem(name: "board", value: "main"), URLQueryItem(name: "tail", value: "65536")]
            ),
            (
                .kanbanAddComment(KanbanAddCommentRequest(cardID: cardID, board: "main", body: "test")),
                "/comments",
                [URLQueryItem(name: "board", value: "main")]
            ),
            (
                .kanbanEditCard(KanbanEditCardRequest(
                    cardID: cardID, board: "main", title: "Edit", body: "", tenant: nil,
                    priority: 0, assignee: nil, status: nil
                )),
                "",
                [URLQueryItem(name: "board", value: "main")]
            )
        ]

        for (endpoint, suffix, queryItems) in endpoints {
            let url = endpoint.url(relativeTo: baseURL)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.percentEncodedPath, expectedPrefix + suffix)
            XCTAssertEqual(components.queryItems, queryItems)
        }
    }

    func testCardDetailCommentAndWorkerLogUseVerifiedContracts() async throws {
        var requestIndex = 0
        let client = makeClient { request in
            defer { requestIndex += 1 }
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            switch requestIndex {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1")
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "release board")])
                XCTAssertNil(request.httpBody)
                return apiTestJSONResponse(Self.detailJSON, for: request)
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1/log")
                XCTAssertEqual(components?.queryItems, [
                    URLQueryItem(name: "board", value: "release board"),
                    URLQueryItem(name: "tail", value: "2000000")
                ])
                return apiTestJSONResponse(
                    #"{"task_id":"CARD-1","path":"/private/not-retained","exists":true,"size_bytes":3000000,"content":"tail","truncated":true}"#,
                    for: request
                )
            default:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1/comments")
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "release board")])
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try XCTUnwrap(apiTestBodyData(from: request))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(object, ["body": "Ready for review"])
                return apiTestJSONResponse(#"{"ok":true,"comment_id":42,"read_only":false}"#, for: request)
            }
        }

        let detail = try await client.kanbanCardDetail(
            KanbanCardDetailRequest(cardID: "CARD-1", board: "release board")
        )
        let log = try await client.kanbanWorkerLog(
            KanbanWorkerLogRequest(cardID: "CARD-1", board: "release board", tailBytes: 9_000_000)
        )
        let comment = try await client.addKanbanComment(
            KanbanAddCommentRequest(cardID: "CARD-1", board: "release board", body: "Ready for review")
        )

        XCTAssertEqual(detail.card?.cardID, "CARD-1")
        XCTAssertEqual(log.content, "tail")
        XCTAssertEqual(log.truncated, true)
        XCTAssertEqual(comment.commentID, "42")
    }

    func testCreateAndEditUseExactVerifiedAsymmetricBodies() async throws {
        var requestIndex = 0
        let client = makeClient { request in
            defer { requestIndex += 1 }
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "release board")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            if requestIndex == 0 {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/tasks")
                XCTAssertEqual(Set(body.keys), [
                    "title", "body", "status", "priority", "assignee", "tenant",
                    "workspace_kind", "workspace_path", "skills", "max_runtime_seconds",
                    "parents", "idempotency_key"
                ])
                XCTAssertEqual(body["title"] as? String, "Native editor")
                XCTAssertEqual(body["status"] as? String, "ready")
                XCTAssertEqual(body["workspace_kind"] as? String, "worktree")
                XCTAssertEqual(body["parents"] as? [String], ["CARD-0"])
                XCTAssertEqual(body["idempotency_key"] as? String, "intent-153")
                return apiTestJSONResponse(
                    #"{"task":{"id":"CARD-153","title":"Native editor","body":"Complete","status":"ready","priority":4,"assignee":"builder","tenant":"mobile","workspace_kind":"worktree","workspace_path":"/workspace","skills":["swift"],"max_runtime_seconds":900},"read_only":false,"future":true}"#,
                    for: request
                )
            }

            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-153")
            XCTAssertEqual(Set(body.keys), ["title", "body", "tenant", "priority", "assignee", "status"])
            XCTAssertTrue(body["assignee"] is NSNull)
            XCTAssertTrue(body["tenant"] is NSNull)
            XCTAssertNil(body["workspace_kind"])
            XCTAssertNil(body["idempotency_key"])
            return apiTestJSONResponse(
                #"{"task":{"id":"CARD-153","title":"Edited","body":"","status":"todo","priority":0},"read_only":false}"#,
                for: request
            )
        }

        let created = try await client.createKanbanCard(KanbanCreateCardRequest(
            board: "release board",
            title: "Native editor",
            body: "Complete",
            status: "ready",
            priority: 4,
            assignee: "builder",
            tenant: "mobile",
            workspaceKind: "worktree",
            workspacePath: "/workspace",
            skills: ["swift"],
            maxRuntimeSeconds: 900,
            prerequisiteID: "CARD-0",
            idempotencyKey: "intent-153"
        ))
        let edited = try await client.editKanbanCard(KanbanEditCardRequest(
            cardID: "CARD-153",
            board: "release board",
            title: "Edited",
            body: "",
            tenant: nil,
            priority: 0,
            assignee: nil,
            status: "todo"
        ))

        XCTAssertEqual(created.card?.cardID, "CARD-153")
        XCTAssertEqual(edited.card?.title, "Edited")
    }

    func testCreateOmitsUnsetOptionalFieldsAndMutationValidationRejectsMalformedIdentity() async throws {
        let client = makeClient { request in
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["title", "status", "workspace_kind", "idempotency_key"])
            return apiTestJSONResponse(#"{"task":{"id":"CARD-1","status":"triage"},"unknown":true}"#, for: request)
        }
        let envelope = try await client.createKanbanCard(KanbanCreateCardRequest(
            board: "main", title: "Minimal", body: nil, status: "triage", priority: nil,
            assignee: nil, tenant: nil, workspaceKind: "scratch", workspacePath: nil,
            skills: nil, maxRuntimeSeconds: nil, prerequisiteID: nil, idempotencyKey: "same-key"
        ))
        XCTAssertEqual(try KanbanCardMutationValidator.validate(envelope).cardID, "CARD-1")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let malformed = try decoder.decode(
            KanbanCardMutationEnvelope.self,
            from: Data(#"{"task":{"title":"missing identity","status":"ready"}}"#.utf8)
        )
        XCTAssertThrowsError(try KanbanCardMutationValidator.validate(malformed))
    }

    func testWorkflowAndDependencyMutationsUseExactVerifiedContracts() async throws {
        var requestIndex = 0
        let client = makeClient { request in
            defer { requestIndex += 1 }
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "board", value: "release board")])
            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            switch requestIndex {
            case 0:
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1")
                XCTAssertEqual(body as NSDictionary, ["status": "done"])
                return apiTestJSONResponse(#"{"task":{"id":"CARD-1","status":"done"},"read_only":false}"#, for: request)
            case 1:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1/block")
                XCTAssertEqual(body as NSDictionary, ["reason": "Waiting for review"])
                return apiTestJSONResponse(#"{"task":{"id":"CARD-1","status":"blocked"},"read_only":false}"#, for: request)
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/tasks/CARD-1/unblock")
                XCTAssertTrue(body.isEmpty)
                return apiTestJSONResponse(#"{"task":{"id":"CARD-1","status":"ready"},"read_only":false}"#, for: request)
            case 3:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/links")
                XCTAssertEqual(body as NSDictionary, ["parent_id": "CARD-0", "child_id": "CARD-1"])
                return apiTestJSONResponse(#"{"ok":true,"parent_id":"CARD-0","child_id":"CARD-1","read_only":false}"#, for: request)
            default:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(components?.path, "/api/kanban/links/delete")
                XCTAssertEqual(body as NSDictionary, ["parent_id": "CARD-0", "child_id": "CARD-1"])
                return apiTestJSONResponse(#"{"ok":true,"changed":true,"parent_id":"CARD-0","child_id":"CARD-1","read_only":false}"#, for: request)
            }
        }

        let status = try await client.setKanbanCardStatus(
            KanbanCardStatusRequest(cardID: "CARD-1", board: "release board", status: "done")
        )
        let blocked = try await client.blockKanbanCard(
            KanbanCardActionRequest(cardID: "CARD-1", board: "release board", reason: "Waiting for review")
        )
        let unblocked = try await client.unblockKanbanCard(
            KanbanCardActionRequest(cardID: "CARD-1", board: "release board", reason: nil)
        )
        let dependency = KanbanDependencyMutationRequest(
            board: "release board", prerequisiteID: "CARD-0", dependentID: "CARD-1"
        )
        let linked = try await client.addKanbanDependency(dependency)
        let unlinked = try await client.removeKanbanDependency(dependency)

        XCTAssertEqual(status.card?.status?.rawValue, "done")
        XCTAssertEqual(blocked.card?.status?.rawValue, "blocked")
        XCTAssertEqual(unblocked.card?.status?.rawValue, "ready")
        XCTAssertNoThrow(try KanbanDependencyMutationValidator.validate(linked, request: dependency))
        XCTAssertNoThrow(try KanbanDependencyMutationValidator.validate(unlinked, request: dependency))
    }

    func testRunningEntryIsRejectedBeforeRequestConstruction() async {
        let client = makeClient { _ in
            XCTFail("Running must never reach URLSession")
            throw URLError(.badURL)
        }

        await XCTAssertThrowsErrorAsync(
            try await client.setKanbanCardStatus(
                KanbanCardStatusRequest(cardID: "CARD-1", board: "main", status: " Running ")
            )
        ) { error in
            XCTAssertEqual(error as? KanbanRequestError, .runningStatusRequiresDispatcher)
        }
    }

    func testCardDetailDecodesExpandedAndMinimalEnvelopesTolerantly() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(KanbanCardDetailEnvelope.self, from: Data(Self.detailJSON.utf8))

        XCTAssertNoThrow(try KanbanCardDetailValidator.validate(detail, requestedCardID: "CARD-1"))
        XCTAssertEqual(detail.comments?.first?.commentID, "7")
        XCTAssertEqual(detail.events?.first?.payload?.status, "ready")
        XCTAssertNil(detail.events?.first?.payload?.summary)
        XCTAssertEqual(detail.links?.prerequisites, ["CARD-0"])
        XCTAssertEqual(detail.links?.dependents, ["CARD-2"])
        XCTAssertEqual(detail.runs?.first?.runID, "run-1")
        XCTAssertNil(detail.card?.workerID) // malformed metadata is ignored

        let minimal = try decoder.decode(KanbanCardDetailEnvelope.self, from: Data(
            #"{"task":{"id":"CARD-1","status":"future"},"future":{"nested":true}}"#.utf8
        ))
        XCTAssertNoThrow(try KanbanCardDetailValidator.validate(minimal, requestedCardID: "CARD-1"))
        XCTAssertEqual(minimal.card?.status?.rawValue, "future")
        XCTAssertNil(minimal.comments)

        let missingIdentity = try decoder.decode(
            KanbanCardDetailEnvelope.self,
            from: Data(#"{"task":{"status":"ready"}}"#.utf8)
        )
        XCTAssertThrowsError(try KanbanCardDetailValidator.validate(missingIdentity, requestedCardID: "CARD-1"))
    }

    func testMissingCardAndNonJSONCommentResponseRemainTypedFailures() async throws {
        let missingClient = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"task not found","path":"/private/must-not-surface"}"#.utf8))
        }
        await XCTAssertThrowsErrorAsync(
            try await missingClient.kanbanCardDetail(KanbanCardDetailRequest(cardID: "gone", board: "main"))
        ) { error in
            guard case let APIError.http(statusCode, _) = error else {
                return XCTFail("Expected HTTP error, got \(error)")
            }
            XCTAssertEqual(statusCode, 404)
        }

        let nonJSONClient = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>proxy</html>".utf8))
        }
        await XCTAssertThrowsErrorAsync(
            try await nonJSONClient.addKanbanComment(
                KanbanAddCommentRequest(cardID: "CARD-1", board: "main", body: "hello")
            )
        ) { error in
            XCTAssertEqual(error as? KanbanResponseError, .nonJSONContentType)
        }
    }

    func testKanbanCarriesConfiguredCustomHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Proxy"), "enabled")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            return apiTestJSONResponse(Self.configurationJSON, for: request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let serverURL = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(
            baseURL: serverURL,
            session: URLSession(configuration: configuration),
            customHeaderProvider: { [CustomHeader(name: "X-Hermes-Proxy", value: "enabled")] }
        )

        _ = try await client.kanbanConfiguration()
    }

    func testNonJSONAndMalformedJSONAreNotAcceptedAsKanban() async throws {
        let nonJSONClient = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>login</html>".utf8))
        }
        await XCTAssertThrowsErrorAsync(try await nonJSONClient.kanbanConfiguration()) { error in
            XCTAssertEqual(error as? KanbanResponseError, .nonJSONContentType)
        }

        let malformedClient = makeClient { request in
            apiTestJSONResponse("{not valid json", for: request)
        }
        await XCTAssertThrowsErrorAsync(try await malformedClient.kanbanConfiguration()) { error in
            guard case APIError.decoding = error else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testTolerantModelsKeepUnknownStatusAndIgnoreUnknownFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {
          "changed": true,
          "columns": [{
            "name": "future-status",
            "tasks": [{"id": "card-1", "status": "future-status", "new_field": {"nested": true}}]
          }],
          "new_envelope_field": 17
        }
        """.utf8))

        XCTAssertEqual(snapshot.columns?.first?.cards?.first?.status?.rawValue, "future-status")
        XCTAssertFalse(snapshot.columns?.first?.cards?.first?.status?.isSupported ?? true)
    }

    func testCardSummaryFieldsStatsEnvelopesAndStalenessDecodeTolerantly() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {
          "changed": true,
          "columns": [{"name":"blocked","tasks":[{
            "id":"CARD-9","title":"Blocked read","body":"**Markdown** body","status":"blocked",
            "assignee":"review","tenant":"mobile","priority":"2","comment_count":"3",
            "link_counts":{"parents":"1","children":2},"age_seconds":"90000"
          }]}],
          "tenants":["mobile"],"assignees":["review"],
          "filters":{"tenant":"mobile","include_archived":true,"only_mine":false}
        }
        """.utf8))
        let card = try XCTUnwrap(snapshot.columns?.first?.cards?.first)
        XCTAssertEqual(card.body, "**Markdown** body")
        XCTAssertEqual(card.priority, 2)
        XCTAssertEqual(card.commentCount, 3)
        XCTAssertEqual(card.linkCounts?.parents, 1)
        XCTAssertEqual(card.linkCounts?.children, 2)
        XCTAssertEqual(card.staleness, .critical)
        XCTAssertEqual(snapshot.filters?.includeArchived, true)

        let current = try decoder.decode(KanbanStats.self, from: Data(Self.statsJSON.utf8))
        XCTAssertEqual(current.total, 3)
        XCTAssertEqual(current.byStatus?["ready"], 2)
        let older = try decoder.decode(KanbanStats.self, from: Data(#"{"by_status":{"ready":1}}"#.utf8))
        XCTAssertNil(older.total)
        XCTAssertEqual(older.byStatus?["ready"], 1)
        XCTAssertNil(older.byAssignee)
    }

    func testSemanticValidationRejectsMissingSafetyCriticalDataAndMarksUnknownStatusPartial() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(KanbanConfiguration.self, from: Data(Self.configurationJSON.utf8))
        let boards = try decoder.decode(KanbanBoardsResponse.self, from: Data(Self.boardsJSON.utf8))
        let snapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data(Self.boardJSON.utf8))

        let report = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: snapshot
        )
        XCTAssertFalse(report.isPartial)

        let missingCurrent = try decoder.decode(KanbanBoardsResponse.self, from: Data(#"{"boards": []}"#.utf8))
        XCTAssertThrowsError(
            try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: missingCurrent,
                snapshot: snapshot
            )
        ) { error in
            XCTAssertEqual(error as? KanbanContractViolation, .missingCurrentBoard)
        }

        let futureSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"changed":true,"read_only":false,"columns":[{"name":"future","tasks":[{"id":"card-1","status":"future"}]}]}
        """.utf8))
        let partialReport = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: futureSnapshot
        )
        XCTAssertEqual(partialReport.warnings, [.unsupportedStatus("future")])

        let incompleteSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"read_only":false,"columns":[{"name":"triage","tasks":[]}]}
        """.utf8))
        XCTAssertThrowsError(
            try KanbanCompatibilityValidator.validate(
                configuration: configuration,
                boardsResponse: boards,
                snapshot: incompleteSnapshot
            )
        ) { error in
            XCTAssertEqual(error as? KanbanContractViolation, .missingBoardSnapshot)
        }

        let caseMismatchedSnapshot = try decoder.decode(KanbanBoardSnapshot.self, from: Data("""
        {"changed":true,"read_only":false,"columns":[{"name":"TRIAGE","tasks":[{"id":"card-1","status":"TRIAGE"}]}]}
        """.utf8))
        let exactStatusReport = try KanbanCompatibilityValidator.validate(
            configuration: configuration,
            boardsResponse: boards,
            snapshot: caseMismatchedSnapshot
        )
        XCTAssertEqual(exactStatusReport.warnings, [.unsupportedStatus("TRIAGE")])
    }

    private static let configurationJSON = """
    {"columns":["triage","todo","ready"],"assignees":["work"],"read_only":false}
    """

    private static let boardsJSON = """
    {"boards":[{"slug":"main board","name":"Main","is_current":true,"total":1}],"current":"main board","read_only":false}
    """

    private static let boardJSON = """
    {"changed":true,"latest_event_id":7,"read_only":false,"columns":[{"name":"triage","tasks":[{"id":"card-1","title":"Safe read","status":"triage"}]}]}
    """

    private static let statsJSON = """
    {"total":3,"by_status":{"ready":2,"done":1},"by_assignee":{"work":3}}
    """

    private static let detailJSON = """
    {
      "task": {
        "id":"CARD-1","title":"Detail","status":"ready","body":"**Markdown**",
        "workspace_path":"/private/explicit-only","worker_pid":{"malformed":true},
        "future_task_field":true
      },
      "comments":[{"id":7,"task_id":"CARD-1","author":"review","body":"Ship it","created_at":1700000000}],
      "events":[{"id":8,"task_id":"CARD-1","kind":"status","payload":{"status":"ready","secret":"discarded"},"created_at":1700000001}],
      "links":{"parents":["CARD-0"],"children":["CARD-2"]},
      "runs":[{"run_id":"run-1","status":"finished","worker":"worker-private","future":true}],
      "read_only":false,
      "future_envelope_field":{"nested":true}
    }
    """
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error, but none was thrown")
    } catch {
        errorHandler(error)
    }
}
