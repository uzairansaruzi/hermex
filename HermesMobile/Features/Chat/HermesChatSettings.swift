import Foundation
import Observation
import UIKit

enum HermesProfilePreference {
    static func key(for server: URL) -> String {
        "hermes.selectedProfile|\(server.absoluteString)"
    }

    static func save(_ profile: String?, for server: URL, in defaults: UserDefaults = .standard) {
        if let profile {
            defaults.set(profile, forKey: key(for: server))
        } else {
            defaults.removeObject(forKey: key(for: server))
        }
    }

    static func showsAllProfiles(for server: URL, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showsAllKey(for: server))
    }

    static func saveShowsAllProfiles(_ showsAll: Bool, for server: URL, in defaults: UserDefaults = .standard) {
        if showsAll { defaults.set(true, forKey: showsAllKey(for: server)) } else { defaults.removeObject(forKey: showsAllKey(for: server)) }
    }

    private static func showsAllKey(for server: URL) -> String {
        "hermes.sessionsShowAllProfiles|\(server.absoluteString)"
    }

    static func lastListed(for server: URL, in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastListedKey(for: server))
    }

    static func saveLastListed(_ profile: String?, for server: URL, in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: lastListedKey(for: server)) != profile else { return }
        if let profile { defaults.set(profile, forKey: lastListedKey(for: server)) } else { defaults.removeObject(forKey: lastListedKey(for: server)) }
    }

    private static func lastListedKey(for server: URL) -> String {
        "hermes.lastListedProfile|\(server.absoluteString)"
    }

    static func resolve(for server: URL, listed: [String], current: String,
                        in defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: key(for: server)) else { return current }
        guard !listed.isEmpty else { return current }
        if listed.contains(saved) { return saved }
        save(nil, for: server, in: defaults)
        return current
    }

    @MainActor
    static func starting(for server: URL, on wire: any BotTransport,
                         in defaults: UserDefaults = .standard) async throws -> (profile: String, listed: [String]) {
        let rows = (try? await wire.call(.profilesList(includeSessions: false)))?["profiles"].list ?? []
        let listed = rows.compactMap { $0["name"].text }
        let current = try await wire.currentProfile()
        return (resolve(for: server, listed: listed, current: current, in: defaults), listed)
    }
}

@MainActor @Observable final class HermesChatSettings {
    let controls = BotChatControls()
    let profile: String
    private(set) var profiles: [String] = []
    private(set) var bots: [BotProfile] = []
    private(set) var mentions: BotMentions
    private(set) var avatars: [String: UIImage] = [:]
    private let loadsAvatars: Bool
    @ObservationIgnored var onRosterRead: (() -> Void)?
    @ObservationIgnored var onAvatarsChange: (() -> Void)?
    private(set) var pendingPersonality: String?
    private var reportedEffort: (requested: String, sent: String)?
    @ObservationIgnored private var latestInfo: BotJSON?
    @ObservationIgnored private var reportedModel: String?
    @ObservationIgnored private(set) var presetApplication: Task<Void, Never>?
    private let engine: HermesConversation

    init(engine: HermesConversation, loadsAvatars: Bool = false, openedBot: BotProfile? = nil) {
        self.engine = engine
        self.loadsAvatars = loadsAvatars
        profile = engine.target.profile
        mentions = BotMentions(roster: [], excluding: profile)
        if let openedBot { bots = [openedBot] }
        if loadsAvatars { avatars = BotAvatarStore.shared.images(connectionID: engine.connection.id) }
        controls.onPickedModelActive = { [weak self] option in self?.pickRan(option) }
    }

    private func pickRan(_ option: ModelCatalogOption) {
        reportedModel = option.id
        applyPreset(for: option)
    }

    private func applyPreset(for option: ModelCatalogOption) {
        let store = ModelPresetStore(server: engine.server)
        guard let preset = store.preset(for: option.favoriteKey) else { return }
        let context = controls.context
        presetApplication = Task { [weak self] in
            guard let self, liveModelKey == option.favoriteKey else { return }
            if let effort = preset.effort, effort != controls.effort, showsEffort, effortLevels.contains(effort) {
                _ = await select(effort: effort)
            }
            if let fast = preset.fast, fast != controls.fast, controls.showsFast,
               controls.context == context, liveModelKey == option.favoriteKey {
                _ = await select(fast: fast)
            }
        }
    }

    private var liveModelKey: ModelFavoriteKey? {
        guard let active = controls.catalog.active else { return nil }
        if let reportedModel, reportedModel != active.id { return nil }
        return active.favoriteKey
    }

    private func remember(_ model: ModelFavoriteKey?, _ record: (ModelPresetStore, ModelFavoriteKey) -> Void) {
        guard let model, model == liveModelKey else { return }
        record(ModelPresetStore(server: engine.server), model)
    }

    var selectedModel: ModelCatalogOption? { controls.pendingModel ?? controls.catalog.active }

    var profileOptions: [ProfileSummary] {
        profiles.map {
            ProfileSummary(name: $0, path: nil, isDefault: nil, isActive: nil, gatewayRunning: nil,
                           model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        }
    }

    func connect(runtime: String, attempt: Int) async {
        guard engine.generation == attempt, engine.connectionState == .connected else { return }
        let mutate: BotChatControls.Mutate? = engine.wire.speaksCanonicalProtocol ? { [engine] operation, check in
            try await engine.mutate(operation, attempt: attempt, runtime: runtime, stillCurrent: check)
        } : nil
        await controls.connect(.init(connectionID: engine.connection.id, profile: profile, runtime: runtime,
                                     generation: attempt), wire: engine.wire, mutate: mutate)
        guard engine.generation == attempt else { return }
        if let latestInfo { controls.snapshot(latestInfo) }
        await readProfiles(attempt: attempt)
    }

    func refreshProfiles() async {
        guard engine.connectionState == .connected else { return }
        await readProfiles(attempt: engine.generation)
    }

    private func readProfiles(attempt: Int) async {
        guard let roster = try? await engine.request(.profilesList(includeSessions: false), attempt: attempt),
              let rows = roster["profiles"].list else { return }
        var seen = Set<String>()
        profiles = rows.compactMap { $0["name"].text }.filter { !$0.isEmpty && seen.insert($0).inserted }
        bots = rows.compactMap(BotProfile.init)
        mentions = BotMentions(roster: bots, excluding: profile)
        onRosterRead?()
        guard loadsAvatars else { return }
        let store = BotAvatarStore.shared, connectionID = engine.connection.id
        await store.refresh(bots, connectionID: connectionID, using: engine.wire,
                            validateDispatch: { [engine] in try engine.check(attempt) }) {
            avatars = store.images(connectionID: connectionID)
            onAvatarsChange?()
        }
    }

    func disconnect() { reportedModel = nil; controls.disconnect() }

    func apply(info: BotJSON, idle: Bool) {
        latestInfo = info
        if let model = info["model"].text, !model.isEmpty { reportedModel = model }
        let awaited = controls.awaitsDeferredPick(named: info["model"].text)
        controls.snapshot(info)
        reportedEffort = info["reasoning_effort"].text.map { ($0, info["reasoning_effort_wire"].text ?? "") }
        if (idle && controls.pendingModel != nil) || awaited { controls.refresh() }
    }

    func select(_ option: ModelCatalogOption) async -> Bool {
        guard !option.matchesSelection(modelID: selectedModel?.id, providerID: selectedModel?.providerID),
              let action = controls.prepare(.model(option)) else { return false }
        await controls.apply(action)
        let picked = controls.errorMessage == nil && controls.confirmation == nil
        if picked { reportedEffort = nil }
        return picked
    }

    func model(matching query: String) -> ModelCatalogOption? {
        let query = query.lowercased()
        let options = controls.catalog.groups.flatMap(\.allModels)
        return options.first { $0.id.lowercased() == query }
            ?? options.first { $0.id.lowercased().contains(query) || $0.displayName.lowercased().contains(query) }
    }

    var showsEffort: Bool { controls.supportsEffort }

    var effortLevels: [String] {
        guard let active = controls.catalog.active,
              controls.catalog.capabilities[active.favoriteKey]?["can_disable_reasoning"].flag == false
        else { return HermesModelCatalog.effortLevels }
        return HermesModelCatalog.effortLevels.filter { $0 != "none" }
    }

    var sentEffort: String? {
        guard let reportedEffort, reportedEffort.requested == controls.effort, !reportedEffort.sent.isEmpty,
              reportedEffort.sent != reportedEffort.requested else { return nil }
        return reportedEffort.sent
    }

    func select(effort: String) async -> Bool {
        guard effortLevels.contains(effort), let action = controls.prepare(.effort(effort)) else { return false }
        let model = liveModelKey
        await controls.apply(action)
        let applied = controls.errorMessage == nil && controls.effort == effort
        if applied { remember(model) { $0.record(effort: effort, for: $1) } }
        return applied
    }

    var fast: Bool? { controls.showsFast ? controls.fast : nil }

    var mayChangeFast: Bool { controls.mayChangeFast }

    func select(fast enabled: Bool) async -> Bool {
        guard enabled != controls.fast, let action = controls.prepare(.fast(enabled)) else { return false }
        let model = liveModelKey
        await controls.apply(action)
        let applied = controls.errorMessage == nil && controls.fast == enabled
        if applied { remember(model) { $0.record(fast: enabled, for: $1) } }
        return applied
    }

    func personalities() async throws -> [(name: String, description: String)] {
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.stale }
        let reply = try await engine.request(.completeSlash(text: "/personality ", sessionID: runtime),
                                             attempt: engine.generation)
        guard let items = reply["items"].list else { throw BotFailure.unsupported }
        return items.compactMap { item in
            guard let name = item["text"].text?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  name != "none" else { return nil }
            return (name, item["meta"].text ?? "")
        }
    }

    func ask(personality name: String) { pendingPersonality = name }
    func cancelPersonality() { pendingPersonality = nil }

    func setPersonality(_ name: String) async throws {
        pendingPersonality = nil
        guard engine.connectionState == .connected, let runtime = engine.runtime else { throw BotFailure.stale }
        var dispatched = false
        do {
            let reply = try await engine.write(.configSet(sessionID: runtime, profile: profile, setting: .personality(name)),
                                               attempt: engine.generation, runtime: runtime) { dispatched = true }
            guard reply["key"].text == "personality" else { throw BotSettingFailure.unknownOutcome }
        } catch let failure as BotSettingFailure {
            throw failure
        } catch {
            throw dispatched ? BotSettingFailure.unknownOutcome : error
        }
    }
}
