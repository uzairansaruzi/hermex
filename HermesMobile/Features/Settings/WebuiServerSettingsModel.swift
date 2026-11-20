import SwiftUI

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

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        cliSessionsSync = CliSessionsSyncModel(server: server) { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showCliSessions: value)
        } writeClaudeCodeToServer: { value in
            let client = APIClient(baseURL: server)
            _ = try await client.updateSettings(showClaudeCodeSessions: value)
        }
    }

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
            serverUpdateState = nil
        }

        do {
            let catalog = try await client.models()
            defaultModel = catalog.defaultModel
        } catch {
            defaultModel = nil
        }

        isLoadingDefaultModel = false

        do {
            let profiles = try await client.profiles()
            defaultProfileName = profiles.effectiveDefaultProfileName
            defaultProfileDisplayName = profiles.displayName(for: defaultProfileName)
        } catch {
            defaultProfileName = nil
            defaultProfileDisplayName = nil
        }

        isLoadingDefaultProfile = false
    }

    func checkForUpdatesManually() async {
        guard !isCheckingForUpdates, !isUpdateApplyInFlight else {
            return
        }

        isCheckingForUpdates = true
        let client = APIClient(baseURL: server)

        do {
            let response = try await client.updatesCheckForced()
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
        guard !isCheckingForUpdates else { return }

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

    private func waitForServerToReturn(using client: APIClient, previousVersion: String?) async {
        let maxAttempts = 30

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

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

        await load()
        if serverSettingsError != nil {
            updateApplyMessage = String(localized: "The server didn't come back after the update. Check the server, then retry.")
            updateApplyPhase = .failed
        } else if case .updateAvailable = serverUpdateState {
            updateApplyMessage = String(localized: "The update is taking longer than expected to finish. Try again in a moment.")
            updateApplyPhase = .failed
        } else {
            updateApplyPhase = .idle
            updateApplyMessage = nil
        }
    }
}

enum ServerUpdateApplyPhase: Equatable {
    case idle
    case applying
    case recovering
    case blocked
    case failed
}
