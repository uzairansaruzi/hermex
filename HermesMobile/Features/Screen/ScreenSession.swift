import CoreGraphics
import Foundation
import OSLog
import QuartzCore

/// The per-server "Bot Screen (beta)" switch (#1567): off by default, and set only from a Hermes
/// server's page, so a webui server never has it. Sign-out and server removal delete it.
enum BotScreenSettings {
    static func key(for server: URL) -> String { "botScreen.enabled|\(server.absoluteString)" }

    static func remove(for server: URL, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: server))
    }
}

/// A `display.*` call the host refused. Every failure is 5300; a refusal adds `data.code`, which
/// the caller reads first. With no code it is a state, such as a stopped screen. -32601 means the
/// host has no such method.
struct ScreenCallFailure: Error, Equatable {
    let code: Int
    let refusal: String?
}

/// `display.status`, read tolerantly: `display.observe` carries the same fields.
struct ScreenStatus: Equatable {
    /// Which side controls the screen. Unknown holders read as the agent's.
    enum Holder: Equatable { case agent, human }

    let supported: Bool
    let running: Bool
    let holder: Holder

    init(_ json: BotJSON) {
        supported = json["supported"].flag ?? false
        running = json["running"].flag ?? false
        holder = json["lease"]["holder"].text == "human" ? .human : .agent
    }
}

/// Where the picture comes from. Only the bot's own virtual desktop for now (`display.*` and
/// `/api/display/ws`); each case supplies its status and its stream's upgrade, and nothing above
/// this branches on the host.
enum ScreenSource {
    case botDesktop

    /// The current state of `profile`'s screen.
    func status(profile: String, client: BotClient) async throws -> ScreenStatus {
        ScreenStatus(try await client.call(.displayStatus(profile: profile)))
    }

    /// A fresh upgrade for `profile`'s stream, which spends one ticket.
    func streamUpgrade(profile: String, client: BotClient) async throws -> URLRequest {
        let observed = try await client.call(.displayObserve(profile: profile, viewerID: nil))
        guard let ticket = observed["ticket"].text, !ticket.isEmpty else { throw BotFailure.unsupported }
        return try await client.http.screenUpgrade(ticket: ticket)
    }
}

/// Holds the newest picture and hands it straight to the layer on screen, so frames never
/// invalidate SwiftUI. A layer that attaches later, or again, shows the last one.
@MainActor final class ScreenFrameStore {
    private(set) var image: CGImage?
    weak var layer: CALayer? {
        didSet { show() }
    }

    func show(_ image: CGImage) {
        self.image = image
        show()
    }

    private func show() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

/// Owns one open Screen view: its gateway client, its stream and its state. Streams only while
/// `open()` holds, which the view limits to being on screen with the app not in the background.
/// A generation token rejects anything a stream or call from before the last `open()` or
/// `close()` delivers late.
@MainActor @Observable final class ScreenSession {
    enum Phase: Equatable {
        case connecting
        /// Frames are arriving.
        case live
        /// The stream dropped. The last picture stays, dimmed, while this retries.
        case reconnecting
        /// The screen isn't running.
        case stopped
        /// The host answers `display.status` but can't run a screen.
        case unsupported
        /// The host has no `display.*` methods.
        case unavailable
        /// Retrying won't help until something changes on the host or in front of it.
        case failed
    }

    /// Tests script the socket and shorten the waits; production takes the defaults.
    struct Options {
        var backoff: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
        var rfb = RFBClient.Options()
        /// Gets the finished upgrade; nil opens a native socket on the connection's session.
        var socketFactory: ((URLRequest) -> any RFBSocket)?
    }

    let profile: String
    let source: ScreenSource
    private(set) var phase = Phase.connecting
    private(set) var holder = ScreenStatus.Holder.agent
    @ObservationIgnored let frames = ScreenFrameStore()

    @ObservationIgnored private let client: BotClient
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stream: Task<Void, Never>?
    /// Attempts since the last frame, which picks the next wait.
    @ObservationIgnored private var failures = 0
    /// Wakes a backoff wait early when the network changes.
    @ObservationIgnored private var wait: Task<Void, Never>?

    init(profile: String, source: ScreenSource = .botDesktop, client: BotClient, options: Options = Options()) {
        self.profile = profile
        self.source = source
        self.client = client
        self.options = options
    }

    /// Starts or restarts the stream.
    func open() {
        stop()
        failures = 0
        if phase != .live, phase != .reconnecting { set(.connecting) }
        let owner = generation
        stream = Task { [weak self] in await self?.run(owner) }
    }

    /// Ends the stream and this view's part of the gateway socket.
    func close() {
        stop()
        client.close()
        if phase == .live { set(.reconnecting) }
    }

    /// Retries now rather than at the end of the wait: a new path often fixes a dropped stream.
    func networkDidChange() {
        wait?.cancel()
    }

    private func stop() {
        generation += 1
        stream?.cancel()
        stream = nil
        wait?.cancel()
        wait = nil
    }

    private func set(_ phase: Phase) {
        if self.phase != phase { self.phase = phase }
    }

    private func run(_ owner: Int) async {
        while owner == generation {
            do {
                try await streamOnce(owner)
            } catch {
                guard owner == generation else { return }
                let reason = HermesConnectionLog.reason(error)
                HermesConnectionLog.logger.notice("screen stream ended: \(reason, privacy: .public)")
                switch ScreenStreamOutcome(error) {
                case .settled(let phase):
                    set(phase)
                    return
                case .reopen where failures == 0:
                    // A spent or expired ticket: a new one fixes it, once.
                    failures = 1
                    continue
                case .reopen, .retry:
                    break
                }
            }
            guard owner == generation else { return }
            set(.reconnecting)
            let delay = options.backoff[min(failures, options.backoff.count - 1)]
            failures += 1
            await pause(delay)
        }
    }

    /// One pass: reads the state and, while the screen runs, streams until the stream ends.
    /// Returns only for a state with nothing to stream.
    private func streamOnce(_ owner: Int) async throws {
        do { try await client.connect() } catch BotFailure.stale {
            // Only a replaced connection refuses to join: this client can never reach the host
            // again. A call's `.stale` is only a socket lost between calls, which a retry fixes.
            throw ScreenStreamEnd.settled(.failed)
        }
        let status = try await source.status(profile: profile, client: client)
        guard owner == generation else { return }
        holder = status.holder
        guard status.supported else { throw ScreenStreamEnd.settled(.unsupported) }
        guard status.running else { throw ScreenStreamEnd.settled(.stopped) }
        let upgrade = try await source.streamUpgrade(profile: profile, client: client)
        guard owner == generation else { return }
        let rfb = RFBClient(socket: makeSocket(upgrade), options: options.rfb) { [weak self] image in
            await self?.deliver(image, owner)
        }
        try await rfb.run()
    }

    private func deliver(_ image: CGImage, _ owner: Int) {
        guard owner == generation else { return }
        frames.show(image)
        failures = 0
        set(.live)
    }

    private func makeSocket(_ upgrade: URLRequest) -> any RFBSocket {
        if let socketFactory = options.socketFactory { return socketFactory(upgrade) }
        let task = client.http.session.webSocketTask(with: upgrade)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return NativeRFBSocket(task: task)
    }

    private func pause(_ duration: Duration) async {
        let wait = Task { _ = try? await Task.sleep(for: duration) }
        self.wait = wait
        await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
    }
}

/// Thrown by a pass that found a state rather than a stream.
private enum ScreenStreamEnd: Error {
    case settled(ScreenSession.Phase)
}

/// What a stream's end means for the next attempt.
private enum ScreenStreamOutcome {
    /// Nothing to retry: show this.
    case settled(ScreenSession.Phase)
    /// Open again with a new ticket.
    case reopen
    /// Wait out the backoff, then open again.
    case retry

    init(_ error: Error) {
        switch error {
        case ScreenStreamEnd.settled(let phase):
            self = .settled(phase)
        case RFBStreamEnd.closed(code: 4401):
            self = .reopen
        case RFBStreamEnd.closed(code: 4001):
            self = .settled(.stopped)
        case RFBStreamEnd.closed(code: 1003), is RFBFailure:
            self = .settled(.failed)
        case let failure as ScreenCallFailure:
            if failure.code == -32601 { self = .settled(.unavailable) }
            // 5300 with no refusal is a state: observe found no screen running.
            else if failure.code == 5300, failure.refusal == nil { self = .settled(.stopped) }
            else { self = .settled(.failed) }
        default:
            // A sign-in the host refused or a socket it won't upgrade doesn't heal on its own.
            self = BotConnectionAdvice.isRetryable(error) ? .retry : .settled(.failed)
        }
    }
}
