import Foundation
import Observation

@MainActor
@Observable
final class CliSessionsSyncModel {
    private(set) var showsCliSessions: Bool
    private(set) var showsClaudeCodeSessions: Bool
    private(set) var serverSyncsCliSessions = false
    private(set) var serverSyncsClaudeCodeSessions = false
    private(set) var syncErrorMessage: String?
    private(set) var claudeCodeSyncErrorMessage: String?
    private(set) var pendingWrite: Task<Void, Never>?
    private(set) var pendingClaudeCodeWrite: Task<Void, Never>?

    private let server: URL
    private let defaults: UserDefaults
    private let writeToServer: @MainActor (Bool) async throws -> Void
    private let writeClaudeCodeToServer: @MainActor (Bool) async throws -> Void
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

    func adopt(serverValue: Bool?) {
        guard let serverValue else {
            serverSyncsCliSessions = false
            return
        }

        serverSyncsCliSessions = true
        syncErrorMessage = nil
        persist(serverValue)
    }

    func adoptClaudeCode(serverValue: Bool?) {
        guard let serverValue else {
            serverSyncsClaudeCodeSessions = false
            return
        }

        serverSyncsClaudeCodeSessions = true
        claudeCodeSyncErrorMessage = nil
        persistClaudeCode(serverValue)
    }

    func setShowsCliSessions(_ newValue: Bool) {
        guard newValue != showsCliSessions else { return }

        let previousValue = showsCliSessions
        persist(newValue)
        syncErrorMessage = nil

        guard serverSyncsCliSessions else { return }

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
