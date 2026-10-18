import Foundation
import Observation

/// The companion plugin's host-shell wire contract.
enum TerminalWire {
    static let path = "api/plugins/hermex-push/terminal/shell"

    static func status(base: URL, sessionID: String, profile: String?) throws -> URLRequest {
        URLRequest(url: try url(base: base, sessionID: sessionID, profile: profile, status: true))
    }

    static func upgrade(base: URL, sessionID: String, profile: String?, rows: Int, cols: Int,
                        restart: Bool, ticket: String) throws -> URLRequest {
        var parts = URLComponents(url: try url(base: base, sessionID: sessionID, profile: profile), resolvingAgainstBaseURL: false)!
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.queryItems = (parts.queryItems ?? []) + [
            URLQueryItem(name: "cols", value: String(max(1, cols))),
            URLQueryItem(name: "rows", value: String(max(1, rows))),
            URLQueryItem(name: "ticket", value: ticket)
        ] + (restart ? [URLQueryItem(name: "restart", value: "1")] : [])
        // Hermes parses query strings as form data: a literal + is not a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return URLRequest(url: url)
    }

    static func resize(rows: Int, cols: Int) -> URLSessionWebSocketTask.Message {
        .string("\u{1B}[RESIZE:\(max(1, cols));\(max(1, rows))]")
    }

    static func input(_ data: Data) -> URLSessionWebSocketTask.Message { .data(data) }

    private static func url(base: URL, sessionID: String, profile: String?, status: Bool = false) throws -> URL {
        guard !sessionID.isEmpty,
              var parts = URLComponents(url: base.appendingPathComponent(path + (status ? "/status" : "")), resolvingAgainstBaseURL: false)
        else { throw BotFailure.invalidAddress }
        parts.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
            + (profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? [])
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }
}

enum TerminalConnectionFailure: Error, Equatable {
    case closed(Int)
    case handshake(Int)
    case network(String)

    var isAuthenticationFailure: Bool {
        self == .closed(4401) || self == .handshake(403) || self == .handshake(401)
    }

    var message: String {
        switch self {
        case .closed(4410): return String(localized: "Shell exited")
        case .closed(1013): return String(localized: "Too many terminals open")
        case .closed(4409): return String(localized: "Shell opened in another terminal")
        case .closed(1011): return String(localized: "Terminal unavailable")
        case .closed(4401), .handshake(401), .handshake(403): return String(localized: "Sign in to Hermes again to open Terminal")
        case .closed(let code): return String(localized: "Terminal disconnected (\(code))")
        case .handshake(let code): return String(localized: "Terminal connection refused (HTTP \(code))")
        case .network(let message): return message
        }
    }
}

enum TerminalEvent: Equatable {
    case output(Data)
    case failed(TerminalConnectionFailure)
}

@MainActor protocol TerminalTransport: AnyObject {
    func status() async throws -> Bool
    /// The reader awaits `onEvent` before it receives the next frame, so a slow consumer
    /// stops reading the socket instead of queueing its output.
    func connect(rows: Int, cols: Int, restart: Bool, onEvent: @escaping (TerminalEvent) async -> Void) async throws
    func send(_ frame: URLSessionWebSocketTask.Message)
    func disconnect()
}

/// One socket carries input, size and output. It has no input resend, SSE sequence
/// dedupe, or output replay buffer: the plugin owns the shell and its replay.
@MainActor final class HermesTerminalClient: TerminalTransport {
    let target: TerminalTarget
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var onEvent: ((TerminalEvent) async -> Void)?
    private var generation = UUID()

    init(target: TerminalTarget) { self.target = target }

    func status() async throws -> Bool {
        let data = try await target.http.data(.terminalStatus(sessionID: target.sessionID, profile: target.profile))
        guard let running = try JSONDecoder().decode(TerminalStatus.self, from: data).running else { throw BotFailure.unsupported }
        return running
    }

    func connect(rows: Int, cols: Int, restart: Bool, onEvent: @escaping (TerminalEvent) async -> Void) async throws {
        disconnect()
        let current = generation
        let request = try await target.http.terminalUpgrade(sessionID: target.sessionID, profile: target.profile,
                                                          rows: rows, cols: cols, restart: restart)
        guard generation == current, !Task.isCancelled, !target.http.isRetired else { throw CancellationError() }
        let socket = target.http.session.webSocketTask(with: request)
        socket.maximumMessageSize = 2 * 1024 * 1024
        self.socket = socket
        self.onEvent = onEvent
        socket.resume()
        // Read replay while the ping is in flight: URLSession needs its receive
        // demand active to drain buffered data before delivering the pong.
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await socket.receive()
                    // No strong self across the await: a reader waiting for the screen must not keep this client alive.
                    guard self?.generation == current else { return }
                    switch frame {
                    case .data(let bytes): await onEvent(.output(bytes))
                    case .string(let text): await onEvent(.output(Data(text.utf8)))
                    @unknown default: break
                    }
                }
            } catch {
                guard self?.generation == current, !Task.isCancelled else { return }
                let failure = Self.failure(socket: socket, error: error)
                self?.disconnect()
                await onEvent(.failed(failure))
            }
        }
        // A completed ping means the upgrade really opened, even on a shell with no new output.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            // The reader may already have delivered the close while the ping awaited.
            guard generation == current else { throw CancellationError() }
            let failure = Self.failure(socket: socket, error: error)
            disconnect()
            throw failure
        }
        guard generation == current, !Task.isCancelled else { throw CancellationError() }
    }

    /// Each send awaits the preceding send, including resizes; never replay keystrokes
    /// after a failure (they may already have reached the shell).
    func send(_ frame: URLSessionWebSocketTask.Message) {
        guard let socket else { return }
        let previous = sender, current = generation
        sender = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == current, !Task.isCancelled else { return }
            do { try await socket.send(frame) } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                let callback = self.onEvent
                let failure = Self.failure(socket: socket, error: error)
                self.disconnect()
                await callback?(.failed(failure))
            }
        }
    }

    func disconnect() {
        generation = UUID()
        reader?.cancel(); reader = nil
        sender?.cancel(); sender = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        onEvent = nil
    }

    private static func failure(socket: URLSessionWebSocketTask, error: Error) -> TerminalConnectionFailure {
        if socket.closeCode != .invalid { return .closed(socket.closeCode.rawValue) }
        if let response = socket.response as? HTTPURLResponse, response.statusCode != 101 {
            return .handshake(response.statusCode)
        }
        return .network(error.localizedDescription)
    }

    private struct TerminalStatus: Decodable { let running: Bool? }
}

/// The stored session id and Profile, never a gateway runtime id or the web UI URL.
@MainActor struct TerminalTarget: Identifiable {
    let http: HermesConnection
    let sessionID: String
    let profile: String?
    var id: String { [http.connection.id.uuidString, profile ?? "", sessionID].joined(separator: "\u{0}") }
}

/// Read mounted companion routes when chat/Settings appears, as the Git feature does.
@MainActor @Observable final class TerminalAvailability {
    enum State: Equatable { case checking, available, missing, failed(String) }
    private(set) var state: State = .checking
    private var generation = UUID()
    var isAvailable: Bool { state == .available }
    /// Counts the reconnects that came after a failed check (or during one that then failed).
    /// It is part of the chat's check identity, so only a failure is read again, once per
    /// reconnect; an available or missing answer is kept.
    private var retries = 0
    private var reconnectedDuringCheck = false

    /// The identity the chat's capability check runs under.
    func checkID(for target: TerminalTarget?) -> String { "\(target?.id ?? "unattached")|\(retries)" }

    /// The chat's socket came up or went down. Coming up re-reads a failed check.
    func connectionChanged(isConnected: Bool) {
        guard isConnected else { return }
        switch state {
        case .failed: retries += 1
        case .checking: reconnectedDuringCheck = true
        case .available, .missing: break
        }
    }

    func refresh(_ target: TerminalTarget?) async {
        let current = UUID(); generation = current
        state = .checking
        reconnectedDuringCheck = false
        guard let target else { state = .missing; return }
        do {
            let routes = try await BotDashboardClient(http: target.http).companionRoutes()
            guard generation == current, !Task.isCancelled else { return }
            state = routes.supports("GET /terminal/shell/status") ? .available : .missing
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if error as? BotFailure == .rejected(404) { state = .missing }
            else {
                state = .failed(error.localizedDescription)
                if reconnectedDuringCheck { retries += 1 }
            }
        }
    }
}
