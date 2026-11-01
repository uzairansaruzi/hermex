import Foundation
import Observation

/// The API Keys screen's state (#1318): the host's Profiles, the one shown, and its `.env` keys.
/// Every read goes to the host; nothing is kept past the screen.
@MainActor
@Observable
final class APIKeysModel {
    enum State: Equatable {
        case loading
        /// Every key the host knows for the Profile, set or not.
        case loaded([HermesEnvKey])
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    /// The Profile the screen lists and writes to, once the host has named its Profiles.
    private(set) var profile: String?

    private let client: HermesEnvironmentClient
    /// Bumped by each read, so only the latest one applies after a Profile switch.
    @ObservationIgnored private var readSerial = 0

    init(client: HermesEnvironmentClient) { self.client = client }

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    /// Every key the host knows for the Profile, for the Add Key picker.
    var keys: [HermesEnvKey] {
        if case .loaded(let keys) = state { return keys }
        return []
    }

    /// The keys the Profile's `.env` sets, by category.
    var setSections: [HermesEnvKey.Section] {
        HermesEnvKey.sections(keys.filter(\.isSet))
    }

    /// Reads the host's Profiles, keeping the shown one while it still exists and otherwise
    /// starting on the default, then that Profile's keys. A newer read or a Profile switch
    /// supersedes it, so an overlapping refresh never replaces a later result.
    func load() async {
        if case .failed = state { state = .loading }
        readSerial += 1
        let serial = readSerial
        do {
            let listed = try await client.profiles()
            guard serial == readSerial else { return }
            profiles = listed.names
            if profile.map(listed.names.contains) != true {
                // The shown Profile is gone: its keys must not stay tappable under the new one.
                profile = listed.initial
                state = .loading
            }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
            return
        }
        await loadKeys()
    }

    func select(_ name: String) async {
        guard name != profile else { return }
        profile = name
        state = .loading
        await loadKeys()
    }

    /// Writes `value` to `profile`'s `.env`, then reads the list again. Throws the host's refusal.
    func save(_ name: String, value: String, profile: String) async throws {
        try await client.set(name, value: value, profile: profile)
        await loadKeys()
    }

    /// Removes `name` from `profile`'s `.env`, then reads the list again. Throws the host's refusal.
    func remove(_ name: String, profile: String) async throws {
        try await client.remove(name, profile: profile)
        await loadKeys()
    }

    private func loadKeys() async {
        guard let profile else { return }
        readSerial += 1
        let serial = readSerial
        do {
            let keys = try await client.keys(profile: profile)
            if serial == readSerial { state = .loaded(keys) }
        } catch {
            if serial == readSerial, !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }
}
