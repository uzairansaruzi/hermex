import CoreGraphics
import Foundation
import OSLog
import QuartzCore

enum BotScreenSettings {
    static func key(for server: URL) -> String { "botScreen.enabled|\(server.absoluteString)" }
    static func trackpadKey(for server: URL) -> String { "botScreen.usesTrackpad|\(server.absoluteString)" }

    static func remove(for server: URL, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: server))
        defaults.removeObject(forKey: trackpadKey(for: server))
    }
}

struct ScreenCallFailure: Error, Equatable {
    let code: Int
    let refusal: String?
    var message: String?
}

struct ScreenStatus: Equatable {
    let supported: Bool
    let installed: Bool
    let running: Bool
    let blocker: String?
    let installCommand: String?
    let lease: ScreenLease
    let profileKey: String?
    var host: ScreenHostFacts?

    init(_ json: BotJSON) {
        supported = json["supported"].flag ?? false
        installed = json["installed"].flag ?? true
        running = json["running"].flag ?? false
        blocker = json["blocker"].text?.nonEmptyTrimmed
        installCommand = json["install_command"].text?.nonEmptyTrimmed
        lease = ScreenLease(json["lease"])
        profileKey = json["profile_key"].text
    }
}

struct ScreenHostFacts: Equatable {
    let refusal: String?
    let driverProblem: String?
    let lacksAccessibility: Bool
    let lacksScreenRecording: Bool
    let isLocked: Bool
    let canUnlock: Bool

    init(_ json: BotJSON) {
        refusal = json["refusal"].text
        driverProblem = json["driver"]["problem"].text
        lacksAccessibility = json["permissions"]["accessibility"].flag == false
        lacksScreenRecording = json["permissions"]["screen_recording"].flag == false
        isLocked = json["locked"].flag ?? false
        canUnlock = json["locked_input"].flag ?? false
    }
}

extension ScreenStatus {
    init(host json: BotJSON) {
        self.init(.object(["supported": .bool(true), "running": .bool(true), "lease": json["lease"]]))
        host = ScreenHostFacts(json)
    }

    var settledPhase: ScreenSession.Phase {
        if let blocker { return .blocked(blocker) }
        if !installed { return .needsPackages(command: installCommand) }
        return .stopped
    }
}

struct ScreenObservation: Equatable {
    let ticket: String
    let viewerID: String
    let status: ScreenStatus
}

enum ScreenSource: String, Codable, Equatable, Sendable {
    case botDesktop, hostDesktop

    func status(profile: String, client: BotClient) async throws -> ScreenStatus {
        switch self {
        case .botDesktop:
            return ScreenStatus(try await client.call(.displayStatus(profile: profile)))
        case .hostDesktop:
            do {
                return ScreenStatus(host: try await Self.json(.screenStatus, client))
            } catch BotFailure.rejected(404) {
                return try await Self.botDesktop.status(profile: profile, client: client)
            }
        }
    }

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

    private static func releaseOnEveryProfile(profile: String, viewerID: String?, client: BotClient) async throws -> ScreenLease {
        let roster = try await client.call(.profilesList(includeSessions: false))
        for other in roster["profiles"].list?.compactMap({ $0["name"].text }) ?? [] where other != profile {
            _ = try await client.call(.displayLeaseRelease(profile: other, viewerID: viewerID))
        }
        return ScreenLease(try await client.call(.displayLeaseRelease(profile: profile, viewerID: viewerID))["lease"])
    }

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

    func start(profile: String, client: BotClient) async throws {
        _ = try await client.call(.displayStart(profile: profile))
    }

    func stop(profile: String, force: Bool, client: BotClient) async throws {
        _ = try await client.call(.displayStop(profile: profile, force: force))
    }

    private static func json(_ rest: HermesREST, _ client: BotClient) async throws -> BotJSON {
        let data = try await client.http.data(rest)
        return (try? JSONDecoder().decode(BotJSON.self, from: data)) ?? .null
    }
}

enum HermexScreenPlugin {
    static let name = "hermex-screen"
    static let installIdentifier = "uzairansaruzi/hermex-screen"
    static let pinnedCommit = "463935999b5bfa11e7a25585869a387f804625e7"

    enum State: Equatable {
        case live
        case notInstalled
        case notMounted
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

@MainActor final class ScreenFrameStore {
    private(set) var image: CGImage?
    var onSizeChange: (() -> Void)?
    weak var layer: CALayer? {
        didSet { show() }
    }
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

@MainActor @Observable final class ScreenSession {
    enum Phase: Equatable {
        case connecting
        case live
        case reconnecting
        case stopped
        case starting
        case blocked(String)
        case needsPackages(command: String?)
        case pluginNotInstalled
        case pluginBusy
        case pluginNeedsRestart(canRestart: Bool)
        case pluginFailed
        case hostRefused(String)
        case driverProblem(String)
        case permissionsMissing(accessibility: Bool, screenRecording: Bool)
        case unavailable
        case failed
    }

    enum Control: Equatable {
        case bot
        case mine
        case other
    }

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

    struct Options {
        var backoff: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
        var rfb = RFBClient.Options()
        var idlePrompt = ScreenIdlePolicy.prompt
        var idleLimit = ScreenIdlePolicy.limit
        var idleRetry: Duration = .seconds(15)
        var holds: ScreenHoldStore = .shared
        var now: () -> Date = { Date() }
        var socketFactory: ((URLRequest) -> any RFBSocket)?
        var pluginRecheck: Duration = .seconds(1)
        var removesFromItsProfile = false
        var lockPoll: Duration = .seconds(20)
        var takesOverWhenLive = false
    }

    let profile: String
    let title: String
    private(set) var source: ScreenSource = .botDesktop
    private(set) var isHostLocked = false
    private(set) var canUnlockHost = false
    private(set) var phase = Phase.connecting
    private(set) var control = Control.bot
    var notice: Notice?
    private(set) var isAskingStillThere = false
    private(set) var latchedModifiers: Set<ScreenKey> = []
    @ObservationIgnored let frames = ScreenFrameStore()

    @ObservationIgnored private let server: URL
    @ObservationIgnored private let client: BotClient
    var servesWebapp: Bool { client.http.servesWebapp }
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var blindCaptureFailures = 0
    @ObservationIgnored private var wait: Task<Void, Never>?
    @ObservationIgnored private var viewerID: String?
    @ObservationIgnored private var profileKey: String?
    @ObservationIgnored private var rfb: RFBClient?
    @ObservationIgnored private var isStreamReady = false
    @ObservationIgnored private var input = ScreenInputQueue()
    @ObservationIgnored private var inputPump: Task<Void, Never>?
    @ObservationIgnored private var lockWatch: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private var lastInput: Date?
    @ObservationIgnored private var isReleasing = false
    @ObservationIgnored private var acquiring: Task<Void, Never>?
    @ObservationIgnored private var takesOverWhenLive: Bool
    @ObservationIgnored private var pointer: (x: Int, y: Int)?

    init(profile: String, title: String, server: URL, client: BotClient, options: Options = Options()) {
        self.profile = profile
        self.title = title
        self.server = server
        self.client = client
        self.options = options
        takesOverWhenLive = options.takesOverWhenLive
        client.onEvent = { [weak self] event in self?.handle(event) }
        client.onDisconnect = { [weak self] _ in self?.restart() }
    }

    private var hold: ScreenHold? {
        options.holds.hold(server: server, profile: profile)
    }

    func open() {
        stopStream()
        failures = 0
        blindCaptureFailures = 0
        options.holds.idleNotification.cancel(server: server, profile: profile)
        if phase != .live, phase != .reconnecting { set(.connecting) }
        let owner = generation
        stream = Task { [weak self] in await self?.run(owner) }
    }

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
        if phase == .starting { set(.connecting) }
    }

    func returnToForeground() {
        guard phase != .live, phase != .starting else { return }
        open()
    }

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
            if hold.source == .hostDesktop { await acquiring?.value }
            await release(hold, owner: nil)
            client.close()
        }
    }

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

    private func run(_ owner: Int) async {
        while owner == generation {
            do {
                try await streamOnce(owner)
            } catch {
                guard owner == generation else { return }
                let reason = HermesConnectionLog.reason(error)
                HermesConnectionLog.logger.notice("screen stream ended: \(reason, privacy: .public)")
                let sawFrame = isStreamReady
                endStream()
                switch ScreenStreamOutcome(error, source: source) {
                case .settled(let phase):
                    set(phase)
                    return
                case .evicted:
                    forgetHold(notice: .someoneTookOver, control: .other)
                    continue
                case .handedBack:
                    forgetHold(notice: .handedBackAutomatically, control: .bot)
                    continue
                case .reopen where failures == 0:
                    failures = 1
                    continue
                case .captureFailed where !sawFrame:
                    blindCaptureFailures += 1
                    if blindCaptureFailures >= 2 {
                        set(.driverProblem(String(localized: "This computer's driver couldn't capture the screen.")))
                        return
                    }
                case .reopen, .retry, .captureFailed:
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

    private func streamOnce(_ owner: Int) async throws {
        do { try await client.connect() } catch BotFailure.stale {
            throw ScreenStreamEnd.settled(.failed)
        }
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
            settleBlockedControl(status.lease)
            throw ScreenStreamEnd.settled(status.settledPhase)
        }
        try await streamFrom(.botDesktop, owner)
    }

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

    private func settleBlockedControl(_ lease: ScreenLease) {
        if let hold, hold.holder(of: lease) != nil {
            set(.mine)
        } else if hold != nil {
            settleLostHold(lease)
        } else {
            set(lease.holder == .human ? .other : .bot)
        }
    }

    private func settleLostHold(_ lease: ScreenLease) {
        guard let hold, hold.holder(of: lease) == nil else { return }
        forgetHold(notice: !hold.isConfirmed ? nil : lease.holder == .human ? .someoneTookOver : .returnedToBot,
                   control: lease.holder == .human ? .other : .bot)
    }

    private func deliver(_ image: CGImage, _ owner: Int) {
        guard owner == generation else { return }
        frames.show(image)
        failures = 0
        blindCaptureFailures = 0
        isStreamReady = true
        set(.live)
        if takesOverWhenLive {
            takesOverWhenLive = false
            if control != .mine, !isHostLocked || canUnlockHost { takeOver() }
        }
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

    func installPlugin() {
        runPluginAction { [self] dashboard in
            try await dashboard.installPlugin(identifier: HermexScreenPlugin.installIdentifier, ref: HermexScreenPlugin.pinnedCommit)
        }
    }

    func restartForPlugin() {
        runPluginAction { dashboard in
            try await dashboard.restartHermes()
        }
    }

    func removePlugin() {
        let hold = hold
        runPluginAction { [self] dashboard in
            if let hold { _ = try await hold.source.release(hold, profile: profile, client: client) }
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
                options.holds.forget(viewerIDs: [viewerID], server: server, profile: profile)
                guard owner == generation else { return }
                notice = .takeOverFailed
            } catch {
                guard owner == generation else { return }
                notice = .takeOverFailed
                restart()
            }
        }
    }

    func handBack() {
        guard let hold else { return }
        let owner = generation
        Task { await release(hold, owner: owner) }
    }

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

    func keepControl() {
        noteActivity()
        if source == .hostDesktop { movePointer(byX: 0, y: 0) }
    }

    var canRemovePlugin: Bool {
        guard source == .hostDesktop, control == .bot, hold == nil else { return false }
        switch phase {
        case .live, .reconnecting, .pluginNeedsRestart, .pluginFailed, .hostRefused, .driverProblem, .permissionsMissing:
            return true
        default:
            return false
        }
    }

    func noteActivity() {
        lastInput = options.now()
        if isAskingStillThere { isAskingStillThere = false }
    }

    private func persistLastInput() {
        guard control == .mine, var hold, let lastInput else { return }
        hold.lastInput = lastInput
        options.holds.save(hold, server: server, profile: profile)
    }

    private var canSendInput: Bool {
        control == .mine && isStreamReady
    }

    func movePointer(byX dx: Int, y dy: Int, buttons: UInt8 = 0) {
        guard canSendInput, let image = frames.image else { return }
        noteActivity()
        let from = pointer ?? (image.width / 2, image.height / 2)
        let to = (x: min(max(from.x + dx, 0), image.width - 1), y: min(max(from.y + dy, 0), image.height - 1))
        pointer = to
        input.movePointer(x: to.x, y: to.y, buttons: buttons)
        pumpInput()
    }

    func clickAtPointer(button: UInt8) {
        guard let image = frames.image else { return }
        let at = pointer ?? (image.width / 2, image.height / 2)
        click(x: at.x, y: at.y, button: button)
    }

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

    func press(_ key: ScreenKey) {
        guard canSendInput else { return }
        noteActivity()
        withLatchedModifiers {
            input.append(RFBMessage.key(key, down: true))
            input.append(RFBMessage.key(key, down: false))
        }
        pumpInput()
    }

    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            if let key = ScreenKey(typing: scalar) { press(key) }
        }
    }

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

    private func pumpInput() {
        guard inputPump == nil else { return }
        inputPump = Task { [weak self] in
            while let self, !self.input.isEmpty, let rfb = self.rfb {
                let batch = self.input.drain()
                try? await rfb.send(batch)
            }
            self?.inputPump = nil
        }
    }
}

private enum ScreenStreamEnd: Error {
    case settled(ScreenSession.Phase)
}

private enum ScreenStreamOutcome {
    case settled(ScreenSession.Phase)
    case evicted
    case handedBack
    case reopen
    case retry
    case captureFailed

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
            self = source == .botDesktop ? .settled(.stopped) : .captureFailed
        case RFBStreamEnd.closed(code: 1003), is RFBFailure:
            self = .settled(.failed)
        case let failure as ScreenCallFailure:
            if failure.code == -32601 { self = .settled(.unavailable) }
            else if failure.code == 5300, failure.refusal == nil { self = .settled(.stopped) }
            else { self = .settled(.failed) }
        default:
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
