import XCTest
@testable import HermesMobile

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

    func testServerDefaultClearsBothTheModelAndTheProvider() {
        var draft = CronJobEditorDraft(model: "gpt-5", provider: "openai")

        draft.applyModelSelection(nil)

        XCTAssertEqual(draft.model, "")
        XCTAssertEqual(draft.provider, "")
        XCTAssertNil(draft.trimmedModel)
        XCTAssertNil(draft.trimmedProvider)
    }

    func testSelectingAModelWithoutAProviderDoesNotLeaveTheOldProviderBehind() {
        var draft = CronJobEditorDraft(model: "gpt-5", provider: "openai")

        draft.applyModelSelection(option("llama3", provider: nil))

        XCTAssertEqual(draft.model, "llama3")
        XCTAssertEqual(draft.provider, "")
    }

    func testSelectingAProfileNeverPrefillsTheModel() {
        var draft = CronJobEditorDraft()

        draft.applyProfileSelection("work")

        XCTAssertEqual(draft.profile, "work")
        XCTAssertEqual(draft.model, "")
        XCTAssertEqual(draft.provider, "")
    }

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

    func testTheTasksPickersCustomEntryNeedsBothAModelAndAProviderID() {
        XCTAssertNil(
            ModelPickerSheet.customOption(modelID: "gpt-5", providerID: "  ", configuration: .cronJob)
        )
        XCTAssertEqual(
            ModelPickerSheet.customOption(modelID: " gpt-5 ", providerID: " OpenAI ", configuration: .cronJob),
            ModelCatalogOption(id: "gpt-5", displayName: "gpt-5", providerID: "openai")
        )
    }

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
            case "/api/skills":
                return apiTestJSONResponse(#"{"skills": [{"name": "writing"}]}"#, for: request)
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }

        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.load()

        XCTAssertEqual(loader.modelGroups.flatMap(\.allModels).map(\.id), ["gpt-5"])
        XCTAssertEqual(loader.profiles.map(\.normalizedName), ["work"])
        XCTAssertEqual(loader.skills.compactMap(\.name), ["writing"])
        XCTAssertNil(loader.modelsErrorMessage)
        XCTAssertNil(loader.profilesErrorMessage)
        XCTAssertNil(loader.skillsErrorMessage)
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
                return apiTestJSONResponse("{}", for: request)
            }
        }

        var draft = CronJobEditorDraft(prompt: "Report", schedule: "0 9 * * *", model: "gpt-5", provider: "openai")
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)

        await loader.load()

        XCTAssertNotNil(loader.modelsErrorMessage)
        XCTAssertTrue(loader.modelGroups.isEmpty)
        XCTAssertEqual(loader.profiles.map(\.normalizedName), ["work"])
        XCTAssertNil(draft.validationMessage)

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
                return apiTestJSONResponse("{}", for: request)
            }
        }

        let draft = CronJobEditorDraft(profile: "work")
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.load()

        XCTAssertNotNil(loader.profilesErrorMessage)
        XCTAssertTrue(loader.profiles.isEmpty)
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

final class CronJobSkillsPickerTests: APIClientTestCase {
    func testTogglingASkillAddsItToTheEndAndRemovesItAgain() {
        let added = CronJobEditorDraft.togglingSkill("research", in: ["writing"])
        XCTAssertEqual(added, ["writing", "research"])

        XCTAssertEqual(CronJobEditorDraft.togglingSkill("writing", in: added), ["research"])
    }

    func testASkillSelectionRoundTripsThroughSkillsText() {
        var draft = CronJobEditorDraft()

        draft.applySkillSelection(["writing", "research"])

        XCTAssertEqual(draft.skillsText, "writing, research")
        XCTAssertEqual(draft.skills, ["writing", "research"])
    }

    func testSkillSearchMatchesNameCategoryAndDescription() {
        let skills = [
            SkillSummary(name: "writing", category: "docs", description: "Drafts prose", path: nil),
            SkillSummary(name: "research", category: "web", description: "Reads sources", path: nil),
        ]

        XCTAssertEqual(CronJobSkillsPickerSheet.filteredSkills(skills, query: "docs").compactMap(\.name), ["writing"])
        XCTAssertEqual(CronJobSkillsPickerSheet.filteredSkills(skills, query: "sources").compactMap(\.name), ["research"])
        XCTAssertEqual(CronJobSkillsPickerSheet.filteredSkills(skills, query: "  ").count, 2)
    }

    @MainActor
    func testTheEditorLoadsSkillsAndSkipsDisabledOnes() async {
        let client = makeClient { request in
            guard request.url?.path == "/api/skills" else {
                return apiTestJSONResponse("{}", for: request)
            }

            return apiTestJSONResponse(
                #"{"skills": [{"name": "writing", "category": "docs"}, {"name": "retired", "disabled": true}]}"#,
                for: request
            )
        }

        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.loadSkills()

        XCTAssertEqual(loader.skills.compactMap(\.name), ["writing"])
        XCTAssertNil(loader.skillsErrorMessage)
    }

    @MainActor
    func testAFailedSkillListKeepsTheSavedSkillsAndRetriesSuccessfully() async {
        var shouldFailSkills = true
        let client = makeClient { request in
            guard request.url?.path == "/api/skills" else {
                return apiTestJSONResponse("{}", for: request)
            }
            if shouldFailSkills { throw URLError(.notConnectedToInternet) }
            return apiTestJSONResponse(#"{"skills": [{"name": "writing"}]}"#, for: request)
        }

        var draft = CronJobEditorDraft(skillsText: "writing")
        let loader = CronJobEditorConfigurationLoader(server: URL(string: "https://example.test")!, client: client)
        await loader.loadSkills()

        XCTAssertNotNil(loader.skillsErrorMessage)
        XCTAssertTrue(loader.skills.isEmpty)
        XCTAssertEqual(draft.skills, ["writing"])
        XCTAssertEqual(
            CronJobSkillsPickerSheet
                .skillsIncludingSelection(loader.skills, selection: draft.skills)
                .compactMap(\.name),
            ["writing"]
        )

        draft.applySkillSelection(CronJobEditorDraft.togglingSkill("research", in: draft.skills))
        XCTAssertEqual(draft.skills, ["writing", "research"])

        shouldFailSkills = false
        await loader.loadSkills()

        XCTAssertNil(loader.skillsErrorMessage)
        XCTAssertEqual(loader.skills.compactMap(\.name), ["writing"])
    }
}
