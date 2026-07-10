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
    /// True once the active server has reported `show_cli_sessions` — only then
    /// do toggle changes write back. Older servers stay local-only.
    private(set) var serverSyncsCliSessions = false
    private(set) var syncErrorMessage: String?
    /// The in-flight write, exposed so callers (and tests) can await it.
    private(set) var pendingWrite: Task<Void, Never>?

    private let server: URL
    private let defaults: UserDefaults
    private let writeToServer: @MainActor (Bool) async throws -> Void
    /// Invalidates stale write completions: only the latest toggle change may
    /// revert the value or publish an error.
    private var writeGeneration = 0

    init(
        server: URL,
        defaults: UserDefaults = .standard,
        writeToServer: @escaping @MainActor (Bool) async throws -> Void
    ) {
        self.server = server
        self.defaults = defaults
        self.writeToServer = writeToServer
        showsCliSessions = SessionRowDisplaySettings.showsCliSessions(for: server, in: defaults)
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

    private func persist(_ value: Bool) {
        showsCliSessions = value
        defaults.set(value, forKey: SessionRowDisplaySettings.showCliSessionsKey(for: server))
    }
}


import Foundation
import Observation

/// Server-synced "Show Claude Code sessions" toggle (#98).
///
/// The setting is stored per-server and mirrors the upstream
/// `show_claude_code_sessions` preference when the active server reports it.
/// `show_cli_sessions` remains the parent gate: when CLI sessions are hidden,
/// the server echoes `show_claude_code_sessions=false` regardless of the saved
/// child preference. To preserve the user's saved Claude Code choice, adoption
/// skips that echoed `false` while the parent gate is off.
@MainActor
@Observable
final class ClaudeCodeSessionsSyncModel {
    private(set) var showsClaudeCodeSessions: Bool
    private(set) var serverSyncsClaudeCodeSessions = false
    private(set) var syncErrorMessage: String?
    private(set) var pendingWrite: Task<Void, Never>?

    private let server: URL
    private let defaults: UserDefaults
    private let writeToServer: @MainActor (Bool) async throws -> Void
    private var writeGeneration = 0

    init(
        server: URL,
        defaults: UserDefaults = .standard,
        writeToServer: @escaping @MainActor (Bool) async throws -> Void
    ) {
        self.server = server
        self.defaults = defaults
        self.writeToServer = writeToServer
        showsClaudeCodeSessions = SessionRowDisplaySettings.showsClaudeCodeSessions(for: server, in: defaults)
    }

    func adopt(serverValue: Bool?, cliSessionsEnabled: Bool) {
        guard let serverValue else {
            serverSyncsClaudeCodeSessions = false
            return
        }

        serverSyncsClaudeCodeSessions = true
        syncErrorMessage = nil

        guard cliSessionsEnabled else {
            return
        }

        persist(serverValue)
    }

    func setShowsClaudeCodeSessions(_ newValue: Bool) {
        guard newValue != showsClaudeCodeSessions else { return }

        let previousValue = showsClaudeCodeSessions
        persist(newValue)
        syncErrorMessage = nil

        guard serverSyncsClaudeCodeSessions else { return }

        writeGeneration += 1
        let generation = writeGeneration
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

    private func persist(_ value: Bool) {
        showsClaudeCodeSessions = value
        defaults.set(value, forKey: SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server))
    }
}
