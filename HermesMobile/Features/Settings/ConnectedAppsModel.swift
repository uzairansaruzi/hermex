import Foundation
import Observation

/// The Connected Apps screen's state (#1629): the host's Profiles, the one shown, and the apps
/// its Nous account can connect. Every read goes to the host; nothing is kept past the screen.
@MainActor
@Observable
final class ConnectedAppsModel {
    enum State: Equatable {
        case loading
        case loaded([HermesConnectedApp])
        /// The host has no Connected Apps for this Profile, and says why.
        case deadEnd(HermesConnectedAppsDeadEnd)
        case failed(String)
    }

    /// The apps under one heading, in the order the screen lists them.
    struct Section: Identifiable, Equatable {
        let id: String
        let apps: [HermesConnectedApp]
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    /// The Profile the screen lists and acts on, once the host has named its Profiles.
    private(set) var profile: String?
    /// The app whose connect, cancel or disconnect is in flight. One at a time: each ends in a
    /// fresh read, and a second one started meanwhile would act on rows about to change.
    private(set) var busyApp: String?
    /// The last action's refusal, for the screen's alert.
    var actionError: String?
    var query = ""
    /// The category chip chosen, nil for All. It filters only the apps not yet connected.
    var category: String?

    private let client: HermesConnectedAppsClient
    /// Bumped by each read, so only the latest one applies after a Profile switch.
    @ObservationIgnored private var readSerial = 0

    init(client: HermesConnectedAppsClient) { self.client = client }

    var apps: [HermesConnectedApp] {
        if case .loaded(let apps) = state { return apps }
        return []
    }

    /// Every category the catalog names, in alphabetical order, for the chips.
    var categories: [String] {
        Set(apps.map(\.category)).subtracting([""]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The apps that have an account, whatever its state, matching the search.
    var connected: [HermesConnectedApp] {
        searched.filter { !$0.accounts.isEmpty }
    }

    /// The apps with no account, matching the search and the chosen chip, by category.
    var available: [Section] {
        let rest = searched.filter { $0.accounts.isEmpty && (category == nil || $0.category == category) }
        return Dictionary(grouping: rest, by: \.category)
            .map { Section(id: $0.key, apps: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func app(_ id: String) -> HermesConnectedApp? { apps.first { $0.id == id } }

    /// Reads the host's Profiles, keeping the shown one while it still exists and otherwise
    /// starting on the default, then that Profile's apps. A newer read or a Profile switch
    /// supersedes it, so an overlapping refresh never replaces a later result.
    func load() async {
        if !isLoaded { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true {
                // The shown Profile is gone: its apps must not stay tappable under the new one.
                profile = listed.initial
                state = .loading
            }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
            return
        }
        await loadApps()
    }

    /// Shows another Profile's apps. Not while an action is in flight: its sign-in would open,
    /// and its result land, under a Profile it was not started for.
    func select(_ name: String) async {
        guard name != profile, busyApp == nil else { return }
        profile = name
        category = nil
        state = .loading
        await loadApps()
    }

    /// Starts `app`'s sign-in, or repairs its broken account, shows the link through `browse`, and
    /// reads the list again once the browser closes, however it closed. Continue on a waiting
    /// row is this too: the host hands back the sign-in that is still open.
    func connect(_ app: HermesConnectedApp, browse: (URL) async -> Void) async {
        await act(on: app) { profile in
            let repairing = app.state == .needsReconnect ? app.accountToRepair : nil
            if case .link(let link, let opID) = try await self.client.signIn(profile: profile, app: app.id, repairing: repairing) {
                await browse(link)
                await self.client.finished(profile: profile, opID: opID)
            }
        }
    }

    /// Gives up on `app`'s unfinished sign-in by removing its pending accounts.
    func cancel(_ app: HermesConnectedApp) async {
        await act(on: app) { profile in
            for account in app.accounts where account.isPending { try await self.client.remove(account, profile: profile) }
        }
    }

    /// Removes one of `app`'s accounts, so Hermes on this host loses that access.
    func disconnect(_ account: HermesConnectedApp.Account, of app: HermesConnectedApp) async {
        await act(on: app) { profile in try await self.client.remove(account, profile: profile) }
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    private var searched: [HermesConnectedApp] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedStandardContains(needle) || $0.summary?.localizedStandardContains(needle) == true
        }
    }

    /// Runs one action on the shown Profile and reads the list again, whether it worked or not:
    /// the host's rows are the only truth about what changed.
    private func act(on app: HermesConnectedApp, _ work: (String) async throws -> Void) async {
        guard let profile, busyApp == nil else { return }
        busyApp = app.id
        defer { busyApp = nil }
        do {
            try await work(profile)
        } catch {
            if self.profile == profile, !Task.isCancelled { actionError = Self.message(for: error) }
        }
        if self.profile == profile { await loadApps() }
    }

    private func loadApps() async {
        guard let profile else { return }
        readSerial += 1
        let serial = readSerial
        do {
            let apps = try await client.apps(profile: profile)
            if serial == readSerial { state = .loaded(apps) }
        } catch let deadEnd as HermesConnectedAppsDeadEnd {
            if serial == readSerial { state = .deadEnd(deadEnd) }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }

    /// An action refused for a reason the screen's dead ends already word, in those words.
    private static func message(for error: Error) -> String {
        switch error as? HermesConnectedAppsDeadEnd {
        case .hostTooOld: String(localized: "Connected apps need a newer Hermes release. Update Hermes on your server, then refresh.")
        case .unavailable: String(localized: "They are turned off on this server, or this Profile's Nous account doesn't include them.")
        case .needsNousSignIn: String(localized: "This Profile isn't signed in to Nous Portal. Sign in on the server, then refresh.")
        case nil: error.localizedDescription
        }
    }
}
