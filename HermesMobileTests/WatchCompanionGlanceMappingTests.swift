import Foundation
import WatchShared
import XCTest
@testable import HermesMobile

/// The iPhone side of the watch glances: server JSON → wrist-shaped glance
/// values. Decoded with the same snake-case strategy `APIClient` uses.
final class WatchCompanionGlanceMappingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Tasks

    func testTaskGlanceTakesRunningFromCronStatusAndKeepsTimesAndFailure() throws {
        let job = try decode(CronJob.self, #"""
        {"job_id":"digest","name":"Morning digest","schedule":{"kind":"cron","expr":"0 8 * * *"},
         "enabled":true,"state":"scheduled","next_run_at":1700050000,"last_run_at":1699990000,
         "last_status":"error","last_error":"Timed out after 300s\nTraceback (most recent call last):"}
        """#)

        let glance = try XCTUnwrap(APIClientWatchPhoneBackend.taskGlance(from: job, runningJobIDs: ["digest"]))

        XCTAssertTrue(glance.running)
        XCTAssertTrue(glance.enabled)
        XCTAssertEqual(glance.lastResult, "error")
        XCTAssertEqual(glance.failureSummary, "Timed out after 300s")
        XCTAssertEqual(glance.nextRunAt, Date(timeIntervalSince1970: 1_700_050_000))
        XCTAssertEqual(glance.lastRunAt, Date(timeIntervalSince1970: 1_699_990_000))
        // The humanized schedule, not the raw cron expression.
        XCTAssertNotEqual(glance.schedule, "0 8 * * *")
    }

    func testPausedTaskIsNotEnabledAndHasNoNextRun() throws {
        let job = try decode(CronJob.self, #"""
        {"job_id":"prices","name":"Price watch","enabled":false,"state":"paused","next_run_at":1700050000}
        """#)

        let glance = try XCTUnwrap(APIClientWatchPhoneBackend.taskGlance(from: job, runningJobIDs: []))

        XCTAssertFalse(glance.enabled)
        XCTAssertFalse(glance.running)
        XCTAssertNil(glance.nextRunAt)
    }

    // MARK: Kanban

    func testKanbanGlanceUsesTheIPhoneBoardBeforeAnEmptyActiveBoard() throws {
        let boards = try decode(KanbanBoardsResponse.self, #"""
        {"current":"default","boards":[
          {"slug":"default","name":"Default","is_current":true,"total":0},
          {"slug":"studio","name":"Studio","total":4},
          {"slug":"archive","name":"Archive","total":0}
        ]}
        """#)

        XCTAssertEqual(
            APIClientWatchPhoneBackend.boardSlugsToTry(in: boards, preferred: "studio"),
            ["studio", "default"]
        )
        XCTAssertEqual(
            APIClientWatchPhoneBackend.boardSlugsToTry(in: boards, preferred: nil),
            ["default", "studio"]
        )
    }

    func testKanbanHarvestReadsTasksWhenTheColumnModelMissesThem() {
        let data = Data(#"""
        {"lanes":[{"name":"todo","items":[{"task_id":"t_9","title":"Ship the watch","status":"todo"}]}]}
        """#.utf8)
        let cards = APIClientWatchPhoneBackend.harvestedCards(from: data, limit: 10)
        XCTAssertEqual(cards.map(\.id), ["t_9"])
        XCTAssertEqual(cards.first?.title, "Ship the watch")
        XCTAssertEqual(cards.first?.status, "todo")
    }

    func testKanbanCardsCarryStatusKeysAndSkipArchivedAndIDlessCards() throws {
        let snapshot = try decode(KanbanBoardSnapshot.self, #"""
        {"columns":[
          {"name":"todo","tasks":[{"id":"C1","title":"Write notes","status":"todo","assignee":"default","priority":2,"body":"**Body**","tenant":"studio","comment_count":3,"age_seconds":3700,"skills":["swift"],"link_counts":{"parents":1,"children":1}}]},
          {"name":"running","tasks":[{"title":"No id","status":"running"},{"id":"C2","title":"Ship","status":"running"}]},
          {"name":"archived","tasks":[{"id":"C3","title":"Old","status":"archived"}]}
        ]}
        """#)

        let cards = APIClientWatchPhoneBackend.kanbanCards(from: snapshot, limit: 10)

        XCTAssertEqual(cards.map(\.id), ["C1", "C2"])
        XCTAssertEqual(cards.map(\.status), ["todo", "running"])
        XCTAssertEqual(cards.first?.assignee, "default")
        XCTAssertEqual(cards.first?.priority, 2)
        XCTAssertEqual(cards.first?.body, "**Body**")
        XCTAssertEqual(cards.first?.tenant, "studio")
        XCTAssertEqual(cards.first?.commentCount, 3)
        XCTAssertEqual(cards.first?.linkCount, 2)
        XCTAssertEqual(cards.first?.ageSeconds, 3_700)
        XCTAssertEqual(cards.first?.skills, ["swift"])
    }

    // MARK: Memory

    func testMemoryIsSplitIntoEntriesWithoutTheDelimiter() throws {
        let response = try decode(MemoryResponse.self, #"""
        {"memory":"Prefers short replies.\n§\nShips from the Mac mini.",
         "user":"**Name:** Aaryan Guglani\n§\n**Email:** guglaniaaryan@gmail.com\n§\n**Timezone:** GMT+5:30",
         "soul":"Persona text"}
        """#)

        let glances = APIClientWatchPhoneBackend.memoryGlances(from: response)

        XCTAssertEqual(glances.map(\.section), ["memory", "user"])
        let user = try XCTUnwrap(glances.last)
        XCTAssertEqual(WatchMemoryProjection.entries(in: user.text), [
            "**Name:** Aaryan Guglani",
            "**Email:** guglaniaaryan@gmail.com",
            "**Timezone:** GMT+5:30",
        ])
        XCTAssertFalse(user.isTruncated)
    }

    func testPersonaFillsInOnlyWhenTheOtherSectionsAreEmpty() throws {
        let response = try decode(MemoryResponse.self, #"{"memory":"  ","user":null,"soul":"Calm and direct."}"#)

        XCTAssertEqual(APIClientWatchPhoneBackend.memoryGlances(from: response).map(\.section), ["soul"])
    }

    // MARK: Usage

    func testUsageCarriesPerModelCostAndDailyTokensOldestFirst() throws {
        let response = try decode(InsightsResponse.self, #"""
        {"period_days":7,"total_sessions":3,"total_cost":2.5,"total_tokens":1000,
         "models":[{"model":"cheap","total_tokens":900,"cost":0.5,"sessions":2},{"model":"pricey","input_tokens":60,"output_tokens":40,"cost":2.0,"sessions":1}],
         "daily_tokens":[{"date":"2026-10-03","input_tokens":5,"output_tokens":5},{"date":"2026-10-01","input_tokens":1,"output_tokens":0}]}
        """#)

        let glance = APIClientWatchPhoneBackend.usageGlance(from: response, window: 7)

        XCTAssertEqual(glance.days, 7)
        XCTAssertEqual(glance.modelUsage.map(\.name), ["pricey", "cheap"])
        XCTAssertEqual(glance.modelUsage.first?.totalTokens, 100)
        XCTAssertEqual(glance.dailyTokens, [1, 10])
    }
}

final class WatchVoiceNoteTranscriptionTests: XCTestCase {
    func testServerFirstKeepsTheServerTranscript() async throws {
        let text = try await WatchVoiceNoteTranscription.transcript(
            preference: .serverFirst,
            speechAuthorized: true,
            onDeviceSupported: true,
            server: { "from the server" },
            onDevice: { XCTFail("on-device should wait until the server fails"); return "" }
        )
        XCTAssertEqual(text, "from the server")
    }

    func testServerFailureUsesOnDeviceWhenSpeechIsAlreadyAllowed() async throws {
        let text = try await WatchVoiceNoteTranscription.transcript(
            preference: .serverFirst,
            speechAuthorized: true,
            onDeviceSupported: true,
            server: { throw WatchCompanionError.backend(.invalidResponse) },
            onDevice: { "from the phone" }
        )
        XCTAssertEqual(text, "from the phone")
    }

    func testOnDeviceIsSkippedUntilSpeechPermissionAlreadyExists() async {
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .serverFirst,
                speechAuthorized: false,
                onDeviceSupported: true,
                server: { throw WatchCompanionError.backend(.invalidResponse) },
                onDevice: { XCTFail("a locked phone cannot ask for speech permission"); return "nope" }
            )
            XCTFail("expected the server failure to surface")
        } catch {
            XCTAssertEqual(error as? WatchCompanionError, .backend(.invalidResponse))
        }
    }

    func testOnDeviceOnlyDoesNotCallTheServer() async throws {
        let text = try await WatchVoiceNoteTranscription.transcript(
            preference: .onDeviceOnly,
            speechAuthorized: true,
            onDeviceSupported: true,
            server: { XCTFail("on-device only should not call the server"); return "" },
            onDevice: { "from the phone" }
        )
        XCTAssertEqual(text, "from the phone")
    }

    func testOnDeviceOnlyWithoutPermissionDoesNotCallEitherProvider() async {
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .onDeviceOnly,
                speechAuthorized: false,
                onDeviceSupported: true,
                server: { XCTFail("on-device only must not call the server"); return "" },
                onDevice: { XCTFail("a locked phone cannot ask for speech permission"); return "" }
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? WatchCompanionError, .backend(.invalidResponse))
        }
    }

    func testOnDeviceFirstUsesThePhoneBeforeTheServer() async throws {
        let text = try await WatchVoiceNoteTranscription.transcript(
            preference: .onDeviceFirst,
            speechAuthorized: true,
            onDeviceSupported: true,
            server: { XCTFail("on-device first should not call the server yet"); return "" },
            onDevice: { "from the phone" }
        )
        XCTAssertEqual(text, "from the phone")
    }

    func testOnDeviceFirstFallsBackToTheServer() async throws {
        let text = try await WatchVoiceNoteTranscription.transcript(
            preference: .onDeviceFirst,
            speechAuthorized: true,
            onDeviceSupported: true,
            server: { "from the server" },
            onDevice: { throw WatchCompanionError.backend(.invalidResponse) }
        )
        XCTAssertEqual(text, "from the server")
    }

    func testBlankTranscriptsFailInsteadOfSendingEmptyText() async {
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .serverFirst,
                speechAuthorized: true,
                onDeviceSupported: true,
                server: { "  \n" },
                onDevice: { " " }
            )
            XCTFail("blank text is not a transcript")
        } catch {
            XCTAssertEqual(error as? WatchCompanionError, .backend(.invalidResponse))
        }
    }

    func testCancellationDoesNotFallThrough() async {
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .onDeviceFirst,
                speechAuthorized: true,
                onDeviceSupported: true,
                server: { XCTFail("a cancelled attempt must not try the next provider"); return "" },
                onDevice: { throw CancellationError() }
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testATranscriptIsDroppedWhenTheAttemptIsCancelled() async {
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .serverFirst,
                speechAuthorized: true,
                onDeviceSupported: true,
                server: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "hello"
                },
                onDevice: { XCTFail("must not fall through after cancellation"); return "nope" }
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTheLaterFailureIsWhatSurfaces() async {
        struct Later: Error {}
        do {
            _ = try await WatchVoiceNoteTranscription.transcript(
                preference: .serverFirst,
                speechAuthorized: true,
                onDeviceSupported: true,
                server: { throw WatchCompanionError.backend(.timeout) },
                onDevice: { throw Later() }
            )
            XCTFail("expected failure")
        } catch is Later {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testServerTranscriptKeepsTextWhenAnErrorIsAlsoPresent() {
        XCTAssertEqual(
            WatchVoiceNoteTranscription.serverTranscriptText(transcript: " from the server ", error: "partial"),
            "from the server"
        )
        XCTAssertNil(WatchVoiceNoteTranscription.serverTranscriptText(transcript: " ", error: "no speech"))
        XCTAssertNil(WatchVoiceNoteTranscription.serverTranscriptText(transcript: nil, error: nil))
    }
}

final class WatchHermesRouteTests: XCTestCase {
    func testHermesKindComesFromTheRegistryAndDoesNotRevealWebuiSessions() {
        let hermes = account("https://hermes.example/", kind: .hermes)
        let webui = account("https://webui.example", kind: .webui)
        XCTAssertEqual(
            WatchHermesRoute.kind(of: "https://hermes.example", accounts: [hermes, webui]),
            .hermes
        )
        XCTAssertEqual(WatchHermesRoute.kind(of: "https://unknown.example", accounts: [hermes]), .webui)
        XCTAssertFalse(WatchHermesRoute.revealsWebuiCLISessions(.hermes))
        XCTAssertTrue(WatchHermesRoute.revealsWebuiCLISessions(.webui))
        XCTAssertFalse(WatchHermesRoute.awaitsRunNowTrigger(.hermes))
        XCTAssertTrue(WatchHermesRoute.awaitsRunNowTrigger(.webui))
        XCTAssertFalse(WatchHermesRoute.togglesSkills(on: .hermes))
        XCTAssertTrue(WatchHermesRoute.remembersProfileLocally(.hermes))
        XCTAssertFalse(WatchHermesRoute.remembersProfileLocally(.webui))
        XCTAssertTrue(WatchHermesRoute.writesUnsupported(.hermes))
        XCTAssertFalse(WatchHermesRoute.writesUnsupported(.webui))
    }

    func testHermesProfileSwitchIsRememberedLocally() throws {
        let defaults = UserDefaults(suiteName: "watch-hermes-profile")!
        defaults.removePersistentDomain(forName: "watch-hermes-profile")
        let server = try XCTUnwrap(URL(string: "https://hermes.example"))
        try WatchHermesRoute.rememberProfile("ops", server: server, listed: ["default", "ops"], defaults: defaults)
        XCTAssertEqual(
            WatchHermesRoute.rememberedProfile(server: server, listed: ["default", "ops"], current: "default", defaults: defaults),
            "ops"
        )
        XCTAssertThrowsError(
            try WatchHermesRoute.rememberProfile("missing", server: server, listed: ["ops"], defaults: defaults)
        )
    }

    func testHermesSessionRowsStayOnTheSelectedProfileAndSkipHiddenChats() throws {
        let ops = try profile(#"""
        {"name":"ops","canonical_session":{"id":"sess-ops","preview":"ship it","last_active":1700000000},
         "ui_meta":{"hermes-bots":{"title":"Ops","pinned":false}}}
        """#)
        let hidden = try profile(#"""
        {"name":"old","canonical_session":{"id":"sess-old","last_active":1700000001},
         "ui_meta":{"hermes-bots":{"hidden":true,"title":"Old"}}}
        """#)
        let rows = WatchHermesRoute.sessionRows(
            from: [hidden, ops], live: ["ops": .working], selectedProfile: "ops",
            archived: false, query: nil, limit: 10
        )
        XCTAssertEqual(rows.map(\.sessionID), ["sess-ops"])
        XCTAssertEqual(rows.first?.runState, .responding)
        XCTAssertEqual(rows.first?.title, "Ops")
        let archived = WatchHermesRoute.sessionRows(
            from: [hidden, ops], live: [:], selectedProfile: "ops", archived: true, query: "old", limit: 10
        )
        XCTAssertEqual(archived.map(\.sessionID), ["sess-old"])
    }

    func testHermesRunningStateAndKanbanMovesFollowTheHost() throws {
        let job = try self.decode(CronJob.self, #"""
        {"id":"job-1","name":"Digest","state":"scheduled","enabled":true,"profile":"ops","fire_claim":{"at":1700000000}}
        """#)
        let running = WatchHermesRoute.runningJobIDs(CronJobList(hermesJobs: [job]))
        XCTAssertTrue(running.contains("job-1"))
        XCTAssertNil(WatchHermesRoute.createWorkspaceKind())
        XCTAssertFalse(WatchHermesRoute.kanbanMoveSucceeded(requested: "todo", landed: "todo", backend: .hermes))
        XCTAssertTrue(WatchHermesRoute.kanbanMoveSucceeded(requested: "ready", landed: "todo", backend: .hermes))
        XCTAssertFalse(WatchHermesRoute.kanbanMoveSucceeded(
            requested: "ready", landed: "todo", from: "todo", backend: .hermes
        ))
        XCTAssertTrue(WatchHermesRoute.kanbanMoveSucceeded(
            requested: "ready", landed: "todo", from: "blocked", backend: .hermes
        ))
        XCTAssertTrue(WatchHermesRoute.kanbanMoveSucceeded(requested: "done", landed: "done", backend: .hermes))
        XCTAssertTrue(WatchHermesRoute.kanbanMoveSucceeded(requested: "todo", landed: "todo", backend: .webui))
        let snapshot = KanbanBoardSnapshot(
            columns: [KanbanColumn(name: "Review", cards: nil), KanbanColumn(name: "scheduled", cards: nil)],
            tenants: nil, assignees: nil, filters: nil, changed: nil, latestEventID: nil, readOnly: false
        )
        XCTAssertEqual(
            WatchHermesRoute.columns(in: snapshot, cards: [], includeArchived: false),
            ["review", "scheduled"]
        )
    }

    func testHermesTranscriptPageUsesTheLatestMessages() throws {
        let data = Data(#"{"messages":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"}]}"#.utf8)
        let page = try WatchHermesRoute.transcriptPage(from: data, limit: 1)
        XCTAssertEqual(page.blocks.count, 1)
        XCTAssertTrue(page.isTruncated)
        XCTAssertNil(page.nextBefore)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func account(_ url: String, kind: ServerKind) -> ServerAccount {
        ServerAccount(
            id: url, urlString: url, displayName: "Server", initials: "S",
            headerLogoColorHex: HeaderLogoColor.defaultHex,
            createdAt: .distantPast, updatedAt: .distantPast, kind: kind
        )
    }

    private func profile(_ json: String) throws -> BotProfile {
        let row = try JSONDecoder().decode(BotJSON.self, from: Data(json.utf8))
        return try XCTUnwrap(BotProfile(row))
    }
}

final class WatchChatCancelAcceptanceTests: XCTestCase {
    func testExplicitRefusalIsNotASuccessfulStop() {
        XCTAssertFalse(WatchChatCancelAcceptance.isAccepted(ChatCancelResponse(ok: false, cancelled: false, streamId: "s", error: "busy")))
    }

    func testACancelWithoutOkStillCounts() {
        XCTAssertTrue(WatchChatCancelAcceptance.isAccepted(ChatCancelResponse(ok: nil, cancelled: nil, streamId: "s", error: nil)))
        XCTAssertTrue(WatchChatCancelAcceptance.isAccepted(ChatCancelResponse(ok: true, cancelled: true, streamId: "s", error: nil)))
    }
}
