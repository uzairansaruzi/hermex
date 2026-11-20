import Foundation
import Observation

@MainActor
@Observable
final class ProvidersViewModel {
    private(set) var providers: [ProviderSummary] = []
    private(set) var activeProviderID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client: APIClient

    private var loadGeneration = 0

    init(server: URL, client: APIClient? = nil) {
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration

        isLoading = true
        errorMessage = nil

        do {
            let response = try await client.providers()
            guard generation == loadGeneration else { return }
            providers = response.providers ?? []
            activeProviderID = Self.normalizedProviderID(response.activeProvider)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch APIError.network(let underlying) where (underlying as? URLError)?.code == .cancelled {
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }

        guard generation == loadGeneration else { return }
        isLoading = false
    }

    func isActive(_ provider: ProviderSummary) -> Bool {
        guard let active = activeProviderID,
              let id = Self.normalizedProviderID(provider.id)
        else {
            return false
        }

        return id == active
    }

    static func normalizedProviderID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    static func displayName(for provider: ProviderSummary) -> String {
        if let name = trimmedNonEmpty(provider.displayName) {
            return name
        }

        if let id = trimmedNonEmpty(provider.id) {
            return id
        }

        return String(localized: "Unknown provider")
    }

    static func keySourceBadge(for provider: ProviderSummary) -> String? {
        guard provider.hasKey == true else {
            return nil
        }

        let raw = provider.keySource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        switch raw {
        case "", "none":
            return nil
        case "env_file", "env_var", "env":
            return "env"
        case "oauth", "token":
            return "OAuth"
        case "config_yaml", "config":
            return "config"
        default:
            return raw
        }
    }

    static func authErrorText(for provider: ProviderSummary) -> String? {
        trimmedNonEmpty(provider.authError)
    }

    static func modelCount(for provider: ProviderSummary) -> Int {
        max(provider.modelsTotal ?? 0, provider.models?.count ?? 0)
    }

    static func modelCountLabel(for provider: ProviderSummary) -> String? {
        if let info = truncatedModelInfo(for: provider) {
            return "\(info.shown.formatted()) / \(info.total.formatted())"
        }

        let count = modelCount(for: provider)
        return count > 0 ? count.formatted() : nil
    }

    static func truncatedModelInfo(for provider: ProviderSummary) -> (shown: Int, total: Int)? {
        let shown = provider.models?.count ?? 0

        guard let total = provider.modelsTotal, shown > 0, total > shown else {
            return nil
        }

        return (shown: shown, total: total)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
