import XCTest
@testable import HermesMobile

/// Pins the rules behind the Task editor's Model and Profile rows: model and
/// provider always move together, "Server default" is a real value, a selection
/// the server no longer offers stays visible, and neither load failure is
/// allowed to disturb the rest of the draft.
final class CronJobEditorConfigurationTests: APIClientTestCase {
    private func option(_ id: String, provider: String?) -> ModelCatalogOption {
        ModelCatalogOption(id: id, displayName: id, providerID: provider)
    }

    private var catalog: [ModelCatalogGroup] {
        [
            ModelCatalogGroup(
                id: "openai",
                name: "OpenAI",
                providerID: "openai",
                models: [option("gpt-5", provider: "openai")]
            )
        ]
    }

    // MARK: Model selection writes both fields

    func testSelectingAModelWritesTheModelAndTheProvider() {
        var draft = CronJobEditorDraft()

        draft.applyModelSelection(option("gpt-5", provider: "openai"))

        XCTAssertEqual(draft.model, "gpt-5")
        XCTAssertEqual(draft.provider, "openai")
        XCTAssertEqual(draft.trimmedModel, "gpt-5")
        XCTAssertEqual(draft.trimmedProvider, "openai")
    }

    func testServerDefaultClearsBothTheModelAndTheProvider() {
        var draft = CronJobEditorDraft(model: "gpt-5", provider: "openai")

        draft.applyModelSelection(nil)

        XCTAssertEqual(draft.model, "")
        XCTAssertEqual(draft.provider, "")
        // Blank is what the server reads as "inherit"; the literal string is not.
        XCTAssertNil(draft.trimmedModel)
        XCTAssertNil(draft.trimmedProvider)
    }

    func testSelectingAModelWithoutAProviderDoesNotLeaveTheOldProviderBehind() {
        // A stale provider paired with a new model is exactly the mismatch the
        // combined picker exists to prevent.
        var draft = CronJobEditorDraft(model: "gpt-5", provider: "openai")

        draft.applyModelSelection(option("llama3", provider: nil))

        XCTAssertEqual(draft.model, "llama3")
        XCTAssertEqual(draft.provider, "")
    }

    // MARK: Profile selection leaves the model alone

    func testSelectingAProfileNeverPrefillsTheModel() {
        // Upstream fills the model in from the profile only while it is blank,
        // so prefilling here would suppress the server's own snapshot.
        var draft = CronJobEditorDraft()

        draft.applyProfileSelection("work")

        XCTAssertEqual(draft.profile, "work")
        XCTAssertEqual(draft.model, "")
        XCTAssertEqual(draft.provider, "")
    }

    func testServerDefaultClearsTheProfileWithoutTouchingTheModel() {
        var draft = CronJobEditorDraft(model: "gpt-5", provider: "openai", profile: "work")

        draft.applyProfileSelection(nil)

        XCTAssertEqual(draft.profile, "")
        XCTAssertEqual(draft.model, "gpt-5")
        XCTAssertEqual(draft.provider, "openai")
    }

    // MARK: The row's current selection

    func testAModelMissingFromTheCatalogStillResolvesToADisplayableSelection() {
        let selection = CronJobModelSelection.resolve(
            modelID: "retired-model",
            providerID: "openai",
            in: catalog
        )

        XCTAssertEqual(selection?.id, "retired-model")
        XCTAssertEqual(selection?.displayName, "retired-model")
        XCTAssertEqual(selection?.providerID, "openai")
    }

    func testACatalogModelResolvesToItsCatalogOption() {
        let selection = CronJobModelSelection.resolve(modelID: "gpt-5", providerID: "openai", in: catalog)

        XCTAssertEqual(selection, option("gpt-5", provider: "openai"))
    }

    func testABlankModelResolvesToNoSelection() {
        XCTAssertNil(CronJobModelSelection.resolve(modelID: "  ", providerID: "openai", in: catalog))
    }

    func testAProfileMissingFromTheListStillGetsARow() {
        let listed = CronJobProfilePickerSheet.profilesIncludingSelection([], selectedProfileName: "retired")

        XCTAssertEqual(listed.map(\.normalizedName), ["retired"])
    }

    func testAProfileAlreadyInTheListIsNotDuplicated() {
        let work = ProfileSummary(
            name: "work",
            path: nil,
            isDefault: nil,
            isActive: nil,
            gatewayRunning: nil,
            model: "gpt-5",
            provider: "openai",
            hasEnv: nil,
            skillCount: nil
        )

        let listed = CronJobProfilePickerSheet.profilesIncludingSelection([work], selectedProfileName: "work")

        XCTAssertEqual(listed.map(\.normalizedName), ["work"])
        // The profile's own model and provider are what make the inheritance
        // the section footer describes visible.
        XCTAssertEqual(CronJobProfilePickerSheet.details(for: work), "gpt-5 - openai")
    }

    // MARK: The .cronJob picker preset

    func testTheTasksPickerNeitherShowsNorWritesFavorites() {
        XCTAssertFalse(ModelPickerConfiguration.cronJob.showsCustomFavoriteStar)
        XCTAssertFalse(ModelPickerConfiguration.cronJob.showsSavedCustomModelGroup)
        // The current selection still gets a row, so an off-catalog model is
        // visible and checked.
        XCTAssertTrue(ModelPickerConfiguration.cronJob.showsCurrentCustomModelGroup)
    }

    func testTheTasksPickersCustomEntryNeedsBothAModelAndAProviderID() {
        XCTAssertNil(
            ModelPickerSheet.customOption(modelID: "gpt-5", providerID: "  ", configuration: .cronJob)
        )
        XCTAssertEqual(
            ModelPickerSheet.customOption(modelID: " gpt-5 ", providerID: " OpenAI ", configuration: .cronJob),
            ModelCatalogOption(id: "gpt-5", displayName: "gpt-5", providerID: "openai")
        )
    }

    // MARK: Loading

    @MainActor
    func testTheEditorLoadsTheCatalogAndTheProfileList() async {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/models":
                return apiTestJSONResponse("""
                {
                  "groups": [
                    {
                      "name": "OpenAI",
                      "provider_id": "openai",
                      "models": [{"id": "gpt-5", "name": "GPT-5"}]
                    }
                  ]
                }
                """, for: request)
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"active": "default", "profiles": [{"name": "work", "model": "gpt-5", "provider": "openai"}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.load()

        XCTAssertEqual(loader.modelGroups.flatMap(\.allModels).map(\.id), ["gpt-5"])
        XCTAssertEqual(loader.profiles.map(\.normalizedName), ["work"])
        XCTAssertNil(loader.modelsErrorMessage)
        XCTAssertNil(loader.profilesErrorMessage)
    }

    @MainActor
    func testAFailedCatalogLeavesTheProfileListAndTheDraftIntact() async {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/models":
                throw URLError(.timedOut)
            case "/api/profiles":
                return apiTestJSONResponse(#"{"profiles": [{"name": "work"}]}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        var draft = CronJobEditorDraft(prompt: "Report", schedule: "0 9 * * *", model: "gpt-5", provider: "openai")
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)

        // Loading never throws out of the sheet; it lands in the loader.
        await loader.load()

        XCTAssertNotNil(loader.modelsErrorMessage)
        XCTAssertTrue(loader.modelGroups.isEmpty)
        XCTAssertEqual(loader.profiles.map(\.normalizedName), ["work"])
        XCTAssertNil(draft.validationMessage)

        // With no catalog, a hand-typed model and provider still commit.
        let custom = ModelPickerSheet.customOption(
            modelID: "gpt-5-mini",
            providerID: "openai",
            configuration: .cronJob
        )
        draft.applyModelSelection(custom)
        XCTAssertEqual(draft.trimmedModel, "gpt-5-mini")
        XCTAssertEqual(draft.trimmedProvider, "openai")
    }

    @MainActor
    func testAFailedProfileListKeepsTheSavedProfileAndRetriesSuccessfully() async {
        var shouldFailProfiles = true
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/models":
                return apiTestJSONResponse(#"{"groups": []}"#, for: request)
            case "/api/profiles":
                if shouldFailProfiles { throw URLError(.notConnectedToInternet) }
                return apiTestJSONResponse(#"{"profiles": [{"name": "work"}]}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        let draft = CronJobEditorDraft(profile: "work")
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.load()

        XCTAssertNotNil(loader.profilesErrorMessage)
        XCTAssertTrue(loader.profiles.isEmpty)
        // The saved value survives the failure and still gets a checked row.
        XCTAssertEqual(draft.profile, "work")
        XCTAssertEqual(
            CronJobProfilePickerSheet
                .profilesIncludingSelection(loader.profiles, selectedProfileName: draft.profile)
                .map(\.normalizedName),
            ["work"]
        )

        shouldFailProfiles = false
        await loader.loadProfiles()

        XCTAssertNil(loader.profilesErrorMessage)
        XCTAssertEqual(loader.profiles.map(\.normalizedName), ["work"])
    }

    @MainActor
    func testACancelledLoadIsNotReportedAsAFailure() async {
        let client = makeClient { _ in throw URLError(.cancelled) }
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)

        await loader.load()

        XCTAssertNil(loader.modelsErrorMessage)
        XCTAssertNil(loader.profilesErrorMessage)
    }
}
