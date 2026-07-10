import XCTest
@testable import HermesMobile

/// Issue #19: expanded `/api/settings` decode, the `show_cli_sessions`
/// server-sync model, and its per-server storage isolation.
final class CliSessionsSyncModelTests: APIClientTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "CliSessionsSyncModelTests"
    private let serverA = URL(string: "https://alpha.example.test")!
    private let serverB = URL(string: "https://beta.example.test")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - SettingsResponse decode

    func testSettingsDecodesExpandedFieldsAndIgnoresUnknownKeys() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {
              "bot_name": "Hermes",
              "webui_version": "v0.50.253",
              "agent_version": "v0.9.1",
              "theme": "system",
              "check_for_updates": true,
              "show_cli_sessions": false,
              "show_claude_code_sessions": true,
              "max_tokens": 4096,
              "max_tokens_effective": 4096,
              "auth_enabled": true,
              "password_auth_enabled": true,
              "passkeys_enabled": false,
              "passwordless_enabled": false,
              "some_future_key": {"nested": [1, 2, 3]}
            }
            """, for: request)
        }

        let response = try await client.settings()

        XCTAssertEqual(response.botName, "Hermes")
        XCTAssertEqual(response.webuiVersion, "v0.50.253")
        XCTAssertEqual(response.agentVersion, "v0.9.1")
        XCTAssertEqual(response.theme, "system")
        XCTAssertEqual(response.checkForUpdates, true)
        XCTAssertEqual(response.showCliSessions, false)
        XCTAssertEqual(response.showClaudeCodeSessions, true)
        XCTAssertEqual(response.maxTokens, 4096)
        XCTAssertEqual(response.maxTokensEffective, 4096)
        XCTAssertEqual(response.authEnabled, true)
        XCTAssertEqual(response.passwordAuthEnabled, true)
        XCTAssertEqual(response.passkeysEnabled, false)
        XCTAssertEqual(response.passwordlessEnabled, false)
    }

    func testSettingsDecodesAllFieldsAsNilWhenAbsent() async throws {
        let client = makeClient { request in
            apiTestJSONResponse("{}", for: request)
        }

        let response = try await client.settings()

        XCTAssertNil(response.botName)
        XCTAssertNil(response.webuiVersion)
        XCTAssertNil(response.agentVersion)
        XCTAssertNil(response.theme)
        XCTAssertNil(response.checkForUpdates)
        XCTAssertNil(response.showCliSessions)
        XCTAssertNil(response.showClaudeCodeSessions)
        XCTAssertNil(response.maxTokens)
        XCTAssertNil(response.maxTokensEffective)
        XCTAssertNil(response.authEnabled)
        XCTAssertNil(response.passwordAuthEnabled)
        XCTAssertNil(response.passkeysEnabled)
        XCTAssertNil(response.passwordlessEnabled)
    }

    // MARK: - POST /api/settings write

    func testUpdateSettingsPostsExactlyTheShowCliSessionsKey() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/settings")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(body.count, 1, "The write must touch only show_cli_sessions")
            XCTAssertEqual(body["show_cli_sessions"] as? Bool, false)

            // The server echoes the full saved settings dict back.
            return apiTestJSONResponse("""
            {
              "bot_name": "Hermes",
              "show_cli_sessions": false,
              "auth_enabled": true
            }
            """, for: request)
        }

        let response = try await client.updateSettings(showCliSessions: false)

        XCTAssertEqual(response.showCliSessions, false)
    }

    func testSettingsToleratesMalformedClaudeCodeValue() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(
                #"{"show_claude_code_sessions":{"future":"shape"},"unknown":true}"#,
                for: request
            )
        }

        let response = try await client.settings()

        XCTAssertNil(response.showClaudeCodeSessions)
    }

    func testUpdateSettingsPostsExactlyTheShowClaudeCodeSessionsKey() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/settings")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(body.count, 1)
            XCTAssertEqual(body["show_claude_code_sessions"] as? Bool, false)

            return apiTestJSONResponse(
                #"{"show_cli_sessions":true,"show_claude_code_sessions":false}"#,
                for: request
            )
        }

        let response = try await client.updateSettings(showClaudeCodeSessions: false)

        XCTAssertEqual(response.showClaudeCodeSessions, false)
    }

    // MARK: - Adopt on load

    @MainActor
    func testAdoptServerValueWinsOverLocalAndPersistsPerServer() {
        defaults.set(true, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA))
        let model = makeModel(server: serverA)
        XCTAssertTrue(model.showsCliSessions)

        model.adopt(serverValue: false)

        XCTAssertFalse(model.showsCliSessions)
        XCTAssertTrue(model.serverSyncsCliSessions)
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            false
        )
    }

    @MainActor
    func testAdoptNilLeavesLocalValueAndKeepsToggleLocalOnly() async {
        defaults.set(false, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA))
        var writtenValues: [Bool] = []
        let model = makeModel(
            server: serverA,
            writeToServer: { writtenValues.append($0) }
        )

        model.adopt(serverValue: nil)

        XCTAssertFalse(model.showsCliSessions)
        XCTAssertFalse(model.serverSyncsCliSessions)

        // Toggling still works locally but never writes to the server.
        model.setShowsCliSessions(true)
        await model.pendingWrite?.value

        XCTAssertTrue(model.showsCliSessions)
        XCTAssertEqual(writtenValues, [])
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            true
        )
    }

    // MARK: - Toggle write + revert on failure

    @MainActor
    func testToggleWritesTheNewValueToTheServer() async {
        var writtenValues: [Bool] = []
        let model = makeModel(
            server: serverA,
            writeToServer: { writtenValues.append($0) }
        )
        model.adopt(serverValue: true)

        model.setShowsCliSessions(false)
        await model.pendingWrite?.value

        XCTAssertEqual(writtenValues, [false])
        XCTAssertFalse(model.showsCliSessions)
        XCTAssertNil(model.syncErrorMessage)
    }

    @MainActor
    func testFailedWriteRevertsTheToggleAndSurfacesAnError() async {
        let model = makeModel(
            server: serverA,
            writeToServer: { _ in throw URLError(.notConnectedToInternet) }
        )
        model.adopt(serverValue: true)

        model.setShowsCliSessions(false)
        XCTAssertFalse(model.showsCliSessions, "Optimistic update applies immediately")

        await model.pendingWrite?.value

        XCTAssertTrue(model.showsCliSessions, "Failed write must revert the toggle")
        XCTAssertNotNil(model.syncErrorMessage)
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            true,
            "The revert must also restore the persisted per-server value"
        )
    }

    @MainActor
    func testRapidReToggleIgnoresTheStaleFailureAndWritesTheFinalValue() async {
        // The write for `false` fails; the follow-up write for `true` succeeds.
        // The stale failure must neither revert the newer value nor surface an
        // error.
        let model = makeModel(
            server: serverA,
            writeToServer: { value in
                if value == false { throw URLError(.timedOut) }
            }
        )
        model.adopt(serverValue: true)

        model.setShowsCliSessions(false)
        let staleWrite = model.pendingWrite
        model.setShowsCliSessions(true)

        await staleWrite?.value
        await model.pendingWrite?.value

        XCTAssertTrue(model.showsCliSessions)
        XCTAssertNil(model.syncErrorMessage)
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            true
        )
    }

    @MainActor
    func testRapidReTogglesSerializeWritesAndCoalesceToTheFinalValue() async {
        // Cancelling a Task cannot un-send an in-flight POST, so the model must
        // instead hold the next write until the previous response lands and
        // skip superseded writes. Here the first write is suspended while the
        // user toggles twice more: no second request may be sent while the
        // first is in flight, and after it completes only the *final* value is
        // written (the intermediate toggle is coalesced away).
        var writtenValues: [Bool] = []
        var releaseFirstWrite: CheckedContinuation<Void, Never>?
        let model = makeModel(
            server: serverA,
            writeToServer: { value in
                writtenValues.append(value)
                if writtenValues.count == 1 {
                    await withCheckedContinuation { releaseFirstWrite = $0 }
                }
            }
        )
        model.adopt(serverValue: true)

        model.setShowsCliSessions(false) // write 1 — held in flight below

        // Let write 1 start and suspend inside writeToServer, so it is truly
        // in flight when the user keeps toggling.
        while releaseFirstWrite == nil { await Task.yield() }

        model.setShowsCliSessions(true)  // superseded before it can send
        model.setShowsCliSessions(false) // final desired value

        await Task.yield()
        XCTAssertEqual(
            writtenValues, [false],
            "No follow-up POST may be sent while the first is still in flight"
        )

        releaseFirstWrite?.resume()
        await model.pendingWrite?.value

        XCTAssertEqual(
            writtenValues, [false, false],
            "The superseded intermediate write must be skipped; only the final value is sent"
        )
        XCTAssertFalse(model.showsCliSessions)
        XCTAssertNil(model.syncErrorMessage)
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            false
        )
    }

    // MARK: - Per-server isolation

    @MainActor
    func testAdoptedValueDoesNotLeakToAnotherServer() {
        defaults.set(true, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverB))
        let model = makeModel(server: serverA)

        model.adopt(serverValue: false)

        XCTAssertFalse(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))
        XCTAssertTrue(
            SessionRowDisplaySettings.showsCliSessions(for: serverB, in: defaults),
            "Server A's adopted value must not change server B's toggle"
        )
    }

    func testShowsCliSessionsFallsBackToLegacyGlobalValueThenDefault() {
        // No per-server or legacy value: shown by default, exactly as today.
        XCTAssertTrue(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))

        // A pre-#19 global value seeds servers that have no per-server value yet.
        defaults.set(false, forKey: SessionRowDisplaySettings.showCliSessionsKey)
        XCTAssertFalse(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))

        // A per-server value always wins over the legacy seed.
        defaults.set(true, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA))
        XCTAssertTrue(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))
        XCTAssertFalse(
            SessionRowDisplaySettings.showsCliSessions(for: serverB, in: defaults),
            "Another server still reads the legacy seed until it stores its own value"
        )
    }

    // MARK: - Claude Code child setting

    @MainActor
    func testClaudeCodeSettingAdoptsServerValueAndPersistsPerServer() {
        defaults.set(
            true,
            forKey: SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: serverA)
        )
        let model = makeModel(server: serverA)

        model.adoptClaudeCode(serverValue: false)

        XCTAssertFalse(model.showsClaudeCodeSessions)
        XCTAssertTrue(model.serverSyncsClaudeCodeSessions)
        XCTAssertFalse(
            SessionRowDisplaySettings.showsClaudeCodeSessions(for: serverA, in: defaults)
        )
        XCTAssertTrue(
            SessionRowDisplaySettings.showsClaudeCodeSessions(for: serverB, in: defaults),
            "A newly seen server must retain the shown-by-default preference"
        )
    }

    @MainActor
    func testClaudeCodeSettingOmissionStaysLocalAndDefaultsShown() async {
        var writtenValues: [Bool] = []
        let model = makeModel(
            server: serverA,
            writeClaudeCodeToServer: { writtenValues.append($0) }
        )

        model.adoptClaudeCode(serverValue: nil)
        model.setShowsClaudeCodeSessions(false)
        await model.pendingClaudeCodeWrite?.value

        XCTAssertFalse(model.showsClaudeCodeSessions)
        XCTAssertFalse(model.serverSyncsClaudeCodeSessions)
        XCTAssertEqual(writtenValues, [])
    }

    @MainActor
    func testClaudeCodeSettingWritesAndFailedWriteReverts() async {
        var shouldFail = false
        var writtenValues: [Bool] = []
        let model = makeModel(
            server: serverA,
            writeClaudeCodeToServer: { value in
                writtenValues.append(value)
                if shouldFail { throw URLError(.notConnectedToInternet) }
            }
        )
        model.adoptClaudeCode(serverValue: true)

        model.setShowsClaudeCodeSessions(false)
        await model.pendingClaudeCodeWrite?.value
        XCTAssertEqual(writtenValues, [false])
        XCTAssertFalse(model.showsClaudeCodeSessions)

        shouldFail = true
        model.setShowsClaudeCodeSessions(true)
        await model.pendingClaudeCodeWrite?.value

        XCTAssertFalse(model.showsClaudeCodeSessions)
        XCTAssertNotNil(model.claudeCodeSyncErrorMessage)
        XCTAssertFalse(
            SessionRowDisplaySettings.showsClaudeCodeSessions(for: serverA, in: defaults)
        )
    }

    @MainActor
    func testChangingCliParentDoesNotOverwriteClaudeCodePreference() {
        let model = makeModel(server: serverA)
        model.adopt(serverValue: true)
        model.adoptClaudeCode(serverValue: false)

        model.setShowsCliSessions(false)
        model.setShowsCliSessions(true)

        XCTAssertFalse(model.showsClaudeCodeSessions)
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel(
        server: URL,
        writeClaudeCodeToServer: @escaping @MainActor (Bool) async throws -> Void = { _ in },
        writeToServer: @escaping @MainActor (Bool) async throws -> Void = { _ in }
    ) -> CliSessionsSyncModel {
        CliSessionsSyncModel(
            server: server,
            defaults: defaults,
            writeToServer: writeToServer,
            writeClaudeCodeToServer: writeClaudeCodeToServer
        )
    }

    private static func jsonBody(from request: URLRequest) -> [String: Any]? {
        guard let data = bodyData(from: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data
    }
}
