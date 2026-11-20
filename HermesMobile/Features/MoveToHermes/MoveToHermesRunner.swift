import Foundation

struct MoveToHermesReport: Codable, Equatable, Sendable {
    var finishedEarly = false
    var recovered = false
    var partialScan = false
    var copied: [String] = []
    var alreadyThere: [String] = []
    var presentUnconfirmed: [String] = []
    var sentUnconfirmed: [String] = []
    var notCopied: [String] = []
    var oversized: [String] = []
    var rejected: [String: String] = [:]
    var unchecked: [String] = []
    var keptOnWebui: [String] = []
    var pairing: MoveToHermesPairing?
    var changesApplied = 0
    var changesNotApplied: [MoveToHermesReconcile.Operation] = []
    var changesUnconfirmed: [MoveToHermesReconcile.Operation] = []
    var changesLeftAlone: [MoveToHermesReconcile.Operation] = []
    var foldersMissing: [MoveToHermesReconcile.Operation] = []
    var changesRejected: [MoveToHermesReconcile.Operation] = []
    var notReconciled: [String] = []
    var draftsMoved = 0
    var draftConflicts: [String] = []
    var draftsKept: [String] = []
    var titles: [String: String] = [:]

    func summary(at date: Date) -> MovedWebuiReport {
        MovedWebuiReport(remaining: partialScan ? nil : notCopied.count + oversized.count + rejected.count + keptOnWebui.count,
                         unchecked: unchecked.count + sentUnconfirmed.count, oversized: oversized.count,
                         kept: partialScan ? nil : keptOnWebui.count, recordedAt: date)
    }
}

struct MoveToHermesProgress {
    struct ChangeKey: Hashable {
        let id: String
        let profile: String
        let field: Int

        init(_ operation: MoveToHermesReconcile.Operation) {
            id = operation.id
            profile = operation.profile
            switch operation.change {
            case .title: field = 0
            case .pinned: field = 1
            case .folder: field = 2
            }
        }
    }

    let review: MoveToHermesReview
    private(set) var pairing: MoveToHermesPairing?
    private(set) var copy: [String: WebuiSessionTransfer.Outcome] = [:]
    private(set) var sentTo: [String: String] = [:]
    private(set) var awaiting: Set<String> = []
    private(set) var unconfirmedSend: Set<String> = []
    private var sentIn: [String: UUID] = [:]
    private(set) var plans: [String: MoveToHermesReconcile.Planned] = [:]
    private(set) var inFlight: [ChangeKey: MoveToHermesReconcile.Operation] = [:]
    private(set) var changes: [ChangeKey: MoveToHermesReconcile.Outcome] = [:]
    private(set) var changed: [ChangeKey: MoveToHermesReconcile.Operation] = [:]
    private(set) var drafts: [String: MoveToHermesDraftResult] = [:]
    private(set) var finished: MoveToHermesReport?

    init(review: MoveToHermesReview, events: [MoveToHermesEvent]) {
        self.review = review
        events.forEach { apply($0) }
    }

    private mutating func apply(_ event: MoveToHermesEvent) {
        switch event {
        case .pairing(let result):
            pairing = result
        case .importing(let profile, let ids, let attempt):
            for id in ids {
                if awaiting.contains(id) { unconfirmedSend.insert(id) }
                sentTo[id] = profile
                awaiting.insert(id)
                sentIn[id] = attempt
            }
        case .copied(let outcomes, let attempt):
            for (id, outcome) in outcomes {
                if awaiting.remove(id) != nil, sentIn.removeValue(forKey: id) != attempt { unconfirmedSend.insert(id) }
                if case .uncertain = outcome { unconfirmedSend.insert(id) }
                copy[id] = outcome
            }
        case .planned(let planned):
            plans.merge(planned) { _, new in new }
        case .changing(let operation):
            inFlight[ChangeKey(operation)] = operation
        case .changed(let operation, let outcome):
            inFlight[ChangeKey(operation)] = nil
            changes[ChangeKey(operation)] = outcome
            changed[ChangeKey(operation)] = operation
        case .drafts(let results):
            drafts.merge(results) { _, new in new }
        case .finished(let report):
            finished = report
        }
    }

    private func unconfirmed(_ id: String) -> Bool { unconfirmedSend.contains(id) || awaiting.contains(id) }

    var copyItems: [WebuiSessionTransfer.Item] {
        review.entries.compactMap { entry in
            guard entry.location == .missing, let destination = review.destination(of: entry.chat) else { return nil }
            let id = entry.chat.id
            switch copy[id] {
            case _ where awaiting.contains(id), nil, .uncertain?, .notSent?, .unknown?, .unreadable?:
                return WebuiSessionTransfer.Item(chat: entry.chat, destination: sentTo[id] ?? destination)
            default:
                return nil
            }
        }
    }

    var targets: [MoveToHermesReconcile.Target] {
        let mapped = review.entries.filter { review.destination(of: $0.chat) != nil }
        var outcomes = copy
        for id in awaiting { outcomes[id] = nil }
        return MoveToHermesReconcile.targets(mapped, outcomes: outcomes, firstMove: review.firstMove)
    }

    var unplannedTargets: [MoveToHermesReconcile.Target] { targets.filter { plans[$0.chat.id] == nil } }

    private var planned: [MoveToHermesReconcile.Plan] {
        plans.values.compactMap { if case .plan(let plan) = $0 { plan } else { nil } }
            .sorted { $0.target.chat.id < $1.target.chat.id }
    }

    var operationsToApply: [MoveToHermesReconcile.Operation] {
        planned.flatMap(\.operations).filter { operation in
            let key = ChangeKey(operation)
            guard inFlight[key] == nil else { return false }
            switch changes[key] {
            case nil, .notSent?: return true
            default: return false
            }
        }
    }

    var plansNeedingDrafts: [MoveToHermesReconcile.Plan] {
        planned.filter { drafts[$0.target.chat.id] == nil || drafts[$0.target.chat.id] == .failed }
    }

    var hasWorkLeft: Bool {
        !copyItems.isEmpty || !unplannedTargets.isEmpty || !inFlight.isEmpty
            || !operationsToApply.isEmpty || !plansNeedingDrafts.isEmpty
    }

    func report(finishedEarly: Bool, draftsWaiting: Set<String>) -> MoveToHermesReport {
        var report = MoveToHermesReport(finishedEarly: finishedEarly, recovered: review.recovering,
                                        partialScan: review.onlyProfile != nil, pairing: pairing)
        var listed = Set<String>()
        func list(_ id: String, _ path: WritableKeyPath<MoveToHermesReport, [String]>) {
            report[keyPath: path].append(id)
            if path != \.copied, path != \.alreadyThere { listed.insert(id) }
        }
        for entry in review.entries {
            let id = entry.chat.id
            guard review.destination(of: entry.chat) != nil else {
                switch entry.location {
                case .missing: list(id, \.keptOnWebui)
                case .unknown, .ambiguous: list(id, \.unchecked)
                case .present: break
                }
                continue
            }
            switch entry.location {
            case .present: list(id, \.alreadyThere)
            case .unknown, .ambiguous: list(id, \.unchecked)
            case .missing:
                switch copy[id] {
                case _ where awaiting.contains(id): list(id, \.sentUnconfirmed)
                case .imported?: list(id, \.copied)
                case .alreadyPresent(let profile)?:
                    list(id, unconfirmed(id) && sentTo[id] == profile ? \.presentUnconfirmed : \.alreadyThere)
                case .ambiguous?: list(id, \.unchecked)
                case .oversized?: list(id, \.oversized)
                case .rejected(let reason)?:
                    report.rejected[id] = reason
                    listed.insert(id)
                case .uncertain?: list(id, \.sentUnconfirmed)
                case .unknown?: list(id, unconfirmed(id) ? \.sentUnconfirmed : \.unchecked)
                case .unreadable?, .notSent?, nil: list(id, unconfirmed(id) ? \.sentUnconfirmed : \.notCopied)
                }
            }
        }
        for plan in planned {
            for operation in plan.operations {
                let key = ChangeKey(operation)
                if let sent = inFlight[key] {
                    report.changesUnconfirmed.append(sent)
                    continue
                }
                let attempted = changed[key] ?? operation
                switch changes[key] {
                case .applied?: report.changesApplied += 1
                case .changed?: report.changesLeftAlone.append(attempted)
                case .folderMissing?: report.foldersMissing.append(attempted)
                case .rejected?: report.changesRejected.append(attempted)
                case .uncertain?: report.changesUnconfirmed.append(attempted)
                case .missing?, .notSent?, nil: report.changesNotApplied.append(attempted)
                }
            }
            let id = plan.target.chat.id
            switch drafts[id] {
            case .moved?, .alreadyMoved?: report.draftsMoved += 1
            case .conflict?: report.draftConflicts.append(id)
            case .unverified?, .missing?: report.draftsKept.append(id)
            case .failed?, nil: if draftsWaiting.contains(id) { report.draftsKept.append(id) }
            case .nothingToMove?: break
            }
        }
        report.notReconciled = unplannedTargets.map(\.chat.id)
        let operations = [report.changesNotApplied, report.changesUnconfirmed, report.changesLeftAlone,
                          report.foldersMissing, report.changesRejected].joined().map(\.id)
        listed.formUnion(operations + report.notReconciled + report.draftConflicts + report.draftsKept)
        for entry in review.entries where listed.contains(entry.chat.id) {
            if let title = entry.chat.title { report.titles[entry.chat.id] = title }
        }
        return report
    }
}

@MainActor struct MoveToHermesDestination {
    let transport: any BotTransport
    let readPairing: () async throws -> PushPairing
    let close: () -> Void

    static func live(_ saved: BotConnection, connections: HermesConnections = .shared) -> MoveToHermesDestination {
        let server = URL(string: MoveToHermesRunner.destinationID(for: saved)) ?? saved.address
        let http = connections.ownConnection(for: saved, server: server)
        let client = BotClient(http: http)
        let dashboard = BotDashboardClient(http: http)
        return MoveToHermesDestination(transport: client, readPairing: {
            try await dashboard.signIn()
            return try await dashboard.pairing()
        }, close: {
            client.close()
            connections.retire(own: http, server: server)
        })
    }
}

@MainActor @Observable final class MoveToHermesRunner {
    enum Step: Equatable {
        case pairing, copying, reconciling, movingDrafts, finishing
    }

    enum Pause: Equatable {
        case cancelled
        case workLeft
        case destinationUnavailable
        case destinationRemoved
        case saveFailed
        case damaged
        case unreadable
        case needsRescan
    }

    enum StartFailure: Error, Equatable {
        case moveInProgress
        case journal
        case commit(AuthManager.MoveCommitError)
    }

    enum State: Equatable {
        case idle
        case running(Step)
        case paused(Pause)
        case finished(MoveToHermesReport)
        case notStarted(StartFailure)
    }

    struct Review {
        let source: ServerAccount
        let connection: BotConnection
        let profiles: [MovedWebuiProfile]
        let hermesProfiles: [String]
        let scan: MoveToHermesScan.Result
    }

    struct Environment {
        var root = MoveToHermesJournal.defaultRoot
        var destination: @MainActor (BotConnection) -> MoveToHermesDestination = { MoveToHermesDestination.live($0) }
        var webuiConfiguration: URLSessionConfiguration = .ephemeral
        var cookies: @MainActor (URL) -> [HTTPCookie] = { HTTPCookieStorage.shared.cookies(for: $0) ?? [] }
        var registrar: @MainActor () -> (any PushPairingCopying)? = { PushRegistrar.shared }
        var drafts: @MainActor () -> ChatDraftStore = { .shared }
        var willWrite: @MainActor (MoveToHermesJournal.Write) throws -> Void = { _ in }
        var now: () -> Date = Date.init
    }

    let sourceServerID: String
    let destinationID: String
    private(set) var state: State = .idle
    private(set) var copyProgress: (settled: Int, total: Int)?

    @ObservationIgnored private let auth: AuthManager
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var journal: MoveToHermesJournal?

    init(auth: AuthManager, sourceServerID: String, destinationID: String, environment: Environment = Environment()) {
        self.auth = auth
        self.sourceServerID = sourceServerID
        self.destinationID = destinationID
        self.environment = environment
    }

    static func destinationID(for connection: BotConnection) -> String {
        ((try? BotConnection.address(connection.address.absoluteString)) ?? connection.address).absoluteString
    }

    private var folder: URL {
        MoveToHermesJournal.folder(source: sourceServerID, destination: destinationID, in: environment.root)
    }

    private var record: MovedWebuiServer? {
        guard !auth.removingServerIDs.contains(destinationID), let held = auth.moveRecord(forSource: sourceServerID), held.destination.id == destinationID else { return nil }
        return held.record
    }

    func start(_ review: Review) async {
        guard MoveToHermesJournal.claim(folder) else { return state = .notStarted(.moveInProgress) }
        defer { MoveToHermesJournal.release(folder) }
        var recovering = false
        switch MoveToHermesJournal.open(folder) {
        case .missing: recovering = record.map { $0.completedAt == nil } ?? false
        case .damaged:
            try? FileManager.default.removeItem(at: folder)
            recovering = true
        case .ready, .unreadable: return state = .notStarted(.moveInProgress)
        }
        let existing = record
        var frozen = MoveToHermesReview(firstMove: existing == nil, profiles: existing?.profiles ?? review.profiles,
                                        hermesProfiles: review.hermesProfiles, entries: review.scan.entries,
                                        onlyProfile: review.scan.onlyProfile)
        frozen.recovering = recovering
        let journal: MoveToHermesJournal
        do {
            journal = try MoveToHermesJournal.create(frozen, at: folder, willWrite: environment.willWrite)
        } catch {
            return state = .notStarted(.journal)
        }
        guard !Task.isCancelled else {
            journal.discard()
            return state = .idle
        }
        do {
            let committed = try auth.commitMove(from: review.source, to: review.connection, profiles: frozen.profiles)
            guard committed.id == destinationID else { throw AuthManager.MoveCommitError.invalidMapping }
        } catch {
            journal.discard()
            return state = .notStarted(.commit((error as? AuthManager.MoveCommitError) ?? .saveFailed))
        }
        self.journal = journal
        await runPass()
    }

    func resume() async {
        guard MoveToHermesJournal.claim(folder) else { return }
        defer { MoveToHermesJournal.release(folder) }
        guard loadJournal() != nil else { return }
        await runPass()
    }

    func finishEarly() async {
        guard MoveToHermesJournal.claim(folder) else { return }
        defer { MoveToHermesJournal.release(folder) }
        guard let journal = loadJournal() else { return }
        await finish(journal, early: true)
    }

    func acknowledge() {
        guard case .finished = state, !MoveToHermesJournal.isClaimed(folder) else { return }
        (journal ?? loadJournal())?.discard()
        journal = nil
        state = .idle
    }

    struct Snapshot: Equatable {
        let report: MoveToHermesReport
        let total: Int
        let copyLeft: Int
        let changesLeft: Int
        let draftsLeft: Int
        let unplanned: Int

        var inHermes: Int { report.copied.count + report.alreadyThere.count + report.presentUnconfirmed.count }
    }

    func snapshot() async -> Snapshot? {
        let opened: MoveToHermesJournal
        if let journal {
            opened = journal
        } else if !MoveToHermesJournal.isClaimed(folder),
                  case .ready(let read) = MoveToHermesJournal.open(folder, willWrite: environment.willWrite) {
            opened = read
        } else {
            return nil
        }
        let progress = MoveToHermesProgress(review: opened.review, events: opened.events)
        let waiting = await draftsWaiting(progress)
        let report = opened.finishedReport ?? progress.report(finishedEarly: false, draftsWaiting: waiting)
        return Snapshot(report: report, total: opened.review.entries.count, copyLeft: progress.copyItems.count,
                        changesLeft: progress.operationsToApply.count, draftsLeft: waiting.count,
                        unplanned: progress.unplannedTargets.count)
    }

    private func loadJournal() -> MoveToHermesJournal? {
        if let journal { return journal }
        switch MoveToHermesJournal.open(folder, willWrite: environment.willWrite) {
        case .ready(let opened):
            journal = opened
            return opened
        case .missing:
            state = record?.completedAt == nil && record != nil ? .paused(.needsRescan) : .idle
        case .damaged: state = .paused(.damaged)
        case .unreadable: state = .paused(.unreadable)
        }
        return nil
    }

    private enum Stop: Error {
        case saveFailed
        case destinationRemoved
    }

    private func runPass() async {
        guard let journal else { return }
        if journal.finishedReport != nil { return await finish(journal, early: false) }
        guard record != nil else {
            journal.discard()
            self.journal = nil
            return state = .paused(.destinationRemoved)
        }
        guard let destinationURL = URL(string: destinationID),
              let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: destinationURL)
        else { return state = .paused(.destinationUnavailable) }
        let destination = environment.destination(saved)
        defer { destination.close() }
        do {
            try await destination.transport.connect()
        } catch {
            return state = Task.isCancelled ? .paused(.cancelled) : .paused(.destinationUnavailable)
        }
        do {
            try await carryPairing(journal, to: destinationURL, destination: destination)
            try await copy(journal, on: destination.transport)
            try await reconcile(journal, on: destination.transport)
            try await moveDrafts(journal, hermes: destinationURL, connectionID: saved.id, on: destination.transport)
        } catch Stop.destinationRemoved {
            return state = .paused(.destinationRemoved)
        } catch {
            return state = .paused(.saveFailed)
        }
        let progress = MoveToHermesProgress(review: journal.review, events: journal.events)
        if Task.isCancelled || progress.hasWorkLeft {
            let report = progress.report(finishedEarly: false, draftsWaiting: await draftsWaiting(progress))
            try? auth.updateMoveRecord(forSource: sourceServerID) { $0.report = report.summary(at: environment.now()) }
            state = .paused(Task.isCancelled ? .cancelled : .workLeft)
        } else {
            await finish(journal, early: false)
        }
    }

    private func logIntent(_ event: MoveToHermesEvent, in journal: MoveToHermesJournal) throws {
        guard record != nil else { throw Stop.destinationRemoved }
        do { try journal.append(event, durable: true) } catch { throw Stop.saveFailed }
    }

    private func log(_ event: MoveToHermesEvent, in journal: MoveToHermesJournal) throws {
        do { try journal.append(event, durable: false) } catch { throw Stop.saveFailed }
    }

    private func carryPairing(_ journal: MoveToHermesJournal, to destinationURL: URL,
                              destination: MoveToHermesDestination) async throws {
        let progress = MoveToHermesProgress(review: journal.review, events: journal.events)
        guard progress.pairing == nil || progress.pairing == .unchecked, !Task.isCancelled,
              let sourceURL = URL(string: sourceServerID) else { return }
        state = .running(.pairing)
        let result: MoveToHermesPairing
        if let registrar = environment.registrar() {
            let auth = auth
            result = MoveToHermesPairing(await MovePushPairing.carry(
                from: sourceURL, to: destinationURL, registrar: registrar,
                isConfigured: { url in auth.servers.contains { $0.id == url.absoluteString } },
                readDestination: destination.readPairing))
        } else {
            result = .sourceUnpaired
        }
        try log(.pairing(result), in: journal)
    }

    private func copy(_ journal: MoveToHermesJournal, on hermes: any BotTransport) async throws {
        let items = MoveToHermesProgress(review: journal.review, events: journal.events).copyItems
        guard !items.isEmpty, !Task.isCancelled,
              let source = auth.servers.first(where: { $0.id == sourceServerID && $0.kind == .webui }),
              let sourceURL = URL(string: source.urlString) else { return }
        state = .running(.copying)
        let headers = [CustomHeader].decodeFromStorage(try? auth.keychain.load(.customHeaders, scope: source.id))
        let webui = WebuiSource(baseURL: sourceURL, headers: headers, cookies: environment.cookies(sourceURL))
        var settled = 0
        copyProgress = (0, items.count)
        defer { copyProgress = nil }
        for group in Dictionary(grouping: items, by: \.chat.profile).sorted(by: { $0.key < $1.key }).map(\.value) {
            guard !Task.isCancelled else { break }
            let attempt = UUID()
            var failure: Error?
            let outcomes = await WebuiSessionTransfer.run(
                group, hermesProfiles: journal.review.hermesProfiles, source: webui, hermes: hermes,
                configuration: environment.webuiConfiguration,
                willDispatch: { [self] dispatch in
                    do { try logIntent(.importing(profile: dispatch.destination, ids: dispatch.ids, attempt: attempt), in: journal) }
                    catch { failure = error; throw error }
                },
                progress: { [self] done, _ in copyProgress = (settled + done, items.count) })
            settled += group.count
            try log(.copied(outcomes, attempt: attempt), in: journal)
            if let failure { throw failure }
        }
    }

    private func reconcile(_ journal: MoveToHermesJournal, on hermes: any BotTransport) async throws {
        var progress = MoveToHermesProgress(review: journal.review, events: journal.events)
        let unplanned = progress.unplannedTargets
        guard !Task.isCancelled else { return }
        if !unplanned.isEmpty || !progress.inFlight.isEmpty || !progress.operationsToApply.isEmpty {
            state = .running(.reconciling)
        }
        if !unplanned.isEmpty {
            let planned = await MoveToHermesReconcile.plan(unplanned, on: hermes).filter { $0.value != .unread }
            if !planned.isEmpty { try logIntent(.planned(planned), in: journal) }
        }
        progress = MoveToHermesProgress(review: journal.review, events: journal.events)
        let inFlight = Array(progress.inFlight.values)
        if !inFlight.isEmpty, !Task.isCancelled {
            for (operation, outcome) in await MoveToHermesReconcile.settle(inFlight, on: hermes) {
                try log(.changed(operation, outcome), in: journal)
            }
        }
        let operations = progress.operationsToApply
        guard !operations.isEmpty, !Task.isCancelled else { return }
        var failure: Error?
        var sent: [MoveToHermesProgress.ChangeKey: MoveToHermesReconcile.Operation] = [:]
        let outcomes = await MoveToHermesReconcile.apply(operations, on: hermes) { [self] operation in
            do { try logIntent(.changing(operation), in: journal) }
            catch { failure = error; throw error }
            sent[MoveToHermesProgress.ChangeKey(operation)] = operation
        }
        for operation in operations {
            if let outcome = outcomes[operation] {
                try log(.changed(sent[MoveToHermesProgress.ChangeKey(operation)] ?? operation, outcome), in: journal)
            }
        }
        if let failure { throw failure }
    }

    private func moveDrafts(_ journal: MoveToHermesJournal, hermes: URL, connectionID: UUID,
                            on transport: any BotTransport) async throws {
        let plans = MoveToHermesProgress(review: journal.review, events: journal.events).plansNeedingDrafts
        guard !plans.isEmpty, !Task.isCancelled, let webui = URL(string: sourceServerID) else { return }
        state = .running(.movingDrafts)
        let store = environment.drafts()
        for plan in plans {
            guard !Task.isCancelled else { return }
            let outcomes = await MoveToHermesReconcile.moveDrafts([plan], webui: webui, hermes: hermes, connectionID: connectionID,
                                                                 store: store, on: transport,
                                                                 canTransfer: { [self] in record != nil && !Task.isCancelled })
            guard record != nil else { throw Stop.destinationRemoved }
            try log(.drafts(outcomes.mapValues(MoveToHermesDraftResult.init)), in: journal)
        }
    }

    private func draftsWaiting(_ progress: MoveToHermesProgress) async -> Set<String> {
        guard let webui = URL(string: sourceServerID) else { return [] }
        var waiting = Set<String>()
        for plan in progress.plansNeedingDrafts {
            let key = ChatDraftKey.session(server: webui, sessionID: plan.target.chat.id)
            if await environment.drafts().draft(for: key)?.isEmpty == false { waiting.insert(plan.target.chat.id) }
        }
        return waiting
    }

    private func finish(_ journal: MoveToHermesJournal, early: Bool) async {
        state = .running(.finishing)
        let report: MoveToHermesReport
        if let saved = journal.finishedReport {
            report = saved
        } else {
            let progress = MoveToHermesProgress(review: journal.review, events: journal.events)
            report = progress.report(finishedEarly: early && progress.hasWorkLeft, draftsWaiting: await draftsWaiting(progress))
            do {
                try logIntent(.finished(report), in: journal)
            } catch Stop.destinationRemoved {
                return state = .paused(.destinationRemoved)
            } catch {
                return state = .paused(.saveFailed)
            }
        }
        let now = environment.now()
        do {
            try auth.updateMoveRecord(forSource: sourceServerID) { record in
                record.completedAt = now
                record.report = report.summary(at: now)
            }
        } catch {
            return state = .paused(record == nil ? .destinationRemoved : .saveFailed)
        }
        state = .finished(report)
    }
}
