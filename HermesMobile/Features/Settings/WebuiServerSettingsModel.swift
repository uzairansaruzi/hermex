import SwiftData
import SwiftUI

/// The active webui server's settings state (#1252): its status and version, the in-app update
/// (#180, #308), its default model and profile, its session visibility (#19), and its offline
/// cache. `load()` runs each time the server's page appears.
@MainActor @Observable final class WebuiServerSettingsModel {
    let server: URL
    let cliSessionsSync: CliSessionsSyncModel
    private let onAPIError: (Error) -> Void

    var isLoadingServerSettings = false
    var serverVersion: String?
    var serverSettingsError: String?
    var serverUpdateState: UpdatesCheckResponse.WebUIUpdateState?
    var updateApplyPhase: ServerUpdateApplyPhase = .idle
    var isConfirmingUpdate = false
    var updateApplyMessage: String?
    var isCheckingForUpdates = false
    var forcedCheckOutcome: UpdatesCheckResponse.ForcedCheckOutcome?
    var isPresentingForcedCheckResult = false
    var defaultModel: String?
    var defaultProfileName: String?
    var defaultProfileDisplayName: String?
    var isLoadingDefaultModel = false
    var isLoadingDefaultProfile = false
    var showsDefaultModelPicker = false
    var showsDefaultProfilePicker = false
    var isConfirmingClearCache = false
    var isClearingCache = false
    var cacheStatusMessage: String?

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        // The CLI-sessions toggle is server-synced (#19): loads adopt the
        // server's `show_cli_sessions`, toggles POST it back, failures revert.
        // Stored per-server so one server's value never leaks into another.
        cliSessionsSync = CliSessionsSyncModel(server: server) { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showCliSessions: value)
        } writeClaudeCodeToServer: { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showClaudeCodeSessions: value)
        }
    }

    // True while the server is applying/restarting an update. The manual check
    // button is disabled then so a forced check can't race the recovery poll.
    var isUpdateApplyInFlight: Bool {
        switch updateApplyPhase {
        case .applying, .recovering:
            return true
        case .idle, .blocked, .failed:
            return false
        }
    }

    func load() async {
        guard !isLoadingServerSettings else {
            return
        }

        isLoadingServerSettings = true
        isLoadingDefaultModel = true
        isLoadingDefaultProfile = true
        serverSettingsError = nil
        serverUpdateState = nil
        let client = APIClient(baseURL: server)

        do {
            let settings = try await client.settings()
            serverVersion = settings.webuiVersion
            // Server wins on conflict: `show_cli_sessions` is the cross-device
            // truth, the local value is just its offline cache (#19).
            cliSessionsSync.adopt(serverValue: settings.showCliSessions)
            cliSessionsSync.adoptClaudeCode(serverValue: settings.showClaudeCodeSessions)
            if serverVersion == nil {
                serverSettingsError = String(localized: "Unknown")
            }
        } catch {
            onAPIError(error)
            serverSettingsError = String(localized: "Unavailable")
        }

        isLoadingServerSettings = false

        do {
            let updates = try await client.updatesCheck()
            serverUpdateState = updates.webuiUpdateState
        } catch {
            // Non-fatal: update availability is optional info. On any failure we
            // degrade to showing the version only, with no indicator.
            serverUpdateState = nil
        }

        do {
            let catalog = try await client.models()
            defaultModel = catalog.defaultModel
        } catch {
            // Non-fatal: default model is optional info
            defaultModel = nil
        }

        isLoadingDefaultModel = false

        do {
            let profiles = try await client.profiles()
            defaultProfileName = profiles.effectiveDefaultProfileName
            defaultProfileDisplayName = profiles.displayName(for: defaultProfileName)
        } catch {
            // Non-fatal: default profile is optional info
            defaultProfileName = nil
            defaultProfileDisplayName = nil
        }

        isLoadingDefaultProfile = false
    }

    func checkForUpdatesManually() async {
        // Ignore taps while a check is already running or an apply/restart is in
        // flight — both would race the shared `serverUpdateState`.
        guard !isCheckingForUpdates, !isUpdateApplyInFlight else {
            return
        }

        isCheckingForUpdates = true
        let client = APIClient(baseURL: server)

        do {
            let response = try await client.updatesCheckForced()
            // Refresh the passive inline indicator from the fresh result too, so a
            // forced check keeps the on-open note in sync (issue #308).
            serverUpdateState = response.webuiUpdateState
            forcedCheckOutcome = response.forcedCheckOutcome
        } catch {
            onAPIError(error)
            forcedCheckOutcome = .error
        }

        isCheckingForUpdates = false
        isPresentingForcedCheckResult = true
    }

    func applyServerUpdate() async {
        // Never start an apply while a forced check is in flight — the two race
        // the same server-side git state, and the check's completion would
        // overwrite update state / present its popup mid-apply. The inline
        // Update button is also disabled then; this guards the path regardless
        // (e.g. a tap that slips through the confirm dialog). The forced-check
        // popup's own Update is safe: `isCheckingForUpdates` is already false
        // before that popup presents (#308 review).
        guard !isCheckingForUpdates else { return }

        // Allow a fresh attempt only from a resting phase; ignore taps while a
        // request is in flight or the server is mid-restart.
        switch updateApplyPhase {
        case .idle, .blocked, .failed:
            break
        case .applying, .recovering:
            return
        }

        updateApplyPhase = .applying
        updateApplyMessage = nil
        let client = APIClient(baseURL: server)

        let response: UpdatesApplyResponse
        do {
            response = try await client.applyUpdate(target: "webui")
        } catch {
            // The apply call returns before the server restarts, so a failure
            // here is a real pre-restart error (auth, unreachable, decode).
            onAPIError(error)
            updateApplyMessage = String(localized: "Could not reach the server to start the update.")
            updateApplyPhase = .failed
            return
        }

        switch response.outcome {
        case .applying:
            updateApplyPhase = .recovering
            await waitForServerToReturn(using: client, previousVersion: serverVersion)
        case .restartBlocked:
            updateApplyMessage = response.displayMessage(
                default: String(localized: "The server is busy with active work. Wait for it to finish, then retry.")
            )
            updateApplyPhase = .blocked
        case .failed:
            updateApplyMessage = response.displayMessage(
                default: String(localized: "The update could not be applied.")
            )
            updateApplyPhase = .failed
        }
    }

    /// Polls the self-restarting server until the restart is confirmed, then
    /// refreshes the version and indicator. Bounded so a slow/stuck restart
    /// never leaves a spinner up.
    ///
    /// Completion requires *proof the restart happened* — the reported version
    /// changed, or the check explicitly reports `.upToDate` — not merely a
    /// reachable server. That avoids finalising against the outgoing process or
    /// on a transient `stale_check` that still claims a non-zero `behind`, while
    /// still letting update-check-disabled servers converge via the new version.
    /// State is refreshed inline (not via the non-reentrant `load`)
    /// so a concurrent load can't make us flip to `.idle` without refreshing.
    private func waitForServerToReturn(using client: APIClient, previousVersion: String?) async {
        let maxAttempts = 30 // ~60s at a 2s cadence — generous for a self-restart.

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            // Wait first: the server flushes the response, then restarts ~2s
            // later, so an immediate probe could hit the outgoing process.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            // One reachable settings call gives us both liveness and the fresh
            // version; a nil result means the restart outage hasn't cleared yet.
            guard let settings = try? await client.settings() else {
                continue
            }

            let newVersion = settings.webuiVersion
            let updateState = (try? await client.updatesCheck())?.webuiUpdateState ?? .unavailable
            let restartConfirmed = (newVersion != nil && newVersion != previousVersion)
                || updateState == .upToDate

            if restartConfirmed {
                serverVersion = newVersion
                serverSettingsError = newVersion == nil ? String(localized: "Unknown") : nil
                serverUpdateState = updateState
                updateApplyPhase = .idle
                updateApplyMessage = nil
                return
            }
        }

        // Didn't confirm the restart in the window. Refresh once so the indicator
        // reflects reality, then surface a distinct, retryable failure — never a
        // silent reset (the `.failed` UI stays visible regardless of the now
        // possibly-nil `serverUpdateState`).
        await load()
        if serverSettingsError != nil {
            updateApplyMessage = String(localized: "The server didn't come back after the update. Check the server, then retry.")
            updateApplyPhase = .failed
        } else if case .updateAvailable = serverUpdateState {
            updateApplyMessage = String(localized: "The update is taking longer than expected to finish. Try again in a moment.")
            updateApplyPhase = .failed
        } else {
            // Server is back and not reporting a pending update — treat as done.
            updateApplyPhase = .idle
            updateApplyMessage = nil
        }
    }

    func clearOfflineCache(in modelContext: ModelContext) async {
        guard !isClearingCache else {
            return
        }

        isClearingCache = true
        do {
            // Scoped to the active server only, so clearing one server's cache
            // never wipes another configured server's offline data (#18).
            try CacheStore.clearCache(for: server, in: modelContext)
            try await BotHistoryCache.shared.remove(server: server)
            cacheStatusMessage = String(localized: "This server's offline cache was cleared.")
        } catch {
            cacheStatusMessage = String(localized: "Could not clear offline cache.")
        }
        isClearingCache = false
    }
}

/// Phases of the in-app "apply webui update" flow (issue #180).
enum ServerUpdateApplyPhase: Equatable {
    /// No update in flight; show the "Update" button.
    case idle
    /// The apply request is in flight (before the server confirms a restart).
    case applying
    /// Server accepted the update and is restarting; we are polling for it.
    case recovering
    /// Restart was blocked by active chat/agent work; offer a retry.
    case blocked
    /// The update failed (conflict, diverged, unreachable, or timed-out restart).
    case failed
}
