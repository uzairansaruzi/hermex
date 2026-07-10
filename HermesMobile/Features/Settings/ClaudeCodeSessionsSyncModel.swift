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
