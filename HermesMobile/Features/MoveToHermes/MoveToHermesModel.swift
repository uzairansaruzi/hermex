import ActivityKit
import Foundation
import Observation
import SwiftData

enum MoveToHermesEntry: Equatable {
    case start, resume, details, copyMissingAgain
    case offer(destinationID: String)
    case next
}

struct MoveToHermesOffer: Identifiable, Equatable {
    let destinationID: String
    let sourceID: String
    var id: String { "\(sourceID)\n\(destinationID)" }

    init?(destinationID: String, servers: [ServerAccount]) {
        let moved = Set(servers.flatMap { $0.movedWebuiServers.map(\.sourceServerID) })
        guard let source = servers.first(where: { $0.kind == .webui && !moved.contains($0.id) }) else { return nil }
        self.destinationID = destinationID
        self.sourceID = source.id
    }
}

struct MoveToHermesQuestion: Identifiable, Equatable {
    let sourceID: String
    let hasBotsSignIn: Bool
    var id: String { sourceID }
}

@MainActor @Observable final class MoveToHermesModel {
    enum Refusal: Equatable {
        case outdated(String)
        case running(Int)
        case sourceUnreadable
    }

    enum Screen: Equatable {
        case loading
        case chooseHost
        case checking
        case refused(Refusal)
        case review
        case progress(MoveToHermesRunner.Step?)
        case paused(MoveToHermesRunner.Pause)
        case finished(MoveToHermesReport)
        case couldNotStart(MoveToHermesRunner.StartFailure)
    }

    struct Checking: Equatable {
        var signedIn = false
        var hostError: String?
        var chats: Int?
        var located = 0
        var webuiFailed = false
    }

    struct ProfileChoice: Identifiable, Equatable {
        let source: String
        let chats: Int
        let sameName: Bool
        var id: String { source }
    }

    struct Review {
        let connection: BotConnection
        let version: String?
        let hermesProfiles: [String]
        let hermesDefault: String?
        let profiles: [ProfileChoice]
        let scan: MoveToHermesScan.Result
        let drafted: Set<String>
        let isRepeat: Bool
    }

    struct Environment {
        var runner = MoveToHermesRunner.Environment()
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
    var screen: Screen {
        if case .progress = phase, case .running(let step)? = runner?.state { return .progress(step) }
        return phase
    }
    private var phase: Screen = .loading
    private(set) var checking = Checking()
    private(set) var review: Review?
    var mapping: [String: MovedWebuiProfile.Destination] = [:]
    private(set) var destinationID: String?
    private(set) var destinationName = ""
    private(set) var runner: MoveToHermesRunner?
    private(set) var snapshot: MoveToHermesRunner.Snapshot?
    private(set) var savedHost: BotConnection?

    @ObservationIgnored private let auth: AuthManager
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var connection: BotConnection?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var checkedPass: (check: RunningCheck, call: @MainActor (MoveToHermesRunner) async -> Void)?

    init(auth: AuthManager, sourceID: String, environment: Environment = Environment()) {
        self.auth = auth
        self.sourceID = sourceID
        self.environment = environment
    }

    var source: ServerAccount? { auth.servers.first { $0.id == sourceID && $0.kind == .webui } }
    var sourceName: String { source.map(Self.name) ?? URL(string: sourceID)?.host ?? sourceID }
    private var sourceURL: URL? { URL(string: sourceID) }

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
            runPass { await $0.resume() }
        case .damaged?: phase = .paused(.damaged)
        case .needsRescan?: phase = .paused(.needsRescan)
        case .unreadable?: phase = .paused(.unreadable)
        case nil: copyMissingChatsAgain()
        }
    }

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

    var hostChoices: [ServerAccount] {
        let store = BotConnectionStore(keychain: auth.keychain)
        let saved = savedHost.map(MoveToHermesRunner.destinationID)
        return auth.servers.filter { server in
            server.kind == .hermes && server.id != saved && URL(string: server.id).flatMap { try? store.load(server: $0) } != nil
        }
    }

    func choose(_ server: ServerAccount) {
        guard let url = URL(string: server.id), let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: url) else {
            return phase = .couldNotStart(.commit(.destinationSignedOut))
        }
        use(saved)
    }

    func useSaved() {
        if let savedHost { use(savedHost) }
    }

    func signedIn(at address: URL) {
        guard let server = auth.servers.first(where: { $0.id == address.absoluteString }) else { return }
        choose(server)
    }

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

    var sourceHeaders: [CustomHeader] {
        [CustomHeader].decodeFromStorage(try? auth.keychain.load(.customHeaders, scope: sourceID))
    }

    private func webuiClient(_ sourceURL: URL) -> (client: APIClient, session: URLSession) {
        APIClient.moveCopyClient(baseURL: sourceURL, headers: sourceHeaders, cookies: environment.runner.cookies(sourceURL),
                                 configuration: environment.runner.webuiConfiguration)
    }

    private func runningChats() async -> Set<String>? {
        guard let sourceURL, source != nil else { return [] }
        let (client, session) = webuiClient(sourceURL)
        defer { session.invalidateAndCancel() }
        guard let listing = try? await client.moveScanSessions() else { return nil }
        return Set(listing.sessions.filter(\.isRunning).map(\.sessionId)).union(environment.liveActivitySessions(sourceURL))
    }

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

    static func initialMapping(profiles: [ProfileChoice], hermesDefault: String?,
                               record: MovedWebuiServer?) -> [String: MovedWebuiProfile.Destination] {
        if let record { return Dictionary(record.profiles.map { ($0.source, $0.destination) }, uniquingKeysWith: { first, _ in first }) }
        return Dictionary(uniqueKeysWithValues: profiles.compactMap { choice in
            (choice.sameName ? choice.source : hermesDefault).map { (choice.source, .hermes(profile: $0)) }
        })
    }

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

    var unchosenProfile: String? { review?.profiles.first { mapping[$0.source] == nil }?.source }

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

    func resume() { runPass(checking: .whenCopyLeft) { await $0.resume() } }

    func retryCheckedPass() {
        guard let checkedPass else { return }
        runPass(checking: checkedPass.check, checkedPass.call)
    }

    func finishEarly() { runPass { await $0.finishEarly() } }

    func done() {
        acknowledge()
        if let destinationID, let destination = auth.servers.first(where: { $0.id == destinationID }) {
            auth.switchActiveServer(to: destination)
        }
    }

    func acknowledge() {
        work?.cancel()
        runner?.acknowledge()
        refreshNotices()
    }

    func moveNext() -> MoveToHermesModel? {
        guard let next = nextSource else { return nil }
        acknowledge()
        let model = MoveToHermesModel(auth: auth, sourceID: next.id, environment: environment)
        model.open(.next)
        return model
    }

    var nextSource: ServerAccount? {
        auth.servers.first { $0.kind == .webui && $0.id != sourceID && auth.moveRecord(forSource: $0.id) == nil }
    }

    func removeSource(modelContext: ModelContext) async {
        guard let source else { return }
        done()
        await MoveToHermesRemoval.remove(source, auth: auth, modelContext: modelContext)
    }

    func copyMissingChatsAgain() {
        guard let destinationID, let url = URL(string: destinationID),
              let saved = try? BotConnectionStore(keychain: auth.keychain).load(server: url) else {
            return phase = .couldNotStart(.commit(.destinationSignedOut))
        }
        connection = saved
        scan()
    }

    func close() {
        if case .progress = phase, let destinationID { environment.notices().noteClosed(source: sourceID, destination: destinationID) }
        work?.cancel()
        work = nil
        refreshNotices()
    }

    func settled() async { await work?.value }

    var destinationAdded: Bool { destinationID.map { id in auth.moveRecord(forSource: sourceID)?.destination.id == id } ?? false }

    var destinationIsSignedIn: Bool {
        guard let destinationID, let url = URL(string: destinationID) else { return false }
        return (try? BotConnectionStore(keychain: auth.keychain).load(server: url)) != nil
    }

    var wasClosed: Bool {
        destinationID.map { environment.notices().wasClosed(source: sourceID, destination: $0) } ?? false
    }

    private enum RunningCheck {
        case never
        case whenCopyLeft
        case always
    }

    private func runPass(checking: RunningCheck = .never, _ call: @escaping @MainActor (MoveToHermesRunner) async -> Void) {
        guard let runner, let destinationID else { return }
        let notices = environment.notices()
        phase = .progress(nil)
        notices.setRunning(true, source: sourceID, destination: destinationID)
        perform { [self] in
            let checks = switch checking {
            case .never: false
            case .always: true
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

    private func perform(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { await body() }
    }

    private func refreshNotices() {
        let notices = environment.notices()
        let auth = auth
        Task { await notices.refresh(auth) }
    }

    static func name(_ server: ServerAccount) -> String {
        server.displayName.isEmpty ? (URL(string: server.urlString)?.host ?? server.urlString) : server.displayName
    }
}

extension MoveToHermesReport {
    var chatsInHermes: Int { copied.count + alreadyThere.count + presentUnconfirmed.count }
    var chatsListed: Int {
        chatsInHermes + sentUnconfirmed.count + notCopied.count + oversized.count + rejected.count
            + unchecked.count + keptOnWebui.count
    }
}

struct MoveToHermesNotice: Equatable {
    enum Stage: Equatable {
        case running
        case paused(canResume: Bool)
        case finished
        case moved
    }

    let sourceID: String
    let destination: ServerAccount
    let stage: Stage
    var inHermes: Int?
    var total: Int?
    var report: MovedWebuiReport?
}

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
    private(set) var running: Set<String> = []
    @ObservationIgnored private var closed: Set<String> = []
    @ObservationIgnored private var refreshes = 0
    @ObservationIgnored private let environment: MoveToHermesRunner.Environment

    init(environment: MoveToHermesRunner.Environment = MoveToHermesRunner.Environment()) {
        self.environment = environment
    }

    private static func key(_ source: String, _ destination: String) -> String { "\(source)\n\(destination)" }

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
        guard generation == refreshes else { return }
        self.moves = moves
    }

    func setRunning(_ isRunning: Bool, source: String, destination: String) {
        if isRunning { running.insert(Self.key(source, destination)) } else { running.remove(Self.key(source, destination)) }
    }

    func noteClosed(source: String, destination: String) { closed.insert(Self.key(source, destination)) }
    func clearClosed(source: String, destination: String) { closed.remove(Self.key(source, destination)) }
    func wasClosed(source: String, destination: String) -> Bool { closed.contains(Self.key(source, destination)) }

    private var chatListsOnScreen: [String: Int] = [:]

    func noteChatList(of serverID: String, onScreen: Bool) {
        let count = (chatListsOnScreen[serverID] ?? 0) + (onScreen ? 1 : -1)
        chatListsOnScreen[serverID] = count > 0 ? count : nil
    }

    func showsChatList(of serverID: String?) -> Bool {
        serverID.map { chatListsOnScreen[$0] != nil } ?? false
    }

    func card(forSource sourceID: String, in servers: [ServerAccount]) -> MoveToHermesNotice? {
        Self.notice(forSource: sourceID, servers: servers, moves: moves, running: running)
    }

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

@MainActor enum MoveToHermesRemoval {
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

    static func storedPairing(_ server: URL) -> PushPairing? { PushRegistrar.shared?.pairing(for: server) }

    private static func unknownCount(_ from: String) -> String {
        String(localized: "Some chats may exist only on \(from). This move couldn’t count them. After removing it, this iPhone can’t open them; they stay on the server.")
    }

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

    static func remove(_ account: ServerAccount, auth: AuthManager, modelContext: ModelContext) async {
        if let url = URL(string: account.urlString) {
            try? CacheStore.clearCache(for: url, in: modelContext)
            await ChatDraftStore.shared.discardDrafts(for: url)
        }
        await auth.removeServer(account)
    }
}
