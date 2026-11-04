import CoreGraphics
import Foundation
import OSLog
import QuartzCore

/// The per-server Bot Screen settings (#1567). Set only from a Hermes server's page, so a webui
/// server never has them. Sign-out and server removal delete them.
enum BotScreenSettings {
    /// "Bot Screen (beta)": off by default.
    static func key(for server: URL) -> String { "botScreen.enabled|\(server.absoluteString)" }
    /// Whether taking control starts on the trackpad rather than direct touch.
    static func trackpadKey(for server: URL) -> String { "botScreen.usesTrackpad|\(server.absoluteString)" }

    static func remove(for server: URL, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: server))
        defaults.removeObject(forKey: trackpadKey(for: server))
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
    let supported: Bool
    let running: Bool
    let lease: ScreenLease
    /// Names this screen in the `display.lease` event, which reaches every attached client.
    let profileKey: String?

    init(_ json: BotJSON) {
        supported = json["supported"].flag ?? false
        running = json["running"].flag ?? false
        lease = ScreenLease(json["lease"])
        profileKey = json["profile_key"].text
    }
}

/// `display.observe`: a ticket for one stream, and the viewer id this gateway connection minted.
struct ScreenObservation: Equatable {
    let ticket: String
    let viewerID: String
    let status: ScreenStatus
}

/// Where the picture comes from. Only the bot's own virtual desktop for now (`display.*` and
/// `/api/display/ws`); each case supplies its status, stream and lease, and nothing above this
/// branches on the host.
enum ScreenSource {
    case botDesktop

    /// The current state of `profile`'s screen.
    func status(profile: String, client: BotClient) async throws -> ScreenStatus {
        ScreenStatus(try await client.call(.displayStatus(profile: profile)))
    }

    /// A ticket and viewer id. Offers `viewerID`, which comes back when this connection minted it.
    func observe(profile: String, viewerID: String?, client: BotClient) async throws -> ScreenObservation {
        let reply = try await client.call(.displayObserve(profile: profile, viewerID: viewerID))
        guard let ticket = reply["ticket"].text, !ticket.isEmpty,
              let viewer = reply["viewer_id"].text, !viewer.isEmpty
        else { throw BotFailure.unsupported }
        return ScreenObservation(ticket: ticket, viewerID: viewer, status: ScreenStatus(reply))
    }

    /// The upgrade for the stream `ticket` opens.
    func streamUpgrade(ticket: String, client: BotClient) async throws -> URLRequest {
        try await client.http.screenUpgrade(ticket: ticket)
    }

    func acquire(profile: String, viewerID: String, client: BotClient) async throws -> ScreenLease {
        ScreenLease(try await client.call(.displayLeaseAcquire(profile: profile, viewerID: viewerID))["lease"])
    }

    /// Clears any holder: the force Hand Back.
    func releaseAny(profile: String, client: BotClient) async throws -> ScreenLease {
        ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: nil))["lease"])
    }

    /// Releases `hold`, naming each id it may be under. The host answers success whether or not an
    /// id held, and leaves another person's takeover in place, so this throws unless the last
    /// lease shows none of them holding.
    func release(_ hold: ScreenHold, profile: String, client: BotClient) async throws -> ScreenLease {
        var lease: ScreenLease?
        for viewerID in hold.viewerIDs {
            lease = ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: viewerID))["lease"])
        }
        guard let lease, hold.holder(of: lease) == nil else { throw BotFailure.unsupported }
        return lease
    }
}

/// Holds the newest picture and hands it straight to the layer on screen, so frames never
/// invalidate SwiftUI. A layer that attaches later, or again, shows the last one.
@MainActor final class ScreenFrameStore {
    private(set) var image: CGImage?
    /// Tells the canvas the picture's shape changed.
    var onSizeChange: (() -> Void)?
    weak var layer: CALayer? {
        didSet { show() }
    }
    /// A second place for the picture: the zoomed view's inset.
    weak var insetLayer: CALayer? {
        didSet { show() }
    }

    func show(_ image: CGImage) {
        let resized = image.width != self.image?.width || image.height != self.image?.height
        self.image = image
        show()
        if resized { onSizeChange?() }
    }

    private func show() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        insetLayer?.contents = image
        CATransaction.commit()
    }
}

/// Owns one open Screen view: its gateway client, its stream, who controls the screen, and the
/// input going to it. Streams only while the view is on screen with the app not in the background.
/// A generation token rejects anything a stream or call from before the last `open()` or
/// `suspend()` delivers late; a lease reply about a hold still updates the saved hold, which is
/// the host's truth rather than this view's.
///
/// The rules for keeping and returning control are in `docs/agents/screen.md`.
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

    enum Control: Equatable {
        case bot
        /// This iPhone holds it.
        case mine
        /// A person holds it from somewhere else, or from an app that never handed back.
        case other
    }

    /// One thing that happened which the state alone doesn't explain.
    enum Notice: Equatable {
        case someoneTookOver
        case handedBackAutomatically
        case returnedToBot
        case takeOverFailed
        case handBackFailed
        case forceFailed
    }

    /// Tests script the socket and shorten the waits; production takes the defaults.
    struct Options {
        var backoff: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
        var rfb = RFBClient.Options()
        var idlePrompt = ScreenIdlePolicy.prompt
        var idleLimit = ScreenIdlePolicy.limit
        var holds: ScreenHoldStore = .shared
        var now: () -> Date = { Date() }
        /// Gets the finished upgrade; nil opens a native socket on the connection's session.
        var socketFactory: ((URLRequest) -> any RFBSocket)?
    }

    let profile: String
    let title: String
    let source: ScreenSource
    private(set) var phase = Phase.connecting
    private(set) var control = Control.bot
    var notice: Notice?
    /// "Still there?": a minute of the idle limit is left.
    private(set) var isAskingStillThere = false
    /// Modifiers from the key row, which apply to the next key or click.
    private(set) var latchedModifiers: Set<ScreenKey> = []
    @ObservationIgnored let frames = ScreenFrameStore()

    @ObservationIgnored private let server: URL
    @ObservationIgnored private let client: BotClient
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stream: Task<Void, Never>?
    /// Attempts since the last frame, which picks the next wait.
    @ObservationIgnored private var failures = 0
    /// Wakes a backoff wait early when the network changes.
    @ObservationIgnored private var wait: Task<Void, Never>?
    /// The id this gateway connection minted, and what `display.lease` calls this screen.
    @ObservationIgnored private var viewerID: String?
    @ObservationIgnored private var profileKey: String?
    @ObservationIgnored private var rfb: RFBClient?
    /// The stream's handshake is done. The host's filter reads the first 14 client bytes as the
    /// handshake, so a key sent before this would corrupt it.
    @ObservationIgnored private var isStreamReady = false
    @ObservationIgnored private var input = ScreenInputQueue()
    @ObservationIgnored private var inputPump: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    /// Newer than the saved hold's while this view is open; nil until it has seen the hold.
    @ObservationIgnored private var lastInput: Date?
    /// A release is on its way, so its own `display.lease` event isn't news.
    @ObservationIgnored private var isReleasing = false
    /// Where the trackpad's pointer is, in framebuffer pixels.
    @ObservationIgnored private var pointer: (x: Int, y: Int)?

    init(profile: String, title: String, server: URL, source: ScreenSource = .botDesktop, client: BotClient,
         options: Options = Options()) {
        self.profile = profile
        self.title = title
        self.server = server
        self.source = source
        self.client = client
        self.options = options
        client.onEvent = { [weak self] event in self?.handle(event) }
        // A new gateway socket means a new viewer id, so everything starts again from the status.
        client.onDisconnect = { [weak self] _ in self?.restart() }
    }

    private var hold: ScreenHold? {
        options.holds.hold(server: server, profile: profile)
    }

    // MARK: - Lifetime

    /// Starts or restarts the stream.
    func open() {
        stopStream()
        failures = 0
        ScreenIdleNotification.cancel(server: server, profile: profile)
        if phase != .live, phase != .reconnecting { set(.connecting) }
        let owner = generation
        stream = Task { [weak self] in await self?.run(owner) }
    }

    /// The app went to the background: the stream stops and control stays. The close is not a
    /// clean one (`NativeRFBSocket.close`), and the local notice covers a phone that never returns.
    func suspend() {
        persistLastInput()
        if control == .mine, let lastInput {
            ScreenIdleNotification.schedule(server: server, profile: profile, title: title,
                                            at: lastInput.addingTimeInterval(TimeInterval(options.idleLimit.components.seconds)))
        }
        stopStream()
        idleTimer?.cancel()
        client.close()
        if phase == .live { set(.reconnecting) }
    }

    /// The view closed. Any saved hold hands back, then this view's part of the socket ends. That
    /// includes a Take Over whose reply hasn't come, which the host may already have granted.
    func leave() {
        stopStream()
        idleTimer?.cancel()
        guard let hold else {
            client.close()
            return
        }
        control = .bot
        Task {
            await release(hold, owner: nil)
            client.close()
        }
    }

    /// Retries now rather than at the end of the wait: a new path often fixes a dropped stream.
    func networkDidChange() {
        wait?.cancel()
    }

    private func restart() {
        guard stream != nil else { return }
        open()
    }

    private func stopStream() {
        generation += 1
        stream?.cancel()
        stream = nil
        wait?.cancel()
        wait = nil
        endStream()
        viewerID = nil
    }

    private func endStream() {
        rfb = nil
        isStreamReady = false
        input = ScreenInputQueue()
    }

    private func set(_ phase: Phase) {
        if self.phase != phase { self.phase = phase }
    }

    private func set(_ control: Control) {
        if self.control != control { self.control = control }
    }

    // MARK: - Stream

    private func run(_ owner: Int) async {
        while owner == generation {
            do {
                try await streamOnce(owner)
            } catch {
                guard owner == generation else { return }
                let reason = HermesConnectionLog.reason(error)
                HermesConnectionLog.logger.notice("screen stream ended: \(reason, privacy: .public)")
                endStream()
                switch ScreenStreamOutcome(error) {
                case .settled(let phase):
                    set(phase)
                    return
                case .evicted:
                    // Last Take Over wins: this viewer drops to watching, on a new ticket.
                    forgetHold(notice: .someoneTookOver, control: .other)
                    continue
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
        profileKey = status.profileKey
        guard status.supported else { throw ScreenStreamEnd.settled(.unsupported) }
        guard status.running else { throw ScreenStreamEnd.settled(.stopped) }
        let observed = try await source.observe(profile: profile, viewerID: nil, client: client)
        guard owner == generation else { return }
        viewerID = observed.viewerID
        try await settleControl(observed, owner)
        guard owner == generation else { return }
        let upgrade = try await source.streamUpgrade(ticket: observed.ticket, client: client)
        guard owner == generation else { return }
        let rfb = RFBClient(socket: makeSocket(upgrade), options: options.rfb) { [weak self] image in
            await self?.deliver(image, owner)
        }
        self.rfb = rfb
        try await rfb.run()
    }

    /// Works out who holds the screen after a new socket, and takes back a hold this iPhone still
    /// has. A new socket means a new viewer id, so a hold under the old one moves to the new one
    /// without a prompt. Stock hosts have no conditional acquire, so that can race another person's
    /// takeover in the moment between the read and the call; v1 accepts that.
    private func settleControl(_ observed: ScreenObservation, _ owner: Int) async throws {
        let lease = observed.status.lease
        guard let hold else {
            set(lease.holder == .human ? .other : .bot)
            return
        }
        guard let holder = hold.holder(of: lease) else {
            // Handed back or taken while this iPhone was away, or an acquire that never landed.
            forgetHold(notice: !hold.isConfirmed ? nil : lease.holder == .human ? .someoneTookOver : .returnedToBot,
                       control: lease.holder == .human ? .other : .bot)
            return
        }
        // This view's own input counts: the saved time only moves when the app leaves the foreground.
        let last = max(hold.lastInput, lastInput ?? .distantPast)
        if options.now() >= last.addingTimeInterval(TimeInterval(options.idleLimit.components.seconds)) {
            await release(hold, owner: owner)
            if self.hold == nil { notice = .handedBackAutomatically } else { set(.mine) }
            return
        }
        let moving = ScreenHold(viewerIDs: [holder, observed.viewerID], isConfirmed: true, lastInput: last)
        options.holds.save(moving, server: server, profile: profile)
        let taken = try await source.acquire(profile: profile, viewerID: observed.viewerID, client: client)
        guard taken.isHeld(by: observed.viewerID) else { return }
        options.holds.save(ScreenHold(viewerIDs: [observed.viewerID], isConfirmed: true, lastInput: last), server: server, profile: profile)
        guard owner == generation else { return }
        lastInput = last
        set(.mine)
        startIdleTimer()
    }

    private func deliver(_ image: CGImage, _ owner: Int) {
        guard owner == generation else { return }
        frames.show(image)
        failures = 0
        isStreamReady = true
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

    // MARK: - Control

    /// Take Over. The bot's tools answer `human_has_control` from the host's reply on. The hold is
    /// saved first, so a phone that suspends before the reply can still find it on return.
    func takeOver() {
        guard let viewerID else { return }
        let owner = generation
        let taken = options.now()
        options.holds.save(ScreenHold(viewerIDs: [viewerID], isConfirmed: false, lastInput: taken), server: server, profile: profile)
        Task {
            do {
                let lease = try await source.acquire(profile: profile, viewerID: viewerID, client: client)
                guard lease.isHeld(by: viewerID) else { throw BotFailure.unsupported }
                options.holds.save(ScreenHold(viewerIDs: [viewerID], isConfirmed: true, lastInput: taken), server: server, profile: profile)
                guard owner == generation else { return }
                lastInput = taken
                notice = nil
                set(.mine)
                startIdleTimer()
            } catch let failure where failure is ScreenCallFailure || failure as? BotFailure == .unsupported {
                // The host answered no.
                options.holds.forget(viewerIDs: [viewerID], server: server, profile: profile)
                guard owner == generation else { return }
                notice = .takeOverFailed
            } catch {
                // The reply was lost, so it may have landed. The next status read settles that.
                guard owner == generation else { return }
                notice = .takeOverFailed
                restart()
            }
        }
    }

    /// Hand Back. It counts as done only when the host's lease says this iPhone no longer holds.
    func handBack() {
        guard let hold else { return }
        let owner = generation
        Task { await release(hold, owner: owner) }
    }

    /// Clears whoever holds the screen, for a takeover nobody will end: the bot is blocked until
    /// someone does, and stock leases never expire. It sends no id, so it needs no hold of its own.
    func forceHandBack() {
        let owner = generation
        Task {
            do {
                let lease = try await source.releaseAny(profile: profile, client: client)
                options.holds.save(nil, server: server, profile: profile)
                guard owner == generation else { return }
                apply(lease)
                notice = nil
            } catch {
                guard owner == generation else { return }
                notice = .forceFailed
            }
        }
    }

    /// Releases `hold`, always naming its ids: the host releases one only if it still holds, so this
    /// can't revoke someone else's takeover, and `force` lets a new connection's call through.
    private func release(_ hold: ScreenHold, owner: Int?) async {
        isReleasing = true
        defer { isReleasing = false }
        do {
            let lease = try await source.release(hold, profile: profile, client: client)
            options.holds.forget(viewerIDs: hold.viewerIDs, server: server, profile: profile)
            ScreenIdleNotification.cancel(server: server, profile: profile)
            guard owner == generation else { return }
            idleTimer?.cancel()
            isAskingStillThere = false
            latchedModifiers = []
            set(lease.holder == .human ? .other : .bot)
        } catch {
            guard owner == generation else { return }
            notice = .handBackFailed
        }
    }

    private func forgetHold(notice: Notice?, control: Control) {
        options.holds.save(nil, server: server, profile: profile)
        ScreenIdleNotification.cancel(server: server, profile: profile)
        idleTimer?.cancel()
        isAskingStillThere = false
        latchedModifiers = []
        self.notice = notice
        set(control)
    }

    /// The `display.lease` event reaches every attached screen, and may repeat a reply already read.
    func handle(_ event: BotJSON) {
        guard event["type"].text == "display.lease", event["payload"]["profile_key"].text == profileKey, profileKey != nil else { return }
        apply(ScreenLease(event["payload"]["lease"]))
    }

    private func apply(_ lease: ScreenLease) {
        if let viewerID, lease.isHeld(by: viewerID) {
            set(.mine)
        } else if isReleasing, lease.holder == .agent {
            set(.bot)
        } else if control == .mine {
            forgetHold(notice: lease.holder == .human ? .someoneTookOver : .returnedToBot,
                       control: lease.holder == .human ? .other : .bot)
        } else {
            set(lease.holder == .human ? .other : .bot)
        }
    }

    // MARK: - Idle

    /// "Still there?" at the prompt, and a hand-back at the limit. The stock host has no timer of
    /// its own, so this only runs with the app open; `suspend` and `settleControl` cover the rest.
    private func startIdleTimer() {
        idleTimer?.cancel()
        let owner = generation
        idleTimer = Task { [weak self] in
            while let self, owner == self.generation, self.control == .mine {
                let elapsed = Duration.seconds(self.options.now().timeIntervalSince(self.lastInput ?? self.options.now()))
                if elapsed >= self.options.idleLimit {
                    guard let hold = self.hold else { return }
                    await self.release(hold, owner: owner)
                    if self.control != .mine { self.notice = .handedBackAutomatically }
                    self.isAskingStillThere = false
                    return
                }
                let isPast = elapsed >= self.options.idlePrompt
                if isPast != self.isAskingStillThere { self.isAskingStillThere = isPast }
                let next = isPast ? self.options.idleLimit : self.options.idlePrompt
                do { try await Task.sleep(for: next - elapsed) } catch { return }
            }
        }
    }

    /// "Keep Control", and every input.
    func noteActivity() {
        lastInput = options.now()
        if isAskingStillThere { isAskingStillThere = false }
    }

    private func persistLastInput() {
        guard control == .mine, var hold, let lastInput else { return }
        hold.lastInput = lastInput
        options.holds.save(hold, server: server, profile: profile)
    }

    // MARK: - Input

    /// Sends only while this iPhone holds control and a stream is up. Input isn't queued across a
    /// reconnect: keys typed into nothing would land long after the user stopped looking.
    private var canSendInput: Bool {
        control == .mine && isStreamReady
    }

    /// Moves the pointer by a trackpad's motion, kept on the picture. It starts at the center.
    func movePointer(byX dx: Int, y dy: Int, buttons: UInt8 = 0) {
        guard canSendInput, let image = frames.image else { return }
        noteActivity()
        let from = pointer ?? (image.width / 2, image.height / 2)
        let to = (x: min(max(from.x + dx, 0), image.width - 1), y: min(max(from.y + dy, 0), image.height - 1))
        pointer = to
        input.movePointer(x: to.x, y: to.y, buttons: buttons)
        pumpInput()
    }

    /// A press and release of `button` where the trackpad's pointer is.
    func clickAtPointer(button: UInt8) {
        guard let image = frames.image else { return }
        let at = pointer ?? (image.width / 2, image.height / 2)
        click(x: at.x, y: at.y, button: button)
    }

    /// A press and release of `button`, with any latched modifiers held around it.
    func click(x: Int, y: Int, button: UInt8) {
        guard canSendInput else { return }
        noteActivity()
        pointer = (x, y)
        withLatchedModifiers {
            input.movePointer(x: x, y: y, buttons: 0)
            input.append(RFBMessage.pointer(x: x, y: y, buttons: button))
            input.append(RFBMessage.pointer(x: x, y: y, buttons: 0))
        }
        pumpInput()
    }

    /// One tap of `key`, with any latched modifiers held around it.
    func press(_ key: ScreenKey) {
        guard canSendInput else { return }
        noteActivity()
        withLatchedModifiers {
            input.append(RFBMessage.key(key, down: true))
            input.append(RFBMessage.key(key, down: false))
        }
        pumpInput()
    }

    /// Text from the on-screen keyboard, Paste or AutoFill, a key at a time, in the order typed.
    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            if let key = ScreenKey(typing: scalar) { press(key) }
        }
    }

    /// A hardware key going down or up, passed through as it happens. The system ends every press
    /// before the app leaves the foreground, so none stays down on the host.
    func hardwareKey(_ key: ScreenKey, down: Bool) {
        guard canSendInput else { return }
        noteActivity()
        input.append(RFBMessage.key(key, down: down))
        pumpInput()
    }

    func toggleModifier(_ key: ScreenKey) {
        if latchedModifiers.remove(key) == nil { latchedModifiers.insert(key) }
    }

    private func withLatchedModifiers(_ body: () -> Void) {
        let modifiers = latchedModifiers
        for modifier in modifiers { input.append(RFBMessage.key(modifier, down: true)) }
        body()
        for modifier in modifiers { input.append(RFBMessage.key(modifier, down: false)) }
        if !modifiers.isEmpty { latchedModifiers = [] }
    }

    /// One send at a time. What piles up during a send goes out in the next frame.
    private func pumpInput() {
        guard inputPump == nil else { return }
        inputPump = Task { [weak self] in
            while let self, !self.input.isEmpty, let rfb = self.rfb {
                let batch = self.input.drain()
                // A failed send is the stream's to report, through its read.
                try? await rfb.send(batch)
            }
            self?.inputPump = nil
        }
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
    /// Someone else took over.
    case evicted
    /// Open again with a new ticket.
    case reopen
    /// Wait out the backoff, then open again.
    case retry

    init(_ error: Error) {
        switch error {
        case ScreenStreamEnd.settled(let phase):
            self = .settled(phase)
        case RFBStreamEnd.closed(code: 4000):
            self = .evicted
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
