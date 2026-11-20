import Foundation
import Observation

@MainActor
@Observable
final class APIKeysModel {
    enum State: Equatable {
        case loading
        case loaded([HermesEnvKey])
        case failed(String)
    }

    private(set) var state = State.loading
    private(set) var profiles: [String] = []
    private(set) var profile: String?

    private let client: HermesEnvironmentClient
    @ObservationIgnored private var readSerial = 0

    init(client: HermesEnvironmentClient) { self.client = client }

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    var keys: [HermesEnvKey] {
        if case .loaded(let keys) = state { return keys }
        return []
    }

    var setSections: [HermesEnvKey.Section] {
        HermesEnvKey.sections(keys.filter(\.isSet))
    }

    func load() async {
        if case .failed = state { state = .loading }
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
        await loadKeys()
    }

    func select(_ name: String) async {
        guard name != profile else { return }
        profile = name
        state = .loading
        await loadKeys()
    }

    func save(_ name: String, value: String, profile: String) async throws {
        try await client.set(name, value: value, profile: profile)
        await loadKeys()
    }

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
