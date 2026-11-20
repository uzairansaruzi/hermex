import Foundation
import Observation

@MainActor
@Observable
final class ConnectedAppsModel {
    enum State: Equatable {
        case loading
        case loaded([HermesConnectedApp])
        case deadEnd(HermesConnectedAppsDeadEnd)
        case failed(String)
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let apps: [HermesConnectedApp]
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    private(set) var profile: String?
    private(set) var busyApp: String?
    var actionError: String?
    var query = ""
    var category: String?

    private let client: HermesConnectedAppsClient
    @ObservationIgnored private var readSerial = 0

    init(client: HermesConnectedAppsClient) { self.client = client }

    var apps: [HermesConnectedApp] {
        if case .loaded(let apps) = state { return apps }
        return []
    }

    var categories: [String] {
        Set(apps.map(\.category)).subtracting([""]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var connected: [HermesConnectedApp] {
        searched.filter { !$0.accounts.isEmpty }
    }

    var available: [Section] {
        let rest = searched.filter { $0.accounts.isEmpty && (category == nil || $0.category == category) }
        return Dictionary(grouping: rest, by: \.category)
            .map { Section(id: $0.key, apps: $0.value) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func app(_ id: String) -> HermesConnectedApp? { apps.first { $0.id == id } }

    func load() async {
        if !isLoaded { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true {
                profile = listed.initial
                state = .loading
            }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
            return
        }
        await loadApps()
    }

    func select(_ name: String) async {
        guard name != profile, busyApp == nil else { return }
        profile = name
        category = nil
        state = .loading
        await loadApps()
    }

    func connect(_ app: HermesConnectedApp, browse: (URL) async -> Void) async {
        await act(on: app) { profile in
            let repairing = app.state == .needsReconnect ? app.accountToRepair : nil
            if case .link(let link, let opID) = try await self.client.signIn(profile: profile, app: app.id, repairing: repairing) {
                await browse(link)
                await self.client.finished(profile: profile, opID: opID)
            }
        }
    }

    func cancel(_ app: HermesConnectedApp) async {
        await act(on: app) { profile in
            for account in app.accounts where account.isPending { try await self.client.remove(account, profile: profile) }
        }
    }

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

    private static func message(for error: Error) -> String {
        switch error as? HermesConnectedAppsDeadEnd {
        case .hostTooOld: String(localized: "Connected apps need a newer Hermes release. Update Hermes on your server, then refresh.")
        case .unavailable: String(localized: "They are turned off on this server, or this Profile's Nous account doesn't include them.")
        case .needsNousSignIn: String(localized: "This Profile isn't signed in to Nous Portal. Sign in on the server, then refresh.")
        case nil: error.localizedDescription
        }
    }
}
