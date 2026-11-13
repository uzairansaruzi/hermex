import XCTest
@testable import HermesMobile

/// A Hermes server's Default Model page (#1670): it starts on the Sessions side's Profile and
/// writes that Profile's model only once the host applies it.
@MainActor final class HermesDefaultModelTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "HermesDefaultModelTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)
        HermesProfilePreference.save("work", for: server, in: preferences)
    }

    override func tearDown() {
        preferences.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testPickingAModelPinsItOnTheSessionsSidesProfile() async {
        let (page, wire) = makePage()
        await page.load()
        XCTAssertEqual(page.profile, "work")
        XCTAssertEqual(page.current?.id, "work-model")

        let saved = await page.save(ModelCatalogOption(id: "new-model", displayName: "new-model", providerID: "openai"))

        XCTAssertTrue(saved)
        XCTAssertEqual(page.current?.id, "new-model")
        let params = wire.configures.last
        XCTAssertEqual(params?["name"], .string("work"))
        XCTAssertEqual(params?["model"], .string("new-model"))
        XCTAssertEqual(params?["provider"], .string("openai"))
    }

    func testAnExpensiveModelWritesOnlyAfterContinue() async {
        let (page, wire) = makePage()
        await page.load()
        let guarded = ModelCatalogOption(id: "guarded", displayName: "guarded", providerID: "openai")

        let first = await page.save(guarded)
        XCTAssertFalse(first)
        XCTAssertEqual(page.confirmation?.message, "Costs more")
        page.decline()
        XCTAssertEqual(page.current?.id, "work-model", "Cancel leaves the old model")

        let confirmed = await page.save(guarded, confirmed: true)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(page.current?.id, "guarded")
        XCTAssertEqual(wire.configures.last?["confirm_expensive_model"], .bool(true))
    }

    func testAnotherProfileShowsItsModelAndLeavesTheSessionsPick() async {
        let (page, _) = makePage()
        await page.load()

        await page.select("research")

        XCTAssertEqual(page.current?.id, "research-model")
        XCTAssertEqual(preferences.string(forKey: HermesProfilePreference.key(for: server)), "work")
    }

    func testTheLiveModelListReplacesTheCachedOne() async {
        let (page, _) = makePage()
        await page.load()

        XCTAssertEqual(page.modelGroups.flatMap(\.models).map(\.id), ["live-model"])
    }

    private func makePage() -> (HermesDefaultModel, DefaultModelWire) {
        let wire = DefaultModelWire()
        let connection = BotConnection(id: UUID(), name: "Mac", address: server, username: "u", password: "p", hermesVersion: nil)
        return (HermesDefaultModel(connection: connection, server: server, preferences: preferences, makeWire: { _ in wire }), wire)
    }
}

/// A host with Profiles `default`, `work` and `research`, each pinning `<name>-model`, which asks
/// to confirm the model `guarded`.
@MainActor private final class DefaultModelWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private(set) var configures: [[String: BotJSON]] = []

    func connect() async throws {}
    func close() {}
    func currentProfile() async throws -> String { "default" }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let params = try call.params()
        switch call.method {
        case "profiles.list":
            return .object(["profiles": .array(["default", "work", "research"].map { .object(["name": .string($0)]) })])
        case "profiles.describe":
            let name = params["name"]?.text ?? ""
            return .object(["name": .string(name),
                            "model": .object(["default": .string("\(name)-model"), "provider": .string("openai")])])
        case "model.options":
            let model = params["refresh"] == .bool(true) ? "live-model" : "cached-model"
            return .object(["providers": .array([.object(["slug": .string("openai"), "name": .string("OpenAI"),
                                                          "models": .array([.string(model)])])])])
        case "profiles.configure":
            configures.append(params)
            if params["model"] == .string("guarded"), params["confirm_expensive_model"] != .bool(true) {
                return .object(["ok": .bool(true), "applied": .object([:]),
                                "confirm_required": .bool(true), "confirm_message": .string("Costs more")])
            }
            return .object(["ok": .bool(true), "applied": .object(["model": .bool(true)])])
        default: throw BotFailure.unsupported
        }
    }
}
