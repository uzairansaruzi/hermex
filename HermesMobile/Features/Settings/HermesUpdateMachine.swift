import Foundation

struct HermesUpdateMachine: Equatable {
    enum State: Equatable {
        case applying
        case recovering
        case done(version: String?)
        case partial(summary: String?)
        case failed(summary: String?)
        case needsDashboardRestart(running: String?)
        case stillRunning

        var isSettled: Bool {
            switch self {
            case .applying, .recovering: return false
            case .done, .partial, .failed, .needsDashboardRestart, .stillRunning: return true
            }
        }
    }

    enum Read: Equatable { case status, receipt, health }

    enum Event: Equatable {
        case status(HermesUpdateStatus)
        case statusMissing
        case receipt(HermesUpdateReceipt?)
        case health(version: String?)
        case unreachable
    }

    static let silenceLimit: Duration = .seconds(120)
    static let ceiling: Duration = .seconds(600)
    static let longestRead: Duration = .seconds(60)

    private(set) var state: State = .applying
    private(set) var isRechecking = false
    let baseline: HermesUpdateReceipt?
    let pid: Int?
    private var succeeded: HermesUpdateReceipt?
    private var exitedCleanly = false
    private var statusIsMissing = false
    private var lines: [String] = []
    private var lastAnswer: Duration
    private var waitStarted: Duration
    private var lastEvent: Duration
    private var finishedAt: Duration?

    init(baseline: HermesUpdateReceipt?, pid: Int?, at now: Duration) {
        self.baseline = baseline
        self.pid = pid
        lastAnswer = now
        waitStarted = now
        lastEvent = now
    }

    var isSettled: Bool { state.isSettled && !isRechecking }

    var nextRead: Read? {
        guard !isSettled else { return nil }
        if isFinished { return .health }
        return statusIsMissing ? .receipt : .status
    }

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
        if !state.isSettled, !isFinished, Self.ceiling <= now - waitStarted { expire() }
    }

    mutating func expire() {
        guard !state.isSettled else { return }
        state = state == .recovering || isFinished ? .needsDashboardRestart(running: nil) : .stillRunning
    }

    mutating func checkAgain() {
        switch state {
        case .needsDashboardRestart, .stillRunning: isRechecking = true
        default: break
        }
    }

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

    private func isThisRun(_ receipt: HermesUpdateReceipt) -> Bool {
        guard let baseline else { return true }
        if let started = receipt.startedAt, let before = baseline.startedAt { return started != before }
        return receipt != baseline
    }

    private func isInstalled(_ version: String?) -> Bool {
        guard let version, let installed = succeeded?.postVersion else { return true }
        return version == installed
    }

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

@MainActor @Observable final class HermesUpdateModel {
    enum Check: Equatable {
        case answered(HermesUpdateCheck, at: Date)
        case failed(String)
    }

    enum Run: Equatable {
        case starting
        case refused(message: String?, command: String?)
        case couldNotStart(String)
        case following(HermesUpdateMachine)
    }

    let server: URL
    private(set) var check: Check?
    private(set) var isChecking = false
    private(set) var run: Run?
    var onUpdated: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var checkGeneration = 0
    private let makeClient: @MainActor () -> HermesUpdateClient?
    private let cadence: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private let origin: ContinuousClock.Instant

    private static var models: [URL: HermesUpdateModel] = [:]

    static func `for`(server: URL) -> HermesUpdateModel {
        if let model = models[server] { return model }
        let model = HermesUpdateModel(server: server)
        models[server] = model
        return model
    }

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

    var isWorking: Bool { task != nil }

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

    func checkNow() async {
        guard task == nil, let client = makeClient() else { return }
        if case .following(let machine)? = run, !machine.state.isSettled { return }
        run = nil
        await refresh(force: true, client)
    }

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
            answer = nil
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

    private func watch(_ client: HermesUpdateClient, readFirst: Bool) async {
        let watched = HermesUpdateMachine.ceiling + HermesUpdateMachine.silenceLimit
        let reads = Int(watched / max(cadence, .seconds(1))) + 1
        let delays = (readFirst ? [Duration.zero] : []) + Array(repeating: cadence, count: reads)
        _ = await HermesRestartWait.lastAnswer(after: delays, sleep: sleep) { () async -> Bool? in
            guard case .following(var machine)? = self.run, let read = machine.nextRead else { return true }
            guard let event = await self.event(read, client) else {
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
            return .unreachable
        }
    }

    private static func refusalMessage(_ refusal: HermesUpdateStart) -> String? {
        guard case .refused(_, let message, _) = refusal else { return nil }
        return message
    }

    static func message(for error: Error, server: URL) -> String {
        if case BotFailure.rejected(let status) = error, (404..<502).contains(status), status != 429 {
            return String(localized: "This Hermes host refused the step (HTTP \(status)). Check the host’s logs, then try again.")
        }
        return BotConnectionAdvice.message(for: error, address: server)
    }
}
