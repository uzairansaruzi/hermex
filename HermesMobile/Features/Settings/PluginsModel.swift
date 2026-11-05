import Foundation
import Observation

/// The Plugins screen's state (#1582): the host's Profiles, the one shown, its plugins, and the host's
/// catalog. Every read goes to the host and nothing outlives the screen. A change shows only what the
/// host then reports, nothing is retried, and a restart is always a separate confirmed action.
@MainActor
@Observable
final class PluginsModel {
    enum State: Equatable {
        case loading
        case loaded([HermesPlugin])
        case failed(String)
    }

    enum Filter: CaseIterable, Hashable {
        case all, enabled, off, updates, yours

        func includes(_ plugin: HermesPlugin) -> Bool {
            switch self {
            case .all: true
            case .enabled: plugin.isEnabled
            case .off: !plugin.isEnabled
            case .updates: plugin.hasUpdate
            case .yours: !plugin.isBundled
            }
        }
    }

    /// One titled group of rows. A plugin is in only the first group it fits.
    struct Group: Identifiable, Equatable {
        enum Kind: Hashable { case updates, yours, bundled }
        let kind: Kind
        let plugins: [HermesPlugin]
        var id: Kind { kind }
    }

    /// A toggle waiting for the user's answer to its warning.
    struct PendingToggle: Equatable {
        let plugin: HermesPlugin
        let turningOn: Bool
        let warning: String
    }

    /// What the screen last learned about a change on the shown Profile.
    enum Notice: Equatable {
        case reported(String)
        case refused(String)
        /// The connection dropped or the host went quiet, so the change may or may not have applied.
        case unconfirmed(String)
    }

    enum Tab: Hashable { case installed, discover }

    enum CatalogState: Equatable {
        case idle, loading
        case loaded(HermesPluginCatalog)
        case failed(String)
    }

    /// What the install sheet's field resolves to.
    enum InstallReview: Equatable {
        case none
        case invalid
        case repo(String)
        case catalog(HermesCatalogEntry)
        /// A catalog name that isn't listed. It's never reinterpreted as a repository.
        case notInCatalog(String)
        /// A name Nous took out of the catalog, with its reason.
        case removed(String, reason: String)
        case loadingCatalog
        case catalogUnavailable(String)
    }

    /// How an install ended for the sheet that asked. Anything else it has to say goes in the notice.
    enum InstallResult: Equatable {
        /// The sheet can close, and the list shows what the host reported or that it's unconfirmed.
        case finished
        /// The host says this plugin is already there, the only case that offers Replace.
        case alreadyExists(String)
        case refused(String)
    }

    /// The keys a plugin installed just now needs before it can run.
    struct PluginSetup: Equatable {
        let profile: String
        let name: String
        var keys: [String]
    }

    private struct Target: Hashable {
        let profile: String
        let key: String
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    /// The Profile the screen lists and acts on, once the host has named its Profiles.
    private(set) var profile: String?
    private(set) var notice: Notice?
    private(set) var isRestarting = false
    var tab = Tab.installed
    var query = ""
    var filter = Filter.all
    /// The Discover category, or nil for all of them.
    var discoverCategory: String?
    var pendingToggle: PendingToggle?
    /// A user install waiting for the user to confirm its removal.
    var pendingRemoval: HermesPlugin?
    private(set) var catalog = CatalogState.idle
    private(set) var setup: PluginSetup?

    private let client: HermesPluginsClient
    private var stakes = HermesPluginStakes()
    /// Each toggle on its way to the host and the state it asked for.
    private var toggling: [Target: Bool] = [:]
    /// The plugins whose last change the host said needs a restart, until one is requested.
    private var awaitingRestart: Set<Target> = []
    /// Bumped by each read, so only the latest one applies after a Profile switch.
    @ObservationIgnored private var readSerial = 0
    /// Bumped by each change the host confirms, so a read that left before it goes out again.
    @ObservationIgnored private var changeSerial = 0
    @ObservationIgnored private var catalogLoad: Task<Void, Never>?

    init(client: HermesPluginsClient) { self.client = client }

    var plugins: [HermesPlugin] {
        if case .loaded(let plugins) = state { return plugins }
        return []
    }

    var needsRestart: Bool { awaitingRestart.contains { $0.profile == profile } }

    func count(of filter: Filter) -> Int { plugins.lazy.filter(filter.includes).count }

    /// The rows the filter and search leave, grouped as the screen lists them.
    var groups: [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = plugins.filter { plugin in
            filter.includes(plugin) && (query.isEmpty || [plugin.name, plugin.key, plugin.summary].contains {
                $0.localizedCaseInsensitiveContains(query)
            })
        }
        let updates = shown.filter(\.hasUpdate)
        let others = shown.filter { !$0.hasUpdate }
        return [Group(kind: .updates, plugins: updates),
                Group(kind: .yours, plugins: others.filter { !$0.isBundled }),
                Group(kind: .bundled, plugins: others.filter(\.isBundled))].filter { !$0.plugins.isEmpty }
    }

    /// Reads the host's Profiles, keeping the shown one while it still exists and otherwise
    /// starting on the default, then that Profile's plugins.
    func load() async {
        if case .failed = state { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true { show(listed.initial) }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(Self.message(for: error)) }
            return
        }
        await read()
    }

    func select(_ name: String) async {
        guard name != profile else { return }
        show(name)
        await read()
    }

    /// Whether `plugin`'s row reads as on: what a toggle in flight asked for, else what the host said.
    func isOn(_ plugin: HermesPlugin) -> Bool {
        profile.flatMap { toggling[Target(profile: $0, key: plugin.key)] } ?? plugin.isEnabled
    }

    func isToggling(_ plugin: HermesPlugin) -> Bool {
        profile.map { toggling[Target(profile: $0, key: plugin.key)] != nil } ?? false
    }

    /// The row's switch: one that needs a warning waits for the answer, any other applies at once.
    func requestToggle(_ plugin: HermesPlugin, to turningOn: Bool) {
        guard !isToggling(plugin) else { return }
        if let warning = stakes.warning(for: plugin, turningOn: turningOn) {
            pendingToggle = PendingToggle(plugin: plugin, turningOn: turningOn, warning: warning)
        } else {
            Task { await apply(plugin, turningOn: turningOn) }
        }
    }

    /// The user accepted the pending toggle's warning.
    func confirmPendingToggle() {
        guard let pendingToggle else { return }
        self.pendingToggle = nil
        Task { await apply(pendingToggle.plugin, turningOn: pendingToggle.turningOn) }
    }

    /// The catalog, read once while the screen is open. The read belongs to the model, so a caller
    /// cancelled by the next keystroke doesn't take it down. A failed read can be tried again.
    func loadCatalog() async {
        if catalogLoad == nil {
            catalog = .loading
            catalogLoad = Task { [client] in
                do {
                    catalog = .loaded(try await client.catalog())
                } catch {
                    catalog = .failed(String(localized: "This host's catalog isn't available. You can still install from a repository."))
                    catalogLoad = nil
                }
            }
        }
        await catalogLoad?.value
    }

    /// What Discover lists now, or nothing until the catalog arrives.
    var discoverGroups: [PluginDiscoverGroup] {
        guard case .loaded(let catalog) = catalog else { return [] }
        return catalog.groups(query: query, category: discoverCategory)
    }

    var discoverCategories: [String] {
        guard case .loaded(let catalog) = catalog else { return [] }
        return catalog.categories
    }

    /// The catalog entries on the shown Profile, or nil until its list is read, which is no time to
    /// offer an install. The catalog's own `installed` field isn't used, because its route reads only
    /// the dashboard's Profile.
    var installedCatalogNames: Set<String>? {
        guard case .loaded(let plugins) = state else { return nil }
        return Set(plugins.map { $0.catalogName ?? $0.name })
    }

    /// Why Nous took `plugin` out of the catalog, once the catalog has arrived.
    func removalReason(for plugin: HermesPlugin) -> String? {
        guard !plugin.isBundled, case .loaded(let catalog) = catalog else { return nil }
        return catalog.removalReasons[plugin.catalogName ?? plugin.name]
    }

    /// Resolves the install field against the catalog. A removal reason wins, so a name Nous took out
    /// is never offered.
    func review(of input: PluginInstallInput) -> InstallReview {
        switch input {
        case .empty: return .none
        case .invalid: return .invalid
        case .repo(let identifier): return .repo(identifier)
        case .catalogName(let name):
            switch catalog {
            case .idle, .loading: return .loadingCatalog
            case .failed(let message): return .catalogUnavailable(message)
            case .loaded(let catalog):
                if let reason = catalog.removalReasons[name] { return .removed(name, reason: reason) }
                return catalog.entries[name].map(InstallReview.catalog) ?? .notInCatalog(name)
            }
        }
    }

    func isTooNew(_ entry: HermesCatalogEntry) -> Bool { entry.isTooNew(forHost: client.hostVersion) }

    /// Installs on `profile`, which the sheet fixed when it opened, then reads the list again. Nothing
    /// here retries: `replace` comes only from the user answering `.alreadyExists`, and a lost reply
    /// ends as an unconfirmed notice.
    func install(_ source: HermesPluginSource, profile: String, replace: Bool, enable: Bool) async -> InstallResult {
        do {
            let install = try await client.install(source, profile: profile, replace: replace, enable: enable)
            let target = Target(profile: profile, key: install.name)
            if install.change.needsRestart { awaitingRestart.insert(target) } else { awaitingRestart.remove(target) }
            changeSerial += 1
            if self.profile == profile {
                notice = .reported(Self.report(install, profile: profile))
                setup = install.missingKeys.isEmpty ? nil : PluginSetup(profile: profile, name: install.name, keys: install.missingKeys)
                await read()
            }
            return .finished
        } catch BotSettingFailure.rejected(_, let message) {
            // The plugin can be on disk after a refused enable, so the list is read either way.
            if self.profile == profile { await read() }
            // The host's only signal at the pin is its sentence for this refusal.
            return message.contains("already exists") ? .alreadyExists(message) : .refused(message)
        } catch {
            if self.profile == profile {
                notice = .unconfirmed(String(localized: "The server didn't confirm the install of \(Self.name(of: source)). This list shows what it reports now, so check it before trying again."))
                await read()
            }
            return .finished
        }
    }

    /// Writes one key `setup` asked for, then takes it off the list. Throws the host's refusal.
    func saveKey(_ name: String, value: String) async throws {
        guard let setup else { return }
        try await client.saveKey(name, value: value, profile: setup.profile)
        // A switch while it was saving ended this setup, and any new one isn't what was saved.
        guard self.setup?.profile == setup.profile, self.setup?.name == setup.name else { return }
        notice = .reported(String(localized: "\(name) is saved on \(setup.profile)."))
        self.setup?.keys.removeAll { $0 == name }
        if self.setup?.keys.isEmpty == true { self.setup = nil }
    }

    func dismissSetup() { setup = nil }

    /// The user confirmed the pending removal. Synchronous, because the alert clears `pendingRemoval`
    /// as it closes, before a task started from its button would run.
    func confirmPendingRemoval() {
        guard let pendingRemoval else { return }
        self.pendingRemoval = nil
        Task { await remove(pendingRemoval) }
    }

    /// Removes a user install from the Profile shown when it was asked for.
    func remove(_ plugin: HermesPlugin) async {
        guard let profile else { return }
        let target = Target(profile: profile, key: plugin.key)
        guard toggling[target] == nil else { return }
        toggling[target] = false
        notice = nil
        do {
            let clearedMemory = try await client.remove(key: plugin.key, profile: profile)
            toggling[target] = nil
            awaitingRestart.remove(target)
            changeSerial += 1
            guard self.profile == profile else { return }
            notice = .reported(clearedMemory
                ? String(localized: "\(plugin.name) is removed from \(profile), which is back on its built-in memory.")
                : String(localized: "\(plugin.name) is removed from \(profile)."))
            await read()
        } catch BotSettingFailure.rejected(_, let message) {
            toggling[target] = nil
            if self.profile == profile { notice = .refused(message) }
        } catch {
            toggling[target] = nil
            guard self.profile == profile else { return }
            notice = .unconfirmed(String(localized: "The server didn't confirm removing \(plugin.name). This list shows what it reports now."))
            await read()
        }
    }

    /// Sends one toggle for the Profile shown when it was asked for. Its outcome reaches the
    /// screen only while that Profile is still shown. Nothing here retries.
    func apply(_ plugin: HermesPlugin, turningOn: Bool) async {
        guard let profile else { return }
        let target = Target(profile: profile, key: plugin.key)
        guard toggling[target] == nil else { return }
        toggling[target] = turningOn
        notice = nil
        do {
            let change = try await client.setPlugin(key: plugin.key, enabled: turningOn, profile: profile)
            toggling[target] = nil
            if change.needsRestart { awaitingRestart.insert(target) }
            else if !change.isUnchanged { awaitingRestart.remove(target) }
            guard self.profile == profile else { return }
            notice = .reported(Self.report(change, name: plugin.name, turningOn: turningOn, profile: profile))
            if let row = change.plugin {
                changeSerial += 1
                replace(row)
            } else {
                await read()
            }
        } catch BotSettingFailure.rejected(_, let message) {
            toggling[target] = nil
            if self.profile == profile { notice = .refused(message) }
        } catch {
            toggling[target] = nil
            guard self.profile == profile else { return }
            notice = .unconfirmed(String(localized: "The server didn't confirm the change to \(plugin.name). This list shows what it reports now."))
            await read()
        }
    }

    /// Asks the host to restart the shown Profile's gateway, after the user confirmed it.
    func restartGateway() async {
        guard let profile, !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        do {
            try await client.restartGateway(profile: profile)
            awaitingRestart = awaitingRestart.filter { $0.profile != profile }
            if self.profile == profile { notice = .reported(String(localized: "The gateway for \(profile) is restarting.")) }
        } catch {
            if self.profile == profile { notice = .refused(Self.message(for: error)) }
        }
    }

    /// Shows `name` with nothing carried over from the Profile before it.
    private func show(_ name: String) {
        profile = name
        state = .loading
        notice = nil
        pendingToggle = nil
        pendingRemoval = nil
        setup = nil
        stakes = HermesPluginStakes()
    }

    private func replace(_ row: HermesPlugin) {
        guard case .loaded(var plugins) = state, let index = plugins.firstIndex(where: { $0.key == row.key }) else { return }
        plugins[index] = row
        state = .loaded(plugins)
    }

    /// Lists the shown Profile's plugins, then reads what it relies on. Until that arrives every
    /// plugin it might cover asks first, so a slow read never skips a warning.
    private func read() async {
        guard let profile else { return }
        readSerial += 1
        let serial = readSerial, change = changeSerial
        do {
            let plugins = try await client.plugins(profile: profile)
            guard serial == readSerial else { return }
            guard change == changeSerial else { return await read() }
            state = .loaded(plugins)
            // Only the catalog knows what Nous removed, and only a user install can be on that list.
            if plugins.contains(where: { !$0.isBundled }), catalog == .idle { Task { await loadCatalog() } }
        } catch {
            guard serial == readSerial else { return }
            guard change == changeSerial else { return await read() }
            if !Task.isCancelled { state = .failed(Self.message(for: error)) }
            return
        }
        let stakes = await client.stakes(profile: profile)
        if self.profile == profile { self.stakes = stakes }
    }

    /// A host without `plugins.manage` says so, rather than the connection's generic refusal.
    private static func message(for error: Error) -> String {
        if case BotFailure.rejected(-32601) = error {
            return String(localized: "This Hermes host can't manage plugins from Hermex. Update Hermes on the host, then try again.")
        }
        return error.localizedDescription
    }

    private static func name(of source: HermesPluginSource) -> String {
        switch source {
        case .catalog(let name, _): name
        case .repo(let identifier): identifier
        }
    }

    private static func report(_ install: HermesPluginInstall, profile: String) -> String {
        let name = install.name
        var report: String
        switch (install.isEnabled, install.change.needsRestart, install.change.waitsForNextSession) {
        case (false, _, _): report = String(localized: "\(name) is installed on \(profile) and turned off.")
        case (true, true, _): report = String(localized: "\(name) is installed on \(profile). It takes full effect after a restart.")
        case (true, false, true): report = String(localized: "\(name) is installed on \(profile). New tools start in new sessions.")
        case (true, false, false): report = String(localized: "\(name) is installed on \(profile) and live now.")
        }
        for server in install.change.failedServers {
            report += " " + String(localized: "MCP server \(server) didn't connect.")
        }
        return report
    }

    private static func report(_ change: HermesPluginChange, name: String, turningOn: Bool, profile: String) -> String {
        if change.isUnchanged {
            return turningOn ? String(localized: "\(name) was already on for \(profile).")
                : String(localized: "\(name) was already off for \(profile).")
        }
        var report: String
        switch (turningOn, change.needsRestart, change.waitsForNextSession) {
        case (true, true, _): report = String(localized: "\(name) is on for \(profile). It takes full effect after a restart.")
        case (true, false, true): report = String(localized: "\(name) is on for \(profile). New tools start in new sessions.")
        case (true, false, false): report = String(localized: "\(name) is on for \(profile) and live now.")
        case (false, true, _): report = String(localized: "\(name) is off for \(profile). It stops fully after a restart.")
        case (false, false, _): report = String(localized: "\(name) is off for \(profile).")
        }
        for server in change.failedServers {
            report += " " + String(localized: "MCP server \(server) didn't connect.")
        }
        return report
    }
}
