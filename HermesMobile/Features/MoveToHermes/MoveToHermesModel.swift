import ActivityKit
import Foundation
import Observation
import SwiftData

/// How the guided sheet opens (#1218): from a webui server's Move card, a banner's Resume or
/// Details, a finished report, Copy Missing Chats Again, or the offer after a Hermes sign-in
/// (`MoveToHermesOffer`), which names the server signed in to, or another report's "Move
/// <next> Next".
enum MoveToHermesEntry: Equatable {
    case start, resume, details, copyMissingAgain
    case offer(destinationID: String)
    /// Opens at the host step even with a saved Hermes sign-in, so nothing is checked until
    /// the user picks a host (#1268).
    case next
}

/// "Bring your chats" after a Hermes sign-in (#1266): the Hermes server just signed in to, and
/// the first webui server in the list that hasn't moved, so has no move record. One at a time;
/// `AuthManager` ends it when either server changes.
struct MoveToHermesOffer: Identifiable, Equatable {
    let destinationID: String
    let sourceID: String
    var id: String { "\(sourceID)\n\(destinationID)" }

    /// Nil when every webui server has a move record.
    init?(destinationID: String, servers: [ServerAccount]) {
        let moved = Set(servers.flatMap { $0.movedWebuiServers.map(\.sourceServerID) })
        guard let source = servers.first(where: { $0.kind == .webui && !moved.contains($0.id) }) else { return nil }
        self.destinationID = destinationID
        self.sourceID = source.id
    }
}

/// The one-time "Move <server> to Hermes" question for a webui server (#1267).
struct MoveToHermesQuestion: Identifiable, Equatable {
    let sourceID: String
    /// The webui server has a Bots connection, so Move to Hermes goes straight to the scan
    /// instead of the Hermes sign-in; the sheet's second line says which.
    let hasBotsSignIn: Bool
    var id: String { sourceID }
}

/// The guided Move to Hermes sheet's model (#1218). It reads what Review shows without changing
/// either server: the host's own sign-in check (refusal R3), Profiles and a scan, then the
/// webui's running chats (R4). Move hands the frozen Review to `MoveToHermesRunner.start`, which
/// owns everything after it; the sheet then shows the runner's state.
///
/// The sheet owns every task this runs (`perform`), so closing it (`close`) cancels the scan,
/// which changes nothing, or pauses a move, which Resume picks up. Done acknowledges the report,
/// then switches to the destination; nothing switches servers before that. The report can also
/// remove the webui server or move the next one (#1268).
@MainActor @Observable final class MoveToHermesModel {
    enum Refusal: Equatable {
        /// R3: the host runs this release, older than `HermesCompatibility.minimumVersion`.
        case outdated(String)
        /// R4: this many of the webui server's chats are streaming a reply.
        case running(Int)
        /// The webui's list couldn't be read just before a pass, so running chats are unknown.
        case sourceUnreadable
    }

    /// What the sheet shows.
    enum Screen: Equatable {
        case loading
        case chooseHost
        case checking
        case refused(Refusal)
        case review
        case progress(MoveToHermesRunner.Step?)
        case paused(MoveToHermesRunner.Pause)
        case finished(MoveToHermesReport)
        /// Nothing was committed or changed.
        case couldNotStart(MoveToHermesRunner.StartFailure)
    }

    /// The checking screen's steps (A1b). An error stops the check where it happened.
    struct Checking: Equatable {
        var signedIn = false
        /// The host's sign-in or Profile list failed, with the connection advice to show.
        var hostError: String?
        /// The webui's chats, once its list was read.
        var chats: Int?
        var located = 0
        var webuiFailed = false
    }

    /// One webui Profile in Review's mapping (M1).
    struct ProfileChoice: Identifiable, Equatable {
        let source: String
        let chats: Int
        /// A Hermes Profile has this name, so it was preselected.
        let sameName: Bool
        var id: String { source }
    }

    struct Review {
        /// The destination's sign-in: the one the move commits, or the configured server's own.
        let connection: BotConnection
        let version: String?
        let hermesProfiles: [String]
        /// The Profile `profiles.list` marks `is_default`, which an unmatched webui Profile starts on.
        let hermesDefault: String?
        let profiles: [ProfileChoice]
        let scan: MoveToHermesScan.Result
        /// Webui chats with a draft on this iPhone.
        let drafted: Set<String>
        /// Copy Missing Chats Again: the move record's mapping, which can't change.
        let isRepeat: Bool
    }

    /// What the model reaches outside itself; tests replace every part.
    struct Environment {
        var runner = MoveToHermesRunner.Environment()
        /// Sessions of `server` whose Live Activity on this iPhone is still running.
        var liveActivitySessions: @MainActor (URL) -> Set<String> = { server in
            Set(Activity<AgentRunActivityAttributes>.activities.compactMap { activity in
                let state = activity.content.state
                guard activity.attributes.server == server, activity.attributes.bot == nil,
                      activity.activityState == .active, !state.isFinal, !state.isStale else { return nil }
                return state.sessionID
            })
        }
        var notices: @MainActor () -> MoveToHermesNotices = { .shared }
    }

    let sourceID: String
    /// What the sheet shows, with a running pass's live step.
    var screen: Screen {
        if case .progress = phase, case .running(let step)? = runner?.state { return .progress(step) }
        return phase
    }
    private var phase: Screen = .loading
    private(set) var checking = Checking()
    private(set) var review: Review?
    /// Review's choice for each webui Profile; one without an entry is unchosen.
    var mapping: [String: MovedWebuiProfile.Destination] = [:]
    /// The Hermes server a host choice named or the move record holds, by registry id.
    private(set) var destinationID: String?
    /// The destination's name as screens show it.
    private(set) var destinationName = ""
    private(set) var runner: MoveToHermesRunner?
    /// The paused move's counts (finish-early A1), read after each pass.
    private(set) var snapshot: MoveToHermesRunner.Snapshot?
    /// The webui server's saved Hermes sign-in, which Move Next's host step offers first instead
    /// of scanning with it (`.next`).
    private(set) var savedHost: BotConnection?

    @ObservationIgnored private let auth: AuthManager
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var connection: BotConnection?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The pass a running check stopped, for Try Again.
    @ObservationIgnored private var checkedPass: (check: RunningCheck, call: @MainActor (MoveToHermesRunner) async -> Void)?

    init(auth: AuthManager, sourceID: String, environment: Environment = Environment()) {
        self.auth = auth
        self.sourceID = sourceID
        self.environment = environment
    }

    /// The webui server as the registry holds it now; nil once it is removed.
    var source: ServerAccount? { auth.servers.first { $0.id == sourceID && $0.kind == .webui } }
    var sourceName: String { source.map(Self.name) ?? URL(string: sourceID)?.host ?? sourceID }
    private var sourceURL: URL? { URL(string: sourceID) }

    // MARK: Opening

    /// Shows where this webui server's move stands, or starts one. The offer after a sign-in
    /// scans the server it names.
    func open(_ entry: MoveToHermesEntry) {
        guard let held = auth.moveRecord(forSource: sourceID) else {
            if case .offer(let destinationID) = entry, let server = hostChoices.first(where: { $0.id == destinationID }) {
                return choose(server)
            }
            return resolveHost(scanning: entry != .next)
        }
        destinationID = held.destination.id
        destinationName = Self.name(held.destination)
        let runner = makeRunner(held.destination.id)
        self.runner = runner
        if entry == .copyMissingAgain { return copyMissingChatsAgain() }
        let status = MoveToHermesPending.all(in: auth.servers, root: environment.runner.root)
            .first { $0.sourceServerID == sourceID && $0.destinationID == held.destination.id }?.status
        switch status {
        case .unfinished?:
            if entry == .resume { return resume() }
            phase = .paused(.workLeft)
            perform { [self] in snapshot = await runner.snapshot() }
        case .finished?:
            // A saved report only marks the record complete again (the same report), then shows.
            runPass { await $0.resume() }
        case .damaged?: phase = .paused(.damaged)
        case .needsRescan?: phase = .paused(.needsRescan)
        case .unreadable?: phase = .paused(.unreadable)
        case nil: copyMissingChatsAgain()
        }
    }

    /// The webui server's saved Hermes sign-in names the host; without one, D asks. Move Next
    /// (`scanning` false) shows D with the saved sign-in first instead.
    private func resolveHost(scanning: Bool) {
        guard let sourceURL, let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: sourceURL) else {
            phase = .chooseHost
            return
        }
        guard scanning else {
            savedHost = saved
            phase = .chooseHost
            return
        }
        use(saved)
    }

    /// Hermes servers D offers: signed in, so the commit can adopt them. The saved sign-in's
    /// host is offered once, as `savedHost`.
    var hostChoices: [ServerAccount] {
        let store = BotConnectionStore(keychain: auth.keychain)
        let saved = savedHost.map(MoveToHermesRunner.destinationID)
        return auth.servers.filter { server in
            server.kind == .hermes && server.id != saved && URL(string: server.id).flatMap { try? store.load(server: $0) } != nil
        }
    }

    /// D's pick of a configured Hermes server.
    func choose(_ server: ServerAccount) {
        guard let url = URL(string: server.id), let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: url) else {
            return phase = .couldNotStart(.commit(.destinationSignedOut))
        }
        use(saved)
    }

    /// D's pick of the saved sign-in Move Next offers.
    func useSaved() {
        if let savedHost { use(savedHost) }
    }

    /// D's "Sign in to a Hermes host": the normal Hermes sign-in added the server at
    /// `address` without switching to it, so it is scanned as a configured server.
    func signedIn(at address: URL) {
        guard let server = auth.servers.first(where: { $0.id == address.absoluteString }) else { return }
        choose(server)
    }

    /// Scans against `connection`'s host. A Hermes server already configured there is the
    /// destination, scanned with its own sign-in; the commit adopts it.
    private func use(_ connection: BotConnection) {
        let id = MoveToHermesRunner.destinationID(for: connection)
        destinationID = id
        if let configured = auth.servers.first(where: { $0.id == id }) {
            guard configured.kind == .hermes else { return phase = .couldNotStart(.commit(.destinationNotHermes)) }
            guard let url = URL(string: id), let own = try? BotConnectionStore(keychain: auth.keychain).load(server: url) else {
                return phase = .couldNotStart(.commit(.destinationSignedOut))
            }
            destinationName = Self.name(configured)
            self.connection = own
        } else {
            destinationName = connection.name.isEmpty ? (connection.address.host ?? connection.address.absoluteString) : connection.name
            self.connection = connection
        }
        scan()
    }

    // MARK: Scan and Review

    /// Reads what Review shows. Changes nothing on either server and never reads a pairing.
    func scan() {
        guard let connection else { return }
        phase = .checking
        checking = Checking()
        review = nil
        perform { [self] in await scan(on: connection) }
    }

    private func scan(on connection: BotConnection) async {
        guard let sourceURL else { return }
        let destination = environment.runner.destination(connection)
        defer { destination.close() }
        do {
            try await destination.transport.connect()
        } catch {
            guard !Task.isCancelled else { return }
            switch error as? BotFailure {
            case .outdated(let version)?: phase = .refused(.outdated(version))
            default: checking.hostError = BotConnectionAdvice.message(for: error, address: connection.address)
            }
            return
        }
        checking.signedIn = true
        let rows = try? await destination.transport.call(.profilesList(includeSessions: false), validateDispatch: nil)
        let hermesProfiles = rows?["profiles"].list?.compactMap { $0["name"].text } ?? []
        let hermesDefault = rows?["profiles"].list?.first { $0["is_default"].flag == true }?["name"].text
        guard !Task.isCancelled else { return }
        guard !hermesProfiles.isEmpty else {
            checking.hostError = String(localized: "Couldn’t read \(destinationName)’s Profiles. Try again.")
            return
        }
        let (client, session) = webuiClient(sourceURL)
        defer { session.invalidateAndCancel() }
        let result: MoveToHermesScan.Result
        do {
            result = try await MoveToHermesScan.run(webui: client, hermes: destination.transport, hermesProfiles: hermesProfiles) { [self] located, total in
                checking.chats = total
                checking.located = located
            }
        } catch {
            if !Task.isCancelled { checking.webuiFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        let running = Set(result.running).union(environment.liveActivitySessions(sourceURL))
        guard running.isEmpty else { return phase = .refused(.running(running.count)) }
        let webuiProfiles = (try? await client.profiles())?.profiles?.compactMap(\.name) ?? []
        var drafted = Set<String>()
        let drafts = environment.runner.drafts()
        for entry in result.entries {
            if await drafts.draft(for: .session(server: sourceURL, sessionID: entry.chat.id))?.isEmpty == false {
                drafted.insert(entry.chat.id)
            }
        }
        guard !Task.isCancelled else { return }
        let record = auth.moveRecord(forSource: sourceID)?.record
        review = Self.review(connection: connection, hermesProfiles: hermesProfiles, hermesDefault: hermesDefault,
                             webuiProfiles: webuiProfiles, scan: result, drafted: drafted, record: record)
        mapping = Self.initialMapping(profiles: review?.profiles ?? [], hermesDefault: review?.hermesDefault, record: record)
        phase = .review
    }

    /// The webui server's own custom headers, never the active server's. The scan sends them, and
    /// D's sign-in offers them as a tap (#1266).
    var sourceHeaders: [CustomHeader] {
        [CustomHeader].decodeFromStorage(try? auth.keychain.load(.customHeaders, scope: sourceID))
    }

    /// A read-only client on the webui server's own headers and sign-in, never the active server's.
    private func webuiClient(_ sourceURL: URL) -> (client: APIClient, session: URLSession) {
        APIClient.moveCopyClient(baseURL: sourceURL, headers: sourceHeaders, cookies: environment.runner.cookies(sourceURL),
                                 configuration: environment.runner.webuiConfiguration)
    }

    /// The webui's running chats now, with this iPhone's running Live Activities for it, read
    /// again just before a pass copies anything. Nil when the list can't be read, which is
    /// unknown, never "none". Empty once the webui server is gone: nothing more is copied.
    private func runningChats() async -> Set<String>? {
        guard let sourceURL, source != nil else { return [] }
        let (client, session) = webuiClient(sourceURL)
        defer { session.invalidateAndCancel() }
        guard let listing = try? await client.moveScanSessions() else { return nil }
        return Set(listing.sessions.filter(\.isRunning).map(\.sessionId)).union(environment.liveActivitySessions(sourceURL))
    }

    /// Review's Profiles: every webui Profile its list or the scan names, with its chat count.
    /// Copy Missing Chats Again lists the record's Profiles, whose mapping can't change.
    static func review(connection: BotConnection, hermesProfiles: [String], hermesDefault: String?, webuiProfiles: [String],
                       scan: MoveToHermesScan.Result, drafted: Set<String>, record: MovedWebuiServer?) -> Review {
        let counts = Dictionary(grouping: scan.entries, by: \.chat.profile).mapValues(\.count)
        let names = record.map { $0.profiles.map(\.source) }
            ?? Array(Set(webuiProfiles).union(counts.keys)).sorted { ($0 == "default" ? "" : $0) < ($1 == "default" ? "" : $1) }
        let profiles = names.map { ProfileChoice(source: $0, chats: counts[$0] ?? 0, sameName: hermesProfiles.contains($0)) }
        return Review(connection: connection, version: connection.hermesVersion, hermesProfiles: hermesProfiles,
                      hermesDefault: hermesDefault.flatMap { hermesProfiles.contains($0) ? $0 : nil },
                      profiles: profiles, scan: scan, drafted: drafted, isRepeat: record != nil)
    }

    /// A same-name Hermes Profile is preselected, and anything else the host's default Profile
    /// (#1266); Review can change either. Without a default, an unmatched Profile waits for a choice.
    static func initialMapping(profiles: [ProfileChoice], hermesDefault: String?,
                               record: MovedWebuiServer?) -> [String: MovedWebuiProfile.Destination] {
        if let record { return Dictionary(record.profiles.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first }) }
        return Dictionary(uniqueKeysWithValues: profiles.compactMap { choice in
            (choice.sameName ? choice.source : hermesDefault).map { (choice.source, .hermes(profile: $0)) }
        })
    }

    /// Review's counts under the current mapping (A2).
    struct Counts: Equatable {
        var present = 0, toCopy = 0, overLimit = 0, unchecked = 0, drafts = 0
    }

    var counts: Counts {
        guard let review else { return Counts() }
        var counts = Counts()
        for entry in review.scan.entries {
            let mapped = isMapped(entry.chat.profile)
            switch entry.location {
            case .present: counts.present += 1
            case .unknown, .ambiguous: counts.unchecked += 1
            case .missing where mapped && entry.chat.exceedsMessageLimit: counts.overLimit += 1
            case .missing where mapped: counts.toCopy += 1
            case .missing: break
            }
            if mapped, review.drafted.contains(entry.chat.id) { counts.drafts += 1 }
        }
        return counts
    }

    private func isMapped(_ profile: String) -> Bool {
        guard case .hermes? = mapping[profile] else { return false }
        return true
    }

    /// The first webui Profile still without a choice; Move waits for it.
    var unchosenProfile: String? { review?.profiles.first { mapping[$0.source] == nil }?.source }

    // MARK: Running

    /// Freezes Review and starts the move: the commit, then the runner's passes. A report that
    /// Copy Missing Chats Again came from stays until this pass is about to start, so a running
    /// chat or an unreadable webui list still leaves it to reopen.
    func move() {
        guard let review, unchosenProfile == nil, let destinationID, let source else { return }
        let previous = self.runner
        let runner = makeRunner(destinationID)
        self.runner = runner
        let frozen = MoveToHermesRunner.Review(
            source: source, connection: review.connection,
            profiles: review.profiles.compactMap { choice in mapping[choice.source].map { MovedWebuiProfile(source: choice.source, destination: $0) } },
            hermesProfiles: review.hermesProfiles, scan: review.scan)
        runPass(checking: .always) { runner in
            if case .finished? = previous?.state { previous?.acknowledge() }
            await runner.start(frozen)
        }
    }

    /// Another pass; R4 again if a chat started running while the move was paused. Only a pass
    /// with chats left to copy reads the webui: titles, pins, folders and drafts don't need it.
    func resume() { runPass(checking: .whenCopyLeft) { await $0.resume() } }

    /// Try Again after the webui's list couldn't be read before a pass.
    func retryCheckedPass() {
        guard let checkedPass else { return }
        runPass(checking: checkedPass.check, checkedPass.call)
    }

    /// Finish with What's Done: sends nothing, then shows the report.
    func finishEarly() { runPass { await $0.finishEarly() } }

    /// Done: acknowledges the report, then makes the destination the active server.
    func done() {
        acknowledge()
        if let destinationID, let destination = auth.servers.first(where: { $0.id == destinationID }) {
            auth.switchActiveServer(to: destination)
        }
    }

    /// Deletes the finished move's journal, so its report stops waiting.
    func acknowledge() {
        work?.cancel()
        runner?.acknowledge()
        refreshNotices()
    }

    /// "Move <next> Next": acknowledges the report without switching servers, then returns
    /// `nextSource`'s model, which the sheet shows instead. It opens at the host step, so
    /// nothing is checked until the user picks a host.
    func moveNext() -> MoveToHermesModel? {
        guard let next = nextSource else { return nil }
        acknowledge()
        let model = MoveToHermesModel(auth: auth, sourceID: next.id, environment: environment)
        model.open(.next)
        return model
    }

    /// Another configured webui server that hasn't moved, which the report offers to move next.
    var nextSource: ServerAccount? {
        auth.servers.first { $0.kind == .webui && $0.id != sourceID && auth.moveRecord(forSource: $0.id) == nil }
    }

    /// Remove <webui server>…: switches to the destination as Done does, then removes the webui
    /// server as Remove This Server does. The destination keeps the move record (#1224).
    func removeSource(modelContext: ModelContext) async {
        guard let source else { return }
        done()
        await MoveToHermesRemoval.remove(source, auth: auth, modelContext: modelContext)
    }

    /// Scans again and copies only what the destination still lacks, with the record's mapping.
    /// A finished report stays saved until Move starts the next pass (`move()`).
    func copyMissingChatsAgain() {
        guard let destinationID, let url = URL(string: destinationID),
              let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: url) else {
            return phase = .couldNotStart(.commit(.destinationSignedOut))
        }
        connection = saved
        scan()
    }

    /// The sheet closed: a scan stops with nothing changed, a pass pauses where it is.
    func close() {
        if case .progress = phase, let destinationID { environment.notices().noteClosed(source: sourceID, destination: destinationID) }
        work?.cancel()
        work = nil
        refreshNotices()
    }

    /// Waits for the sheet's current task; tests await it instead of sleeping.
    func settled() async { await work?.value }

    /// Whether the destination already holds this move's record, so a pass that is still
    /// checking the webui doesn't show it as being added.
    var destinationAdded: Bool { destinationID.map { id in auth.moveRecord(forSource: sourceID)?.destination.id == id } ?? false }

    /// Whether the destination has a saved sign-in, so a pause there means unreachable, not signed out.
    var destinationIsSignedIn: Bool {
        guard let destinationID, let url = URL(string: destinationID) else { return false }
        return (try? BotConnectionStore(keychain: auth.keychain).load(server: url)) != nil
    }

    /// Whether the user closed this move's last pass, so its paused details say so (3A).
    var wasClosed: Bool {
        destinationID.map { environment.notices().wasClosed(source: sourceID, destination: $0) } ?? false
    }

    /// When a pass reads the webui's list again first (a scan or pause can be minutes old): a chat
    /// streaming now (R4), or a list that can't be read, stops it before anything is sent.
    private enum RunningCheck {
        /// Finish with What's Done sends nothing to check.
        case never
        /// Resume, only while chats are left to copy (or the journal can't say).
        case whenCopyLeft
        /// Move: a new pass always copies what its Review counted, whatever an older journal says.
        case always
    }

    /// Runs one runner call as the sheet's task, marked running for the card, then shows the
    /// runner's state with the counts a pause shows, after the `checking` it asks for.
    private func runPass(checking: RunningCheck = .never, _ call: @escaping @MainActor (MoveToHermesRunner) async -> Void) {
        guard let runner, let destinationID else { return }
        let notices = environment.notices()
        phase = .progress(nil)
        notices.setRunning(true, source: sourceID, destination: destinationID)
        perform { [self] in
            let checks = switch checking {
            case .never: false
            case .always: true
            // Unknown work left (an unreadable journal) checks too.
            case .whenCopyLeft: await runner.snapshot()?.copyLeft ?? 1 > 0
            }
            if checks {
                checkedPass = (checking, call)
                let running = await runningChats()
                if running?.isEmpty != true {
                    notices.setRunning(false, source: sourceID, destination: destinationID)
                    guard !Task.isCancelled else { return }
                    return phase = .refused(running.map { .running($0.count) } ?? .sourceUnreadable)
                }
            }
            await call(runner)
            notices.setRunning(false, source: sourceID, destination: destinationID)
            guard !Task.isCancelled else { return refreshNotices() }
            notices.clearClosed(source: sourceID, destination: destinationID)
            snapshot = await runner.snapshot()
            showRunner()
            refreshNotices()
        }
    }

    private func showRunner() {
        switch runner?.state {
        case .running(let step)?: phase = .progress(step)
        case .paused(let pause)?: phase = .paused(pause == .cancelled ? .workLeft : pause)
        case .finished(let report)?: phase = .finished(report)
        case .notStarted(let failure)?: phase = .couldNotStart(failure)
        case .idle?, nil: break
        }
    }

    private func makeRunner(_ destinationID: String) -> MoveToHermesRunner {
        MoveToHermesRunner(auth: auth, sourceServerID: sourceID, destinationID: destinationID, environment: environment.runner)
    }

    /// Runs `body` as the sheet's one task, replacing any before it.
    private func perform(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { await body() }
    }

    private func refreshNotices() {
        let notices = environment.notices()
        let auth = auth
        Task { await notices.refresh(auth) }
    }

    /// A server's name as Settings shows it.
    static func name(_ server: ServerAccount) -> String {
        server.displayName.isEmpty ? (URL(string: server.urlString)?.host ?? server.urlString) : server.displayName
    }
}

// MARK: - Report counts

extension MoveToHermesReport {
    /// Chats in Hermes, whether this move copied them or not.
    var chatsInHermes: Int { copied.count + alreadyThere.count + presentUnconfirmed.count }
    /// Every chat the report lists: each scanned chat is in exactly one list.
    var chatsListed: Int {
        chatsInHermes + sentUnconfirmed.count + notCopied.count + oversized.count + rejected.count
            + unchecked.count + keptOnWebui.count
    }
}

// MARK: - Notices

/// Where a webui server's move stands, for its Settings card (1A) and the session list banners
/// (S1, 2A, A5).
struct MoveToHermesNotice: Equatable {
    enum Stage: Equatable {
        /// A sheet is running a pass now.
        case running
        /// `canResume` is false when the journal is damaged, lost or unreadable.
        case paused(canResume: Bool)
        /// The report waits for Done.
        case finished
        /// The move is complete; the webui server stays usable with a warning.
        case moved
    }

    let sourceID: String
    let destination: ServerAccount
    let stage: Stage
    /// Chats in Hermes out of every scanned chat, when the journal could be read.
    var inHermes: Int?
    var total: Int?
    /// The move record's last counts, which removal reads.
    var report: MovedWebuiReport?
}

/// The moves the app hasn't closed, read from their journals (`MoveToHermesPending`), and the
/// notice each server shows. Refreshed when a list or Settings appears, on foreground, and after
/// each pass; reading journals never happens in a view's body.
@MainActor @Observable final class MoveToHermesNotices {
    static let shared = MoveToHermesNotices()

    struct Move: Equatable {
        let sourceID: String
        let destinationID: String
        let status: MoveToHermesPending.Status
        var inHermes: Int?
        var total: Int?
    }

    private(set) var moves: [Move] = []
    /// Moves a sheet is running now.
    private(set) var running: Set<String> = []
    /// Moves whose last pass the user closed, until another pass ends (3A).
    @ObservationIgnored private var closed: Set<String> = []
    /// Refreshes started, so only the latest one publishes.
    @ObservationIgnored private var refreshes = 0
    /// The journals' folder and draft store the counts read.
    @ObservationIgnored private let environment: MoveToHermesRunner.Environment

    init(environment: MoveToHermesRunner.Environment = MoveToHermesRunner.Environment()) {
        self.environment = environment
    }

    private static func key(_ source: String, _ destination: String) -> String { "\(source)\n\(destination)" }

    /// Reads every unclosed move, deleting journal folders no record owns. Unfinished moves get
    /// their counts unless a runner holds them.
    func refresh(_ auth: AuthManager) async {
        refreshes += 1
        let generation = refreshes
        var moves: [Move] = []
        for pending in MoveToHermesPending.all(in: auth.servers, root: environment.root) {
            var move = Move(sourceID: pending.sourceServerID, destinationID: pending.destinationID, status: pending.status)
            switch pending.status {
            case .unfinished:
                let runner = MoveToHermesRunner(auth: auth, sourceServerID: pending.sourceServerID,
                                                destinationID: pending.destinationID, environment: environment)
                if let snapshot = await runner.snapshot() {
                    move.inHermes = snapshot.inHermes
                    move.total = snapshot.total
                }
            case .finished(let report):
                move.inHermes = report.chatsInHermes
                move.total = report.chatsListed
            case .damaged, .unreadable, .needsRescan: break
            }
            moves.append(move)
        }
        // A refresh that started later already published newer state.
        guard generation == refreshes else { return }
        self.moves = moves
    }

    func setRunning(_ isRunning: Bool, source: String, destination: String) {
        if isRunning { running.insert(Self.key(source, destination)) } else { running.remove(Self.key(source, destination)) }
    }

    func noteClosed(source: String, destination: String) { closed.insert(Self.key(source, destination)) }
    func clearClosed(source: String, destination: String) { closed.remove(Self.key(source, destination)) }
    func wasClosed(source: String, destination: String) -> Bool { closed.contains(Self.key(source, destination)) }

    /// How many of each server's chat lists are on screen. A webui list reports its appearance
    /// (`noteChatList`): on iPhone it disappears under a pushed chat, on iPad with its sidebar.
    /// Counted, so a rebuild's new list appearing before the old one leaves doesn't hide it.
    private var chatListsOnScreen: [String: Int] = [:]

    func noteChatList(of serverID: String, onScreen: Bool) {
        let count = (chatListsOnScreen[serverID] ?? 0) + (onScreen ? 1 : -1)
        chatListsOnScreen[serverID] = count > 0 ? count : nil
    }

    /// Whether `serverID`'s chat list is on screen, which the one-time question waits for.
    func showsChatList(of serverID: String?) -> Bool {
        serverID.map { chatListsOnScreen[$0] != nil } ?? false
    }

    /// The Settings card's notice for a webui server, or nil before any move.
    func card(forSource sourceID: String, in servers: [ServerAccount]) -> MoveToHermesNotice? {
        Self.notice(forSource: sourceID, servers: servers, moves: moves, running: running)
    }

    /// The banner a server's session list shows: its own move as the webui server, or a move
    /// to it that is paused or waiting for Done. A running move shows none; its sheet is up.
    func banner(for serverID: String, in servers: [ServerAccount]) -> MoveToHermesNotice? {
        Self.banner(for: serverID, servers: servers, moves: moves, running: running)
    }

    static func notice(forSource sourceID: String, servers: [ServerAccount], moves: [Move], running: Set<String>) -> MoveToHermesNotice? {
        guard let destination = servers.first(where: { $0.movedWebuiServers.contains { $0.sourceServerID == sourceID } }),
              let record = destination.movedWebuiServers.first(where: { $0.sourceServerID == sourceID }) else { return nil }
        if running.contains(key(sourceID, destination.id)) {
            return MoveToHermesNotice(sourceID: sourceID, destination: destination, stage: .running, report: record.report)
        }
        guard let move = moves.first(where: { $0.sourceID == sourceID && $0.destinationID == destination.id }) else {
            return MoveToHermesNotice(sourceID: sourceID, destination: destination, stage: .moved, report: record.report)
        }
        let stage: MoveToHermesNotice.Stage = switch move.status {
        case .unfinished: .paused(canResume: true)
        case .finished: .finished
        case .damaged, .unreadable, .needsRescan: .paused(canResume: false)
        }
        return MoveToHermesNotice(sourceID: sourceID, destination: destination, stage: stage,
                                  inHermes: move.inHermes, total: move.total, report: record.report)
    }

    static func banner(for serverID: String, servers: [ServerAccount], moves: [Move], running: Set<String>) -> MoveToHermesNotice? {
        if servers.contains(where: { $0.id == serverID && $0.kind == .webui }),
           let notice = notice(forSource: serverID, servers: servers, moves: moves, running: running) {
            return notice.stage == .running ? nil : notice
        }
        guard let destination = servers.first(where: { $0.id == serverID }) else { return nil }
        for record in destination.movedWebuiServers {
            if let notice = notice(forSource: record.sourceServerID, servers: servers, moves: moves, running: running),
               notice.stage != .running, notice.stage != .moved {
                return notice
            }
        }
        return nil
    }
}

// MARK: - Removal

/// Removing a server a move involves (S2, S3, 7A, 8c-1): what stays behind, which old entry
/// points keep working, and what happens to notifications. Removal deletes the server's drafts
/// on this iPhone as it always has, without its own warning.
@MainActor enum MoveToHermesRemoval {
    /// The alert's message for removing `account`, or nil when no move involves it.
    static func message(for account: ServerAccount, servers: [ServerAccount],
                        pairing: @MainActor (URL) -> PushPairing? = storedPairing) -> String? {
        if account.kind == .webui,
           let destination = servers.first(where: { $0.movedWebuiServers.contains { $0.sourceServerID == account.id } }),
           let record = destination.movedWebuiServers.first(where: { $0.sourceServerID == account.id }) {
            return sourceMessage(source: account, destination: destination, record: record, pairing: pairing)
        }
        let moved = account.movedWebuiServers.map { record in
            servers.first { $0.id == record.sourceServerID }.map(MoveToHermesModel.name)
                ?? URL(string: record.sourceServerID)?.host ?? record.sourceServerID
        }
        guard !moved.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: moved)
        return String(localized: "Old links, Shortcuts and notifications for \(names), which moved here, stop opening. \(names) returns to normal if it’s still configured.")
    }

    private static func sourceMessage(source: ServerAccount, destination: ServerAccount, record: MovedWebuiServer,
                                      pairing: @MainActor (URL) -> PushPairing?) -> String {
        let from = MoveToHermesModel.name(source)
        let to = MoveToHermesModel.name(destination)
        var sentences: [String] = []
        let report = record.report
        if record.completedAt == nil {
            sentences.append(String(localized: "The move to \(to) hasn’t finished."))
            if let remaining = report?.remaining, let unchecked = report?.unchecked {
                sentences.append(String(localized: "At the last count, \(remaining) chats were only on \(from)."))
                if unchecked > 0 { sentences.append(String(localized: "\(unchecked) more couldn’t be checked.")) }
                sentences.append(String(localized: "After removing it, this iPhone can’t open chats that are only on \(from); they stay on the server."))
            } else {
                sentences.append(unknownCount(from))
            }
        } else if let remaining = report?.remaining, let unchecked = report?.unchecked {
            let total = remaining + unchecked
            if total == 0 {
                sentences.append(String(localized: "Every chat from \(from) is in \(to)."))
            } else {
                let oversized = report?.oversized ?? 0
                let kept = report?.kept ?? 0
                var parts: [String] = []
                if oversized > 0 { parts.append(String(localized: "\(oversized) too large to copy")) }
                let notCopied = max(0, remaining - oversized - kept)
                if notCopied > 0 { parts.append(String(localized: "\(notCopied) not copied")) }
                if unchecked > 0 { parts.append(String(localized: "\(unchecked) that couldn’t be checked")) }
                if kept > 0 {
                    let profiles = record.profiles.filter { $0.destination == .keepOnWebui }.map { "“\($0.source)”" }
                    parts.append(String(localized: "\(kept) in \(ListFormatter.localizedString(byJoining: profiles)), which you kept there"))
                }
                sentences.append(String(localized: "\(total) chats may exist only on \(from): \(ListFormatter.localizedString(byJoining: parts))."))
                sentences.append(String(localized: "After removing it, this iPhone can’t open them; they stay on the server."))
            }
        } else {
            sentences.append(unknownCount(from))
        }
        sentences.append(contentsOf: routing(from: from, to: to, source: source, destination: destination, pairing: pairing))
        return sentences.joined(separator: " ")
    }

    /// This iPhone's stored push pairing for `server`.
    static func storedPairing(_ server: URL) -> PushPairing? { PushRegistrar.shared?.pairing(for: server) }

    private static func unknownCount(_ from: String) -> String {
        String(localized: "Some chats may exist only on \(from). This move couldn’t count them. After removing it, this iPhone can’t open them; they stay on the server.")
    }

    /// Links and Shortcuts always keep opening in the destination. Notifications do only when
    /// both servers share one install's pairing; otherwise the webui server's stop with it.
    private static func routing(from: String, to: String, source: ServerAccount, destination: ServerAccount,
                                pairing: @MainActor (URL) -> PushPairing?) -> [String] {
        let sourcePairing = URL(string: source.id).flatMap(pairing)
        let destinationPairing = URL(string: destination.id).flatMap(pairing)
        guard let sourcePairing else {
            return [String(localized: "Old links and Shortcuts for chats that moved keep opening in \(to).")]
        }
        if let destinationPairing, destinationPairing.installKey == sourcePairing.installKey {
            return [String(localized: "Old links, Shortcuts and notifications for chats that moved keep opening in \(to).")]
        }
        let notifications = destinationPairing == nil
            ? String(localized: "\(from)’s notifications stop with it. \(to)’s own notifications aren’t affected.")
            : String(localized: "\(from) is a different host, so its notifications stop. \(to)’s own notifications aren’t affected.")
        return [String(localized: "Old links and Shortcuts for chats that moved keep opening in \(to)."), notifications]
    }

    /// Removes `account` as Settings does: its offline cache and drafts on this iPhone first,
    /// while the caller's view is alive, then the registry entry.
    static func remove(_ account: ServerAccount, auth: AuthManager, modelContext: ModelContext) async {
        if let url = URL(string: account.urlString) {
            try? CacheStore.clearCache(for: url, in: modelContext)
            await ChatDraftStore.shared.discardDrafts(for: url)
        }
        await auth.removeServer(account)
    }
}
