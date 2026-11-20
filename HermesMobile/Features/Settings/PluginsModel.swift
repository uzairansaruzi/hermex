import Foundation
import Observation

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

    struct Group: Identifiable, Equatable {
        enum Kind: Hashable { case updates, yours, bundled }
        let kind: Kind
        let plugins: [HermesPlugin]
        var id: Kind { kind }
    }

    struct PendingToggle: Equatable {
        let plugin: HermesPlugin
        let turningOn: Bool
        let warning: String
    }

    enum Notice: Equatable {
        case reported(String)
        case refused(String)
        case unconfirmed(String)
    }

    enum Tab: Hashable { case installed, discover }

    enum CatalogState: Equatable {
        case idle, loading
        case loaded(HermesPluginCatalog)
        case failed(String)
    }

    enum InstallReview: Equatable {
        case none
        case invalid
        case repo(String)
        case catalog(HermesCatalogEntry)
        case notInCatalog(String)
        case removed(String, reason: String)
        case loadingCatalog
        case catalogUnavailable(String)
    }

    enum InstallResult: Equatable {
        case finished
        case alreadyExists(String)
        case refused(String)
    }

    struct UpdateReview: Identifiable, Equatable {
        enum Reason: Equatable {
            case newAbilities([String])
            case scan(canOverride: Bool, findings: [HermesPluginUpdate.Finding])
        }

        let plugin: HermesPlugin
        let profile: String
        let reason: Reason
        let acceptedCapabilities: Bool
        var id: String { plugin.key }
    }

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
    private(set) var profile: String?
    private(set) var notice: Notice?
    private(set) var isRestarting = false
    var tab = Tab.installed
    var query = ""
    var filter = Filter.all
    var discoverCategory: String?
    var pendingToggle: PendingToggle?
    var pendingRemoval: HermesPlugin?
    private(set) var catalog = CatalogState.idle
    private(set) var setup: PluginSetup?
    var updateReview: UpdateReview?

    private let client: HermesPluginsClient
    private var stakes = HermesPluginStakes()
    private var toggling: [Target: Bool] = [:]
    private var awaitingRestart: Set<Target> = []
    @ObservationIgnored private var readSerial = 0
    @ObservationIgnored private var changeSerial = 0
    @ObservationIgnored private var catalogLoad: Task<Void, Never>?

    init(client: HermesPluginsClient) { self.client = client }

    var plugins: [HermesPlugin] {
        if case .loaded(let plugins) = state { return plugins }
        return []
    }

    var needsRestart: Bool { awaitingRestart.contains { $0.profile == profile } }

    func count(of filter: Filter) -> Int { plugins.lazy.filter(filter.includes).count }

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

    func isOn(_ plugin: HermesPlugin) -> Bool {
        profile.flatMap { toggling[Target(profile: $0, key: plugin.key)] } ?? plugin.isEnabled
    }

    func isToggling(_ plugin: HermesPlugin) -> Bool {
        profile.map { toggling[Target(profile: $0, key: plugin.key)] != nil } ?? false
    }

    func requestToggle(_ plugin: HermesPlugin, to turningOn: Bool) {
        guard !isToggling(plugin) else { return }
        if let warning = stakes.warning(for: plugin, turningOn: turningOn) {
            pendingToggle = PendingToggle(plugin: plugin, turningOn: turningOn, warning: warning)
        } else {
            Task { await apply(plugin, turningOn: turningOn) }
        }
    }

    func confirmPendingToggle() {
        guard let pendingToggle else { return }
        self.pendingToggle = nil
        Task { await apply(pendingToggle.plugin, turningOn: pendingToggle.turningOn) }
    }

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

    var discoverGroups: [PluginDiscoverGroup] {
        guard case .loaded(let catalog) = catalog else { return [] }
        return catalog.groups(query: query, category: discoverCategory)
    }

    var discoverCategories: [String] {
        guard case .loaded(let catalog) = catalog else { return [] }
        return catalog.categories
    }

    var installedCatalogNames: Set<String>? {
        guard case .loaded(let plugins) = state else { return nil }
        return Set(plugins.map { $0.catalogName ?? $0.name })
    }

    func removalReason(for plugin: HermesPlugin) -> String? {
        guard !plugin.isBundled, case .loaded(let catalog) = catalog else { return nil }
        return catalog.removalReasons[plugin.catalogName ?? plugin.name]
    }

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
            if self.profile == profile { await read() }
            return message.contains("already exists") ? .alreadyExists(message) : .refused(message)
        } catch {
            if self.profile == profile {
                notice = .unconfirmed(String(localized: "The server didn't confirm the install of \(Self.name(of: source)). This list shows what it reports now, so check it before trying again."))
                await read()
            }
            return .finished
        }
    }

    func saveKey(_ name: String, value: String) async throws {
        guard let setup else { return }
        try await client.saveKey(name, value: value, profile: setup.profile)
        _ = try? await client.saveSettings(key: setup.name, values: [:], profile: setup.profile)
        guard self.setup?.profile == setup.profile, self.setup?.name == setup.name else { return }
        notice = .reported(String(localized: "\(name) is saved on \(setup.profile)."))
        self.setup?.keys.removeAll { $0 == name }
        if self.setup?.keys.isEmpty == true { self.setup = nil }
    }

    func dismissSetup() { setup = nil }

    func update(_ plugin: HermesPlugin) async {
        guard let profile else { return }
        await update(plugin, profile: profile, acceptCapabilities: false, acceptCaution: false)
    }

    private func update(_ plugin: HermesPlugin, profile: String, acceptCapabilities: Bool, acceptCaution: Bool) async {
        let target = Target(profile: profile, key: plugin.key)
        guard toggling[target] == nil else { return }
        toggling[target] = plugin.isEnabled
        notice = nil
        defer { toggling[target] = nil }
        do {
            let update = try await client.update(key: plugin.key, profile: profile, acceptCapabilities: acceptCapabilities, acceptCaution: acceptCaution)
            switch update {
            case .finished(let change):
                if change.needsRestart { awaitingRestart.insert(target) }
                changeSerial += 1
                guard self.profile == profile else { return }
                notice = .reported(Self.report(update: change, name: plugin.name, profile: profile))
                await read()
            case .needsConsent(let abilities):
                guard self.profile == profile else { return }
                updateReview = UpdateReview(plugin: plugin, profile: profile, reason: .newAbilities(abilities), acceptedCapabilities: acceptCapabilities)
            case .blockedByScan(let canOverride, let findings):
                guard self.profile == profile else { return }
                updateReview = UpdateReview(plugin: plugin, profile: profile, reason: .scan(canOverride: canOverride, findings: findings), acceptedCapabilities: acceptCapabilities)
            }
        } catch BotSettingFailure.rejected(_, let message) {
            if self.profile == profile { notice = .refused(message) }
        } catch {
            guard self.profile == profile else { return }
            notice = .unconfirmed(String(localized: "The server didn't confirm the update of \(plugin.name). This list shows what it reports now."))
            await read()
        }
    }

    func accept(_ review: UpdateReview) {
        guard review == updateReview, review.profile == profile else { return }
        let acceptsCaution: Bool
        switch review.reason {
        case .newAbilities: acceptsCaution = false
        case .scan(let canOverride, _):
            guard canOverride else { return }
            acceptsCaution = true
        }
        updateReview = nil
        Task {
            await update(review.plugin, profile: review.profile,
                         acceptCapabilities: review.acceptedCapabilities || !acceptsCaution, acceptCaution: acceptsCaution)
        }
    }

    func saveSettings(_ plugin: HermesPlugin, values: [String: BotJSON]) async -> String? {
        guard let profile else { return nil }
        do {
            let row = try await client.saveSettings(key: plugin.key, values: values, profile: profile)
            changeSerial += 1
            guard self.profile == profile else { return nil }
            notice = .reported(String(localized: "\(plugin.name)'s settings are saved on \(profile)."))
            if let row { replace(row) } else { await read() }
            return nil
        } catch BotSettingFailure.rejected(_, let message) {
            return message
        } catch {
            guard self.profile == profile else { return nil }
            notice = .unconfirmed(String(localized: "The server didn't confirm the settings for \(plugin.name). This page shows what it reports now."))
            await read()
            return nil
        }
    }

    func setSecret(_ env: String, value: String?, of plugin: HermesPlugin) async throws {
        guard let profile else { return }
        if let value {
            try await client.saveKey(env, value: value, profile: profile)
        } else {
            try await client.removeKey(env, profile: profile)
        }
        _ = try? await client.saveSettings(key: plugin.key, values: [:], profile: profile)
        guard self.profile == profile else { return }
        notice = .reported(value == nil ? String(localized: "\(env) is removed from \(profile).") : String(localized: "\(env) is saved on \(profile)."))
        await read()
    }

    func confirmPendingRemoval() {
        guard let pendingRemoval else { return }
        self.pendingRemoval = nil
        Task { await remove(pendingRemoval) }
    }

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

    private func show(_ name: String) {
        profile = name
        state = .loading
        notice = nil
        pendingToggle = nil
        pendingRemoval = nil
        updateReview = nil
        setup = nil
        stakes = HermesPluginStakes()
    }

    private func replace(_ row: HermesPlugin) {
        guard case .loaded(var plugins) = state, let index = plugins.firstIndex(where: { $0.key == row.key }) else { return }
        plugins[index] = row
        state = .loaded(plugins)
    }

    private func read() async {
        guard let profile else { return }
        readSerial += 1
        let serial = readSerial, change = changeSerial
        do {
            let plugins = try await client.plugins(profile: profile)
            guard serial == readSerial else { return }
            guard change == changeSerial else { return await read() }
            state = .loaded(plugins)
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

    private static func report(update change: HermesPluginChange, name: String, profile: String) -> String {
        if change.isUnchanged { return String(localized: "\(name) is already up to date on \(profile).") }
        var report: String
        switch (change.needsRestart, change.waitsForNextSession) {
        case (true, _): report = String(localized: "\(name) is updated on \(profile). It takes full effect after a restart.")
        case (false, true): report = String(localized: "\(name) is updated on \(profile). New tools start in new sessions.")
        case (false, false): report = String(localized: "\(name) is updated on \(profile) and live now.")
        }
        for server in change.failedServers {
            report += " " + String(localized: "MCP server \(server) didn't connect.")
        }
        return report
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
