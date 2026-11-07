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
    /// The host's own words, which say why a start was refused.
    var message: String?
}

/// `display.status`, read tolerantly: `display.observe` carries the same fields.
struct ScreenStatus: Equatable {
    let supported: Bool
    let installed: Bool
    let running: Bool
    /// Why it can't start now: too little memory, or a sandbox image with no desktop.
    let blocker: String?
    /// What installs the desktop on this host, as the user would type it there.
    let installCommand: String?
    let lease: ScreenLease
    /// Names this screen in the `display.lease` event, which reaches every attached client.
    let profileKey: String?
    /// What only a host desktop reports; nil on a bot's own.
    var host: ScreenHostFacts?

    init(_ json: BotJSON) {
        supported = json["supported"].flag ?? false
        // A host that omits it has shown no sign of lacking anything.
        installed = json["installed"].flag ?? true
        running = json["running"].flag ?? false
        blocker = json["blocker"].text?.nonEmptyTrimmed
        installCommand = json["install_command"].text?.nonEmptyTrimmed
        lease = ScreenLease(json["lease"])
        profileKey = json["profile_key"].text
    }
}

/// hermex-screen's `/status`, read tolerantly.
struct ScreenHostFacts: Equatable {
    /// Why this host refuses, in the plugin's words: an unsupported platform, or Windows without
    /// its opt-in.
    let refusal: String?
    /// Why the driver can't do the job, in the plugin's words.
    let driverProblem: String?
    let lacksAccessibility: Bool
    let lacksScreenRecording: Bool
    let isLocked: Bool
    /// Whether keys typed from the phone can reach this host's lock screen.
    let canUnlock: Bool

    init(_ json: BotJSON) {
        refusal = json["refusal"].text
        driverProblem = json["driver"]["problem"].text
        // Only an explicit false: a driver that can't say is reported as a driver problem.
        lacksAccessibility = json["permissions"]["accessibility"].flag == false
        lacksScreenRecording = json["permissions"]["screen_recording"].flag == false
        isLocked = json["locked"].flag ?? false
        canUnlock = json["locked_input"].flag ?? false
    }
}

extension ScreenStatus {
    /// A hermex-screen host: its desktop is always there, unless its facts say otherwise.
    init(host json: BotJSON) {
        self.init(.object(["supported": .bool(true), "running": .bool(true), "lease": json["lease"]]))
        host = ScreenHostFacts(json)
    }

    /// What a screen that isn't running shows. The host's blocker comes first: a sandbox missing
    /// its desktop image reports that as well as the missing packages, and installing on the
    /// host wouldn't fix it.
    var settledPhase: ScreenSession.Phase {
        if let blocker { return .blocked(blocker) }
        if !installed { return .needsPackages(command: installCommand) }
        return .stopped
    }
}

/// `display.observe`: a ticket for one stream, and the viewer id this gateway connection minted.
struct ScreenObservation: Equatable {
    let ticket: String
    let viewerID: String
    let status: ScreenStatus
}

/// Where the picture comes from: a bot's own virtual desktop through stock `display.*` and
/// `/api/display/ws`, or the real logged-in desktop through the hermex-screen plugin. Each case
/// supplies its status, stream and lease, and nothing above this branches on the host except what
/// it calls itself.
enum ScreenSource: String, Codable, Equatable, Sendable {
    case botDesktop, hostDesktop

    /// The current state of `profile`'s screen. The plugin's isn't per Profile: its one desktop
    /// is every bot's.
    func status(profile: String, client: BotClient) async throws -> ScreenStatus {
        switch self {
        case .botDesktop:
            return ScreenStatus(try await client.call(.displayStatus(profile: profile)))
        case .hostDesktop:
            do {
                return ScreenStatus(host: try await Self.json(.screenStatus, client))
            } catch BotFailure.rejected(404) {
                // The plugin has gone. Stock still reports the lease it left.
                return try await Self.botDesktop.status(profile: profile, client: client)
            }
        }
    }

    /// A ticket and viewer id. Each is new, and a hold under an older id moves to it.
    func observe(profile: String, client: BotClient) async throws -> ScreenObservation {
        switch self {
        case .botDesktop:
            let reply = try await client.call(.displayObserve(profile: profile, viewerID: nil))
            guard let ticket = reply["ticket"].text, !ticket.isEmpty,
                  let viewer = reply["viewer_id"].text, !viewer.isEmpty
            else { throw BotFailure.unsupported }
            return ScreenObservation(ticket: ticket, viewerID: viewer, status: ScreenStatus(reply))
        case .hostDesktop:
            let reply = try await Self.json(.screenObserve, client)
            guard let ticket = reply["stream_ticket"].text, !ticket.isEmpty,
                  let viewer = reply["viewer_id"].text, !viewer.isEmpty
            else { throw BotFailure.unsupported }
            return ScreenObservation(ticket: ticket, viewerID: viewer, status: ScreenStatus(host: reply))
        }
    }

    /// The upgrade for the stream `ticket` opens.
    func streamUpgrade(ticket: String, client: BotClient) async throws -> URLRequest {
        switch self {
        case .botDesktop: return try await client.http.screenUpgrade(ticket: ticket)
        case .hostDesktop: return try await client.http.screenPluginUpgrade(streamTicket: ticket)
        }
    }

    func acquire(profile: String, viewerID: String, client: BotClient) async throws -> ScreenLease {
        switch self {
        case .botDesktop:
            return ScreenLease(try await client.call(.displayLeaseAcquire(profile: profile, viewerID: viewerID))["lease"])
        case .hostDesktop:
            return ScreenLease(try await Self.json(.screenAcquire(viewerID: viewerID), client)["lease"])
        }
    }

    /// Clears any holder: the force Hand Back. A hold left by a plugin that has since been removed
    /// holds every Profile's stock lease, so without the plugin this clears them there.
    func releaseAny(profile: String, client: BotClient) async throws -> ScreenLease {
        switch self {
        case .botDesktop:
            return ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: nil))["lease"])
        case .hostDesktop:
            do {
                return ScreenLease(try await Self.json(.screenRelease(viewerID: nil), client)["lease"])
            } catch BotFailure.rejected(404) {
                return try await Self.releaseOnEveryProfile(profile: profile, viewerID: nil, client: client)
            }
        }
    }

    /// A plugin that has gone leaves its hold on every Profile's stock lease, with nothing left to
    /// end it. An id releases only itself; nil clears any holder. Answers `profile`'s lease.
    private static func releaseOnEveryProfile(profile: String, viewerID: String?, client: BotClient) async throws -> ScreenLease {
        let roster = try await client.call(.profilesList(includeSessions: false))
        for other in roster["profiles"].list?.compactMap({ $0["name"].text }) ?? [] where other != profile {
            _ = try await client.call(.displayLeaseRelease(profile: other, viewerID: viewerID))
        }
        return ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: viewerID))["lease"])
    }

    /// Releases `hold`, naming each id it may be under. The host answers success whether or not an
    /// id held, and leaves another person's takeover in place, so this throws unless the last
    /// lease shows none of them holding.
    func release(_ hold: ScreenHold, profile: String, client: BotClient) async throws -> ScreenLease {
        var lease: ScreenLease?
        for viewerID in hold.viewerIDs {
            switch self {
            case .botDesktop:
                lease = ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: viewerID))["lease"])
            case .hostDesktop:
                do {
                    lease = ScreenLease(try await Self.json(.screenRelease(viewerID: viewerID), client)["lease"])
                } catch BotFailure.rejected(404) {
                    lease = try await Self.releaseOnEveryProfile(profile: profile, viewerID: viewerID, client: client)
                }
            }
        }
        guard let lease, hold.holder(of: lease) == nil else { throw BotFailure.unsupported }
        return lease
    }

    /// Starts the screen, returning once it's up. Only a bot's desktop starts and stops.
    func start(profile: String, client: BotClient) async throws {
        _ = try await client.call(.displayStart(profile: profile))
    }

    /// Stops the screen. `force` is for one a person holds, which the host otherwise refuses.
    func stop(profile: String, force: Bool, client: BotClient) async throws {
        _ = try await client.call(.displayStop(profile: profile, force: force))
    }

    private static func json(_ rest: HermesREST, _ client: BotClient) async throws -> BotJSON {
        let data = try await client.http.data(rest)
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}

/// The hermex-screen plugin as this build knows it (#1567). The app pins one commit, so a fix reaches
/// normal users through an app update; testers can install a newer one from the command line.
enum HermexScreenPlugin {
    static let name = "hermex-screen"
    static let installIdentifier = "uzairansaruzi/hermex-screen"
    static let pinnedCommit = "dad2cf0ebb5017eee05eddd0fc19ea44ab0a72e6"

    /// Whether its routes are live, from `GET /capabilities`' status and body.
    enum State: Equatable {
        /// A 200: the routes are mounted, including a hot-mount on newer hosts.
        case live
        /// The dashboard's own "Plugin not found": off or not installed.
        case notInstalled
        /// A catch-all 404: it's enabled, but this dashboard never mounted it. A restart may help.
        case notMounted
        /// FastAPI's bare "Not Found": a newer host tried to mount it and failed, so a restart won't help.
        case failedToLoad

        init?(status: Int, body: BotJSON) {
            switch status {
            case 200..<300: self = .live
            case 404:
                switch HermexPushPlugin.missingRoute(body) {
                case .pluginOff: self = .notInstalled
                case .notMounted: self = .notMounted
                case nil:
                    guard body["detail"].text == "Not Found" else { return nil }
                    self = .failedToLoad
                }
            default: return nil
            }
        }
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
        /// The screen isn't running, and can start.
        case stopped
        /// `display.start` is on its way.
        case starting
        /// The screen can't start, in the host's words.
        case blocked(String)
        /// The desktop packages are missing. The command is the host's, when it has a package manager.
        case needsPackages(command: String?)
        /// This host has no stock screen and no plugin. Nothing runs until the user consents.
        case pluginNotInstalled
        /// The install or the restart is on its way.
        case pluginBusy
        /// Installed, but this dashboard hasn't mounted it. `canRestart` when hermex-push offers it.
        case pluginNeedsRestart(canRestart: Bool)
        /// A newer host tried to mount it and failed, so the dashboard's log says why.
        case pluginFailed
        /// The host refuses, or its driver can't do the job, in the plugin's words.
        case hostRefused(String)
        case driverProblem(String)
        /// What to grant at the host. These can't be granted from a phone.
        case permissionsMissing(accessibility: Bool, screenRecording: Bool)
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
        case stopFailed
        case pluginActionFailed
    }

    /// Tests script the socket and shorten the waits; production takes the defaults.
    struct Options {
        var backoff: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
        var rfb = RFBClient.Options()
        var idlePrompt = ScreenIdlePolicy.prompt
        var idleLimit = ScreenIdlePolicy.limit
        /// How soon a hand-back at the limit that failed tries again.
        var idleRetry: Duration = .seconds(15)
        var holds: ScreenHoldStore = .shared
        var now: () -> Date = { Date() }
        /// Gets the finished upgrade; nil opens a native socket on the connection's session.
        var socketFactory: ((URLRequest) -> any RFBSocket)?
        /// How long before reading a missing plugin's route again, since a hot-mount can be in flight.
        var pluginRecheck: Duration = .seconds(1)
        /// Remove acts on this session's Profile, for the Plugins screen, which names one. Otherwise it
        /// acts on the dashboard's own Profile, the one this screen's Install puts the plugin on.
        var removesFromItsProfile = false
        /// How often an open host stream re-reads whether its screen is locked.
        var lockPoll: Duration = .seconds(20)
    }

    let profile: String
    let title: String
    /// Settled by the first read: stock support decides it, and a host without moves to the plugin.
    private(set) var source: ScreenSource = .botDesktop
    /// The host's screen is locked, so the picture shows only that.
    private(set) var isHostLocked = false
    private(set) var canUnlockHost = false
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
    /// Whether the host is a gateway's Webapp, whose restart on the host is the gateway's (#1606).
    var servesWebapp: Bool { client.http.servesWebapp }
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
    @ObservationIgnored private var lockWatch: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    /// Newer than the saved hold's while this view is open; nil until it has seen the hold.
    @ObservationIgnored private var lastInput: Date?
    /// A release is on its way, so its own `display.lease` event isn't news.
    @ObservationIgnored private var isReleasing = false
    /// A Take Over on its way. A host's goes by HTTP, so a release sent after it can overtake it.
    @ObservationIgnored private var acquiring: Task<Void, Never>?
    /// Where the trackpad's pointer is, in framebuffer pixels.
    @ObservationIgnored private var pointer: (x: Int, y: Int)?

    init(profile: String, title: String, server: URL, client: BotClient, options: Options = Options()) {
        self.profile = profile
        self.title = title
        self.server = server
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
        options.holds.idleNotification.cancel(server: server, profile: profile)
        if phase != .live, phase != .reconnecting { set(.connecting) }
        let owner = generation
        stream = Task { [weak self] in await self?.run(owner) }
    }

    /// The app went to the background: the stream stops and control stays. The close is not a
    /// clean one (`NativeRFBSocket.close`), and the local notice covers a phone that never returns.
    func suspend() {
        persistLastInput()
        if control == .mine, let lastInput {
            options.holds.idleNotification.schedule(server: server, profile: profile, title: title,
                                                    at: lastInput.addingTimeInterval(TimeInterval(options.idleLimit.components.seconds)))
        }
        stopStream()
        idleTimer?.cancel()
        client.close()
        if phase == .live { set(.reconnecting) }
        // Going to the background ended the call, so the state needs reading again on return.
        if phase == .starting { set(.connecting) }
    }

    /// The app came back to the front, from the background or just Control Center. A live stream
    /// and a Start still on its way carry on; anything else reads the state again.
    func returnToForeground() {
        guard phase != .live, phase != .starting else { return }
        open()
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
        let acquiring = acquiring
        Task {
            // On a host, a release sent ahead of the acquire would finish first and leave the
            // acquire to pause every bot with nobody watching. A gateway call keeps its order.
            if hold.source == .hostDesktop { await acquiring?.value }
            // Only what this view took: the store is shared, and a reopened Screen may hold it by now.
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
        lockWatch?.cancel()
        lockWatch = nil
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
                switch ScreenStreamOutcome(error, source: source) {
                case .settled(let phase):
                    set(phase)
                    return
                case .evicted:
                    // Last Take Over wins: this viewer drops to watching, on a new ticket.
                    forgetHold(notice: .someoneTookOver, control: .other)
                    continue
                case .handedBack:
                    // The plugin's own timer, which runs whether or not the phone is connected.
                    forgetHold(notice: .handedBackAutomatically, control: .bot)
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
        // Always the stock read: it's what decides which kind of screen this is.
        let status = try await ScreenSource.botDesktop.status(profile: profile, client: client)
        guard owner == generation else { return }
        profileKey = status.profileKey
        guard status.supported else {
            try await settleHost(stock: status, owner)
            try await streamFrom(.hostDesktop, owner)
            return
        }
        source = .botDesktop
        guard status.running else {
            // Stopping a screen ends its lease, so a hold from before that is over.
            settleBlockedControl(status.lease)
            throw ScreenStreamEnd.settled(status.settledPhase)
        }
        try await streamFrom(.botDesktop, owner)
    }

    /// A host with no stock screen. Reads the plugin's route, and throws the state to show unless
    /// the plugin is ready to stream. `stock` still reports the lease on every host, so a takeover
    /// left by a plugin that has since gone still shows, with its force Hand Back.
    private func settleHost(stock: ScreenStatus, _ owner: Int) async throws {
        source = .hostDesktop
        var state = try await pluginState()
        if state == .notMounted {
            try await Task.sleep(for: options.pluginRecheck)
            state = try await pluginState()
        }
        guard owner == generation else { throw CancellationError() }
        if state != .live { settleBlockedControl(stock.lease) }
        switch state {
        case .live: break
        case .notInstalled:
            throw ScreenStreamEnd.settled(.pluginNotInstalled)
        case .notMounted:
            let routes = try? await BotDashboardClient(http: client.http).companionRoutes()
            // hermex-push's restart skips the drain of a gateway that serves the Webapp (#1606).
            throw ScreenStreamEnd.settled(.pluginNeedsRestart(
                canRestart: routes?.routes.contains("POST /restart") == true && !client.http.servesWebapp))
        case .failedToLoad:
            throw ScreenStreamEnd.settled(.pluginFailed)
        }
        let status = try await ScreenSource.hostDesktop.status(profile: profile, client: client)
        guard owner == generation, let facts = status.host else { throw CancellationError() }
        if facts.refusal != nil || facts.driverProblem != nil || facts.lacksAccessibility || facts.lacksScreenRecording {
            settleBlockedControl(status.lease)
        }
        if let refusal = facts.refusal { throw ScreenStreamEnd.settled(.hostRefused(refusal)) }
        if let problem = facts.driverProblem { throw ScreenStreamEnd.settled(.driverProblem(problem)) }
        if facts.lacksAccessibility || facts.lacksScreenRecording {
            throw ScreenStreamEnd.settled(.permissionsMissing(accessibility: facts.lacksAccessibility,
                                                              screenRecording: facts.lacksScreenRecording))
        }
        apply(facts)
    }

    private func apply(_ facts: ScreenHostFacts) {
        if isHostLocked != facts.isLocked { isHostLocked = facts.isLocked }
        if canUnlockHost != facts.canUnlock { canUnlockHost = facts.canUnlock }
    }

    /// A screen can lock or unlock while its stream runs, and only `/status` says so.
    private func watchHostLock(_ owner: Int) {
        lockWatch?.cancel()
        lockWatch = Task { [weak self] in
            while let interval = self?.options.lockPoll {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, owner == self.generation else { return }
                guard let status = try? await ScreenSource.hostDesktop.status(profile: self.profile, client: self.client),
                      owner == self.generation else { continue }
                if let facts = status.host { self.apply(facts) }
            }
        }
    }

    private func pluginState() async throws -> HermexScreenPlugin.State {
        let reply = try await client.http.reply(.screenCapabilities)
        let body = (try? JSONDecoder().decode(BotJSON.self, from: reply.body)) ?? .null
        guard let state = HermexScreenPlugin.State(status: reply.status, body: body) else {
            throw BotFailure.rejected(reply.status)
        }
        return state
    }

    /// Spends a ticket on `source`'s stream, and reads frames until it ends.
    private func streamFrom(_ source: ScreenSource, _ owner: Int) async throws {
        let observed = try await source.observe(profile: profile, client: client)
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
        if source == .hostDesktop { watchHostLock(owner) }
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
            settleLostHold(lease)
            return
        }
        // This view's own input counts: the saved time only moves when the app leaves the foreground.
        let last = max(hold.lastInput, lastInput ?? .distantPast)
        if options.now() >= last.addingTimeInterval(TimeInterval(options.idleLimit.components.seconds)) {
            await release(hold, owner: owner)
            if self.hold == nil { notice = .handedBackAutomatically } else { set(.mine) }
            return
        }
        let moving = ScreenHold(viewerIDs: [holder, observed.viewerID], isConfirmed: true, lastInput: last, source: source)
        options.holds.save(moving, server: server, profile: profile)
        let taken = try await source.acquire(profile: profile, viewerID: observed.viewerID, client: client)
        guard taken.isHeld(by: observed.viewerID) else { return }
        options.holds.save(ScreenHold(viewerIDs: [observed.viewerID], isConfirmed: true, lastInput: last, source: source),
                           server: server, profile: profile)
        guard owner == generation else { return }
        lastInput = last
        set(.mine)
        startIdleTimer()
    }

    /// Who holds a screen in a state with no stream, so its Hand Back or force shows there too.
    private func settleBlockedControl(_ lease: ScreenLease) {
        if let hold, hold.holder(of: lease) != nil {
            set(.mine)
        } else if hold != nil {
            settleLostHold(lease)
        } else {
            set(lease.holder == .human ? .other : .bot)
        }
    }

    /// A saved hold the host doesn't show: handed back or taken while this iPhone was away, or an
    /// acquire that never landed, which goes quietly. A hold it does show stays for the next read.
    private func settleLostHold(_ lease: ScreenLease) {
        guard let hold, hold.holder(of: lease) == nil else { return }
        forgetHold(notice: !hold.isConfirmed ? nil : lease.holder == .human ? .someoneTookOver : .returnedToBot,
                   control: lease.holder == .human ? .other : .bot)
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

    // MARK: - Start and stop

    /// Starts the screen, then streams it. A refusal shows the host's reason.
    func start() {
        stopStream()
        set(.starting)
        let owner = generation
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.connect()
                try await self.source.start(profile: self.profile, client: self.client)
                guard owner == self.generation else { return }
                self.open()
            } catch let failure as ScreenCallFailure where failure.code == 5300 {
                guard owner == self.generation else { return }
                self.set(failure.message?.nonEmptyTrimmed.map(Phase.blocked) ?? .failed)
            } catch {
                guard owner == self.generation else { return }
                self.set(.failed)
            }
        }
    }

    /// Stops the screen. Only offered to someone not holding it, and `force` overrides another
    /// person's takeover, which the view confirms first.
    func stopScreen(force: Bool) {
        stopStream()
        notice = nil
        let owner = generation
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.connect()
                try await self.source.stop(profile: self.profile, force: force, client: self.client)
                guard owner == self.generation else { return }
                self.open()
            } catch {
                guard owner == self.generation else { return }
                self.notice = .stopFailed
                self.open()
            }
        }
    }

    // MARK: - The plugin

    /// Installs the pinned plugin, from a consented tap only, then reads where that leaves things.
    /// Newer hosts hot-mount it; older ones land on the restart state.
    func installPlugin() {
        runPluginAction { [self] dashboard in
            try await dashboard.installPlugin(identifier: HermexScreenPlugin.installIdentifier, ref: HermexScreenPlugin.pinnedCommit)
        }
    }

    /// Restarts the dashboard through hermex-push, from a confirmed tap only. The gateway socket
    /// drops with it, and the read that follows waits out the restart's backoff.
    func restartForPlugin() {
        runPluginAction { dashboard in
            try await dashboard.restartHermes()
        }
    }

    /// Hermes runs no plugin code on removal, so any hold has to go first, or it would stay held
    /// with nothing left to end it.
    func removePlugin() {
        let hold = hold
        runPluginAction { [self] dashboard in
            if let hold { _ = try await hold.source.release(hold, profile: profile, client: client) }
            // Someone can take over while the confirmation is open. Removing the plugin then would
            // leave their takeover with nothing to end it.
            guard try await ScreenSource.hostDesktop.status(profile: profile, client: client).lease.holder != .human else {
                throw BotFailure.unsupported
            }
            options.holds.save(nil, server: server, profile: profile)
            if options.removesFromItsProfile {
                _ = try await HermesPluginsClient(http: client.http).remove(key: HermexScreenPlugin.name, profile: profile)
            } else {
                try await dashboard.removePlugin(HermexScreenPlugin.name)
            }
        }
    }

    private func runPluginAction(_ action: @escaping (BotDashboardClient) async throws -> Void) {
        stopStream()
        set(.pluginBusy)
        notice = nil
        let owner = generation
        stream = Task { [weak self] in
            guard let self else { return }
            do {
                try await action(BotDashboardClient(http: self.client.http))
                guard owner == self.generation else { return }
                self.open()
            } catch {
                guard owner == self.generation else { return }
                self.notice = .pluginActionFailed
                self.open()
            }
        }
    }

    // MARK: - Control

    /// Take Over. The bot's tools answer `human_has_control` from the host's reply on. The hold is
    /// saved first, so a phone that suspends before the reply can still find it on return.
    func takeOver() {
        guard let viewerID else { return }
        let owner = generation
        let taken = options.now()
        let source = source
        options.holds.save(ScreenHold(viewerIDs: [viewerID], isConfirmed: false, lastInput: taken, source: source),
                           server: server, profile: profile)
        acquiring = Task {
            do {
                let lease = try await source.acquire(profile: profile, viewerID: viewerID, client: client)
                guard lease.isHeld(by: viewerID) else { throw BotFailure.unsupported }
                // A late reply can't replace what's been saved since, or bring back what's been released.
                if hold?.viewerIDs == [viewerID] {
                    options.holds.save(ScreenHold(viewerIDs: [viewerID], isConfirmed: true, lastInput: taken, source: source),
                                       server: server, profile: profile)
                }
                guard owner == generation else { return }
                lastInput = taken
                notice = nil
                set(.mine)
                startIdleTimer()
            } catch let failure where failure is ScreenCallFailure || failure as? BotFailure == .unsupported
                || failure as? BotFailure == .rejected(409) {
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
            let lease = try await hold.source.release(hold, profile: profile, client: client)
            options.holds.forget(viewerIDs: hold.viewerIDs, server: server, profile: profile)
            options.holds.idleNotification.cancel(server: server, profile: profile)
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
        options.holds.idleNotification.cancel(server: server, profile: profile)
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
                    guard self.control == .mine else {
                        self.notice = .handedBackAutomatically
                        self.isAskingStillThere = false
                        return
                    }
                    // It didn't go through, and a stock lease never expires: try again until it does.
                    do { try await Task.sleep(for: self.options.idleRetry) } catch { return }
                    continue
                }
                let isPast = elapsed >= self.options.idlePrompt
                if isPast != self.isAskingStillThere { self.isAskingStillThere = isPast }
                let next = isPast ? self.options.idleLimit : self.options.idlePrompt
                do { try await Task.sleep(for: next - elapsed) } catch { return }
            }
        }
    }

    /// "Keep Control". A plugin's timer runs on the host and counts only input it receives, so a host's
    /// also hears a pointer move to where the pointer already is. A stock host has no timer.
    func keepControl() {
        noteActivity()
        if source == .hostDesktop { movePointer(byX: 0, y: 0) }
    }

    /// Whether the plugin can be offered for removal: known to be on the host, with nobody's
    /// takeover on it, which removing it would leave stranded.
    var canRemovePlugin: Bool {
        guard source == .hostDesktop, control == .bot, hold == nil else { return false }
        switch phase {
        case .live, .reconnecting, .pluginNeedsRestart, .pluginFailed, .hostRefused, .driverProblem, .permissionsMissing:
            return true
        default:
            return false
        }
    }

    /// Every input.
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
    /// The host's own timer ended this viewer's takeover.
    case handedBack
    /// Open again with a new ticket.
    case reopen
    /// Wait out the backoff, then open again.
    case retry

    init(_ error: Error, source: ScreenSource) {
        switch error {
        case ScreenStreamEnd.settled(let phase):
            self = .settled(phase)
        case RFBStreamEnd.closed(code: 4000):
            self = .evicted
        case RFBStreamEnd.closed(code: 4002):
            self = .handedBack
        case RFBStreamEnd.closed(code: 4401):
            self = .reopen
        case RFBStreamEnd.closed(code: 4001):
            // A bot's screen stopped. A host's desktop has no such state: its read says what's wrong.
            self = source == .botDesktop ? .settled(.stopped) : .retry
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

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
