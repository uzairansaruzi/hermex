import Foundation
import Observation

@MainActor
@Observable
final class CronJobEditorConfigurationLoader {
    private(set) var modelGroups: [ModelCatalogGroup] = []
    private(set) var isLoadingModels = false
    private(set) var modelsErrorMessage: String?

    private(set) var profiles: [ProfileSummary] = []
    private(set) var isLoadingProfiles = false
    private(set) var profilesErrorMessage: String?

    private(set) var skills: [SkillSummary] = []
    private(set) var isLoadingSkills = false
    private(set) var skillsErrorMessage: String?

    private(set) var deliveryOptions: [CronDeliveryOption]?

    let profile: String?
    private let client: any CronDataClient

    init(server: URL, client: (any CronDataClient)? = nil, profile: String? = nil) {
        self.client = client ?? APIClient(baseURL: server)
        self.profile = profile
    }

    func load() async {
        async let models: Void = loadModels()
        async let profiles: Void = loadProfiles()
        async let skills: Void = loadSkills()
        async let delivery: Void = loadDeliveryOptions()
        _ = await (models, profiles, skills, delivery)
    }

    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsErrorMessage = nil
        defer { isLoadingModels = false }

        do {
            modelGroups = try await client.cronModelGroups(profile: profile)
        } catch {
            guard !error.isCancellation, error as? BotFailure != .stale else { return }
            modelsErrorMessage = error.localizedDescription
        }
    }

    func loadProfiles() async {
        guard !isLoadingProfiles else { return }
        isLoadingProfiles = true
        profilesErrorMessage = nil
        defer { isLoadingProfiles = false }

        do {
            profiles = try await client.cronProfiles()
        } catch {
            guard !error.isCancellation, error as? BotFailure != .stale else { return }
            profilesErrorMessage = error.localizedDescription
        }
    }

    func loadSkills() async {
        guard !isLoadingSkills else { return }
        isLoadingSkills = true
        skillsErrorMessage = nil
        defer { isLoadingSkills = false }

        do {
            skills = try await client.cronSkills(profile: profile).filter { $0.disabled != true }
        } catch {
            guard !error.isCancellation, error as? BotFailure != .stale else { return }
            skillsErrorMessage = error.localizedDescription
        }
    }

    func loadDeliveryOptions() async {
        guard client.cronFeatures.isProfileScoped else { return }
        deliveryOptions = (try? await client.cronDeliveryOptions(profile: profile))?.platforms
    }
}
