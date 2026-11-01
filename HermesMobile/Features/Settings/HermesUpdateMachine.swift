import Foundation

/// One update of a Hermes host started from Settings (#1075), as a pure reducer of what the
/// host answers. `HermesUpdateModel` reads what `nextRead` names about every 3 seconds and
/// hands the answer to `handle`, with the time since the model began.
///
/// The host's receipt is the outcome, over any exit code: the update restarts the dashboard,
/// which then no longer tracks the process and can report an exit code from an earlier run's
/// receipt. A receipt counts once it differs from `baseline`, the one the host held before this
/// run; an exit code counts only while the dashboard still tracks the process (`pid`), and a
/// null one keeps waiting. A read that gets no answer means the dashboard is restarting. A
/// receipt that says success is done once `/api/health` answers on the release it installed.
/// Silence for `silenceLimit` means the dashboard isn't coming back, and `ceiling` ends a wait
/// that hasn't finished on what the host last said. Both count only time the app watched: a gap
/// between two answers longer than `longestRead` (the app was suspended, or another server was
/// active) counts as one read.
struct HermesUpdateMachine: Equatable {
    enum State: Equatable {
        /// The host is running the update and answering.
        case applying
        /// Hermes doesn't answer: the update is restarting the dashboard.
        case recovering
        /// The receipt says success and Hermes answers on `version`, the release it installed.
        case done(version: String?)
        /// The host's own words for a run that stopped part way, or failed; nil when it gave none.
        case partial(summary: String?)
        case failed(summary: String?)
        /// The update finished, but the dashboard didn't come back: silent for `silenceLimit`, or
        /// still answering on `running`, another release than the update installed.
        case needsDashboardRestart(running: String?)
        /// The host still runs the update at the ceiling.
        case stillRunning

        /// Whether the run has stopped moving: nothing is read until the user asks.
        var isSettled: Bool {
            switch self {
            case .applying, .recovering: return false
            case .done, .partial, .failed, .needsDashboardRestart, .stillRunning: return true
            }
        }
    }

    /// The read the model makes next.
    enum Read: Equatable { case status, receipt, health }

    enum Event: Equatable {
        case status(HermesUpdateStatus)
        /// The status route answered 404: this host has no such action, so the receipt is read.
        case statusMissing
        /// The receipt route answered; nil for its 404, no receipt yet.
        case receipt(HermesUpdateReceipt?)
        /// `/api/health` answered with the running release.
        case health(version: String?)
        /// A read got no answer from Hermes: a dropped connection, or a proxy's or tunnel's 5xx.
        case unreachable
    }

    /// No answer for this long means the dashboard isn't coming back.
    static let silenceLimit: Duration = .seconds(120)
    /// How long one wait watches before it stops on what the host last said.
    static let ceiling: Duration = .seconds(600)
    /// The longest one read takes while the app watches: the cadence, plus a request that times
    /// out and a sign-in again. A longer gap is time nobody watched.
    static let longestRead: Duration = .seconds(60)

    private(set) var state: State = .applying
    /// "Check again" on a run that stopped without an outcome: its first answer decides, and
    /// a host that still doesn't answer leaves the card as it was.
    private(set) var isRechecking = false
    /// The receipt the host held before this run started.
    let baseline: HermesUpdateReceipt?
    /// The update process the host started; nil when it didn't say.
    let pid: Int?
    /// This run's receipt once it reports success, while the dashboard comes back.
    private var succeeded: HermesUpdateReceipt?
    /// The process exited 0 while the dashboard still tracked it, and left no receipt.
    private var exitedCleanly = false
    private var statusIsMissing = false
    private var lines: [String] = []
    private var lastAnswer: Duration
    private var waitStarted: Duration
    /// When the last event arrived, to tell a read from a gap nobody watched.
    private var lastEvent: Duration
    /// When the host said the run had finished, for a dashboard back on another release.
    private var finishedAt: Duration?

    init(baseline: HermesUpdateReceipt?, pid: Int?, at now: Duration) {
        self.baseline = baseline
        self.pid = pid
        lastAnswer = now
        waitStarted = now
        lastEvent = now
    }

    /// Whether the model stops reading.
    var isSettled: Bool { state.isSettled && !isRechecking }

    var nextRead: Read? {
        guard !isSettled else { return nil }
        if isFinished { return .health }
        return statusIsMissing ? .receipt : .status
    }

    /// The host said the run ended well; only the dashboard's release is left to wait for.
    private var isFinished: Bool { succeeded != nil || exitedCleanly }

    mutating func handle(_ event: Event, at now: Duration) {
        guard !isSettled else { return }
        skipUnwatched(until: now)
        if isRechecking {
            isRechecking = false
            switch event {
            case .unreachable: return
            case .health(let version) where !isInstalled(version):
                state = .needsDashboardRestart(running: version)
                return
            default:
                state = .applying
                waitStarted = now
            }
        }
        switch event {
        case .unreachable:
            state = Self.silenceLimit <= now - lastAnswer ? .needsDashboardRestart(running: nil) : .recovering
        case .statusMissing:
            answered(at: now)
            statusIsMissing = true
        case .status(let status):
            answered(at: now)
            lines = status.lines
            if let receipt = status.receipt, isThisRun(receipt) {
                finish(receipt, at: now)
            } else if !status.running, let code = status.exitCode, let pid, status.pid == pid {
                if code == 0 {
                    exitedCleanly = true
                    finishedAt = now
                } else {
                    state = .failed(summary: summary)
                }
            }
        case .receipt(let receipt):
            answered(at: now)
            if let receipt, isThisRun(receipt) { finish(receipt, at: now) }
        case .health(let version):
            answered(at: now)
            if isInstalled(version) {
                state = .done(version: version ?? succeeded?.postVersion)
            } else if let finishedAt, Self.silenceLimit <= now - finishedAt {
                state = .needsDashboardRestart(running: version)
            }
        }
        // A finished run waits on the dashboard's release under `silenceLimit` alone.
        if !state.isSettled, !isFinished, Self.ceiling <= now - waitStarted { expire() }
    }

    /// Ends a wait the model stopped watching, on what the host last said: still running if
    /// it answered and hadn't finished, the dashboard to restart otherwise.
    mutating func expire() {
        guard !state.isSettled else { return }
        state = state == .recovering || isFinished ? .needsDashboardRestart(running: nil) : .stillRunning
    }

    /// "Check again" on a run that ended without an outcome. A dashboard that is still silent,
    /// or still on another release, leaves the card as it is; one that answers is watched again.
    mutating func checkAgain() {
        switch state {
        case .needsDashboardRestart, .stillRunning: isRechecking = true
        default: break
        }
    }

    /// Moves the limits' clocks past time nobody watched, so a gap counts as one read.
    private mutating func skipUnwatched(until now: Duration) {
        let unwatched = now - lastEvent - Self.longestRead
        lastEvent = now
        guard unwatched > .zero else { return }
        lastAnswer += unwatched
        waitStarted += unwatched
        finishedAt = finishedAt.map { $0 + unwatched }
    }

    private mutating func answered(at now: Duration) {
        lastAnswer = now
        if state == .recovering { state = .applying }
    }

    /// Settles a receipt this run wrote. One still running is waited on.
    private mutating func finish(_ receipt: HermesUpdateReceipt, at now: Duration) {
        switch receipt.outcome {
        case nil, .running?: return
        case .success?:
            succeeded = receipt
            finishedAt = finishedAt ?? now
        case .partial?: state = .partial(summary: summary)
        case .failed?, .refused?, .other?: state = .failed(summary: summary)
        }
    }

    /// A receipt other than the one the host held before this run.
    private func isThisRun(_ receipt: HermesUpdateReceipt) -> Bool {
        guard let baseline else { return true }
        if let started = receipt.startedAt, let before = baseline.startedAt { return started != before }
        return receipt != baseline
    }

    /// Whether the dashboard answers on the release the update installed. Without either
    /// release, an answer is all there is to go on.
    private func isInstalled(_ version: String?) -> Bool {
        guard let version, let installed = succeeded?.postVersion else { return true }
        return version == installed
    }

    /// The host's own words for a run that stopped: the last line of its update log marked as
    /// a failure (✗) or a warning (⚠), else its last line, without the marker.
    private var summary: String? {
        let markers: Set<Unicode.Scalar> = ["\u{2717}", "\u{26A0}", "\u{FE0F}"]
        let shown = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("===") && $0.hasSuffix("===")) }
        let line = shown.last { $0.unicodeScalars.first.map(markers.contains) == true } ?? shown.last
        guard let line else { return nil }
        let words = String(String.UnicodeScalarView(line.unicodeScalars.drop { markers.contains($0) || $0.properties.isWhitespace }))
        return words.isEmpty ? nil : words
    }
}

/// Settings' update standing for one Hermes server (#1075): the host's update check, and an
/// update started from this phone, followed through the dashboard's restart. One model per
/// server (`for(server:)`), kept for the app's life, so an update keeps running and keeps its
/// card while Settings is closed or another server is active. Its reads hold the connection
/// they started with; when that is retired (another server became active) they stop, and the
/// card picks the update up again when Settings appears on this server.
@MainActor @Observable final class HermesUpdateModel {
    enum Check: Equatable {
        case answered(HermesUpdateCheck, at: Date)
        case failed(String)
    }

    /// The update started from this phone.
    enum Run: Equatable {
        /// Reading the host's latest receipt, then asking it to start.
        case starting
        /// The host can't update this install in place.
        case refused(message: String?, command: String?)
        /// The host never took the update.
        case couldNotStart(String)
        case following(HermesUpdateMachine)
    }

    let server: URL
    private(set) var check: Check?
    private(set) var isChecking = false
    private(set) var run: Run?
    /// Told the release an update installed, so the saved server version follows it.
    var onUpdated: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var checkGeneration = 0
    private let makeClient: @MainActor () -> HermesUpdateClient?
    private let cadence: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private let origin: ContinuousClock.Instant

    private static var models: [URL: HermesUpdateModel] = [:]

    /// `server`'s model, made on first use.
    static func `for`(server: URL) -> HermesUpdateModel {
        if let model = models[server] { return model }
        let model = HermesUpdateModel(server: server)
        models[server] = model
        return model
    }

    /// `makeClient` reaches the host over the server's saved connection; nil when it has none.
    init(server: URL, makeClient: (@MainActor () -> HermesUpdateClient?)? = nil, cadence: Duration = .seconds(3),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.server = server
        self.makeClient = makeClient ?? {
            (try? BotConnectionStore().load(server: server)).map { HermesUpdateClient(saved: $0, server: server) }
        }
        self.cadence = cadence
        self.sleep = sleep
        self.now = now
        origin = now()
    }

    /// Whether a request for the update is running.
    var isWorking: Bool { task != nil }

    /// Settings appeared on this server: follows an update this model stopped following, or one
    /// the host reports running (started before a relaunch, or from another client), else reads
    /// the host's check, which it caches for 24 hours.
    func appear() async {
        if case .following(let machine)? = run {
            if task == nil, !machine.isSettled { follow(readFirst: true) }
            return
        }
        guard run == nil, task == nil, let client = makeClient() else { return }
        if let status = try? await client.status(), status.running, run == nil, task == nil {
            run = .following(HermesUpdateMachine(baseline: status.receipt, pid: status.pid, at: elapsed))
            follow(readFirst: false)
            return
        }
        await refresh(force: false, client)
    }

    /// Settings closed: an update that finished stops showing, so the next visit reads the
    /// host's check again. One still running, or waiting on the host, stays.
    func leaveSettings() {
        guard task == nil else { return }
        switch run {
        case .following(let machine)?:
            switch machine.state {
            case .done, .partial, .failed: run = nil
            default: break
            }
        case .refused?, .couldNotStart?: run = nil
        case .starting?, nil: break
        }
    }

    /// "Check" and a partial update's "Check again": asks the host to look again now.
    func checkNow() async {
        guard task == nil, let client = makeClient() else { return }
        if case .following(let machine)? = run, !machine.state.isSettled { return }
        run = nil
        await refresh(force: true, client)
    }

    /// The confirmed Update: one `POST /api/hermes/update`, then the host is followed through
    /// its restart. The run outlives Settings.
    func apply() {
        guard task == nil else { return }
        if case .following(let machine)? = run, !machine.state.isSettled { return }
        guard let client = makeClient() else {
            run = .couldNotStart(String(localized: "Connect to this Hermes host first."))
            return
        }
        run = .starting
        task = Task { [weak self] in await self?.start(client) }
    }

    /// "Check again" on an update that ended without an outcome: one read now, then the
    /// usual wait while the host answers.
    func checkAgain() {
        guard task == nil, case .following(var machine)? = run else { return }
        machine.checkAgain()
        guard !machine.isSettled else { return }
        run = .following(machine)
        follow(readFirst: true)
    }

    private var elapsed: Duration { now() - origin }

    private func refresh(force: Bool, _ client: HermesUpdateClient) async {
        checkGeneration &+= 1
        let generation = checkGeneration
        isChecking = true
        let answer: Check?
        do {
            answer = .answered(try await client.check(force: force), at: Date())
        } catch BotFailure.rejected(404) {
            answer = nil // A host without the route has no updates to offer.
        } catch BotFailure.stale {
            answer = check
        } catch is CancellationError {
            answer = check
        } catch {
            answer = .failed(Self.message(for: error, server: server))
        }
        guard generation == checkGeneration else { return }
        check = answer
        isChecking = false
    }

    private func start(_ client: HermesUpdateClient) async {
        do {
            // The receipt the host holds now is an earlier run's; this run's replaces it when it ends.
            let baseline: HermesUpdateReceipt?
            do { baseline = try await client.status().receipt } catch BotFailure.rejected(404) {
                baseline = try await client.receipt()
            }
            switch try await Self.start(client, after: baseline) {
            case .started(let pid):
                run = .following(HermesUpdateMachine(baseline: baseline, pid: pid, at: elapsed))
            case let refusal:
                run = .refused(message: Self.refusalMessage(refusal), command: refusal.hostCommand)
                task = nil
                return
            }
        } catch {
            run = (error as? BotFailure == .stale || error is CancellationError)
                ? nil : .couldNotStart(Self.message(for: error, server: server))
            task = nil
            return
        }
        await watch(client, readFirst: false)
    }

    /// Asks the host to update. A request that fails without the host's answer may still have
    /// started the update before its reply was lost (a dropped connection, a proxy's 5xx), so a
    /// run the host then reports is followed rather than offered again; else the failure stands.
    private static func start(_ client: HermesUpdateClient, after baseline: HermesUpdateReceipt?) async throws -> HermesUpdateStart {
        do { return try await client.start() } catch {
            if error as? BotFailure == .stale || error is CancellationError { throw error }
            guard let status = try? await client.status(), status.running || status.receipt.map({ $0 != baseline }) == true
            else { throw error }
            return .started(pid: status.pid)
        }
    }

    private func follow(readFirst: Bool) {
        guard let client = makeClient() else { return }
        task = Task { [weak self] in await self?.watch(client, readFirst: readFirst) }
    }

    /// Reads what the machine asks for until it settles, on `HermesRestartWait`'s schedule.
    private func watch(_ client: HermesUpdateClient, readFirst: Bool) async {
        // The machine's own limits end the wait: the ceiling, then the wait for the release. This
        // bounds the schedule for a zero cadence too.
        let watched = HermesUpdateMachine.ceiling + HermesUpdateMachine.silenceLimit
        let reads = Int(watched / max(cadence, .seconds(1))) + 1
        let delays = (readFirst ? [Duration.zero] : []) + Array(repeating: cadence, count: reads)
        _ = await HermesRestartWait.lastAnswer(after: delays, sleep: sleep) { () async -> Bool? in
            guard case .following(var machine)? = self.run, let read = machine.nextRead else { return true }
            guard let event = await self.event(read, client) else {
                // The connection was retired: stop here and pick the run up on the next appear.
                self.task?.cancel()
                return nil
            }
            guard case .following(let current)? = self.run, current == machine else { return true }
            machine.handle(event, at: self.elapsed)
            self.run = .following(machine)
            return machine.isSettled
        } isFinal: { $0 }
        guard case .following(var machine)? = run else { task = nil; return }
        if !machine.isSettled, !Task.isCancelled {
            machine.expire()
            run = .following(machine)
        }
        task = nil
        if case .done(let version) = machine.state {
            if let version { onUpdated?(version) }
            HermesConnections.shared.reconnectGateway(server: server)
        }
    }

    /// One read as the machine's event; nil once the connection is retired.
    private func event(_ read: HermesUpdateMachine.Read, _ client: HermesUpdateClient) async -> HermesUpdateMachine.Event? {
        do {
            switch read {
            case .status: return .status(try await client.status())
            case .receipt: return .receipt(try await client.receipt())
            case .health: return .health(version: try await client.health())
            }
        } catch BotFailure.rejected(404) where read == .status {
            return .statusMissing
        } catch BotFailure.stale {
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            // A transport failure, or a proxy's 5xx while the dashboard restarts.
            return .unreachable
        }
    }

    private static func refusalMessage(_ refusal: HermesUpdateStart) -> String? {
        guard case .refused(_, let message, _) = refusal else { return nil }
        return message
    }

    /// A failed request in words for the card: the host's refusal with its status, else what
    /// the connection advice says about the hop that failed.
    static func message(for error: Error, server: URL) -> String {
        if case BotFailure.rejected(let status) = error, (404..<502).contains(status), status != 429 {
            return String(localized: "This Hermes host refused the step (HTTP \(status)). Check the host’s logs, then try again.")
        }
        return BotConnectionAdvice.message(for: error, address: server)
    }
}
