import Foundation

/// A Move to Hermes's report (#1216): where each webui chat stands and what became of its
/// metadata and draft, by what the move could confirm.
///
/// Being in Hermes and having been copied by this move are separate facts. Only an import reply
/// naming a chat confirms a copy. A chat found in Hermes after a send that never got a reply is
/// `presentUnconfirmed`: the earlier send may have landed, or something else put it there.
struct MoveToHermesReport: Codable, Equatable, Sendable {
    /// The user chose Finish with What's Done while work was left.
    var finishedEarly = false
    /// This run started over a lost or damaged journal, so earlier results are unknown.
    var recovered = false
    /// The webui listed only one Profile, so the others weren't scanned.
    var partialScan = false
    /// Hermes's import reply named these as imported.
    var copied: [String] = []
    /// In Hermes before this move sent them anything, or in another Profile than it sent them to.
    var alreadyThere: [String] = []
    /// In the Profile this move sent them to, after a send with no reply.
    var presentUnconfirmed: [String] = []
    /// Sent with no reply and not found since: they may or may not be in Hermes.
    var sentUnconfirmed: [String] = []
    /// Missing from Hermes at the last check and not copied: their export failed or was never tried.
    var notCopied: [String] = []
    /// Over the host's import limits. Never trimmed.
    var oversized: [String] = []
    /// Refused by the host, with its reason.
    var rejected: [String: String] = [:]
    /// Couldn't be checked, or two Hermes Profiles hold them. Not copied by this move.
    var unchecked: [String] = []
    /// Missing from Hermes, in a webui Profile kept there or left unmapped.
    var keptOnWebui: [String] = []
    var pairing: MoveToHermesPairing?
    var changesApplied = 0
    /// Never sent: the move finished first, or the session was gone.
    var changesNotApplied: [MoveToHermesReconcile.Operation] = []
    /// Sent with no reply, and Hermes doesn't show the value. Never sent again.
    var changesUnconfirmed: [MoveToHermesReconcile.Operation] = []
    /// Hermes's value changed after planning, so it was left as it is.
    var changesLeftAlone: [MoveToHermesReconcile.Operation] = []
    var foldersMissing: [MoveToHermesReconcile.Operation] = []
    var changesRejected: [MoveToHermesReconcile.Operation] = []
    /// Chats in Hermes whose row couldn't be read, so nothing was filled for them.
    var notReconciled: [String] = []
    var draftsMoved = 0
    /// A different draft is in Hermes; both stay untouched.
    var draftConflicts: [String] = []
    /// Drafts that stay on this iPhone under the webui server: their Hermes key couldn't be
    /// verified, the session is gone, or the move finished before moving them.
    var draftsKept: [String] = []
    /// The webui titles of the chats listed above, so the report reads without the journal.
    var titles: [String: String] = [:]

    /// The counts the move record keeps for removal copy. Remaining counts only chats confirmed
    /// missing from Hermes; chats that couldn't be checked or confirmed count as unchecked.
    func summary(at date: Date) -> MovedWebuiReport {
        MovedWebuiReport(remaining: partialScan ? nil : notCopied.count + oversized.count + rejected.count + keptOnWebui.count,
                         unchecked: unchecked.count + sentUnconfirmed.count, oversized: oversized.count,
                         kept: partialScan ? nil : keptOnWebui.count, recordedAt: date)
    }
}

/// A Move's progress, folded from its frozen Review and its log (#1216). Recomputed whenever the
/// runner needs it, so the log is the only state.
struct MoveToHermesProgress {
    /// A metadata write's field, which stays the same when a title is retried with a suffix.
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
    /// The Profile each chat's latest import was sent to.
    private(set) var sentTo: [String: String] = [:]
    /// Sent with no outcome logged yet: in flight, or the reply or its line was lost.
    private(set) var awaiting: Set<String> = []
    /// A send whose result was never known: `.uncertain`, or its outcome line lost before a
    /// later attempt settled the chat.
    private(set) var unconfirmedSend: Set<String> = []
    /// The copy attempt each awaiting chat was last sent in.
    private var sentIn: [String: UUID] = [:]
    private(set) var plans: [String: MoveToHermesReconcile.Planned] = [:]
    /// Writes logged as sent with no outcome: settled by reading, never resent.
    private(set) var inFlight: [ChangeKey: MoveToHermesReconcile.Operation] = [:]
    private(set) var changes: [ChangeKey: MoveToHermesReconcile.Outcome] = [:]
    /// The write each outcome is for, which is the suffixed title after a collision retry.
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
                // Still awaiting a send from another attempt: that attempt's outcome was lost.
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

    /// Whether an import may have reached Hermes without the move knowing.
    private func unconfirmed(_ id: String) -> Bool { unconfirmedSend.contains(id) || awaiting.contains(id) }

    /// The chats still to copy, each to its mapped Profile. A chat sent before goes to the same
    /// Profile under the same id: the host skips an id it already has, so this resends imports only.
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

    /// The chats reconcile fills (`MoveToHermesReconcile.targets`) from mapped Profiles only. A
    /// chat found after an unconfirmed send counts as one Hermes already had: on the first move
    /// it gets empty titles and folders and its draft, never a pin; Copy Missing Chats Again
    /// leaves it alone.
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

    /// Planned writes never sent, or not sent last time.
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

    /// Whether Resume has anything left to try. A pairing check that didn't answer is tried
    /// again on Resume but never holds the move open.
    var hasWorkLeft: Bool {
        !copyItems.isEmpty || !unplannedTargets.isEmpty || !inFlight.isEmpty
            || !operationsToApply.isEmpty || !plansNeedingDrafts.isEmpty
    }

    /// The report as things stand. Work left becomes what it is at a stop: a send with no reply
    /// is unconfirmed, a write never sent is not applied, a draft not moved stays on the webui.
    /// `draftsWaiting` are the planned chats that still have a webui draft.
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

/// The Hermes host a Move writes to: a client on a connection of the move's own, never the
/// shared one (`HermesConnections.shared` keeps one connection, and asking it for the
/// destination would close the active server's). `connections` makes it beside that one
/// (`ownConnection`), so a browser sign-in's rotated refresh tokens are saved as the
/// destination's own connection saves them (#1265).
@MainActor struct MoveToHermesDestination {
    let transport: any BotTransport
    /// Signs in and reads the host's push pairing, which can create the host's keys.
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

/// Runs one Move to Hermes after the user confirms it, and resumes it after any interruption
/// (#1216). The guided sheet (#1218) owns it and the task each call runs in; cancelling that
/// task pauses the move.
///
/// `start` writes the frozen Review to the journal, then commits (`AuthManager.commitMove`).
/// Cancelling or failing before the commit leaves nothing behind. Each pass after it runs:
/// 1. The push pairing carry (`MovePushPairing.carry`), only ever after the commit.
/// 2. The copy (`WebuiSessionTransfer`), one source Profile at a time. Each import is logged
///    and flushed before it goes out; one whose result is unknown is sent again next pass.
/// 3. Reconcile (`MoveToHermesReconcile`): plans are logged before any write, each write is
///    logged before it goes out, and one logged with no result is only ever settled by reading.
/// 4. Draft moves.
///
/// A pass with work left pauses for Resume; Finish with What's Done ends it early. Finishing
/// logs the report, then marks the move record complete with its counts, and keeps the journal
/// until the user taps Done (`acknowledge`). A failed write anywhere stops sending and pauses.
@MainActor @Observable final class MoveToHermesRunner {
    enum Step: Equatable {
        case pairing, copying, reconciling, movingDrafts, finishing
    }

    enum Pause: Equatable {
        /// The task was cancelled: the sheet closed or the app stopped it.
        case cancelled
        /// A pass ended with work Resume can try again.
        case workLeft
        /// The destination is signed out or didn't connect.
        case destinationUnavailable
        /// The destination was removed, and its move with it.
        case destinationRemoved
        /// The journal or the move record couldn't be saved; nothing more was sent.
        case saveFailed
        /// The journal can't be trusted. Copy Missing Chats Again from a fresh scan starts over.
        case damaged
        /// The journal can't be read now, such as before the first unlock. Try again later.
        case unreadable
        /// The move isn't complete and its journal is gone. Start over from a fresh scan.
        case needsRescan
    }

    enum StartFailure: Error, Equatable {
        /// This move already has a journal: resume or finish it first.
        case moveInProgress
        /// The journal couldn't be written, so nothing was committed.
        case journal
        case commit(AuthManager.MoveCommitError)
    }

    enum State: Equatable {
        case idle
        case running(Step)
        case paused(Pause)
        case finished(MoveToHermesReport)
        /// Nothing was committed or changed.
        case notStarted(StartFailure)
    }

    /// What Review hands the runner when the user confirms Move.
    struct Review {
        let source: ServerAccount
        /// The destination's sign-in, saved by the commit when the server is new.
        let connection: BotConnection
        let profiles: [MovedWebuiProfile]
        let hermesProfiles: [String]
        let scan: MoveToHermesScan.Result
    }

    /// What the runner reaches outside itself; tests replace every part.
    struct Environment {
        var root = MoveToHermesJournal.defaultRoot
        var destination: @MainActor (BotConnection) -> MoveToHermesDestination = { MoveToHermesDestination.live($0) }
        /// The webui copy's URL session setup; tests add their protocol class.
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
    /// Chats settled out of those this pass is copying.
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

    /// The id `commitMove` gives the Hermes server at `connection`'s address.
    static func destinationID(for connection: BotConnection) -> String {
        ((try? BotConnection.address(connection.address.absoluteString)) ?? connection.address).absoluteString
    }

    private var folder: URL {
        MoveToHermesJournal.folder(source: sourceServerID, destination: destinationID, in: environment.root)
    }

    /// The move's record while its destination holds it and isn't being removed.
    private var record: MovedWebuiServer? {
        guard !auth.removingServerIDs.contains(destinationID), let held = auth.moveRecord(forSource: sourceServerID), held.destination.id == destinationID else { return nil }
        return held.record
    }

    // MARK: Entry points

    /// Freezes `review`, commits, then runs the first pass. A move this webui server already
    /// made to this destination runs as Copy Missing Chats Again, with the record's mapping.
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

    /// Picks the move up from its journal: another pass, or only the record update when its
    /// report is already saved.
    func resume() async {
        guard MoveToHermesJournal.claim(folder) else { return }
        defer { MoveToHermesJournal.release(folder) }
        guard loadJournal() != nil else { return }
        await runPass()
    }

    /// Finish with What's Done: ends a paused move now, with what is left reported as it stands.
    /// Sends nothing.
    func finishEarly() async {
        guard MoveToHermesJournal.claim(folder) else { return }
        defer { MoveToHermesJournal.release(folder) }
        guard let journal = loadJournal() else { return }
        await finish(journal, early: true)
    }

    /// Done: deletes the journal once the report is saved in both places.
    func acknowledge() {
        guard case .finished = state, !MoveToHermesJournal.isClaimed(folder) else { return }
        (journal ?? loadJournal())?.discard()
        journal = nil
        state = .idle
    }

    /// Where a move stands, for the guided sheet's paused details and the banners (#1218).
    struct Snapshot: Equatable {
        /// The report as things stand, or the saved final report.
        let report: MoveToHermesReport
        /// Every webui chat the scan listed.
        let total: Int
        /// Chats Resume would copy, writes it would send and drafts it would move.
        let copyLeft: Int
        let changesLeft: Int
        let draftsLeft: Int
        /// Chats in Hermes whose titles, pins, folders and drafts aren't planned yet.
        let unplanned: Int

        /// Chats in Hermes, whether this move copied them or not.
        var inHermes: Int { report.copied.count + report.alreadyThere.count + report.presentUnconfirmed.count }
    }

    /// Reads the move's journal without changing `state`; nil when it can't be read, or while
    /// another runner holds it (opening cuts a torn last line, which could be that runner's).
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

    /// The journal, read from disk unless this runner holds it, or nil with `state` saying why.
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

    // MARK: Pass

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
            // Best effort: removal copy reads these counts, and a later pass saves them again.
            let report = progress.report(finishedEarly: false, draftsWaiting: await draftsWaiting(progress))
            try? auth.updateMoveRecord(forSource: sourceServerID) { $0.report = report.summary(at: environment.now()) }
            state = .paused(Task.isCancelled ? .cancelled : .workLeft)
        } else {
            await finish(journal, early: false)
        }
    }

    /// Logs `event` and flushes it before anything it names is sent, while the move's record
    /// still exists: after the destination is removed, nothing more is written or sent.
    private func logIntent(_ event: MoveToHermesEvent, in journal: MoveToHermesJournal) throws {
        guard record != nil else { throw Stop.destinationRemoved }
        do { try journal.append(event, durable: true) } catch { throw Stop.saveFailed }
    }

    private func log(_ event: MoveToHermesEvent, in journal: MoveToHermesJournal) throws {
        do { try journal.append(event, durable: false) } catch { throw Stop.saveFailed }
    }

    /// The first step after the commit; tried again on Resume while the host hasn't answered.
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

    /// Copies what is left, one source Profile at a time, while the webui server is configured.
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

    /// Plans the targets not planned yet, settles writes left in flight, then applies the rest.
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
            // Logged as the write last sent, so a suffixed title retry reports the title it tried.
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
        // One chat at a time, each result logged before the next, so a quit loses at most one
        // chat's result: its draft has moved, and Resume finds nothing left to move.
        for plan in plans {
            guard !Task.isCancelled else { return }
            // Asked again just before the transfer: a destination removal discards its drafts
            // before its entry goes, so a draft moved after that point would be lost with it.
            let outcomes = await MoveToHermesReconcile.moveDrafts([plan], webui: webui, hermes: hermes, connectionID: connectionID,
                                                                 store: store, on: transport,
                                                                 canTransfer: { [self] in record != nil && !Task.isCancelled })
            guard record != nil else { throw Stop.destinationRemoved }
            try log(.drafts(outcomes.mapValues(MoveToHermesDraftResult.init)), in: journal)
        }
    }

    /// The planned chats whose webui draft is still on this iPhone, for a report made before
    /// every draft step finished.
    private func draftsWaiting(_ progress: MoveToHermesProgress) async -> Set<String> {
        guard let webui = URL(string: sourceServerID) else { return [] }
        var waiting = Set<String>()
        for plan in progress.plansNeedingDrafts {
            let key = ChatDraftKey.session(server: webui, sessionID: plan.target.chat.id)
            if await environment.drafts().draft(for: key)?.isEmpty == false { waiting.insert(plan.target.chat.id) }
        }
        return waiting
    }

    // MARK: Finish

    /// Logs the report, flushed, before the move record is marked complete, and keeps the
    /// journal for Done. A report already logged is reused, so a retry after a failed record
    /// save reports the same thing.
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
