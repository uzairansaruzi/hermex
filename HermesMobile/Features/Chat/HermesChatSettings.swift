import Foundation
import Observation
import UIKit

/// The Profile a new Hermes session starts in, remembered per server (#1015). It is client
/// state: never written to the host, whose `POST /api/profiles/active` would move the CLI's
/// and gateways' default. Sign-out and server removal clear it (`AuthManager`).
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

    /// Whether the server's Sessions list shows every Profile's sessions (#709). The pick still
    /// names the Profile New Session opens in.
    static func showsAllProfiles(for server: URL, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showsAllKey(for: server))
    }

    static func saveShowsAllProfiles(_ showsAll: Bool, for server: URL, in defaults: UserDefaults = .standard) {
        if showsAll { defaults.set(true, forKey: showsAllKey(for: server)) } else { defaults.removeObject(forKey: showsAllKey(for: server)) }
    }

    private static func showsAllKey(for server: URL) -> String {
        "hermes.sessionsShowAllProfiles|\(server.absoluteString)"
    }

    /// The Profile New Session opens in: the saved pick while `listed` (a fresh
    /// `profiles.list`) still has it, else the host's `current`. A pick the host no longer
    /// lists is dropped without a word; an empty list proves nothing, so it keeps the pick.
    static func resolve(for server: URL, listed: [String], current: String,
                        in defaults: UserDefaults = .standard) -> String {
        guard let saved = defaults.string(forKey: key(for: server)) else { return current }
        guard !listed.isEmpty else { return current }
        if listed.contains(saved) { return saved }
        save(nil, for: server, in: defaults)
        return current
    }
}

/// A Hermes session's model, effort, Fast and Profile chips in the main chat's composer (#1015,
/// #1016, #1142), and its `/personality` command. `HermesChatTurnCoordinator` owns it and connects
/// it on each attach.
///
/// The model rides `BotChatControls` on the session's runtime: the catalog is
/// `model.options` for the chat's Profile, and a pick goes out once as `config.set` with
/// `--session`, so the next chat in the Profile still starts on its default. The host may
/// ask to confirm an expensive model (`confirmation`) or apply the pick after the running
/// response (`pendingModel`). A new chat's session exists from the moment it opens, so a pick
/// there is sent at once, like any other.
///
/// Effort is session-scoped like the model: one `config.set` reasoning for this chat, never a
/// display word. The host may send a lower level than the one picked when the model's route
/// can't take it; `session.info` reports that as `reasoning_effort_wire` (`sentEffort`).
///
/// Fast is session-scoped too: one `config.set fast` for this chat, shown only from the host's
/// answer (#1142). The host may fall back to the Profile's default if the runtime goes away
/// mid-dispatch, an accepted limitation (#508).
///
/// A personality is Profile-wide: the host has no session-only one, so a confirmed change
/// writes the Profile's default and switches this session too.
///
/// The Profile chip lists `profiles.list`. A session's Profile never changes: picking another
/// starts a new chat in it (`ChatView`).
@MainActor @Observable final class HermesChatSettings {
    let controls = BotChatControls()
    /// The session's Profile.
    let profile: String
    /// The host's Profiles, from the latest attach's `profiles.list`; empty until it answers.
    private(set) var profiles: [String] = []
    /// The same read's rows as bots: a Bot Chat's pill (#1145).
    private(set) var bots: [BotProfile] = []
    /// Those bots as `@`mention completions, without this chat's own Profile; built once per read.
    private(set) var mentions: BotMentions
    /// A Bot Chat's bots' pictures by Profile, for its pill and `@` panel, from the shared
    /// `BotAvatarStore`: what it already holds at once, then each fetched picture as it arrives.
    /// Empty for a session, which loads none.
    private(set) var avatars: [String: UIImage] = [:]
    /// Loads `avatars` after each roster read: only a Bot Chat's.
    private let loadsAvatars: Bool
    /// Called after each `profiles.list` read lands, so a Bot Chat's activity takes the bot's look.
    @ObservationIgnored var onRosterRead: (() -> Void)?
    /// Called each time `avatars` changes, so a Bot Chat's activity draws the bot's picture.
    @ObservationIgnored var onAvatarsChange: (() -> Void)?
    /// A `/personality` name waiting for the user to confirm the Profile-wide change.
    private(set) var pendingPersonality: String?
    /// The latest `session.info`'s requested effort and the level its route sends.
    private var reportedEffort: (requested: String, sent: String)?
    /// The latest `session.info`, applied again once an attach reconnects the controls.
    @ObservationIgnored private var latestInfo: BotJSON?
    private let engine: HermesConversation

    init(engine: HermesConversation, loadsAvatars: Bool = false) {
        self.engine = engine
        self.loadsAvatars = loadsAvatars
        profile = engine.target.profile
        mentions = BotMentions(roster: [], excluding: profile)
    }

    /// The model the chip shows: a pick waiting for the running response, else the
    /// runtime's live model.
    var selectedModel: ModelCatalogOption? { controls.pendingModel ?? controls.catalog.active }

    var profileOptions: [ProfileSummary] {
        profiles.map {
            ProfileSummary(name: $0, path: nil, isDefault: nil, isActive: nil, gatewayRunning: nil,
                           model: nil, provider: nil, hasEnv: nil, skillCount: nil)
        }
    }

    /// Reads the catalog for `runtime` and the host's Profiles, and restores the effort and Fast
    /// mode the attach's `session.info` reported, which connecting clears. Nothing reads for an
    /// attach that is no longer current, and a failed Profile read keeps the last list.
    func connect(runtime: String, attempt: Int) async {
        guard engine.generation == attempt, engine.connectionState == .connected else { return }
        await controls.connect(.init(connectionID: engine.connection.id, profile: profile, runtime: runtime,
                                     generation: attempt), wire: engine.wire)
        guard engine.generation == attempt else { return }
        if let latestInfo { controls.snapshot(latestInfo) }
        await readProfiles(attempt: attempt)
    }

    /// Reads the host's Profiles again, as after the bot's profile editor closes. Nothing is
    /// read while disconnected, and a failed read keeps the last list.
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
        // A chat opened straight from its row never passes the Bots inbox, which loads them too.
        // A newer attach ends the pass, as its own read loads them again.
        let store = BotAvatarStore.shared, connectionID = engine.connection.id
        await store.refresh(bots, connectionID: connectionID, using: engine.wire,
                            validateDispatch: { [engine] in try engine.check(attempt) }) {
            avatars = store.images(connectionID: connectionID)
            onAvatarsChange?()
        }
    }

    func disconnect() { controls.disconnect() }

    /// A `session.info` frame, or an attach's `session.resume` info. Once a turn ends with a
    /// pick still waiting on it, the catalog is read again for the model the host now runs.
    func apply(info: BotJSON, idle: Bool) {
        latestInfo = info
        controls.snapshot(info)
        reportedEffort = info["reasoning_effort"].text.map { ($0, info["reasoning_effort_wire"].text ?? "") }
        if idle, controls.pendingModel != nil { controls.refresh() }
    }

    /// Sends `option` for this session; false when it can't go now or the host refused it.
    /// A pick the host wants confirmed returns false with `controls.confirmation` set.
    func select(_ option: ModelCatalogOption) async -> Bool {
        guard !option.matchesSelection(modelID: selectedModel?.id, providerID: selectedModel?.providerID),
              let action = controls.prepare(.model(option)) else { return false }
        await controls.apply(action)
        let picked = controls.errorMessage == nil && controls.confirmation == nil
        // The last level sent was the old model's; the next `session.info` reports the new one's.
        if picked { reportedEffort = nil }
        return picked
    }

    /// The catalog's model `query` names, by id first, then by any id or name containing it.
    func model(matching query: String) -> ModelCatalogOption? {
        let query = query.lowercased()
        let options = controls.catalog.groups.flatMap(\.allModels)
        return options.first { $0.id.lowercased() == query }
            ?? options.first { $0.id.lowercased().contains(query) || $0.displayName.lowercased().contains(query) }
    }

    // MARK: Reasoning

    /// The effort menu shows unless the host marks the live model `reasoning: false`.
    var showsEffort: Bool { controls.supportsEffort }

    /// The host's ladder for the live model, without `none` when it can't turn reasoning off.
    var effortLevels: [String] {
        guard let active = controls.catalog.active,
              controls.catalog.capabilities[active.favoriteKey]?["can_disable_reasoning"].flag == false
        else { return HermesModelCatalog.effortLevels }
        return HermesModelCatalog.effortLevels.filter { $0 != "none" }
    }

    /// The level the host sends for the chosen effort when the model's route takes less; nil
    /// when they match, or until a `session.info` reports the chosen effort.
    var sentEffort: String? {
        guard let reportedEffort, reportedEffort.requested == controls.effort, !reportedEffort.sent.isEmpty,
              reportedEffort.sent != reportedEffort.requested else { return nil }
        return reportedEffort.sent
    }

    /// Sends `effort` for this chat only; false when it can't go now or the host refused it.
    func select(effort: String) async -> Bool {
        guard effortLevels.contains(effort), let action = controls.prepare(.effort(effort)) else { return false }
        await controls.apply(action)
        return controls.errorMessage == nil && controls.effort == effort
    }

    // MARK: Fast

    /// The Fast chip's mode, nil to hide it: shown once `session.info` reports one, on a model
    /// whose capabilities don't rule it out, and kept while on so it can be turned off.
    var fast: Bool? { controls.showsFast ? controls.fast : nil }

    /// Whether Fast can change now: not while another change applies or the catalog loads,
    /// nor once the host refused `config.set`.
    var mayChangeFast: Bool { controls.mayChangeFast }

    /// Turns Fast on or off for this chat only; false when it can't go now or the host refused
    /// it. The chip takes the mode only from a reply naming it.
    func select(fast enabled: Bool) async -> Bool {
        guard enabled != controls.fast, let action = controls.prepare(.fast(enabled)) else { return false }
        await controls.apply(action)
        return controls.errorMessage == nil && controls.fast == enabled
    }

    // MARK: Personality

    /// The host's personalities and their descriptions, `none` left out.
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

    /// Holds `name` until the user confirms or cancels the Profile-wide change.
    func ask(personality name: String) { pendingPersonality = name }
    func cancelPersonality() { pendingPersonality = nil }

    /// Writes a confirmed personality as the Profile's default and switches this session to
    /// it, once. Throws the host's refusal as `BotSettingFailure` (an unknown name answers
    /// 5001), and `unknownOutcome` when the write went out but its reply was lost.
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
