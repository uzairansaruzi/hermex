import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    private(set) var isSatisfied = true
    private(set) var changeCount = 0

    @ObservationIgnored private var monitor: NWPathMonitor?

    private init() {}

    func start() {
        guard monitor == nil else { return }

        let monitor = NWPathMonitor()
        let deduplicator = NetworkPathDeduplicator()
        monitor.pathUpdateHandler = { path in
            let snapshot = NetworkPathSnapshot(
                status: path.status,
                interfaces: path.availableInterfaces.map(\.name)
            )
            guard deduplicator.publishes(snapshot) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NetworkPathMonitor.shared.publish(snapshot)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.uzairansar.hermesmobile.network-path"))
        self.monitor = monitor
    }

    private func publish(_ snapshot: NetworkPathSnapshot) {
        if isSatisfied != snapshot.isSatisfied {
            isSatisfied = snapshot.isSatisfied
        }
        changeCount &+= 1
    }
}

struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let interfaces: [String]

    init(isSatisfied: Bool, interfaces: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    init(status: NWPath.Status, interfaces: [String]) {
        self.init(isSatisfied: status != .unsatisfied, interfaces: interfaces)
    }

    static func publishesChange(from previous: NetworkPathSnapshot?, to next: NetworkPathSnapshot) -> Bool {
        guard let previous else { return !next.isSatisfied }
        if previous.isSatisfied != next.isSatisfied { return true }
        return next.isSatisfied && previous.interfaces != next.interfaces
    }
}

private final class NetworkPathDeduplicator: @unchecked Sendable {
    private var last: NetworkPathSnapshot?

    func publishes(_ next: NetworkPathSnapshot) -> Bool {
        defer { last = next }
        return NetworkPathSnapshot.publishesChange(from: last, to: next)
    }
}

@MainActor final class BotReconnectSchedule {
    private let delays: [Duration]
    private let limit: Int?
    private let isNetworkAvailable: @MainActor () -> Bool
    private var pending: (@MainActor () async -> Void)?
    private var task: Task<Void, Never>?
    private var attempts = 0

    init(delays: [Duration], limit: Int? = nil,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }) {
        self.delays = delays; self.limit = limit; self.isNetworkAvailable = isNetworkAvailable
    }

    func schedule(_ reconnect: @escaping @MainActor () async -> Void) {
        cancel()
        pending = reconnect
        if let limit, attempts >= limit { return }
        guard isNetworkAvailable() else { return }
        let delay = delays[min(attempts, delays.count - 1)]
        attempts += 1
        start(after: delay)
    }

    func networkPathDidChange() {
        guard pending != nil else { return }
        task?.cancel(); task = nil
        guard isNetworkAvailable() else { return }
        attempts = 0
        start(after: nil)
    }

    func succeeded() { attempts = 0 }

    func cancel() {
        task?.cancel(); task = nil
        pending = nil
    }

    private func start(after delay: Duration?) {
        task = Task { [weak self] in
            if let delay, (try? await Task.sleep(for: delay)) == nil { return }
            guard let self, !Task.isCancelled, let reconnect = self.pending else { return }
            self.task = nil; self.pending = nil
            await reconnect()
        }
    }
}
