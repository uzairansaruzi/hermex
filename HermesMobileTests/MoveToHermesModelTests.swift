import SwiftData
import XCTest
import UIKit
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
    private var host: MoveHermesHost!
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
        host = MoveHermesHost()
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
    /// any other starts on the host's default Profile (#1266), which the user can still change.
    func testReviewPreselectsSameNameProfilesAndChangesNothing() async throws {
        host.listed = ["default": ["had"]]
        host.defaultProfile = "research"
        MoveWebuiFixture.rows = [row("had", profile: "default"), row("new", profile: "default"),
                                 row("big", profile: "research", messages: 12_000), row("ops1", profile: "ops")]
        await draftFile.seed([.session(server: webui, sessionID: "new"): ChatDraft(text: "unsent")])
        let model = makeModel()

        model.open(.start)
        await model.settled()

        XCTAssertEqual(model.screen, .review)
        XCTAssertEqual(model.destinationName, "Hermes Home")
        XCTAssertEqual(model.review?.profiles.map(\.source), ["default", "ops", "research"])
        XCTAssertEqual(model.mapping, ["default": .hermes(profile: "default"), "research": .hermes(profile: "research"),
                                       "ops": .hermes(profile: "research")], "An unmatched Profile starts on the host's default")
        XCTAssertNil(model.unchosenProfile)
        XCTAssertEqual(model.counts, .init(present: 1, toCopy: 2, overLimit: 1, unchecked: 0, drafts: 1))

        model.mapping["ops"] = .keepOnWebui
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

    /// R1 and R3 are the host's own sign-in refusals; any other failure shows its advice inline.
    /// A browser sign-in is never refused (#1266): its failure is advice like any other.
    func testRefusalsComeFromTheHostSignInCheck() async throws {
        let cases: [(BotFailure, MoveToHermesModel.Screen?)] = [
            (.unsupported, .refused(.noSignIn)), (.browserSignIn, nil),
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

    /// Without a saved Hermes sign-in, D asks. Its "Sign in to a Hermes host" is the normal
    /// sign-in (#1266), which adds the server without switching to it; the move then scans it
    /// with that server's own sign-in, adopts it at the commit, and only Done switches.
    func testWithoutASavedSignInTheHostIsChosen() async throws {
        try BotConnectionStore(keychain: keychain).remove(server: webui)
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()

        model.open(.start)

        XCTAssertEqual(model.screen, .chooseHost)
        XCTAssertNil(model.savedHost)
        XCTAssertTrue(model.hostChoices.isEmpty)
        let signedIn = BotConnection(id: UUID(), name: "", address: hermes, username: "admin", password: "secret")
        XCTAssertTrue(auth.addHermesServer(signedIn, activating: false))
        XCTAssertEqual(auth.activeServerID, webui.absoluteString, "A sign-in opened from a move never switches servers")
        model.signedIn(at: hermes)
        await model.settled()
        XCTAssertEqual(model.screen, .review)
        XCTAssertEqual(model.review?.connection.id, signedIn.id, "Scanned with the server's own sign-in")
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString), "Nothing is committed at Review")

        model.move()
        await model.settled()

        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        XCTAssertEqual(auth.moveRecord(forSource: webui.absoluteString)?.destination.id, hermes.absoluteString)
        XCTAssertEqual(auth.servers.filter { $0.kind == .hermes }.count, 1, "The signed-in server is adopted, not added again")
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: hermes)?.id, signedIn.id)
        XCTAssertEqual(auth.activeServerID, webui.absoluteString)
        model.done()
        XCTAssertEqual(auth.activeServerID, hermes.absoluteString)
    }

    /// The offer after a sign-in scans the server it names, even where the webui server's Bots
    /// connection names another host; a Bots connection alone skips the host choice as before.
    func testTheOfferScansTheServerJustSignedIn() async throws {
        let other = URL(string: "https://other.example")!
        XCTAssertTrue(auth.addHermesServer(BotConnection(id: UUID(), name: "", address: other, username: "me", password: "pw")))
        let model = makeModel()

        model.open(.offer(destinationID: other.absoluteString))
        await model.settled()

        XCTAssertEqual(model.screen, .review)
        XCTAssertEqual(model.review?.connection.address, other)

        let bots = makeModel()
        bots.open(.start)
        await bots.settled()
        XCTAssertEqual(bots.review?.connection.address, hermes, "The Bots connection still names the host")
    }

    /// Adding a Hermes server offers the first webui server in the list without a move record,
    /// one at a time; a sign-in opened from a move offers nothing.
    func testAHermesSignInOffersTheFirstWebuiServerThatHasntMoved() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        XCTAssertEqual(auth.servers.map(\.id), [webui.absoluteString, studio.absoluteString])
        func signIn(_ host: String, activating: Bool = true) -> BotConnection {
            let connection = BotConnection(id: UUID(), name: "", address: URL(string: "https://\(host)")!, username: "me", password: "pw")
            XCTAssertTrue(auth.addHermesServer(connection, activating: activating))
            return connection
        }
        func moveRecord(_ source: URL, to destination: BotConnection) throws {
            let account = try XCTUnwrap(auth.servers.first { $0.id == source.absoluteString })
            try auth.commitMove(from: account, to: destination,
                                profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "default"))])
        }

        let fromMove = signIn("hermes.example", activating: false)
        XCTAssertNil(auth.moveOffer, "A sign-in opened from a move offers nothing")

        _ = signIn("one.example")
        XCTAssertEqual(auth.moveOffer?.destinationID, "https://one.example")
        XCTAssertEqual(auth.moveOffer?.sourceID, webui.absoluteString, "The first webui server in the list")

        try moveRecord(webui, to: fromMove)
        let two = signIn("two.example")
        XCTAssertEqual(auth.moveOffer?.destinationID, "https://two.example")
        XCTAssertEqual(auth.moveOffer?.sourceID, studio.absoluteString, "A webui server with a move record isn't offered")

        try moveRecord(studio, to: two)
        _ = signIn("three.example")
        XCTAssertNil(auth.moveOffer, "Every webui server has a move record")
    }

    /// The offer holds only while its destination is the signed-in active server and both
    /// servers are still there: switching away, signing out, or removing either one ends it.
    func testTheOfferEndsWhenItsServersChange() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        func signIn(_ host: String) {
            let connection = BotConnection(id: UUID(), name: "", address: URL(string: "https://\(host)")!, username: "me", password: "pw")
            XCTAssertTrue(auth.addHermesServer(connection))
        }
        func account(_ id: String) throws -> ServerAccount { try XCTUnwrap(auth.servers.first { $0.id == id }) }

        signIn("one.example")
        XCTAssertEqual(auth.moveOffer?.destinationID, "https://one.example")
        auth.switchActiveServer(to: try account(studio.absoluteString))
        XCTAssertNil(auth.moveOffer, "Switching away from the destination, as a deep link does")

        signIn("two.example")
        await auth.signOut()
        XCTAssertNil(auth.moveOffer, "Signing out of the destination")

        signIn("three.example")
        XCTAssertEqual(auth.moveOffer?.sourceID, webui.absoluteString)
        await auth.removeServer(try account(webui.absoluteString))
        XCTAssertNil(auth.moveOffer, "Removing the source")

        signIn("four.example")
        XCTAssertEqual(auth.moveOffer?.sourceID, studio.absoluteString)
        await auth.removeServer(try account("https://four.example"))
        XCTAssertNil(auth.moveOffer, "Removing the destination")
    }

    /// Signing in again to a Hermes server already in the list offers the move too, keeping
    /// the server's saved connection; not from a move's own sign-in, or once the webui server
    /// has moved.
    func testSigningInAgainToAHermesServerOffersTheMove() async throws {
        let one = URL(string: "https://one.example")!
        let connection = BotConnection(id: UUID(), name: "", address: one, username: "me", password: "pw")
        XCTAssertTrue(auth.addHermesServer(connection))
        auth.moveOffer = nil
        func signInAgain(offersMove: Bool = true) async throws {
            await auth.signOut()
            XCTAssertEqual(auth.state, .loggedOut(server: one))
            try BotConnectionStore(keychain: keychain).save(connection, server: one)
            auth.hermesSignInSaved(server: one, offersMove: offersMove)
            XCTAssertEqual(auth.state, .loggedIn(server: one))
        }

        try await signInAgain()
        XCTAssertEqual(auth.moveOffer?.destinationID, one.absoluteString)
        XCTAssertEqual(auth.moveOffer?.sourceID, webui.absoluteString)
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: one)?.id, connection.id)

        auth.moveOffer = nil
        try await signInAgain(offersMove: false)
        XCTAssertNil(auth.moveOffer, "A move's own sign-in goes on with that move")

        let account = try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString })
        try auth.commitMove(from: account, to: connection,
                            profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "default"))])
        try await signInAgain()
        XCTAssertNil(auth.moveOffer, "The webui server has a move record")
    }

    // MARK: The one-time question and its banner (#1267)

    /// Each webui server is asked once, one server a launch, and only while it is the active
    /// server. Its second line follows whether it has a Bots connection, and the banner follows
    /// the question.
    func testEachWebuiServerIsAskedOnceAndOneALaunch() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        XCTAssertEqual(auth.activeServerID, studio.absoluteString)
        XCTAssertFalse(auth.showsMoveInvite(for: studio.absoluteString), "No banner before the question")

        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion, MoveToHermesQuestion(sourceID: studio.absoluteString, hasBotsSignIn: false))
        XCTAssertTrue(auth.showsMoveInvite(for: studio.absoluteString))
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString), "The banner is per server")

        auth.moveQuestion = nil
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "One question a launch")
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "Switching servers isn't a launch")
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == studio.absoluteString }))

        relaunch()
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "The other webui server waits for a launch with it active")

        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion, MoveToHermesQuestion(sourceID: webui.absoluteString, hasBotsSignIn: true))
        XCTAssertTrue(auth.showsMoveInvite(for: webui.absoluteString))
        XCTAssertTrue(auth.showsMoveInvite(for: studio.absoluteString))

        relaunch()
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "Every webui server was asked")
    }

    /// The question belongs to its server's screens: it ends when another server becomes active
    /// or its server's sign-in expires, and the server stays asked, with its banner.
    func testTheQuestionEndsWhenItsServerIsNoLongerActive() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion?.sourceID, webui.absoluteString)

        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == studio.absoluteString }))
        XCTAssertNil(auth.moveQuestion, "Not over another server")
        XCTAssertTrue(auth.showsMoveInvite(for: webui.absoluteString))

        relaunch()
        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion?.sourceID, studio.absoluteString)
        auth.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(auth.state, .loggedOut(server: studio))
        XCTAssertNil(auth.moveQuestion, "Not over its sign-in form")
    }

    /// The question shows over its server's chat list only: not while a chat is pushed over it
    /// (iPhone) or its sidebar is hidden (iPad), and once the list is back.
    func testTheQuestionWaitsForItsChatListToBeOnScreen() async throws {
        let notices = MoveToHermesNotices()
        notices.noteChatList(of: webui.absoluteString, onScreen: true)
        notices.noteChatList(of: webui.absoluteString, onScreen: false)
        notices.noteChatList(of: "https://studio.example", onScreen: true)

        await MoveToHermesQuestionTiming.ask(auth, notices: notices, settle: .zero) { [] }
        XCTAssertNil(auth.moveQuestion, "Never over a chat")
        XCTAssertNil(auth.servers.first { $0.id == webui.absoluteString }?.moveToHermesPrompt, "Still unasked")

        notices.noteChatList(of: webui.absoluteString, onScreen: true)
        await MoveToHermesQuestionTiming.ask(auth, notices: notices, settle: .zero) { [] }
        XCTAssertEqual(auth.moveQuestion?.sourceID, webui.absoluteString)
    }

    /// ✕ hides one server's banner for good: across a server switch, an identity edit from an
    /// older copy of the entry, and a relaunch. The other server keeps its banner.
    func testADismissedBannerStaysDismissedForItsServerOnly() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        auth.noteMovePrompt(.asked, forSource: webui.absoluteString)
        auth.noteMovePrompt(.asked, forSource: studio.absoluteString)
        let olderCopy = try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString })

        auth.noteMovePrompt(.dismissed, forSource: webui.absoluteString)
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString))
        XCTAssertTrue(auth.showsMoveInvite(for: studio.absoluteString))

        auth.noteMovePrompt(.asked, forSource: webui.absoluteString)
        auth.updateServerIdentity(olderCopy, displayName: "Home", initials: "H", headerLogoColorHex: HeaderLogoColor.defaultHex)
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString), "Dismissing is permanent")

        relaunch()
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString))
        XCTAssertTrue(auth.showsMoveInvite(for: studio.absoluteString))
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion)
    }

    /// A webui server with a move record, in progress or finished, gets neither the question nor
    /// the invite; its Paused, Finished and Moved banners speak for it (#1225).
    func testAServerWithAMoveRecordIsNeverAskedOrInvited() throws {
        let account = try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString })
        try auth.commitMove(from: account, to: BotConnection(id: UUID(), name: "", address: hermes, username: "admin", password: "secret"),
                            profiles: [MovedWebuiProfile(source: "default", destination: .hermes(profile: "default"))])
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString)?.record.completedAt, "A move in progress")

        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion)
        auth.noteMovePrompt(.asked, forSource: webui.absoluteString)
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString))

        try auth.updateMoveRecord(forSource: webui.absoluteString) { $0.completedAt = .now }
        XCTAssertFalse(auth.showsMoveInvite(for: webui.absoluteString), "A finished move")
        XCTAssertFalse(auth.showsMoveInvite(for: hermes.absoluteString), "A Hermes server is never invited")
    }

    /// The question never stacks on the sign-in offer, and an offer shown this launch takes the
    /// launch's one move sheet. It never shows over a Hermes server or a sign-in form.
    func testTheQuestionWaitsForTheOfferAndASignIn() async throws {
        let one = URL(string: "https://one.example")!
        XCTAssertTrue(auth.addHermesServer(BotConnection(id: UUID(), name: "", address: one, username: "me", password: "pw")))
        XCTAssertNotNil(auth.moveOffer)
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "Never over the offer")
        auth.moveOffer = nil
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "The offer was this launch's move sheet")
        XCTAssertNil(auth.servers.first { $0.id == webui.absoluteString }?.moveToHermesPrompt, "Still unasked")

        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == one.absoluteString }))
        relaunch()
        XCTAssertEqual(auth.state, .loggedIn(server: one))
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "Never over a Hermes server")

        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.handleAPIError(APIError.unauthorized)
        XCTAssertEqual(auth.state, .loggedOut(server: webui))
        auth.askAboutMoveIfDue()
        XCTAssertNil(auth.moveQuestion, "Not over a sign-in form")
        relaunch()
        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion?.sourceID, webui.absoluteString)
    }

    /// Removing a webui server forgets its question and banner with it; added back, it is new.
    func testRemovingAServerForgetsItsQuestion() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        auth.noteMovePrompt(.dismissed, forSource: studio.absoluteString)
        await auth.removeServer(try XCTUnwrap(auth.servers.first { $0.id == studio.absoluteString }))
        auth.noteMovePrompt(.asked, forSource: webui.absoluteString)

        await auth.configure(serverURLString: studio.absoluteString, password: "")
        XCTAssertNil(auth.servers.first { $0.id == studio.absoluteString }?.moveToHermesPrompt)
        relaunch()
        auth.askAboutMoveIfDue()
        XCTAssertEqual(auth.moveQuestion?.sourceID, studio.absoluteString)
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

    /// Remove from the report switches to the destination as Done does, then removes the webui
    /// server; the destination keeps the move record, so old links still route (#1224).
    func testRemovingFromTheReportKeepsTheMoveRecord() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()
        model.move()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        let context = ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        await model.removeSource(modelContext: context)

        XCTAssertEqual(auth.servers.map(\.id), [hermes.absoluteString])
        XCTAssertEqual(auth.activeServerID, hermes.absoluteString)
        let held = try XCTUnwrap(auth.moveRecord(forSource: webui.absoluteString))
        XCTAssertEqual(held.destination.id, hermes.absoluteString)
        XCTAssertNotNil(held.record.completedAt)
        await notices.refresh(auth)
        XCTAssertNil(notices.banner(for: hermes.absoluteString, in: auth.servers), "The report was acknowledged")
    }

    /// Move Next opens at the host step even with a saved Hermes sign-in, which it offers first:
    /// neither server is read until the user picks it.
    func testMoveNextWaitsForAHostBeforeChecking() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        let model = makeModel()

        model.open(.next)
        await model.settled()

        XCTAssertEqual(model.screen, .chooseHost)
        XCTAssertEqual(model.savedHost?.address, hermes)
        XCTAssertEqual(host.connects, 0, "The host isn't signed in to before a pick")
        XCTAssertEqual(MoveWebuiFixture.requests.compactMap { $0.url?.path }, [], "The webui isn't read before a pick")

        model.useSaved()
        await model.settled()

        XCTAssertEqual(model.screen, .review)
        XCTAssertEqual(model.destinationName, "Hermes Home")
        XCTAssertEqual(host.connects, 1)
        XCTAssertEqual(MoveWebuiFixture.requests.compactMap { $0.url?.path }.filter { $0 != "/api/profiles" }, ["/api/sessions"])
    }

    /// Move Next from a finished report acknowledges it without switching servers, then opens the
    /// next webui server at the host step: even with its own saved sign-in, neither server is
    /// read until the user picks a host.
    func testMoveNextAcknowledgesTheReportAndWaitsForAHost() async throws {
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()
        model.move()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        let studio = URL(string: "https://studio.example")!
        try auth.serverRegistry.commit { servers, _ in
            servers.append(ServerAccount(id: studio.absoluteString, urlString: studio.absoluteString, displayName: "Studio",
                                         initials: "ST", headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: .now, updatedAt: .now))
        }
        auth.refreshServers()
        try BotConnectionStore(keychain: keychain).save(
            BotConnection(id: UUID(), name: "Hermes Home", address: hermes, username: "admin", password: "secret", hermesVersion: "0.21.5"),
            server: studio)
        let connects = host.connects
        let requests = MoveWebuiFixture.requests.count

        let next = try XCTUnwrap(model.moveNext())
        await next.settled()

        XCTAssertEqual(next.sourceID, studio.absoluteString)
        XCTAssertEqual(next.screen, .chooseHost)
        XCTAssertEqual(next.savedHost?.address, hermes)
        XCTAssertEqual(host.connects - connects, 0, "The host isn't signed in to before a pick")
        XCTAssertEqual(MoveWebuiFixture.requests.dropFirst(requests).compactMap(\.url), [], "Neither webui is read before a pick")
        XCTAssertEqual(auth.activeServerID, webui.absoluteString, "Move Next never switches servers")
        await notices.refresh(auth)
        XCTAssertNil(notices.banner(for: hermes.absoluteString, in: auth.servers), "The report was acknowledged")
        XCTAssertEqual(notices.banner(for: webui.absoluteString, in: auth.servers)?.stage, .moved)
    }

    /// Move Next inside the one-time question's sheet: the next webui server, without a Bots
    /// connection, signs in the normal way (#1266), which neither switches servers, raises the
    /// offer, nor closes the question's sheet (#1267). Only its Done does, by switching away.
    func testMoveNextFromTheQuestionSignsInWithoutClosingIt() async throws {
        let studio = URL(string: "https://studio.example")!
        await auth.configure(serverURLString: studio.absoluteString, password: "")
        auth.switchActiveServer(to: try XCTUnwrap(auth.servers.first { $0.id == webui.absoluteString }))
        auth.askAboutMoveIfDue()
        let question = try XCTUnwrap(auth.moveQuestion)
        XCTAssertEqual(question.sourceID, webui.absoluteString)
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.start)
        await model.settled()
        model.move()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        XCTAssertEqual(auth.moveQuestion, question, "The commit doesn't close the sheet it runs in")

        let next = try XCTUnwrap(model.moveNext())
        await next.settled()
        XCTAssertEqual(next.sourceID, studio.absoluteString)
        XCTAssertEqual(next.screen, .chooseHost)
        XCTAssertNil(next.savedHost)
        XCTAssertEqual(next.hostChoices.map(\.id), [hermes.absoluteString], "The host just moved to is offered")

        let other = URL(string: "https://other.example")!
        XCTAssertTrue(auth.addHermesServer(BotConnection(id: UUID(), name: "", address: other, username: "me", password: "pw"),
                                           activating: false))
        XCTAssertEqual(auth.activeServerID, webui.absoluteString)
        XCTAssertNil(auth.moveOffer, "Never stacks the offer on the move")
        XCTAssertEqual(auth.moveQuestion, question)
        MoveWebuiFixture.rows = [row("studio", profile: "default")]
        MoveWebuiFixture.exports = ["studio": exportData("studio")]
        next.signedIn(at: other)
        await next.settled()
        XCTAssertEqual(next.screen, .review)
        XCTAssertEqual(next.review?.connection.address, other)
        XCTAssertEqual(next.counts.toCopy, 1)

        next.move()
        await next.settled()
        guard case .finished = next.screen else { return XCTFail("Expected the report, got \(next.screen)") }
        XCTAssertEqual(auth.moveRecord(forSource: studio.absoluteString)?.destination.id, other.absoluteString)
        XCTAssertNil(next.nextSource, "Both webui servers have moved")
        next.done()
        XCTAssertEqual(auth.activeServerID, other.absoluteString)
        XCTAssertNil(auth.moveQuestion, "Done switches away from the question's server, closing its sheet")
        XCTAssertNil(auth.moveOffer)
    }

    /// Remove after a move the sign-in offer started (#1266): the offer's sheet survives the
    /// commit, then Remove ends it with the webui server. The destination keeps its own sign-in
    /// and the move record (#1224, #1265).
    func testRemovingAfterTheOffersMoveKeepsTheDestinationsSignIn() async throws {
        try BotConnectionStore(keychain: keychain).remove(server: webui)
        let signedIn = BotConnection(id: UUID(), name: "", address: hermes, username: "admin", password: "secret")
        XCTAssertTrue(auth.addHermesServer(signedIn))
        let offer = try XCTUnwrap(auth.moveOffer)
        XCTAssertEqual(offer.sourceID, webui.absoluteString)
        MoveWebuiFixture.rows = [row("new", profile: "default")]
        MoveWebuiFixture.exports = ["new": exportData("new")]
        let model = makeModel()
        model.open(.offer(destinationID: offer.destinationID))
        await model.settled()
        XCTAssertEqual(model.review?.connection.id, signedIn.id)
        model.move()
        await model.settled()
        guard case .finished = model.screen else { return XCTFail("Expected the report, got \(model.screen)") }
        XCTAssertEqual(auth.moveOffer, offer, "The commit doesn't close the sheet it runs in")
        let context = ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        await model.removeSource(modelContext: context)

        XCTAssertEqual(auth.servers.map(\.id), [hermes.absoluteString])
        XCTAssertEqual(auth.state, .loggedIn(server: hermes))
        XCTAssertNil(auth.moveOffer, "Its webui server is gone")
        XCTAssertEqual(try BotConnectionStore(keychain: keychain).load(server: hermes)?.id, signedIn.id)
        XCTAssertNotNil(auth.moveRecord(forSource: webui.absoluteString)?.record.completedAt)
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
        XCTAssertTrue(host.imports.allSatisfy { !$0.ids.contains("later") }, "Nothing was sent")
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

    /// A new app launch over the same Keychain: a fresh `AuthManager` and registry.
    private func relaunch() {
        auth = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: CustomHeaderStore(),
            serverRegistry: ServerRegistry(keychain: keychain, identityDefaults: .ephemeral()),
            hermesConnections: HermesConnections(),
            preferences: .ephemeral(),
            forgetPush: { _ in }
        )
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
