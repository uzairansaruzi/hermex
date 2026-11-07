import XCTest
@testable import HermesMobile

/// Serve Every Profile (#1611) against a scripted Webapp whose replies are the shapes the pinned
/// gateway (2bd378ed) answered on `scripts/local-hermes --gateway`: the migrate plan, the `.env`
/// removal, and the migration's start.
@MainActor final class ServeEveryProfileTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The owner's case: `dev` holds `default`'s Telegram token. Keeping the bot on `dev` removes
    /// it from `default` only, the cleared plan offers the migration, and the wait ends once the
    /// restarted gateway serves every Profile.
    func testADuplicateBotIsRemovedFromTheChosenProfileThenEveryProfileIsServed() async throws {
        var plans = 0, cleared = false
        // From Settings: no one Profile's socket to check once the gateway is back.
        let model = Self.model(profile: nil) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/gateway/migrate/plan"?):
                plans += 1
                // Blocked until the removal; after the migration starts, one read before the restart lands.
                let blockers: [BotJSON] = cleared ? [] : [.string(HermesGatewayTests.duplicateBots.components(separatedBy: "; ")[0])]
                return .json(200, .object(["blockers": .array(blockers), "already_multiplexed": .bool(plans >= 4),
                                           "eligible": .bool(false)]))
            case ("DELETE", "/api/env"?):
                cleared = true
                return .json(200, .object(["ok": .bool(true), "key": .string("TELEGRAM_BOT_TOKEN"), "found": .bool(true)]))
            case ("POST", "/api/gateway/migrate"?):
                return .json(200, .object(["ok": .bool(true), "pid": .number(93958), "name": .string("gateway-migrate")]))
            default: return nil
            }
        }
        var served = 0
        model.onServed = { served += 1 }

        await model.reload()
        guard case .ready(let blocked) = model.phase, let bot = blocked.duplicateBots.first else {
            return XCTFail("expected the duplicate bot, got \(model.phase)")
        }
        XCTAssertEqual(model.loser(of: bot), "dev", "the Profile that answers today keeps the bot")
        model.keepers[bot.id] = "dev"
        await model.removeDuplicates()?.value

        let removal = try XCTUnwrap(HermesHostFixture.requests.first { $0.httpMethod == "DELETE" })
        let body = try JSONDecoder().decode(BotJSON.self, from: XCTUnwrap(apiTestBodyData(from: removal)))
        XCTAssertEqual(body["key"].text, "TELEGRAM_BOT_TOKEN")
        XCTAssertEqual(body["profile"].text, "default")

        await model.migrate()?.value

        XCTAssertEqual(HermesHostFixture.count("/api/gateway/migrate"), 1)
        XCTAssertEqual(model.phase, .served)
        XCTAssertEqual(served, 1)
    }

    /// A plan read that finds every Profile already served, as Check Again does after a slow
    /// restart, ends the fix the way the migration does, so the chat behind it reloads.
    func testAPlanThatAlreadyServesEveryProfileEndsTheFix() async {
        let model = Self.model(profile: nil) { request in
            request.url?.path == "/api/gateway/migrate/plan"
                ? .json(200, .object(["blockers": .array([]), "already_multiplexed": .bool(true)])) : nil
        }
        var served = 0
        model.onServed = { served += 1 }

        await model.reload()

        XCTAssertEqual(model.phase, .served)
        XCTAssertEqual(served, 1)
    }

    /// A blocker Hermex doesn't recognize offers no removal, only the host's words. Its recovery chat
    /// opens on the Profile the gateway serves, never New Session's, carrying the unserved Profile
    /// and the host's words for the agent.
    func testAnUnrecognizedBlockerOffersARecoveryChatOnTheServedProfile() async throws {
        let blocker = "Profile 'ops' enables whatsapp, which binds its own port and has no /p/ops/ ingress on the default listener yet; "
            + "the multiplexer would skip the whole profile. Disable it there (platforms.whatsapp.enabled: false) or add a "
            + "/p/<profile>/ ingress for it first."
        let model = Self.model { request in
            request.url?.path == "/api/gateway/migrate/plan"
                ? .json(200, .object(["blockers": .array([.string(blocker)]), "already_multiplexed": .bool(false)])) : nil
        }

        await model.reload()

        guard case .ready(let plan) = model.phase else { return XCTFail("expected the plan, got \(model.phase)") }
        XCTAssertEqual(plan.duplicateBots, [])
        XCTAssertEqual(plan.otherBlockers, [blocker])

        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: inbox) }
        let server = URL(string: "https://hermes.example")!
        try model.openRecoveryChat(blockers: plan.otherBlockers, server: server, inbox: inbox)
        let queued = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: inbox))
        XCTAssertEqual(queued.sharedImport.shortcut,
                       SharedShortcutDestination(server: server, profile: "default", origin: .troubleshooting))
        let text = try XCTUnwrap(queued.sharedImport.draft)
        XCTAssertTrue(text.contains("dev") && text.contains(blocker), text)
    }

    private static func model(profile: String? = "dev",
                              _ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> ServeEveryProfileModel {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        let http = HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script))
        return ServeEveryProfileModel(client: HermesGatewayMigrationClient(http: http), profile: profile,
                                      restartDelays: [.zero, .zero, .zero], sleep: { _ in })
    }
}
