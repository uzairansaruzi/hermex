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

    func testProviderFavoritesAreOrderedDeduplicatedAndServerScoped() {
        let store = ProviderFavoritesStore(defaults: defaults, storageKey: "provider-favorites")

        store.save([" openai-codex ", "fireworks", "openai-codex", "  "], serverID: "work")
        store.save(["anthropic"], serverID: "home")

        XCTAssertEqual(store.favoriteProviderIDs(serverID: "work"), ["openai-codex", "fireworks"])
        XCTAssertEqual(store.favoriteProviderIDs(serverID: "home"), ["anthropic"])
        XCTAssertTrue(store.isFavorite(providerID: "fireworks", serverID: "work"))
        XCTAssertFalse(store.isFavorite(providerID: "fireworks", serverID: "home"))
    }

    func testProviderFavoriteToggleAddsAndRemovesExactProvider() {
        let store = ProviderFavoritesStore(defaults: defaults, storageKey: "provider-favorites-toggle")

        XCTAssertEqual(store.toggleFavorite(providerID: "openai-codex", serverID: "server"), ["openai-codex"])
        XCTAssertEqual(
            store.toggleFavorite(providerID: "fireworks", serverID: "server"),
            ["openai-codex", "fireworks"]
        )
        XCTAssertEqual(store.toggleFavorite(providerID: "openai-codex", serverID: "server"), ["fireworks"])
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

    func testRemoveFavoriteWhenKeyNotPresentIsNoOp() {
        let store = ModelFavoritesStore(defaults: defaults, storageKey: "favorites")
        let existing = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let missing = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude", providerID: "anthropic")
        store.save([existing.favoriteKey])

        let favoriteKeys = store.removeFavorite(for: missing)

        XCTAssertEqual(favoriteKeys, [existing.favoriteKey])
        XCTAssertEqual(store.favoriteKeys, [existing.favoriteKey])
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

    func testRemoveRecentWhenKeyNotPresentIsNoOp() {
        let store = ModelRecentsStore(defaults: defaults, storageKey: "recents", limit: 5)
        let existing = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let missing = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude", providerID: "anthropic")
        store.save([existing.favoriteKey])

        let recentKeys = store.removeRecent(for: missing)

        XCTAssertEqual(recentKeys, [existing.favoriteKey])
        XCTAssertEqual(store.recentKeys, [existing.favoriteKey])
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

    func testFullPickerRecentOptionsIncludeFavoritesInMRUOrder() {
        let gpt = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let claude = ModelCatalogOption(id: "claude-sonnet-4.5", displayName: "Claude Sonnet 4.5", providerID: "anthropic")
        let missing = ModelCatalogOption(id: "missing-model", displayName: "missing-model", providerID: "local")
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [gpt]),
            ModelCatalogGroup(id: "anthropic", name: "Anthropic", providerID: "anthropic", models: [claude])
        ]

        let visibleOptions = ModelRecentsStore.visibleAllRecentOptions(
            in: groups,
            recentKeys: [claude.favoriteKey, missing.favoriteKey, gpt.favoriteKey]
        )

        XCTAssertEqual(visibleOptions, [claude, missing, gpt])
    }

    func testUnifiedPickerSearchMatchesProviderPresentationAndExactIdentity() {
        let openAI = ModelCatalogOption(id: "gpt-5.5-codex", displayName: "GPT-5.5 Codex", providerID: "openai-codex")
        let kimi = ModelCatalogOption(id: "kimi-k2.5", displayName: "Kimi K2.5", providerID: "kimi-coding")
        let options = [openAI, kimi]
        let names = ["openai-codex": "Codex", "kimi-coding": "Moonshot"]

        XCTAssertEqual(
            ModelPickerCatalog.filteredOptions(options, query: "Codex", providerID: nil, providerDisplayNames: names),
            [openAI]
        )
        XCTAssertEqual(
            ModelPickerCatalog.filteredOptions(options, query: "kimi-k2.5", providerID: "kimi-coding", providerDisplayNames: names),
            [kimi]
        )
        XCTAssertEqual(
            ModelPickerCatalog.filteredOptions(options, query: "Moonshot", providerID: "openai-codex", providerDisplayNames: names),
            []
        )
    }

    func testProviderBrandCatalogHumanizesTechnicalNamesWithoutChangingIdentity() {
        XCTAssertEqual(
            ProviderBrandCatalog.displayName(providerID: "openai-codex", catalogName: "openai-codex"),
            "OpenAI Codex"
        )
        XCTAssertEqual(
            ProviderBrandCatalog.displayName(providerID: "fireworks", catalogName: "Fireworks AI"),
            "Fireworks AI"
        )
        XCTAssertEqual(
            ProviderBrandCatalog.displayName(providerID: "my-private-provider", catalogName: "my-private-provider"),
            "My Private Provider"
        )
    }

    func testProviderBrandCatalogUsesFallbackForProvidersWithoutLicensedArtwork() {
        XCTAssertNil(ProviderBrandCatalog.artwork(for: "openai-codex"))
        XCTAssertNil(ProviderBrandCatalog.artwork(for: "openai-api"))
        XCTAssertNil(ProviderBrandCatalog.artwork(for: "fireworks"))
        XCTAssertNil(ProviderBrandCatalog.artwork(for: "custom-private-provider"))
    }

    func testProviderAppearanceStoreScopesDisplayNamesByServerAndKeepsProviderIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAppearanceStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderAppearanceStore(
            defaults: defaults,
            storageKey: "provider-appearances",
            artworkDirectory: directory
        )

        store.setDisplayName("Work Codex", serverID: "server-a", providerID: "openai-codex")
        store.setDisplayName("Home Codex", serverID: "server-b", providerID: "openai-codex")

        XCTAssertEqual(store.appearance(serverID: "server-a", providerID: "openai-codex").displayName, "Work Codex")
        XCTAssertEqual(store.appearance(serverID: "server-b", providerID: "openai-codex").displayName, "Home Codex")
        XCTAssertNil(store.appearance(serverID: "server-a", providerID: "openai").displayName)

        store.reset(serverID: "server-a", providerID: "openai-codex")
        XCTAssertFalse(store.appearance(serverID: "server-a", providerID: "openai-codex").hasOverride)
        XCTAssertEqual(store.appearance(serverID: "server-b", providerID: "openai-codex").displayName, "Home Codex")
    }

    func testProviderAppearanceApplyRejectsBadImageWithoutChangingName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAppearanceAtomicTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderAppearanceStore(
            defaults: defaults,
            storageKey: "provider-appearance-atomic",
            artworkDirectory: directory
        )
        store.setDisplayName("Original", serverID: "server", providerID: "provider")

        XCTAssertThrowsError(try store.apply(
            displayName: "Replacement",
            artworkData: Data("not-an-image".utf8),
            restoresDefaultArtwork: false,
            serverID: "server",
            providerID: "provider"
        ))
        XCTAssertEqual(store.appearance(serverID: "server", providerID: "provider").displayName, "Original")
    }

    func testProviderArtworkProcessorRejectsOversizedInputBeforeDecode() {
        let oversized = Data(count: ProviderArtworkProcessor.maximumInputBytes + 1)

        XCTAssertThrowsError(try ProviderArtworkProcessor.normalizedPNG(from: oversized)) { error in
            guard case ProviderArtworkImportError.imageTooLarge = error else {
                return XCTFail("Expected imageTooLarge, got \(error)")
            }
        }
    }

    func testProviderArtworkProcessorRejectsOversizedFileBeforeDecode() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderArtworkOversized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: ProviderArtworkProcessor.maximumInputBytes + 1).write(to: file)

        XCTAssertThrowsError(try ProviderArtworkProcessor.normalizedPNG(fromFileAt: file)) { error in
            guard case ProviderArtworkImportError.imageTooLarge = error else {
                return XCTFail("Expected imageTooLarge, got \(error)")
            }
        }
    }

    func testProviderArtworkProcessorDownsamplesToBoundedPNG() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let input = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))

        let output = try ProviderArtworkProcessor.normalizedPNG(from: input)
        let normalized = try XCTUnwrap(UIImage(data: output))

        XCTAssertLessThanOrEqual(max(normalized.size.width, normalized.size.height), 512)
    }

    func testProviderAppearanceApplyCanRestoreNameAndArtworkTogether() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAppearanceRestoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderAppearanceStore(
            defaults: defaults,
            storageKey: "provider-appearance-restore",
            artworkDirectory: directory
        )
        store.setDisplayName("Custom", serverID: "server", providerID: "provider")

        try store.apply(
            displayName: nil,
            artworkData: nil,
            restoresDefaultArtwork: true,
            serverID: "server",
            providerID: "provider"
        )

        XCTAssertFalse(store.appearance(serverID: "server", providerID: "provider").hasOverride)
    }

    func testProviderAppearanceRejectsPersistedArtworkPathTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAppearanceTraversalTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("ProviderArtwork", isDirectory: true)
        let outsideFile = root.appendingPathComponent("outside.png")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideFile)
        let payload: [String: Any] = [
            "servers": ["server": ["provider": [
                "artworkFileName": "../outside.png",
                "usesFallback": false
            ]]]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "provider-appearance-traversal")
        let store = ProviderAppearanceStore(
            defaults: defaults,
            storageKey: "provider-appearance-traversal",
            artworkDirectory: directory
        )

        XCTAssertNil(store.artworkImage(serverID: "server", providerID: "provider"))
        store.reset(serverID: "server", providerID: "provider")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testProviderAppearanceOnlyRemovesGeneratedArtworkBasenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAppearanceFilenameTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("ProviderArtwork", isDirectory: true)
        let nestedDirectory = directory.appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let uuid = UUID().uuidString
        let files: [(provider: String, persistedName: String, url: URL)] = [
            ("absolute", root.appendingPathComponent("absolute.png").path, root.appendingPathComponent("absolute.png")),
            ("nested", "nested/\(uuid).png", nestedDirectory.appendingPathComponent("\(uuid).png")),
            ("nonuuid", "not-a-uuid.png", directory.appendingPathComponent("not-a-uuid.png")),
            ("extension", "\(uuid).PNG", directory.appendingPathComponent("\(uuid).PNG"))
        ]
        for file in files {
            try Data("keep".utf8).write(to: file.url)
        }
        let providers = Dictionary(uniqueKeysWithValues: files.map { file in
            (file.provider, ["artworkFileName": file.persistedName, "usesFallback": false] as [String: Any])
        })
        let payload: [String: Any] = ["servers": ["server": providers]]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "provider-appearance-filenames")
        let store = ProviderAppearanceStore(
            defaults: defaults,
            storageKey: "provider-appearance-filenames",
            artworkDirectory: directory
        )

        for file in files {
            XCTAssertNil(store.artworkImage(serverID: "server", providerID: file.provider))
            store.reset(serverID: "server", providerID: file.provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), file.persistedName)
        }
    }

    func testCustomModelFavoriteAndRecentOptionsRemainVisibleWithoutCatalogEntry() {
        let custom = ModelCatalogOption(
            id: "moonshotai/kimi-k2-0905",
            displayName: "moonshotai/kimi-k2-0905",
            providerID: "openrouter"
        )
        let groups = [
            ModelCatalogGroup(id: "openai", name: "OpenAI", providerID: "openai", models: [
                ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
            ])
        ]

        let favoriteOptions = ModelFavoritesStore.visibleFavoriteOptions(
            in: groups,
            favoriteKeys: [custom.favoriteKey]
        )
        let recentOptions = ModelRecentsStore.visibleRecentOptions(
            in: groups,
            recentKeys: [custom.favoriteKey],
            favoriteKeys: []
        )

        XCTAssertEqual(favoriteOptions, [custom])
        XCTAssertEqual(recentOptions, [custom])
    }

    func testFirstMatchingSelectionRequiresExactProviderWhenProviderIsExplicit() {
        let openAI = ModelCatalogOption(id: "shared/model", displayName: "OpenAI Shared", providerID: "openai")
        let anthropic = ModelCatalogOption(id: "shared/model", displayName: "Anthropic Shared", providerID: "anthropic")
        let options = [openAI, anthropic]

        XCTAssertEqual(
            options.firstMatchingSelection(modelID: "shared/model", providerID: "anthropic"),
            anthropic
        )
        XCTAssertNil(options.firstMatchingSelection(modelID: "shared/model", providerID: "openrouter"))
        XCTAssertEqual(options.firstMatchingSelection(modelID: "shared/model", providerID: nil), openAI)
    }
}
