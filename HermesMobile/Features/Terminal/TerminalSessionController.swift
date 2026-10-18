import Foundation
import Observation

@MainActor enum TerminalShellRegistry {
    private static var known: Set<String> = []
    static func key(server: URL, sessionID: String) -> String { "\(server.absoluteString)|\(sessionID)" }
    static func isKnown(_ key: String) -> Bool { known.contains(key) }
    static func markKnown(_ key: String) { known.insert(key) }
    static func reset() { known.removeAll() }
}

/// Detaching closes only this screen's socket. The plugin keeps the shell and
/// buffers its output for up to 30 minutes; every attach clears SwiftTerm once its socket opens, before replay.
@MainActor @Observable final class TerminalSessionController {
    /// `disconnected`: the connection was lost but the shell may still run on the host, so
    /// the screen offers Reconnect as well as Restart. Only close code 4410 means it exited.
    enum EndReason: Equatable {
        case exited(Int?), gone, error(String), disconnected(String)
        var isDisconnected: Bool { if case .disconnected = self { return true }; return false }
    }
    enum State: Equatable {
        case idle, connecting, live, reconnecting
        case ended(EndReason)
        case failed(String)
    }
    static var previousSessionNotice: String { String(localized: "Previous session ended, new shell started") }

    private(set) var state: State = .idle
    private(set) var isRetired = false
    @ObservationIgnored var onOutput: ((Data) async -> Void)?
    @ObservationIgnored var onReset: (() -> Void)?
    @ObservationIgnored private let transport: any TerminalTransport
    @ObservationIgnored private let registryKey: String
    @ObservationIgnored private var size = (rows: 24, cols: 80)
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var authenticationRetried = false
    @ObservationIgnored private var retirementToken: UUID?
    /// Set when an attach starts; the screen is cleared when that attach's socket opens.
    @ObservationIgnored private var pendingReset: (generation: UUID, previousGone: Bool)?
    @ObservationIgnored private weak var http: HermesConnection?

    init(target: TerminalTarget, transport: (any TerminalTransport)? = nil) {
        self.transport = transport ?? HermesTerminalClient(target: target)
        registryKey = target.id
        http = target.http
    }

    private func observeRetirement() -> Bool {
        guard let http, !isRetired else { return false }
        if retirementToken == nil {
            retirementToken = http.observeRetirement { [weak self] in
                self?.isRetired = true
                self?.detach()
                self?.state = .failed(String(localized: "Sign in to Hermes again to open Terminal"))
            }
        }
        return !isRetired
    }

    func open(rows: Int, cols: Int) async {
        guard state == .idle || isFailed else { return }
        size = (max(1, rows), max(1, cols))
        await attach(state: .connecting)
    }

    func retry() async { await open(rows: size.rows, cols: size.cols) }

    /// After a lost connection: attaches to the shell the host kept (`restart: false`),
    /// which replays its output.
    func reconnect() async {
        guard case .ended(let reason) = state, reason.isDisconnected else { return }
        await attach(state: .reconnecting)
    }

    /// Reads whether the shell still runs, then attaches without restarting it.
    private func attach(state: State) async {
        guard observeRetirement() else { return }
        isSuspended = false
        authenticationRetried = false
        let current = beginConnection(state: state)
        do {
            let running = try await transport.status()
            guard generation == current, !Task.isCancelled else { return }
            let previousGone = !running && TerminalShellRegistry.isKnown(registryKey)
            await connect(current: current, restart: false, previousGone: previousGone)
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            let message = error as? BotFailure == .rejected(404)
                ? String(localized: "Terminal needs the hermex-push companion plugin on Hermes")
                : error.localizedDescription
            // A reconnect keeps the old screen and its Reconnect action.
            self.state = state == .reconnecting ? .ended(.disconnected(message)) : .failed(message)
        }
    }

    func restart() async {
        guard observeRetirement() else { return }
        authenticationRetried = false
        isSuspended = false
        let current = beginConnection(state: .connecting)
        await connect(current: current, restart: true)
    }

    func detach() {
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        transport.disconnect()
        isSuspended = false
        if state == .live || state == .connecting || state == .reconnecting { state = .idle }
    }

    func suspend() {
        guard state == .live || state == .connecting || state == .reconnecting else { return }
        detach()
        isSuspended = true
        state = .reconnecting
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        authenticationRetried = false
        let current = beginConnection(state: .reconnecting)
        connectionTask = Task { [weak self] in await self?.connect(current: current, restart: false) }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private func beginConnection(state: State) -> UUID {
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        transport.disconnect()
        self.state = state
        return generation
    }

    private func connect(current: UUID, restart: Bool, previousGone: Bool = false) async {
        guard generation == current, !Task.isCancelled else { return }
        pendingReset = (current, previousGone)
        do {
            try await transport.connect(rows: size.rows, cols: size.cols, restart: restart) { [weak self] event in
                guard let self, self.generation == current else { return }
                await self.handle(event)
            }
            guard generation == current, !Task.isCancelled else { return }
            await resetScreenIfPending()
            TerminalShellRegistry.markKnown(registryKey)
            state = .live
            // The view may have resized while ticket/handshake was in flight.
            transport.send(TerminalWire.resize(rows: size.rows, cols: size.cols))
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
            if let failure = error as? TerminalConnectionFailure, failure.isAuthenticationFailure,
               !authenticationRetried {
                authenticationRetried = true
                await connect(current: current, restart: restart, previousGone: previousGone)
            } else {
                await handle(.failed((error as? TerminalConnectionFailure) ?? .network(error.localizedDescription)))
            }
        }
    }

    /// Clears the screen for the attach whose socket just opened (its first frame, or the
    /// completed open when the shell sent nothing), so a failed attach leaves the old output.
    private func resetScreenIfPending() async {
        guard let pending = pendingReset, pending.generation == generation else { return }
        pendingReset = nil
        onReset?()
        if pending.previousGone { await onOutput?(Data("\u{1B}[2m\(Self.previousSessionNotice)\u{1B}[0m\r\n".utf8)) }
    }

    func handle(_ event: TerminalEvent) async {
        switch event {
        case .output(let bytes):
            await resetScreenIfPending()
            await onOutput?(bytes)
        case .failed(let failure):
            pendingReset = nil
            transport.disconnect()
            if failure.isAuthenticationFailure, !authenticationRetried {
                authenticationRetried = true
                state = .reconnecting
                let current = generation
                connectionTask = Task { [weak self] in await self?.connect(current: current, restart: false) }
            } else if failure == .closed(4410) {
                state = .ended(.exited(nil))
            } else if failure.isAuthenticationFailure {
                state = .ended(.error(failure.message))
            } else {
                state = .ended(.disconnected(failure.message))
            }
        }
    }

    func send(_ text: String) { send(Data(text.utf8)) }
    func send(_ bytes: Data) {
        guard state == .live, !bytes.isEmpty else { return }
        transport.send(TerminalWire.input(bytes))
    }

    func resize(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        size = (rows, cols)
        guard state == .live else { return }
        transport.send(TerminalWire.resize(rows: rows, cols: cols))
    }

    /// Called when the UIKit owner is dismantled; suspend/resume retains the observer.
    func dispose() {
        detach()
        if let retirementToken { http?.removeRetirementObserver(retirementToken) }
        retirementToken = nil
    }
}
