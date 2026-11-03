import CryptoKit
import Foundation
import Observation

/// Flat `display.status` / `display.observe` at the Hermes compatibility pin. The
/// desktop belongs to a Profile, not a chat runtime or conversation id.
struct BotDesktopStatus: Equatable {
    let supported: Bool
    let installed: Bool
    let running: Bool
    let blocked: Bool
    let blocker: String?
    let missing: [String]
    let installCommand: String?

    init(_ value: BotJSON) {
        supported = value["supported"].flag == true
        installed = value["installed"].flag == true
        running = value["running"].flag == true
        blocker = value["blocker"].text
        blocked = !(blocker ?? "").isEmpty
        missing = (value["missing"].list ?? []).compactMap(\.text)
        installCommand = value["install_command"].text
    }
}

private struct BotDesktopLease {
    let human: Bool
    let viewerHash: String?
    let epoch: Int
    let reason: String

    init(_ value: BotJSON) {
        human = value["holder"].text == "human"
        viewerHash = value["viewer_hash"].text
        epoch = value["epoch"].integer ?? 0
        reason = value["reason"].text ?? ""
    }

    static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
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
        case idle, loading, unsupported, notInstalled, blocked, stopped, starting, connecting, live, paused, failed, rendererFailed
    }
    private(set) var phase: Phase = .idle
    private(set) var message = ""
    private(set) var request: URLRequest?
    private(set) var generation = 0
    private(set) var rendererRevision = 0
    private(set) var status: BotDesktopStatus?
    private(set) var clipboard = ""
    private(set) var actionInProgress = false
    private(set) var actionFailed = false
    @ObservationIgnored var sendInput: ((String, [String: Any]) -> Void)?
    private var lease: BotDesktopLease?
    private var profileKey: String?
    private var viewerID: String?
    private var viewerHash: String?
    private var action: Task<Void, Never>?
    var controlsDesktop: Bool { lease?.human == true && viewerHash != nil && lease?.viewerHash == viewerHash }
    var someoneElseControls: Bool { lease?.human == true && !controlsDesktop }
    var leaseReason: String { controlsDesktop ? lease?.reason ?? "" : "" }
    let socketSession: URLSession
    private let client: any BotTransport
    private let connection: BotConnection
    private let profile: String
    private let wait: (Duration) async throws -> Void
    private var active = false
    private var task: Task<Void, Never>?
    private var retries = 0
    private var ticketRetried = false
    private let autoStartOnOpen: Bool
    private var autoStart = false

    convenience init(server: URL, connection: BotConnection, profile: String) {
        let client = BotClient(saved: connection, server: server)
        self.init(client: client, socketSession: client.http.session, connection: connection, profile: profile, autoStartOnOpen: true)
    }

    init(client: any BotTransport, socketSession: URLSession, connection: BotConnection, profile: String, autoStartOnOpen: Bool = false,
         wait: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.socketSession = socketSession
        self.connection = connection
        self.profile = profile
        self.autoStartOnOpen = autoStartOnOpen
        self.wait = wait
        client.onDisconnect = { [weak self] error in
            guard let self, self.active else { return }
            self.recover(error)
        }
        client.onEvent = { [weak self] frame in
            guard let self, active || controlsDesktop, frame["type"].text == "display.lease", let profileKey,
                  frame["payload"]["profile_key"].text == profileKey else { return }
            applyLease(frame["payload"]["lease"])
            if !active && !controlsDesktop { client.close() }
        }
    }

    @discardableResult func open(newPresentation: Bool = false) -> Task<Void, Never>? {
        guard !active else { return nil }
        autoStart = (newPresentation || phase == .idle) && autoStartOnOpen
        active = true
        retries = 0
        ticketRetried = false
        return load(start: false)
    }

    func close(keepLeaseWatch: Bool = false) {
        active = false
        generation += 1
        task?.cancel(); task = nil
        request = nil
        clipboard = ""
        if !actionInProgress && !keepLeaseWatch { client.close() }
        phase = .paused
    }

    @discardableResult func retry() -> Task<Void, Never>? {
        guard active else { return nil }
        if phase == .rendererFailed { rendererRevision += 1 }
        autoStart = autoStartOnOpen
        retries = 0; ticketRetried = false
        return load(start: false)
    }

    /// The fallback after a desktop has stopped while the viewer was open.
    @discardableResult func start() -> Task<Void, Never>? {
        guard active, phase == .stopped else { return nil }
        return load(start: true)
    }

    @discardableResult func takeControl(reason: String = "") -> Task<Void, Never>? {
        guard phase == .live, !controlsDesktop, let viewerID else { return nil }
        return perform(.displayAcquire(profile: profile, viewerID: viewerID, reason: reason)) { self.applyLease($0["lease"]) }
    }

    func handBack() {
        guard controlsDesktop, let viewerID else { return }
        perform(.displayRelease(profile: profile, viewerID: viewerID)) { self.applyLease($0["lease"]) }
    }

    func turnOff(force: Bool) {
        guard phase == .live else { return }
        perform(.displayStop(profile: profile, force: force), releaseFirst: !force) { result in
            self.applyStatus(result)
            if self.status?.running == false {
                self.generation += 1
                self.request = nil
                self.phase = .stopped
            }
        }
    }

    func leave() async -> Bool {
        await action?.value
        if controlsDesktop, leaseReason.isEmpty {
            handBack()
            await action?.value
            if controlsDesktop && actionFailed { return false }
        }
        close(keepLeaseWatch: controlsDesktop && !leaseReason.isEmpty)
        return true
    }

    func receiveClipboard(_ text: String, generation owner: Int) {
        guard active, generation == owner, controlsDesktop, text.utf8.count <= 262_144 else { return }
        clipboard = text
    }

    func clearActionError() { actionFailed = false }

    func input(_ command: String, arguments: [String: Any] = [:]) {
        guard phase == .live, controlsDesktop else { return }
        sendInput?(command, arguments)
    }

    @discardableResult private func perform(_ call: HermesCall, releaseFirst: Bool = false,
                                             apply: @escaping (BotJSON) -> Void) -> Task<Void, Never>? {
        guard active, !actionInProgress else { return nil }
        let owner = generation
        actionInProgress = true
        actionFailed = false
        action = Task { [weak self] in
            guard let self else { return }
            defer {
                actionInProgress = false
                action = nil
                if !active { client.close() }
            }
            do {
                if releaseFirst, controlsDesktop, let viewerID {
                    let released = try await client.call(.displayRelease(profile: profile, viewerID: viewerID),
                                                         validateDispatch: { try self.check(owner) })
                    try check(owner)
                    applyLease(released["lease"])
                }
                let result = try await client.call(call, validateDispatch: { try self.check(owner) })
                if active, generation == owner { apply(result) }
            } catch {
                if active, generation == owner { actionFailed = true }
            }
        }
        return action
    }

    private func applyStatus(_ value: BotJSON) {
        status = BotDesktopStatus(value)
        profileKey = value["profile_key"].text
        applyLease(value["lease"])
    }

    private func applyLease(_ value: BotJSON) {
        guard value["holder"].text != nil else { return }
        let next = BotDesktopLease(value)
        guard next.epoch >= (lease?.epoch ?? 0) else { return }
        lease = next
        if !controlsDesktop { clipboard = "" }
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
                await action?.value
                try check(owner)
                try await client.connect()
                try check(owner)
                lease = nil
                clipboard = ""
                var result = try await client.call(start ? .displayStart(profile: profile) : .displayStatus(profile: profile),
                                                   validateDispatch: { try self.check(owner) })
                try check(owner)
                applyStatus(result)
                if autoStart, !start, status?.running == false, status?.supported == true,
                   status?.installed == true, status?.blocked == false {
                    autoStart = false
                    phase = .starting
                    result = try await client.call(.displayStart(profile: profile), validateDispatch: { try self.check(owner) })
                    try check(owner)
                    applyStatus(result)
                }
                autoStart = false
                guard admit(BotDesktopStatus(result)) else { return }
                let observed = try await client.call(.displayObserve(profile: profile, viewerID: viewerID),
                                                      validateDispatch: { try self.check(owner) })
                try check(owner)
                viewerID = observed["viewer_id"].text
                viewerHash = viewerID.map(BotDesktopLease.hash)
                applyStatus(observed)
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

    func rendererFailed(generation owner: Int) {
        guard active, owner == generation, request != nil else { return }
        generation += 1
        request = nil
        client.close()
        phase = .rendererFailed
    }

    @discardableResult func disconnected(code: Int, httpStatus: Int? = nil, generation owner: Int) -> Task<Void, Never>? {
        guard active, owner == generation, request != nil else { return nil }
        request = nil
        if httpStatus == 403 || code == 4403 {
            client.close()
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

enum BotDesktopUse: Equatable {
    case none, active, ended

    static func matches(tool: String) -> Bool {
        let tool = tool.lowercased()
        return tool.hasPrefix("computer_use") || tool.hasPrefix("browser_")
    }
}

enum BotDesktopPreference {
    static func autoOpen(connection: BotConnection, profile: String) -> String {
        "hermes.botComputerAutoOpen|\(connection.id.uuidString)|\(profile)"
    }
}
