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

/// A Bot screen's quiet reconnect after its socket dropped (#1372): it waits out a backoff
/// step while the network is up, holds without retrying while it is down, and runs at once,
/// from the first step again, when `networkPathDidChange()` finds it back. The inbox, the
/// Hermes session list and a room each own one; closing or backgrounding the screen cancels
/// it, so a hidden screen never reconnects.
@MainActor final class BotReconnectSchedule {
    /// Waits before each attempt; the last one repeats.
    private let delays: [Duration]
    /// Attempts on backoff before its timer stops for the screen's Reconnect button; nil never
    /// stops. The reconnect still waits for a network return, which always gets one more.
    private let limit: Int?
    private let isNetworkAvailable: @MainActor () -> Bool
    /// The reconnect waiting on its backoff step or on the network.
    private var pending: (@MainActor () async -> Void)?
    private var task: Task<Void, Never>?
    private var attempts = 0

    init(delays: [Duration], limit: Int? = nil,
         isNetworkAvailable: @escaping @MainActor () -> Bool = { NetworkPathMonitor.shared.isSatisfied }) {
        self.delays = delays; self.limit = limit; self.isNetworkAvailable = isNetworkAvailable
    }

    /// Runs `reconnect` after the next backoff step, or once the network is back. It replaces
    /// any reconnect already waiting.
    func schedule(_ reconnect: @escaping @MainActor () async -> Void) {
        cancel()
        pending = reconnect
        if let limit, attempts >= limit { return }
        guard isNetworkAvailable() else { return }
        let delay = delays[min(attempts, delays.count - 1)]
        attempts += 1
        start(after: delay)
    }

    /// The device's network path changed. Offline, a waiting reconnect stops its backoff;
    /// online, it runs now. Nothing happens when none is waiting.
    func networkPathDidChange() {
        guard pending != nil else { return }
        task?.cancel(); task = nil
        guard isNetworkAvailable() else { return }
        attempts = 0
        start(after: nil)
    }

    /// The screen reached the host: the next drop starts from the first step.
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
