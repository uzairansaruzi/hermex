import XCTest
@testable import HermesMobile

final class ProvidersViewModelTests: APIClientTestCase {
    private static let serverURL = URL(string: "https://example.test")!

    @MainActor
    func testLoadPopulatesProvidersPreservingServerOrder() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/providers")
            return apiTestJSONResponse("""
            {
              "active_provider": "openai-codex",
              "providers": [
                { "id": "openai-codex", "display_name": "OpenAI Codex", "has_key": true },
                { "id": "anthropic", "display_name": "Anthropic", "has_key": false },
                { "id": "custom:glmcode", "display_name": "glmcode", "has_key": true }
              ]
            }
            """, for: request)
        }
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.providers.map(\.id), ["openai-codex", "anthropic", "custom:glmcode"])
        XCTAssertEqual(model.activeProviderID, "openai-codex")
        XCTAssertTrue(model.isActive(model.providers[0]))
        XCTAssertFalse(model.isActive(model.providers[1]))
    }

    @MainActor
    func testLoadFailureSetsErrorMessageAndKeepsEmptyList() async {
        let client = makeClient { request in
            (HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!, Data())
        }
        let model = ProvidersViewModel(server: Self.serverURL, client: client)

        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.providers.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testActiveProviderMatchingIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(ProvidersViewModel.normalizedProviderID("  OpenAI-Codex \n"), "openai-codex")
        XCTAssertNil(ProvidersViewModel.normalizedProviderID("   "))
        XCTAssertNil(ProvidersViewModel.normalizedProviderID(nil))
    }

    func testDisplayNameFallsBackFromDisplayNameToIDToPlaceholder() {
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: "openai", displayName: "OpenAI")),
            "OpenAI"
        )
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: "openai", displayName: "  ")),
            "openai"
        )
        XCTAssertEqual(
            ProvidersViewModel.displayName(for: ProviderSummary(id: nil)),
            String(localized: "Unknown provider")
        )
    }

    func testKeySourceBadgeCollapsesUpstreamVocabulary() {
        func badge(_ keySource: String?, hasKey: Bool? = true) -> String? {
            ProvidersViewModel.keySourceBadge(
                for: ProviderSummary(id: "p", hasKey: hasKey, keySource: keySource)
            )
        }

        XCTAssertEqual(badge("env_file"), "env")
        XCTAssertEqual(badge("env_var"), "env")
        XCTAssertEqual(badge("env"), "env")
        XCTAssertEqual(badge("oauth"), "OAuth")
        XCTAssertEqual(badge("token"), "OAuth")
        XCTAssertEqual(badge("config_yaml"), "config")
        XCTAssertEqual(badge("config"), "config")
        XCTAssertEqual(badge(" OAuth "), "OAuth")

        // Unknown future sources pass through instead of being hidden.
        XCTAssertEqual(badge("keychain"), "keychain")

        // No badge without a key, or when the source is missing/none.
        XCTAssertNil(badge("none"))
        XCTAssertNil(badge(nil))
        XCTAssertNil(badge("oauth", hasKey: false))
        XCTAssertNil(badge("oauth", hasKey: nil))
    }

    func testAuthErrorTextTrimsAndDropsEmptyValues() {
        XCTAssertEqual(
            ProvidersViewModel.authErrorText(
                for: ProviderSummary(id: "p", authError: "  token expired \n")
            ),
            "token expired"
        )
        XCTAssertNil(ProvidersViewModel.authErrorText(for: ProviderSummary(id: "p", authError: "   ")))
        XCTAssertNil(ProvidersViewModel.authErrorText(for: ProviderSummary(id: "p", authError: nil)))
    }

    func testModelCountPrefersModelsTotalWhenListIsTrimmed() {
        let trimmed = ProviderSummary(
            id: "nous",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 396
        )
        XCTAssertEqual(ProvidersViewModel.modelCount(for: trimmed), 396)
        let info = ProvidersViewModel.truncatedModelInfo(for: trimmed)
        XCTAssertEqual(info?.shown, 2)
        XCTAssertEqual(info?.total, 396)

        let complete = ProviderSummary(
            id: "openai",
            models: [ProviderModel(id: "a"), ProviderModel(id: "b")],
            modelsTotal: 2
        )
        XCTAssertEqual(ProvidersViewModel.modelCount(for: complete), 2)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: complete))

        // No visible models -> no truncation footer even if a total is reported.
        let hidden = ProviderSummary(id: "p", models: [], modelsTotal: 4)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: hidden))

        let bare = ProviderSummary(id: "p")
        XCTAssertEqual(ProvidersViewModel.modelCount(for: bare), 0)
        XCTAssertNil(ProvidersViewModel.truncatedModelInfo(for: bare))
    }
}
