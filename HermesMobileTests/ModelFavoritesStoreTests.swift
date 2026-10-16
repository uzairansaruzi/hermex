import XCTest
@testable import HermesMobile

final class ModelFavoritesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ModelFavoritesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testToggleFavoritePersistsExactModelAndProvider() {
        let store = ModelFavoritesStore(defaults: defaults, storageKey: "favorites")
        let option = ModelCatalogOption(id: "openai/gpt-5.5", displayName: "GPT-5.5", providerID: "openai")

        let favoriteKeys = store.toggleFavorite(for: option)

        XCTAssertEqual(favoriteKeys, [ModelFavoriteKey(modelID: "openai/gpt-5.5", providerID: "openai")])
        XCTAssertTrue(store.isFavorite(option))
        XCTAssertEqual(store.favoriteKeys, favoriteKeys)
    }

    func testToggleFavoriteRemovesExistingFavorite() {
        let store = ModelFavoritesStore(defaults: defaults, storageKey: "favorites")
        let option = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", providerID: "anthropic")

        _ = store.toggleFavorite(for: option)
        let favoriteKeys = store.toggleFavorite(for: option)

        XCTAssertEqual(favoriteKeys, [])
        XCTAssertFalse(store.isFavorite(option))
    }

    func testRemoveFavoriteDeletesExactModelAndProvider() {
        let store = ModelFavoritesStore(defaults: defaults, storageKey: "favorites")
        let openRouter = ModelCatalogOption(id: "moonshotai/kimi-k2-0905", displayName: "Kimi K2", providerID: "openrouter")
        let custom = ModelCatalogOption(id: "moonshotai/kimi-k2-0905", displayName: "Kimi K2", providerID: "custom")
        store.save([openRouter.favoriteKey, custom.favoriteKey])

        let favoriteKeys = store.removeFavorite(for: openRouter)

        XCTAssertEqual(favoriteKeys, [custom.favoriteKey])
        XCTAssertEqual(store.favoriteKeys, [custom.favoriteKey])
    }

    func testVisibleFavoriteOptionsPreservesFavoriteOrderAndKeepsMissingModels() {
        let gpt = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let claude = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", providerID: "anthropic")
        let missing = ModelCatalogOption(id: "missing-model", displayName: "missing-model", providerID: "local")
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [gpt]),
            ModelCatalogGroup(id: "anthropic", name: "Anthropic", providerID: "anthropic", models: [claude])
        ]
        let favoriteKeys = [
            claude.favoriteKey,
            missing.favoriteKey,
            gpt.favoriteKey
        ]

        let visibleOptions = ModelFavoritesStore.visibleFavoriteOptions(
            in: groups,
            favoriteKeys: favoriteKeys
        )

        XCTAssertEqual(visibleOptions, [claude, missing, gpt])
    }

    func testRecordRecentMovesModelToFrontAndLimitsResults() {
        let store = ModelRecentsStore(defaults: defaults, storageKey: "recents", limit: 3)
        let gpt = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let claude = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", providerID: "anthropic")
        let gemini = ModelCatalogOption(id: "gemini-3-pro", displayName: "Gemini 3 Pro", providerID: "google")
        let local = ModelCatalogOption(id: "local-qwen", displayName: "Local Qwen", providerID: "local")

        _ = store.recordRecent(gpt)
        _ = store.recordRecent(claude)
        _ = store.recordRecent(gemini)
        _ = store.recordRecent(claude)
        let recentKeys = store.recordRecent(local)

        XCTAssertEqual(recentKeys, [local.favoriteKey, claude.favoriteKey, gemini.favoriteKey])
        XCTAssertEqual(store.recentKeys, recentKeys)
    }

    func testRemoveRecentDeletesExactModelAndProvider() {
        let store = ModelRecentsStore(defaults: defaults, storageKey: "recents", limit: 5)
        let openRouter = ModelCatalogOption(id: "moonshotai/kimi-k2-0905", displayName: "Kimi K2", providerID: "openrouter")
        let custom = ModelCatalogOption(id: "moonshotai/kimi-k2-0905", displayName: "Kimi K2", providerID: "custom")
        store.save([openRouter.favoriteKey, custom.favoriteKey])

        let recentKeys = store.removeRecent(for: openRouter)

        XCTAssertEqual(recentKeys, [custom.favoriteKey])
        XCTAssertEqual(store.recentKeys, [custom.favoriteKey])
    }

    func testVisibleRecentOptionsSkipsFavoritesAndKeepsMissingModels() {
        let gpt = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let claude = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", providerID: "anthropic")
        let gemini = ModelCatalogOption(id: "gemini-3-pro", displayName: "Gemini 3 Pro", providerID: "google")
        let missing = ModelCatalogOption(id: "missing-model", displayName: "missing-model", providerID: "local")
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [gpt]),
            ModelCatalogGroup(id: "anthropic", name: "Anthropic", providerID: "anthropic", models: [claude]),
            ModelCatalogGroup(id: "google", name: "Google", providerID: "google", models: [gemini])
        ]
        let recentKeys = [
            claude.favoriteKey,
            missing.favoriteKey,
            gpt.favoriteKey,
            gemini.favoriteKey
        ]

        let visibleOptions = ModelRecentsStore.visibleRecentOptions(
            in: groups,
            recentKeys: recentKeys,
            favoriteKeys: [gpt.favoriteKey]
        )

        XCTAssertEqual(visibleOptions, [claude, missing, gemini])
    }
}
