import XCTest
@testable import HermesMobile

/// The Connected Apps screen on a Hermes host (#1629): `ConnectedAppsModel` and the real client
/// over a scripted socket, with the fields the app reads from a live 0.23.1 host's replies (pin 3b421578).
@MainActor final class ConnectedAppsModelTests: XCTestCase {
    private let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                       username: "user", password: "secret")

    func testEachAppShowsTheStateItsAccountsAndPolicyPutItIn() async {
        let host = host(apps: ["notion", "linear", "slack", "jira", "asana", "ahrefs"], turnedOff: ["jira"], accounts: [
            account("ca_1", "notion", "active"), account("ca_2", "linear", "pending"), account("ca_3", "slack", "expired"),
            // A reconnect retires the old account; it stays on the host and must not count.
            account("ca_4", "asana", "active", retired: true)
        ])
        let model = model(on: host)

        await model.load()

        XCTAssertEqual(model.connected.map(\.id), ["notion", "linear", "slack"], "an app with an account sits on top")
        XCTAssertEqual(model.connected.map(\.state), [.connected, .waiting, .needsReconnect])
        let rest = model.available.flatMap(\.apps)
        XCTAssertEqual(rest.map(\.id), ["jira", "asana", "ahrefs"])
        XCTAssertEqual(rest.map(\.state), [.turnedOff, .notConnected, .notConnected])
        XCTAssertNil(model.app("ahrefs")?.summary, "the catalog's filler description is not shown")
        XCTAssertEqual(model.app("notion")?.summary, "What notion does")
    }

    func testAHostWithNoConnectedAppsSaysWhy() async {
        let reasons: [(Int, HermesConnectedAppsDeadEnd)] = [(-32601, .hostTooOld), (4031, .unavailable), (4032, .needsNousSignIn)]
        for (code, deadEnd) in reasons {
            let host = BotSocketHost()
            host.always("profiles.list", .init(result: profiles))
            for method in ["connectors.catalog", "connectors.list", "connectors.accounts"] { host.always(method, .init(error: code)) }
            let model = model(on: host)

            await model.load()

            XCTAssertEqual(model.state, .deadEnd(deadEnd), "\(code)")
        }
    }

    func testConnectNamesTheShownProfileAndRepairsABrokenAccount() async throws {
        let host = host(apps: ["notion", "slack"], accounts: [account("ca_3", "slack", "expired")])
        host.always("connectors.connect", .init(result: signIn(op: "op1", account: "ca_3")))
        let model = model(on: host)
        await model.load()
        await model.select("dev")
        var opened: [URL] = []

        await model.connect(try XCTUnwrap(model.app("slack"))) { opened.append($0) }

        let repair = try XCTUnwrap(host.requests.last { $0["method"].text == "connectors.connect" })["params"]
        XCTAssertEqual(repair["profile"].text, "dev")
        XCTAssertEqual(repair["connectors"].list, [.string("slack")])
        XCTAssertEqual(repair["owner"]["type"].text, "account")
        XCTAssertEqual(repair["reconnect"].flag, true)
        XCTAssertEqual(repair["connection_id"].text, "ca_3")
        XCTAssertEqual(opened, [URL(string: "https://portal.example/connect/op1")!])
        let wake = try XCTUnwrap(host.requests.last { $0["method"].text == "connectors.operation.wake" })["params"]
        XCTAssertEqual(wake["op_id"].text, "op1", "the browser closing tells the host to read the account")
        XCTAssertEqual(wake["profile"].text, "dev")

        await model.connect(try XCTUnwrap(model.app("notion"))) { _ in }

        let first = try XCTUnwrap(host.requests.last { $0["method"].text == "connectors.connect" })["params"]
        XCTAssertEqual(first["connectors"].list, [.string("notion")])
        XCTAssertEqual(first["reconnect"].flag, false)
        XCTAssertEqual(first["connection_id"], .null)
    }

    /// The host keeps a cancelled sign-in open until its deadline and hands its link back, which
    /// the portal answers with 404. Its account is gone, so the link is closed and asked for again.
    func testALinkWhoseAccountWasRemovedIsReplacedByAFreshOne() async throws {
        let host = host(apps: ["notion"], accounts: [])
        host.next("connectors.connect", .init(result: signIn(op: "dead", account: "ca_gone")))
        host.always("connectors.connect", .init(result: signIn(op: "fresh", account: "ca_new")))
        let model = model(on: host)
        await model.load()
        host.always("connectors.accounts", .init(result: .object(["accounts": .array([account("ca_new", "notion", "pending")])])))
        var opened: [URL] = []

        await model.connect(try XCTUnwrap(model.app("notion"))) { opened.append($0) }

        XCTAssertEqual(opened, [URL(string: "https://portal.example/connect/fresh")!])
        let settle = try XCTUnwrap(host.requests.last { $0["method"].text == "connection.respond" })["params"]
        XCTAssertEqual(settle["op_id"].text, "dead")
        XCTAssertEqual(settle["owner"]["type"].text, "account")
        XCTAssertEqual(settle["result"]["settled_by"].text, "continue")
    }

    func testNothingElseStartsAndTheProfileStaysWhileASignInIsOpen() async throws {
        let host = host(apps: ["notion", "linear"], accounts: [account("ca_2", "linear", "pending")])
        host.always("connectors.connect", .init(result: signIn(op: "op1", account: "ca_2")))
        let model = model(on: host)
        await model.load()
        let linear = try XCTUnwrap(model.app("linear"))

        await model.connect(try XCTUnwrap(model.app("notion"))) { _ in
            await model.cancel(linear)
            await model.select("dev")
        }

        XCTAssertFalse(host.requests.contains { $0["method"].text == "connectors.accounts.remove" })
        XCTAssertEqual(host.requests.last { $0["method"].text == "connectors.accounts" }?["params"]["profile"].text, "default",
                       "the sign-in's result is read for the Profile it was started on")
    }

    func testARefusedConnectShowsItsReasonAndLeavesTheListUsable() async throws {
        let host = host(apps: ["notion"], accounts: [])
        host.next("connectors.connect", .init(error: 5034, message: "Connector request failed. Try again explicitly."))
        host.always("connectors.connect", .init(result: .object(["settled": .bool(true), "targets": .array([
            .object(["name": .string("notion"), "state": .string("connected")])
        ])])))
        let model = model(on: host)
        await model.load()
        let notion = try XCTUnwrap(model.app("notion"))

        await model.connect(notion) { _ in XCTFail("a refused sign-in has no link to open") }

        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(model.state, .loaded([notion]), "the rows are read again and stay")
        let sent = host.requests.filter { $0["method"].text == "connectors.connect" }.count
        await model.connect(notion) { _ in }
        XCTAssertEqual(host.requests.filter { $0["method"].text == "connectors.connect" }.count, sent + 1, "the next action is not locked out")
    }

    private var profiles: BotJSON {
        .object(["profiles": .array([
            .object(["name": .string("default"), "is_default": .bool(true)]), .object(["name": .string("dev")])
        ])])
    }

    private func host(apps: [String], turnedOff: Set<String> = [], accounts: [BotJSON]) -> BotSocketHost {
        let host = BotSocketHost()
        host.always("profiles.list", .init(result: profiles))
        host.always("connectors.catalog", .init(result: .object(["connectors": .array(apps.map { slug in
            .object(["slug": .string(slug), "name": .string(slug.capitalized), "category": .string("Work"),
                     "description": .string(slug == "ahrefs" ? "Use Ahrefs through Hermes" : "What \(slug) does")])
        })])))
        host.always("connectors.list", .init(result: .object(["available": .bool(true), "connectors": .array(apps.map { slug in
            .object(["connector": .string(slug), "enabled": .bool(!turnedOff.contains(slug))])
        })])))
        host.always("connectors.accounts", .init(result: .object(["accounts": .array(accounts)])))
        host.always("connectors.operation.wake", .init(result: .object(["status": .string("ok")])))
        host.always("connection.respond", .init(result: .object(["status": .string("ok"), "settled": .bool(true)])))
        return host
    }

    private func account(_ id: String, _ app: String, _ status: String, retired: Bool = false) -> BotJSON {
        .object(["connection_id": .string(id), "connector": .string(app), "status": .string(status),
                 "label": .string("\(app)_label"), "alias": .null, "disabled": .bool(retired)])
    }

    private func signIn(op: String, account: String) -> BotJSON {
        .object(["op_id": .string(op), "settled": .bool(false), "targets": .array([.object([
            "state": .string("initiated"), "connect_url": .string("https://portal.example/connect/\(op)"),
            "connection_id": .string(account)
        ])])])
    }

    private func model(on host: BotSocketHost) -> ConnectedAppsModel {
        ConnectedAppsModel(client: HermesConnectedAppsClient(http: host.connection(record)))
    }
}
