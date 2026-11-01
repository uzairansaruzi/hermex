import XCTest
@testable import HermesMobile

/// A Profile's `.env` keys on a Hermes host (#1318): `HermesEnvironmentClient` against a scripted
/// host whose replies are the shapes a 0.21.5 host (pin ca678285) answered.
@MainActor final class HermesEnvironmentClientTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    func testTheListLeavesOutChannelKeysAndShowsOnlyTheHostsMask() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/env" ? .json(200, .object([
                "OPENAI_API_KEY": Self.row(category: "provider", label: "OpenAI", redacted: "«redacted:sk-o...7890»",
                                           extra: ["provider_primary": .bool(true), "provider_profiles": .array([])]),
                "MY_TOKEN": Self.row(category: "custom", redacted: "«redacted:***»"),
                "FIRECRAWL_API_KEY": Self.row(category: "tool", redacted: nil),
                "PLUGIN_SECRET": Self.row(category: "plugin", redacted: "«redacted:abcd...wxyz»"),
                "TELEGRAM_BOT_TOKEN": Self.row(category: "messaging", redacted: "«redacted:1234...abcd»",
                                               extra: ["channel_managed": .bool(true)])
            ])) : nil
        }

        let keys = try await client.keys(profile: "dev").sorted { $0.name < $1.name }

        XCTAssertEqual(keys.map(\.name), ["FIRECRAWL_API_KEY", "MY_TOKEN", "OPENAI_API_KEY", "PLUGIN_SECRET"])
        XCTAssertEqual(keys.map(\.title), ["FIRECRAWL_API_KEY", "MY_TOKEN", "OpenAI", "PLUGIN_SECRET"])
        XCTAssertEqual(keys.map(\.category), [.tool, .custom, .provider, .other("plugin")])
        XCTAssertEqual(keys.map(\.isSet), [false, true, true, true])
        XCTAssertEqual(keys.map(\.preview), [nil, "•••", "sk-o…7890", "abcd…wxyz"])
        let request = try XCTUnwrap(HermesHostFixture.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.query, "profile=dev")
    }

    func testARefusedWriteCarriesTheHostsDetail() async throws {
        let client = Self.client { request in
            request.url?.path == "/api/env" && request.httpMethod == "PUT"
                ? .json(400, .object(["detail": .string("Invalid environment variable name: '1BAD-NAME'")])) : nil
        }

        do {
            try await client.set("1BAD-NAME", value: "secret", profile: "dev")
            XCTFail("Expected the host's refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "The server rejected the request: Invalid environment variable name: '1BAD-NAME'")
        }
    }

    private static func client(_ script: @escaping (URLRequest) -> HermesHostFixture.Reply?) -> HermesEnvironmentClient {
        let record = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                   username: "user", password: "secret")
        return HermesEnvironmentClient(http: HermesConnection(connection: record, configuration: HermesHostFixture.configuration(script)))
    }

    /// One `GET /api/env` row as the host lists it, set when it has a mask.
    private static func row(category: String, label: String = "", redacted: String?,
                            extra: [String: BotJSON] = [:]) -> BotJSON {
        .object([
            "is_set": .bool(redacted != nil), "redacted_value": redacted.map(BotJSON.string) ?? .null,
            "description": .string(""), "url": .null, "category": .string(category), "is_password": .bool(true),
            "tools": .array([]), "advanced": .bool(false), "channel_managed": .bool(false), "provider": .string(""),
            "provider_label": .string(label), "custom": .bool(category == "custom")
        ].merging(extra) { $1 })
    }
}
