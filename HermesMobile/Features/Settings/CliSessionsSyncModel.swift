import Foundation
import Observation

/// Server-synced "Show CLI sessions" toggle (#19).
///
/// The server's `show_cli_sessions` setting is the cross-device source of
/// truth: on every Settings load the server value is adopted into the
/// per-server local cache (server wins on conflict), and flipping the toggle
/// writes `POST /api/settings {"show_cli_sessions": <bool>}` back. The local
/// value doubles as an offline cache — servers that never report the key keep
/// today's purely local behavior (no adoption, no write). On a failed write
/// the toggle reverts and the error is surfaced.
///
/// Storage is per-server (`SessionRowDisplaySettings.showCliSessionsKey(for:)`)
/// so an adopted value on server A can never leak into server B
/// (docs/agents/multi-server-state-isolation.md).
@MainActor
@Observable
final class CliSessionsSyncModel {
    private(set) var showsCliSessions: Bool
    private(set) var showsClaudeCodeSessions: Bool
    /// True once the active server has reported `show_cli_sessions` — only then
    /// do toggle changes write back. Older servers stay local-only.
    private(set) var serverSyncsCliSessions = false
    private(set) var serverSyncsClaudeCodeSessions = false
    private(set) var syncErrorMessage: String?
    private(set) var claudeCodeSyncErrorMessage: String?
    /// The in-flight write, exposed so callers (and tests) can await it.
    private(set) var pendingWrite: Task<Void, Never>?
    private(set) var pendingClaudeCodeWrite: Task<Void, Never>?

    private let server: URL
    private let defaults: UserDefaults
    private let writeToServer: @MainActor (Bool) async throws -> Void
    private let writeClaudeCodeToServer: @MainActor (Bool) async throws -> Void
    /// Invalidates stale write completions: only the latest toggle change may
    /// revert the value or publish an error.
    private var writeGeneration = 0
    private var claudeCodeWriteGeneration = 0

    init(
        server: URL,
        defaults: UserDefaults = .standard,
        writeToServer: @escaping @MainActor (Bool) async throws -> Void,
        writeClaudeCodeToServer: @escaping @MainActor (Bool) async throws -> Void = { _ in }
    ) {
        self.server = server
        self.defaults = defaults
        self.writeToServer = writeToServer
        self.writeClaudeCodeToServer = writeClaudeCodeToServer
        showsCliSessions = SessionRowDisplaySettings.showsCliSessions(for: server, in: defaults)
        showsClaudeCodeSessions = SessionRowDisplaySettings.showsClaudeCodeSessions(
            for: server,
            in: defaults
        )
    }

    /// Adopts the server-reported value on settings load. `nil` (server omitted
    /// the key) leaves the local toggle exactly as it was and disables
    /// write-back. Adoption never writes back to the server.
    func adopt(serverValue: Bool?) {
        guard let serverValue else {
            serverSyncsCliSessions = false
            return
        }

        serverSyncsCliSessions = true
        syncErrorMessage = nil
        persist(serverValue)
    }

    /// Mirrors `adopt(serverValue:)` for the subordinate Claude Code setting.
    /// Older servers omit the key, retaining the shown-by-default local value.
    func adoptClaudeCode(serverValue: Bool?) {
        guard let serverValue else {
            serverSyncsClaudeCodeSessions = false
            return
        }

        serverSyncsClaudeCodeSessions = true
        claudeCodeSyncErrorMessage = nil
        persistClaudeCode(serverValue)
    }

    /// Applies a user toggle: optimistic local update, then the server write.
    /// On write failure the toggle reverts (unless the user has already toggled
    /// again) and `syncErrorMessage` is set.
    func setShowsCliSessions(_ newValue: Bool) {
        guard newValue != showsCliSessions else { return }

        let previousValue = showsCliSessions
        persist(newValue)
        syncErrorMessage = nil

        guard serverSyncsCliSessions else { return }

        writeGeneration += 1
        let generation = writeGeneration
        // Serialize behind the in-flight write: cancelling a Task does not
        // un-send a POST that already left the device, so the previous request
        // could land at the server *after* a newer one and flip the stored
        // value against the UI. Holding the next request until the previous
        // response arrives guarantees the server applies toggles in UI order;
        // a superseded write skips its POST entirely (the newest queued write
        // carries the final value), so a long chain collapses to one request.
        let predecessor = pendingWrite
        pendingWrite = Task { [weak self] in
            await predecessor?.value
            guard let self, self.writeGeneration == generation else { return }
            do {
                try await self.writeToServer(newValue)
            } catch {
                guard self.writeGeneration == generation else { return }
                self.persist(previousValue)
                self.syncErrorMessage = String(
                    localized: "Could not save to the server. The toggle was reverted."
                )
            }
        }
    }

    /// Applies the saved Claude Code preference independently of the CLI parent
    /// gate. Settings disables this control while CLI sessions are hidden, but
    /// never overwrites the saved child value.
    func setShowsClaudeCodeSessions(_ newValue: Bool) {
        guard newValue != showsClaudeCodeSessions else { return }

        let previousValue = showsClaudeCodeSessions
        persistClaudeCode(newValue)
        claudeCodeSyncErrorMessage = nil

        guard serverSyncsClaudeCodeSessions else { return }

        claudeCodeWriteGeneration += 1
        let generation = claudeCodeWriteGeneration
        let predecessor = pendingClaudeCodeWrite
        pendingClaudeCodeWrite = Task { [weak self] in
            await predecessor?.value
            guard let self, self.claudeCodeWriteGeneration == generation else { return }
            do {
                try await self.writeClaudeCodeToServer(newValue)
            } catch {
                guard self.claudeCodeWriteGeneration == generation else { return }
                self.persistClaudeCode(previousValue)
                self.claudeCodeSyncErrorMessage = String(
                    localized: "Could not save to the server. The toggle was reverted."
                )
            }
        }
    }

    private func persist(_ value: Bool) {
        showsCliSessions = value
        defaults.set(value, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: server))
    }

    private func persistClaudeCode(_ value: Bool) {
        showsClaudeCodeSessions = value
        defaults.set(
            value,
            forKey: SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }
}
