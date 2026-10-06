import Foundation
import Observation

/// The model catalog, profile list, and skill list behind the Task editor's
/// Configuration section.
///
/// Owned by `CronJobEditorSheet` and driven from its `.task`, so the requests
/// happen when the editor opens rather than when the Tasks list appears — a
/// user scrolling their tasks should not pay for a catalog fetch.
/// The create sheet and the edit sheet are the same sheet, so they share this
/// one loader instead of each view model growing its own copy.
///
/// The loads are independent and non-fatal. A failed catalog leaves the
/// model picker with only its custom entry; a failed profile or skill list
/// leaves its row showing an error with a retry. None of them disturbs any
/// other field in the sheet.
///
/// On a server that keeps Tasks in Profiles (a Hermes host, #1040), the models,
/// skills and delivery targets are the Task's Profile's, so one loader serves one
/// Profile and the sheet makes a new one when the Profile changes.
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

    /// The Profile's delivery targets, on a server that scopes them by Profile; nil
    /// elsewhere, where the sheet's caller supplies them.
    private(set) var deliveryOptions: [CronDeliveryOption]?

    /// The Profile the models, skills and delivery targets follow where the server
    /// scopes them; nil reads the server's own.
    let profile: String?
    private let client: any CronDataClient

    init(server: URL, client: (any CronDataClient)? = nil, profile: String? = nil) {
        self.client = client ?? APIClient(baseURL: server)
        self.profile = profile
    }

    /// Runs all the loads concurrently. Re-entrant calls are dropped, so the
    /// sheet's `.task` restarting does not stack requests.
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
            // A cancelled `.task` (the sheet dismissed mid-load) is not a
            // failure the user should see.
            guard !Self.isCancellation(error) else { return }
            modelsErrorMessage = error.localizedDescription
        }
    }

    /// Also the profile row's retry.
    func loadProfiles() async {
        guard !isLoadingProfiles else { return }
        isLoadingProfiles = true
        profilesErrorMessage = nil
        defer { isLoadingProfiles = false }

        do {
            profiles = try await client.cronProfiles()
        } catch {
            guard !Self.isCancellation(error) else { return }
            profilesErrorMessage = error.localizedDescription
        }
    }

    /// Also the skills row's retry.
    func loadSkills() async {
        guard !isLoadingSkills else { return }
        isLoadingSkills = true
        skillsErrorMessage = nil
        defer { isLoadingSkills = false }

        do {
            // Disabled skills are filtered out: the picker offers what a run
            // could actually use, and the server would ignore the rest.
            skills = try await client.cronSkills(profile: profile).filter { $0.disabled != true }
        } catch {
            guard !Self.isCancellation(error) else { return }
            skillsErrorMessage = error.localizedDescription
        }
    }

    /// Only where the server scopes targets by Profile. A failure leaves the
    /// deliver field as free text, as a missing list always has.
    func loadDeliveryOptions() async {
        guard client.cronFeatures.isProfileScoped else { return }
        deliveryOptions = (try? await client.cronDeliveryOptions(profile: profile))?.platforms
    }

    /// Mirrors `DefaultProfilePickerView.isCancellationError`: cancellation
    /// arrives either as `CancellationError` or as a `.cancelled` `URLError`,
    /// possibly wrapped in `APIError.network`. A Hermes host's gateway reads end
    /// as `BotFailure.stale` once their task is cancelled (#1040).
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || error as? BotFailure == .stale { return true }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }
}
