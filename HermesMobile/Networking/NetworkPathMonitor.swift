import Foundation
import Network
import Observation

/// App-wide network path, started once in `HermesMobileApp.init`. The open
/// chat retries its suspended stream when `changeCount` moves, and its stream
/// coordinator reads `isSatisfied` to wait for the network instead of spending
/// status probes while offline (#869). Device-wide: it holds no server state.
@MainActor
@Observable
final class NetworkPathMonitor {
    static let shared = NetworkPathMonitor()

    /// False only once the path is known to be unsatisfied. Unknown counts as
    /// satisfied, so nothing waits before the first update.
    private(set) var isSatisfied = true
    /// Bumps when reachability flips, or when the interfaces change while
    /// satisfied (Wi-Fi to cellular). Identical updates never reach it.
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
            // The main queue keeps updates in order; a Task per update might not.
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

/// The parts of an `NWPath` an open chat reacts to: whether the device has a
/// network at all, and which interfaces carry it.
struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    /// Available interface names in the system's preference order.
    let interfaces: [String]

    init(isSatisfied: Bool, interfaces: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    /// Only `.unsatisfied` counts as offline. A `.requiresConnection` path (an
    /// on-demand VPN) comes up when something connects, so waiting on it
    /// would never end.
    init(status: NWPath.Status, interfaces: [String]) {
        self.init(isSatisfied: status != .unsatisfied, interfaces: interfaces)
    }

    /// Whether `next` is news after `previous`: reachability flipped, or the
    /// interfaces changed while satisfied. `previous` is nil before the first
    /// update and counts as satisfied, so only an offline first path is news.
    static func publishesChange(from previous: NetworkPathSnapshot?, to next: NetworkPathSnapshot) -> Bool {
        guard let previous else { return !next.isSatisfied }
        if previous.isSatisfied != next.isSatisfied { return true }
        return next.isSatisfied && previous.interfaces != next.interfaces
    }
}

/// The last path seen, touched only on the monitor's serial queue, so repeated
/// identical updates are dropped before they reach the main actor.
private final class NetworkPathDeduplicator: @unchecked Sendable {
    private var last: NetworkPathSnapshot?

    func publishes(_ next: NetworkPathSnapshot) -> Bool {
        defer { last = next }
        return NetworkPathSnapshot.publishesChange(from: last, to: next)
    }
}
