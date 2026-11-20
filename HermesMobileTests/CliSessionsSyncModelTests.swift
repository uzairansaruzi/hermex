import XCTest
@testable import HermesMobile

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

    func testUpdateSettingsPostsExactlyTheShowCliSessionsKey() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/settings")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(body.count, 1, "The write must touch only show_cli_sessions")
            XCTAssertEqual(body["show_cli_sessions"] as? Bool, false)

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

        model.setShowsCliSessions(true)
        await model.pendingWrite?.value

        XCTAssertTrue(model.showsCliSessions)
        XCTAssertEqual(writtenValues, [])
        XCTAssertEqual(
            defaults.object(forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA)) as? Bool,
            true
        )
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
        var writtenValues: [Bool] = []
        var releaseFirstWrite: CheckedContinuation<Void, Never>?
        let firstWriteInFlight = expectation(description: "write 1 is in flight")
        let model = makeModel(
            server: serverA,
            writeToServer: { value in
                writtenValues.append(value)
                if writtenValues.count == 1 {
                    await withCheckedContinuation {
                        releaseFirstWrite = $0
                        firstWriteInFlight.fulfill()
                    }
                }
            }
        )
        model.adopt(serverValue: true)

        model.setShowsCliSessions(false)

        await fulfillment(of: [firstWriteInFlight], timeout: 5)

        model.setShowsCliSessions(true)
        model.setShowsCliSessions(false)

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
        XCTAssertTrue(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))

        defaults.set(false, forKey: SessionRowDisplaySettings.showCliSessionsKey)
        XCTAssertFalse(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))

        defaults.set(true, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: serverA))
        XCTAssertTrue(SessionRowDisplaySettings.showsCliSessions(for: serverA, in: defaults))
        XCTAssertFalse(
            SessionRowDisplaySettings.showsCliSessions(for: serverB, in: defaults),
            "Another server still reads the legacy seed until it stores its own value"
        )
    }

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
