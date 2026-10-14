import XCTest
@testable import HermesMobile

/// The guided Move to Hermes sheet's model (#1218): Review reads and changes nothing, refusals
/// come from the host's own sign-in check and the webui's running chats, the pairing is read only
/// after Move, closing pauses, Done switches servers only after acknowledging, and the banners
/// and removal copy say what stays behind without claiming more than the move knows.
@MainActor
final class MoveToHermesModelTests: XCTestCase {
    private let webui = URL(string: "https://webui.example")!
    private let hermes = URL(string: "https://hermes.example")!
    private var root: URL!
    private var keychain: InMemoryKeychainStore!
    private var auth: AuthManager!
    private var host: ModelHermes!
    private var drafts: ChatDraftStore!
    private var draftFile: ModelDrafts!
    private var pairingReads = 0
    private var liveActivities: Set<String> = []
    private var notices: MoveToHermesNotices!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("move-model-\(UUID().uuidString)", isDirectory: true)
        keychain = InMemoryKeychainStore()
        let preferences = UserDefaults.ephemeral()
        try keychain.save(webui.absoluteString, forKey: .serverURL)
        auth = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: CustomHeaderStore(),
            serverRegistry: ServerRegistry(keychain: keychain, identityDefaults: .ephemeral()),
            hermesConnections: HermesConnections(),
            preferences: preferences,
            forgetPush: { _ in }
        )
        host = ModelHermes()
        draftFile = ModelDrafts()
        drafts = ChatDraftStore(persistence: draftFile)
        pairingReads = 0
        liveActivities = []
        notices = MoveToHermesNotices(environment: runnerEnvironment())
        MoveWebuiFixture.reset()
        try BotConnectionStore(keychain: keychain).save(
            BotConnection(id: UUID(), name: "Hermes Home", address: hermes, username: "admin", password: "secret", hermesVersion: "0.21.5"),
            server: webui)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        MoveWebuiFixture.reset()
    }

    // MARK: Review

    /// The scan reads both servers and changes nothing. A same-name Profile is preselected and
    /// any other waits for a choice; Move stays off until every Profile has one.
    func testReviewPreselectsSameNameProfilesAndChangesNothing() async throws {
        host.listed = ["default": ["had"]]
        MoveWebuiFixture.rows = [row("had", profile: "default"), row("new", profile: "default"),
                                 row("big", profile: "research", messages: 12_000), row("ops1", profile: "ops")]
        await draftFile.seed([.session(server: webui, sessionID: "new"): ChatDraft(text: "unsent")])
        let model = makeModel()

        model.open(.start)
        await model.settled()

        XCTAssertEqual(model.screen, .review)
        XCTAssertEqual(model.destinationName, "Hermes Home")
        XCTAssertEqual(model.review?.profiles.map(\.source), ["default", "ops", "research"])
        XCTAssertEqual(model.mapping, ["default": .hermes(profile: "default"), "research": .hermes(profile: "research")])
        XCTAssertEqual(model.unchosenProfile, "ops", "An unmatched Profile is never defaulted")
        XCTAssertEqual(model.counts, .init(present: 1, toCopy: 1, overLimit: 1, unchecked: 0, drafts: 1))

        model.mapping["ops"] = .keepOnWebui
        XCTAssertNil(model.unchosenProfile)
        XCTAssertEqual(model.counts.toCopy, 1, "A kept Profile's chats aren't copied")

        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString), "Nothing is committed at Review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "No journal before Move")
        XCTAssertEqual(pairingReads, 0, "The pairing is never read before Move")
        XCTAssertTrue(host.imports.isEmpty)
        XCTAssertEqual(MoveWebuiFixture.requests.compactMap { $0.url?.path }.filter { $0 != "/api/profiles" }, ["/api/sessions"],
                       "The scan never switches the webui Profile")
        XCTAssertTrue(auth.servers.allSatisfy { $0.kind == .webui })
    }

    /// Chats Hermes didn't answer about are counted apart from those to copy.
    func testUncheckedChatsAreCountedApart() async throws {
        host.failingReads = ["flaky"]
        MoveWebuiFixture.rows = [row("flaky", profile: "default"), row("new", profile: "default")]
        let model = makeModel()

        model.open(.start)
        await model.settled()

        XCTAssertEqual(model.counts, .init(present: 0, toCopy: 1, overLimit: 0, unchecked: 1, drafts: 0))
    }

    /// R1 to R3 are the host's own sign-in refusals; any other failure shows its advice inline.
    func testRefusalsComeFromTheHostSignInCheck() async throws {
        let cases: [(BotFailure, MoveToHermesModel.Screen?)] = [
            (.unsupported, .refused(.noSignIn)), (.browserSignIn, .refused(.singleSignOn)),
            (.outdated("0.20.9"), .refused(.outdated("0.20.9"))), (.rejected(401), nil)
        ]
        for (failure, expected) in cases {
            host.connectFailure = failure
            let model = makeModel()
            model.open(.start)
            await model.settled()
            if let expected {
                XCTAssertEqual(model.screen, expected, "\(failure)")
            } else {
                XCTAssertEqual(model.screen, .checking)
                XCTAssertEqual(model.checking.hostError, BotConnectionAdvice.message(for: failure, address: hermes))
            }
        }
        XCTAssertTrue(MoveWebuiFixture.requests.isEmpty, "A refused host stops before the webui is read")
    }

    /// R4: chats the webui is streaming, by either field the session list reads, and this
    /// iPhone's running Live Activities for it. A running CLI session the webui shows isn't one.
    func testRunningChatsRefuseTheMove() async throws {
        var stream = row("streamID", profile: "default")
        stream["active_stream_id"] = .string("s1")
        var cli = row("cli", profile: "default", streaming: true)
        cli["is_cli_session"] = .bool(true)
        MoveWebuiFixture.rows = [row("busy", profile: "default", streaming: true), stream, cli, row("idle", profile: "default")]
        liveActivities = ["other"]
        let model = makeModel()

        model.open(.start)
        await model.settled()

        XCTAssertEqual(model.screen, .refused(.running(3)))
    }

    /// A chat that starts running while Review is open stops Move before the commit.
    func testMoveChecksRunningChatsAgainBeforeSending() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()
        XCTAssertEqual(model.screen, .review)
        MoveWebuiFixture.rows = [row("new", profile: "default", streaming: true)]

        model.move()
        await model.settled()

        XCTAssertEqual(model.screen, .refused(.running(1)))
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString), "Nothing is committed")
        XCTAssertTrue(host.imports.isEmpty)
        XCTAssertEqual(pairingReads, 0)
        XCTAssertTrue(notices.running.isEmpty)

        // A list that can't be read is unknown, never "nothing running".
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.listingFailure = 503
        model.retryCheckedPass()
        await model.settled()
        XCTAssertEqual(model.screen, .refused(.sourceUnreadable))
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString))

        MoveWebuiFixture.listingFailure = nil
        model.retryCheckedPass()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Try Again runs the same pass, got \(model.screen)") }
    }

    /// Without a saved Hermes sign-in, D asks; a signed-in Hermes server is offered, never matched silently.
    func testWithoutASavedSignInTheHostIsChosen() async throws {
        try BotConnectionStore(keychain: keychain).remove(server: webui)
        let model = makeModel()

        model.open(.start)

        XCTAssertEqual(model.screen, .chooseHost)
        XCTAssertTrue(model.hostChoices.isEmpty)
        model.useVerified(BotConnection(id: UUID(), name: "", address: hermes, username: "admin", password: "secret"))
        await model.settled()
        XCTAssertEqual(model.screen, .review)
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString), "A verified sign-in is saved only by the commit")
        XCTAssertNil(try BotConnectionStore(keychain: keychain).load(server: hermes))
    }

    /// Closing during the scan cancels it: nothing is committed and no Review appears.
    func testClosingBeforeMoveChangesNothing() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        let model = makeModel()

        model.open(.start)
        model.close()
        await model.settled()

        XCTAssertNil(model.review)
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(pairingReads, 0)
    }

    // MARK: Moving

    /// Move runs the landed runner: the pairing read comes after the commit, the report waits
    /// for Done, and only Done switches to the destination, after acknowledging.
    func testMoveFinishesAndOnlyDoneSwitchesToTheDestination() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()

        model.move()
        await model.settled()

        guard case .finished(let report) = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        XCTAssertEqual(report.copied, ["new"])
        XCTAssertEqual(pairingReads, 1, "Read once, after the commit")
        XCTAssertEqual(auth.activeServerID, webui.absoluteString, "Finishing never switches servers")
        await notices.refresh(auth)
        XCTAssertEqual(notices.banner(for: hermes.absoluteString, in: auth.servers)?.stage, .finished,
                       "The report waits for Done on the destination too")

        model.done()

        XCTAssertEqual(auth.activeServerID, hermes.absoluteString)
        await notices.refresh(auth)
        XCTAssertNil(notices.banner(for: hermes.absoluteString, in: auth.servers))
        XCTAssertEqual(notices.banner(for: webui.absoluteString, in: auth.servers)?.stage, .moved)
    }

    /// Copy Missing Chats Again keeps the finished report until Move starts the next pass: a
    /// scan that can't read the webui leaves the report to reopen, and the next pass replaces it.
    func testCopyMissingChatsAgainKeepsTheReportUntilMove() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()
        model.move()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }

        MoveWebuiFixture.listingFailure = 503
        model.copyMissingChatsAgain()
        await model.settled()
        XCTAssertNotEqual(model.screen, .review)

        let reopened = makeModel()
        reopened.open(.details)
        await reopened.settled()
        guard case .finished(let kept) = reopened.screen else { return XCTFail("The report was lost, got \(reopened.screen)") }
        XCTAssertEqual(kept.copied, ["new"])

        MoveWebuiFixture.listingFailure = nil
        MoveWebuiFixture.rows.append(row("later", profile: "default"))
        MoveWebuiFixture.exports["later"] = exportData("later")
        reopened.copyMissingChatsAgain()
        await reopened.settled()
        XCTAssertEqual(reopened.screen, .review)

        // A chat that starts running while this Review is open stops Move, though the old
        // journal has nothing left to copy, and the report is still there.
        MoveWebuiFixture.rows = [row("new", profile: "default"), row("later", profile: "default", streaming: true)]
        reopened.move()
        await reopened.settled()
        XCTAssertEqual(reopened.screen, .refused(.running(1)))
        XCTAssertTrue(host.imports.allSatisfy { !$0.contains("later") }, "Nothing was sent")
        let again = makeModel()
        again.open(.details)
        await again.settled()
        guard case .finished = again.screen else { return XCTFail("The report was lost, got \(again.screen)") }

        MoveWebuiFixture.rows = [row("new", profile: "default"), row("later", profile: "default")]
        reopened.retryCheckedPass()
        await reopened.settled()
        guard case .finished(let next) = reopened.screen else { return XCTFail("Expected the next report, got \(reopened.screen)") }
        XCTAssertEqual(next.copied, ["later"])
    }

    /// Closing mid-move pauses it; the paused details show its counts and that it was closed,
    /// and Resume finishes it.
    func testClosingPausesAndResumeFinishes() async throws {
        MoveWebuiFixture.rows = [row("a", profile: "default"), row("b", profile: "default")]
        MoveWebuiFixture.exports = ["a": exportData("a"), "b": exportData("b")]
        var model = makeModel()
        model.open(.start)
        await model.settled()
        var closed = false
        host.onImport = {
            guard !closed else { return }
            closed = true
            model.close()
        }

        model.move()
        await model.settled()
        host.onImport = nil

        XCTAssertNotNil(auth.moveRecord(forSource: webui.absoluteString), "Closing after the commit keeps the move")
        await notices.refresh(auth)
        XCTAssertEqual(notices.card(forSource: webui.absoluteString, in: auth.servers)?.stage, .paused(canResume: true))
        XCTAssertEqual(notices.banner(for: hermes.absoluteString, in: auth.servers)?.stage, .paused(canResume: true),
                       "The destination shows the paused move too")

        model = makeModel()
        model.open(.details)
        await model.settled()
        XCTAssertEqual(model.screen, .paused(.workLeft))
        XCTAssertTrue(model.wasClosed)
        XCTAssertEqual(model.snapshot?.total, 2)
        XCTAssertEqual(model.snapshot?.unplanned, 2, "Copied chats whose titles, pins, folders and drafts wait for Resume")
        XCTAssertEqual(model.snapshot?.copyLeft, 0)
        // With nothing left to copy, Resume finishes on Hermes even while the webui is unreachable.
        MoveWebuiFixture.listingFailure = 503

        model.resume()
        await model.settled()
        guard case .finished(let report) = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        XCTAssertEqual(report.chatsInHermes, 2)
        XCTAssertFalse(model.wasClosed)
    }

    // MARK: Notices

    func testBannersShowOnTheRightServers() {
        let source = ServerAccount(id: webui.absoluteString, urlString: webui.absoluteString, displayName: "Home Mac", initials: "HM",
                                   headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now)
        let other = ServerAccount(id: "https://work.example", urlString: "https://work.example", displayName: "Work", initials: "W",
                                  headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now)
        let destination = ServerAccount(id: hermes.absoluteString, urlString: hermes.absoluteString, displayName: "Hermes Home",
                                        initials: "HH", headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now,
                                        kind: .hermes, movedWebuiServers: [MovedWebuiServer(sourceServerID: source.id, profiles: [])])
        let servers = [source, other, destination]
        func banner(_ server: ServerAccount, _ moves: [MoveToHermesNotices.Move], running: Set<String> = []) -> MoveToHermesNotice.Stage? {
            MoveToHermesNotices.banner(for: server.id, servers: servers, moves: moves, running: running)?.stage
        }
        let paused = [MoveToHermesNotices.Move(sourceID: source.id, destinationID: destination.id, status: .unfinished)]
        let damaged = [MoveToHermesNotices.Move(sourceID: source.id, destinationID: destination.id, status: .damaged)]
        let finished = [MoveToHermesNotices.Move(sourceID: source.id, destinationID: destination.id, status: .finished(MoveToHermesReport()))]

        XCTAssertEqual(banner(source, []), .moved)
        XCTAssertNil(banner(destination, []), "A complete move shows only on the webui server")
        XCTAssertNil(banner(other, []))
        XCTAssertEqual(banner(source, paused), .paused(canResume: true))
        XCTAssertEqual(banner(destination, paused), .paused(canResume: true))
        XCTAssertEqual(banner(destination, damaged), .paused(canResume: false))
        XCTAssertEqual(banner(source, finished), .finished)
        XCTAssertEqual(banner(destination, finished), .finished)
        XCTAssertNil(banner(source, paused, running: ["\(source.id)\n\(destination.id)"]), "A running move's sheet is up")
        XCTAssertEqual(MoveToHermesNotices.notice(forSource: source.id, servers: servers, moves: paused,
                                                  running: ["\(source.id)\n\(destination.id)"])?.stage, .running)
    }

    // MARK: Removal

    /// S2: what may stay only on the webui server, and the routes that keep working. Notifications
    /// keep opening only for a shared install. No draft warning.
    func testRemovingTheSourceCountsWhatStaysBehind() {
        let pairing = { (key: String) in PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: key, previewKey: "k") }
        let report = MovedWebuiReport(remaining: 6, unchecked: 1, oversized: 1, kept: 5, recordedAt: .now)
        let (source, servers) = moved(report: report)

        let shared = MoveToHermesRemoval.message(for: source, servers: servers) { _ in pairing("same") } ?? ""
        XCTAssertTrue(shared.contains("7 chats may exist only on Home Mac: 1 too large to copy, 1 that couldn’t be checked, and 5 in “ops”, which you kept there."), shared)
        XCTAssertTrue(shared.contains("Old links, Shortcuts and notifications for chats that moved keep opening in Hermes Home."))

        let crossHost = MoveToHermesRemoval.message(for: source, servers: servers) { pairing($0.host == "webui.example" ? "a" : "b") } ?? ""
        XCTAssertTrue(crossHost.contains("Old links and Shortcuts for chats that moved keep opening in Hermes Home."))
        XCTAssertTrue(crossHost.contains("Home Mac is a different host, so its notifications stop."))

        let unpairedDestination = MoveToHermesRemoval.message(for: source, servers: servers) { $0.host == "webui.example" ? pairing("a") : nil } ?? ""
        XCTAssertTrue(unpairedDestination.contains("Home Mac’s notifications stop with it."))
        XCTAssertFalse(unpairedDestination.contains("different host"), "Not claimed without both installs")

        let unpaired = MoveToHermesRemoval.message(for: source, servers: servers) { _ in nil } ?? ""
        XCTAssertFalse(unpaired.contains("notifications"), "No notification promise without a pairing")

        for message in [shared, crossHost, unpairedDestination, unpaired] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("draft"), "Removal never warns about drafts")
        }
    }

    func testRemovalNeverTurnsAnUnknownCountIntoZero() {
        let unknown = MoveToHermesRemoval.message(for: moved(report: nil).source, servers: moved(report: nil).servers) { _ in nil } ?? ""
        XCTAssertTrue(unknown.contains("This move couldn’t count them."))

        let partial = moved(report: MovedWebuiReport(remaining: nil, unchecked: 0, oversized: 0, recordedAt: .now))
        XCTAssertTrue((MoveToHermesRemoval.message(for: partial.source, servers: partial.servers) { _ in nil } ?? "").contains("couldn’t count"))

        let none = moved(report: MovedWebuiReport(remaining: 0, unchecked: 0, oversized: 0, kept: 0, recordedAt: .now))
        XCTAssertTrue((MoveToHermesRemoval.message(for: none.source, servers: none.servers) { _ in nil } ?? "").contains("Every chat from Home Mac is in Hermes Home."))

        let one = moved(report: MovedWebuiReport(remaining: 1, unchecked: 0, oversized: 0, kept: 0, recordedAt: .now))
        XCTAssertTrue((MoveToHermesRemoval.message(for: one.source, servers: one.servers) { _ in nil } ?? "")
            .contains("1 chat may exist only on Home Mac: 1 not copied."), "One chat reads in the singular")

        let unfinished = moved(report: MovedWebuiReport(remaining: 11, unchecked: 2, oversized: 0, kept: 0, recordedAt: .now), completed: false)
        let message = MoveToHermesRemoval.message(for: unfinished.source, servers: unfinished.servers) { _ in nil } ?? ""
        XCTAssertTrue(message.contains("The move to Hermes Home hasn’t finished. At the last count, 11 chats were only on Home Mac. 2 more couldn’t be checked."), message)
    }

    /// S3: removing the destination ends its redirects; a server no move involves keeps today's copy.
    func testRemovingTheDestinationEndsItsRedirects() {
        let (source, servers) = moved(report: nil)
        let destination = servers.first { $0.kind == .hermes }!
        XCTAssertEqual(MoveToHermesRemoval.message(for: destination, servers: servers) { _ in nil },
                       "Old links, Shortcuts and notifications for Home Mac, which moved here, stop opening. Home Mac returns to normal if it’s still configured.")
        var unmoved = source
        unmoved.movedWebuiServers = []
        XCTAssertNil(MoveToHermesRemoval.message(for: unmoved, servers: [unmoved]) { _ in nil })
    }

    /// The record keeps the kept-chat count for S2, unknown after a partial scan, and reads
    /// records saved before it existed.
    func testTheRecordKeepsTheKeptCount() throws {
        var report = MoveToHermesReport()
        report.keptOnWebui = ["a", "b"]
        report.notCopied = ["c"]
        XCTAssertEqual(report.summary(at: .now).kept, 2)
        XCTAssertEqual(report.summary(at: .now).remaining, 3)
        report.partialScan = true
        XCTAssertNil(report.summary(at: .now).kept)

        let old = try JSONDecoder().decode(MovedWebuiReport.self, from: Data(#"{"remaining":1,"recordedAt":0}"#.utf8))
        XCTAssertNil(old.kept)
    }

    // MARK: Helpers

    private func runnerEnvironment() -> MoveToHermesRunner.Environment {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoveWebuiFixture.self]
        var environment = MoveToHermesRunner.Environment()
        environment.root = root
        environment.destination = { [unowned self] _ in
            MoveToHermesDestination(transport: host, readPairing: { [unowned self] in
                pairingReads += 1
                return PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: String(repeating: "a", count: 64), previewKey: "k")
            }, close: {})
        }
        environment.webuiConfiguration = configuration
        environment.cookies = { _ in [] }
        environment.registrar = { ModelRegistrar() }
        environment.drafts = { [unowned self] in drafts }
        return environment
    }

    private func makeModel() -> MoveToHermesModel {
        var environment = MoveToHermesModel.Environment()
        environment.runner = runnerEnvironment()
        environment.liveActivitySessions = { [unowned self] _ in liveActivities }
        environment.notices = { [unowned self] in notices }
        return MoveToHermesModel(auth: auth, sourceID: webui.absoluteString, environment: environment)
    }

    private func row(_ id: String, profile: String, messages: Int? = nil, streaming: Bool = false) -> [String: BotJSON] {
        var row: [String: BotJSON] = ["session_id": .string(id), "profile": .string(profile), "title": .string(id.capitalized)]
        if let messages { row["message_count"] = .number(Double(messages)) }
        if streaming { row["is_streaming"] = .bool(true) }
        return row
    }

    private func exportData(_ id: String) -> Data {
        let export = BotJSON.object(["session_id": .string(id), "messages": .array([
            .object(["role": .string("user"), "content": .string("hi")]),
        ])])
        return (try? JSONEncoder().encode(export)) ?? Data()
    }

    /// A webui server "Home Mac" moved to the Hermes server "Hermes Home", keeping "ops".
    private func moved(report: MovedWebuiReport?, completed: Bool = true) -> (source: ServerAccount, servers: [ServerAccount]) {
        let source = ServerAccount(id: webui.absoluteString, urlString: webui.absoluteString, displayName: "Home Mac", initials: "HM",
                                   headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now)
        let record = MovedWebuiServer(sourceServerID: source.id,
                                      profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "default")),
                                                 MovedWebuiProfile(source: "ops", destination: .keepOnWebui)],
                                      completedAt: completed ? .now : nil, report: report)
        let destination = ServerAccount(id: hermes.absoluteString, urlString: hermes.absoluteString, displayName: "Hermes Home",
                                        initials: "HH", headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now,
                                        kind: .hermes, movedWebuiServers: [record])
        return (source, [source, destination])
    }
}

/// A Hermes host for the scan and the move: Profiles, listings, exact reads, imports and writes.
@MainActor private final class ModelHermes: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var profiles = ["default", "research"]
    var connectFailure: BotFailure?
    /// Ids each Profile's listing shows.
    var listed: [String: [String]] = [:]
    var failingReads: Set<String> = []
    var rows: [String: [String: BotJSON]] = [:]
    /// Runs as each import arrives, before it is answered.
    var onImport: (() -> Void)?
    private(set) var imports: [[String]] = []

    func connect() async throws {
        if let connectFailure { throw connectFailure }
    }

    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        switch call {
        case .profilesList: return .object(["profiles": .array(profiles.map { .object(["name": .string($0)]) })])
        case .sessionWorkspaceMove(let profile, let key, let cwd):
            rows["\(profile)|\(key)"]?["cwd"] = .string(cwd)
            return .object(["cwd": .string(cwd)])
        default: throw BotFailure.unsupported
        }
    }

    func sessionScanPage(profile: String, offset: Int) async throws -> HermesScanPage {
        let ids = listed[profile] ?? []
        return HermesScanPage(ids: Array(ids.dropFirst(offset)), total: ids.count)
    }

    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        if failingReads.contains(key) { throw BotFailure.transport }
        if listed[profile]?.contains(key) == true, rows["\(profile)|\(key)"] == nil { return .object(["id": .string(key)]) }
        return rows["\(profile)|\(key)"].map(BotJSON.object)
    }

    func importSessions(body: Data) async throws -> BotJSON {
        onImport?()
        let request = try JSONDecoder().decode(BotJSON.self, from: body)
        let profile = request["profile"].text ?? ""
        let ids = request["sessions"].list?.compactMap { $0["id"].text } ?? []
        imports.append(ids)
        let skipped = ids.filter { rows["\(profile)|\($0)"] != nil }
        let imported = ids.filter { !skipped.contains($0) }
        for id in imported { rows["\(profile)|\(id)"] = ["id": .string(id), "pinned": .bool(false)] }
        return .object(["imported_ids": .array(imported.map(BotJSON.string)), "skipped_ids": .array(skipped.map(BotJSON.string))])
    }

    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        if case .title(let title) = change {
            rows["\(profile)|\(key)"]?["title"] = .string(title)
            return title
        }
        if case .pinned(let pinned) = change { rows["\(profile)|\(key)"]?["pinned"] = .bool(pinned) }
        return nil
    }
}

/// The webui server is paired, so the carry reads the host once after the commit.
@MainActor private final class ModelRegistrar: PushPairingCopying {
    func pairing(for server: URL) -> PushPairing? {
        guard server.host == "webui.example" else { return nil }
        return PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: String(repeating: "a", count: 64), previewKey: "k")
    }
    func copyPairing(from source: URL, to destination: URL, matching install: PushPairing,
                     isConfigured: @escaping @MainActor (URL) -> Bool) async throws -> MovePushPairingOutcome { .copied }
}

private actor ModelDrafts: ChatDraftPersisting {
    private var values: [ChatDraftKey: ChatDraft] = [:]
    func seed(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) throws { values = drafts }
}
