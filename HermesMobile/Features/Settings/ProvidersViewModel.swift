import Foundation
import Observation

/// Backs the read-only Providers status screen (#26). Loads `GET /api/providers`
/// once per appearance and exposes pure, testable presentation helpers — no
/// write operations by design (key set/delete stays a server-side concern).
@MainActor
@Observable
final class ProvidersViewModel {
    /// Server order is preserved: upstream already sorts active-first, then
    /// custom providers, then key-holders, then the rest.
    private(set) var providers: [ProviderSummary] = []
    private(set) var activeProviderID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client: APIClient

    init(server: URL, client: APIClient? = nil) {
        self.client = client ?? APIClient(baseURL: server)
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await client.providers()
            providers = response.providers ?? []
            activeProviderID = Self.normalizedProviderID(response.activeProvider)
        } catch is CancellationError {
            // The owning view was dismissed (or the refresh gesture was torn
            // down) mid-request — don't surface "cancelled" as a load error.
        } catch let error as URLError where error.code == .cancelled {
            // Same cancellation, surfaced through URLSession.
        } catch {
            errorMessage = error.localizedDescription
        }

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

    // MARK: - Presentation helpers (pure, testable)

    /// `active_provider` comes from config (`model.provider`) while entry `id`s are
    /// canonical slugs — trim and lowercase both sides so cosmetic differences
    /// don't hide the active badge.
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

    /// Short technical badge naming where a configured key came from. Collapses the
    /// upstream `key_source` vocabulary (`env_file`/`env_var`/`env` → env,
    /// `oauth`/`token` → OAuth, `config_yaml`/`config` → config); unknown future
    /// values pass through verbatim rather than being hidden. `nil` when the
    /// provider has no key — the badge only ever describes an existing credential.
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

    /// Catalog size to advertise on the models disclosure: `models_total` reflects
    /// the complete catalog even when `models` is trimmed to a featured subset, so
    /// prefer it whenever it is larger than the visible list.
    static func modelCount(for provider: ProviderSummary) -> Int {
        max(provider.modelsTotal ?? 0, provider.models?.count ?? 0)
    }

    /// Non-nil only when the server trimmed the model list (`models_total` exceeds
    /// the entries actually sent) — drives the "Showing X of Y models" footer.
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
