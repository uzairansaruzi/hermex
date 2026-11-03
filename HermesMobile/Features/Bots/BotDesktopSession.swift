import Foundation
import Observation

/// Flat `display.status` / `display.observe` at the Hermes compatibility pin. The
/// desktop belongs to a Profile, not a chat runtime or conversation id.
struct BotDesktopStatus: Equatable {
    let supported: Bool
    let installed: Bool
    let running: Bool
    let blocked: Bool

    init(_ value: BotJSON) {
        supported = value["supported"].flag == true
        installed = value["installed"].flag == true
        running = value["running"].flag == true
        blocked = !(value["blocker"].text ?? "").isEmpty
    }
}

/// Tickets are single-use, memory-only capabilities. Never let a server reply
/// redirect one to a different host, path, or port, and never pass it into JavaScript.
enum BotDesktopEndpoint {
    static func request(_ reply: BotJSON, connection: BotConnection) throws -> URLRequest {
        guard reply["path"].text == "/api/display/ws",
              let ticket = reply["ticket"].text, !ticket.isEmpty,
              var parts = URLComponents(url: connection.address, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil else { throw BotFailure.unsupported }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = "/api/display/ws"
        parts.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        parts.fragment = nil
        guard let url = parts.url else { throw BotFailure.unsupported }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Native sockets do not supply Origin. Use the saved dashboard origin, never a
        // file:// WebKit origin; the host applies its normal origin guard.
        request.setValue(connection.address.absoluteString, forHTTPHeaderField: "Origin")
        return HermesHeaders(saved: connection).applied(to: request, origin: connection.address)
    }
}

/// Owns exactly one viewer. Closing/backgrounding invalidates pending RPCs, socket
/// callbacks and retry timers. The shared chat gateway remains owned by its other screens.
@MainActor @Observable final class BotDesktopSession {
    enum Phase: Equatable {
        case idle, loading, unsupported, notInstalled, blocked, stopped, starting, connecting, live, paused, failed
    }
    private(set) var phase: Phase = .idle
    private(set) var message = ""
    private(set) var request: URLRequest?
    private(set) var generation = 0
    let socketSession: URLSession
    private let client: any BotTransport
    private let connection: BotConnection
    private let profile: String
    private let wait: (Duration) async throws -> Void
    private var active = false
    private var task: Task<Void, Never>?
    private var retries = 0
    private var ticketRetried = false

    convenience init(server: URL, connection: BotConnection, profile: String) {
        let client = BotClient(saved: connection, server: server)
        self.init(client: client, socketSession: client.http.session, connection: connection, profile: profile)
    }

    init(client: any BotTransport, socketSession: URLSession, connection: BotConnection, profile: String,
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.socketSession = socketSession
        self.connection = connection
        self.profile = profile
        self.wait = wait
        client.onDisconnect = { [weak self] error in
            guard let self, self.active else { return }
            self.recover(error)
        }
    }

    @discardableResult func open() -> Task<Void, Never>? {
        guard !active else { return nil }
        active = true
        retries = 0
        ticketRetried = false
        return load(start: false)
    }

    func close() {
        active = false
        generation += 1
        task?.cancel(); task = nil
        request = nil
        client.close()
        phase = .paused
    }

    @discardableResult func retry() -> Task<Void, Never>? {
        guard active else { return nil }
        retries = 0; ticketRetried = false
        return load(start: false)
    }

    /// Starting is a deliberate button, not an effect of opening a read-only viewer.
    /// It may launch a desktop on the host, but never installs packages or changes its setup.
    @discardableResult func start() -> Task<Void, Never>? {
        guard active, phase == .stopped else { return nil }
        return load(start: true)
    }

    @discardableResult private func load(start: Bool, delay: Duration = .zero) -> Task<Void, Never> {
        generation += 1
        let owner = generation
        task?.cancel()
        request = nil
        phase = start ? .starting : .loading
        message = ""
        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > .zero { try await wait(delay) }
                try check(owner)
                try await client.connect()
                try check(owner)
                let result = try await client.call(start ? .displayStart(profile: profile) : .displayStatus(profile: profile),
                                                   validateDispatch: { try self.check(owner) })
                try check(owner)
                guard admit(BotDesktopStatus(result)) else { return }
                let observed = try await client.call(.displayObserve(profile: profile),
                                                      validateDispatch: { try self.check(owner) })
                try check(owner)
                guard admit(BotDesktopStatus(observed)) else { return }
                request = try BotDesktopEndpoint.request(observed, connection: connection)
                phase = .connecting
            } catch {
                guard active, generation == owner, !Task.isCancelled else { return }
                recover(error)
            }
        }
        task = operation
        return operation
    }

    private func check(_ owner: Int) throws {
        guard active, generation == owner, !Task.isCancelled else { throw CancellationError() }
    }

    private func admit(_ status: BotDesktopStatus) -> Bool {
        if !status.supported { phase = .unsupported }
        else if !status.installed { phase = .notInstalled }
        else if status.running { return true }
        else { phase = status.blocked ? .blocked : .stopped }
        return false
    }

    func connected(generation owner: Int) {
        guard active, owner == generation, phase == .connecting else { return }
        phase = .live
        retries = 0; ticketRetried = false
    }

    @discardableResult func disconnected(code: Int, generation owner: Int) -> Task<Void, Never>? {
        guard active, owner == generation, request != nil else { return nil }
        request = nil
        if code == 4403 {
            phase = .failed
            message = String(localized: "The server refused this desktop connection.")
            return nil
        }
        if code == 4401 {
            if ticketRetried { fail(BotFailure.signInExpired); return nil }
            ticketRetried = true
            return load(start: false)
        }
        // Recheck status after stop/unreachable (4001), and re-observe after takeover
        // (4000), always as a watcher. A host reporting running but refusing its VNC
        // socket still meets this retry budget rather than spinning indefinitely.
        guard retries < 5 else { fail(BotFailure.transport); return nil }
        let seconds = min(1 << retries, 8)
        retries += 1
        return load(start: false, delay: .seconds(seconds))
    }

    private func recover(_ error: Error) {
        guard active else { return }
        if BotConnectionAdvice.isRetryable(error), retries < 5 {
            let seconds = min(1 << retries, 8)
            retries += 1
            load(start: false, delay: .seconds(seconds))
        } else { fail(error) }
    }

    private func fail(_ error: Error) {
        generation += 1
        request = nil
        if error as? BotFailure == .rejected(-32601) {
            phase = .unsupported
        } else {
            phase = .failed
            // Arbitrary errors can contain the ticket URL. Never show/log their text.
            message = String(localized: "Could not connect to the desktop. Try again.")
        }
    }
}
