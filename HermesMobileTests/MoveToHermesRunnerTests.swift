import XCTest
@testable import HermesMobile

/// Move to Hermes's runner and journal (#1216): nothing before the commit, intents on disk before
/// sending, import-only replay, report-only settling, presence apart from copying, a durable
/// final report, and conservative reading of a torn, damaged or unreadable journal.
@MainActor
final class MoveToHermesRunnerTests: XCTestCase {
    private let webui = URL(string: "https://webui.example")!
    private let hermes = URL(string: "https://hermes.example")!
    private let connectionID = UUID()
    private var root: URL!
    private var keychain: FailingKeychain!
    private var auth: AuthManager!
    private var host: MoveHermesHost!
    private var drafts: RunnerDrafts!
    private var registrar: RunnerRegistrar!
    /// Writes the next run's journal refuses, as a full disk or a crash at that point would.
    private var failingWrite: ((MoveToHermesJournal.Write) -> Bool)?
    /// Runs inside `removeServer`'s push teardown: after its drafts are discarded, before its entry goes.
    private var duringRemoval: (@MainActor () async -> Void)?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        keychain = FailingKeychain()
        let preferences = UserDefaults.ephemeral()
        try keychain.save(webui.absoluteString, forKey: .serverURL)
        auth = AuthManager(
            keychain: keychain,
            clientFactory: { _ in MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false)) },
            headerStore: CustomHeaderStore(),
            serverRegistry: ServerRegistry(keychain: keychain, identityDefaults: .ephemeral()),
            hermesConnections: HermesConnections(),
            preferences: preferences,
            forgetPush: { [unowned self] _ in await self.duringRemoval?() }
        )
        host = MoveHermesHost()
        drafts = RunnerDrafts()
        registrar = RunnerRegistrar()
        failingWrite = nil
        MoveWebuiFixture.reset()
    }

    override func tearDown() async throws {
        // The removal test runs on the app's own journal folder; delete only its move there.
        try? FileManager.default.removeItem(at: root == MoveToHermesJournal.defaultRoot ? folder : root)
        MoveWebuiFixture.reset()
    }

    // MARK: Start and commit

    func testAFirstMoveCopiesFillsMovesDraftsAndFinishes() async throws {
        let entries = [entry("new", title: "Trip plan", pinned: true, workspace: "/srv/trip"), entry("had", location: .present(profile: "default"))]
        host.rows["default|had"] = ["id": .string("had"), "title": .string("Mine")]
        exports("new")
        await drafts.seed([sourceDraft("new"): ChatDraft(text: "unsent")])
        let runner = makeRunner()

        await runner.start(review(entries))

        guard case .finished(let report) = runner.state else { return XCTFail("Expected finished, got \(runner.state)") }
        XCTAssertEqual(report.copied, ["new"])
        XCTAssertEqual(report.alreadyThere, ["had"])
        XCTAssertEqual(report.changesApplied, 3)
        XCTAssertEqual(report.draftsMoved, 1)
        XCTAssertEqual(host.rows["default|new"]?["title"], .string("Trip plan"))
        XCTAssertEqual(host.rows["default|new"]?["pinned"], .bool(true))
        XCTAssertEqual(host.rows["default|had"]?["title"], .string("Mine"), "A chat Hermes had keeps its title")
        let saved = await drafts.values
        XCTAssertEqual(saved[hermesDraft("new")]?.text, "unsent")
        XCTAssertNil(saved[sourceDraft("new")])
        let record = try XCTUnwrap(auth.moveRecord(forSource: webui.absoluteString)?.record)
        XCTAssertNotNil(record.completedAt)
        XCTAssertEqual(record.report?.remaining, 0)
        XCTAssertEqual(record.report?.unchecked, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "The report waits for Done")

        runner.acknowledge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(runner.state, .idle)
    }

    func testCancellingOrFailingBeforeTheCommitLeavesNothing() async throws {
        let cancelled = makeRunner()
        let task = Task { await cancelled.start(review([entry("a")])) }
        task.cancel()
        await task.value
        XCTAssertEqual(cancelled.state, .idle)

        failingWrite = { $0 == .plan }
        let unwritten = makeRunner()
        await unwritten.start(review([entry("a")]))
        XCTAssertEqual(unwritten.state, .notStarted(.journal))

        failingWrite = nil
        keychain.failingKeys = [.servers]
        let uncommitted = makeRunner()
        await uncommitted.start(review([entry("a")]))
        XCTAssertEqual(uncommitted.state, .notStarted(.commit(.saveFailed)))

        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(registrar.reads, 0, "No pairing read before the commit")
        XCTAssertTrue(host.imports.isEmpty)
        XCTAssertTrue(MoveWebuiFixture.requests.isEmpty)
    }

    func testThePairingCarryIsTheFirstStepAfterTheCommit() async throws {
        registrar.sourcePaired = true
        registrar.onRead = { [unowned self] in
            XCTAssertNotNil(self.auth.moveRecord(forSource: self.webui.absoluteString), "Read only after the commit")
            XCTAssertTrue(self.host.imports.isEmpty, "Read before anything is copied")
        }
        exports("a")

        await makeRunner().start(review([entry("a")]))

        XCTAssertEqual(registrar.reads, 1)
        XCTAssertEqual(journalEvents().first, .pairing(.copied))
    }

    // MARK: Imports

    /// The import landed but its reply was lost. The replay resends only the import, the host
    /// skips the id, and the report says Hermes has it without claiming this move copied it.
    func testALostImportReplyIsReplayedAndReportedAsPresentNotCopied() async throws {
        host.loseNextImportReply = true
        exports("a")
        let runner = makeRunner()
        await runner.start(review([entry("a", title: "Trip", pinned: true)]))
        XCTAssertEqual(runner.state, .paused(.workLeft))
        XCTAssertNil(host.rows["default|a"]?["title"] ?? nil, "Nothing is reconciled while the copy is unconfirmed")

        let resumed = makeRunner()
        await resumed.resume()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(report.presentUnconfirmed, ["a"])
        XCTAssertEqual(report.copied, [])
        XCTAssertEqual(host.imports.map(\.profile), ["default"], "The host saw one import; the replay's recheck found the chat")
        XCTAssertEqual(host.rows["default|a"]?["title"], .string("Trip"), "An empty title is still filled")
        XCTAssertNotEqual(host.rows["default|a"]?["pinned"], .bool(true), "No pin without a confirmed copy")
    }

    /// Documented limit: a chat whose unconfirmed import landed and was then deleted in Hermes
    /// during the pause is imported again by the replay, and the reply confirms that copy.
    func testAReplayRecreatesAChatDeletedDuringThePause() async throws {
        host.loseNextImportReply = true
        exports("a")
        await makeRunner().start(review([entry("a")]))
        host.rows["default|a"] = nil

        let resumed = makeRunner()
        await resumed.resume()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(report.copied, ["a"])
        XCTAssertEqual(host.imports.map(\.ids), [["a"], ["a"]])
        XCTAssertEqual(host.imports.map(\.profile), ["default", "default"], "The replay goes to the frozen Profile")
    }

    /// The import's reply arrived but its outcome line never reached disk. The next attempt
    /// can't tell that send from any other, so the chat is present or sent, never copied.
    func testALostCopyOutcomeKeepsTheEarlierSendUnconfirmed() async throws {
        exports("a", "b")
        failingWrite = { if case .event(.copied) = $0 { true } else { false } }
        await makeRunner().start(review([entry("a", pinned: true), entry("b")]))
        XCTAssertEqual(Set(host.imports.flatMap(\.ids)), ["a", "b"])
        failingWrite = nil
        // b's retry can't even export, so nothing says whether the first send landed.
        MoveWebuiFixture.exports["b"] = nil
        host.rows["default|b"] = nil

        let resumed = makeRunner()
        await resumed.resume()
        XCTAssertEqual(resumed.state, .paused(.workLeft))
        await resumed.finishEarly()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(report.presentUnconfirmed, ["a"])
        XCTAssertEqual(report.sentUnconfirmed, ["b"])
        XCTAssertEqual(report.notCopied, [])
        XCTAssertNotEqual(host.rows["default|a"]?["pinned"], .bool(true))
        XCTAssertEqual(auth.moveRecord(forSource: webui.absoluteString)?.record.report?.remaining, 0)
    }

    func testAnImportIntentThatIsNotSavedSendsNothing() async throws {
        exports("a")
        failingWrite = { if case .event(.importing) = $0 { true } else { false } }
        let runner = makeRunner()

        await runner.start(review([entry("a")]))

        XCTAssertEqual(runner.state, .paused(.saveFailed))
        XCTAssertTrue(host.imports.isEmpty)
        guard case .copied(let outcomes, _)? = journalEvents().last else { return XCTFail("The copy's outcome is logged") }
        XCTAssertEqual(outcomes, ["a": .notSent])
    }

    // MARK: Metadata

    /// A write landed, its outcome line never made it to disk, and the user changed the field
    /// in Hermes during the pause. Resume reads it and reports it unconfirmed; it never resends.
    func testAWriteThatLandedBeforeItsOutcomeWasSavedIsSettledNotResent() async throws {
        exports("a")
        failingWrite = { if case .event(.changed) = $0 { true } else { false } }
        let runner = makeRunner()
        await runner.start(review([entry("a", title: "Trip")]))
        XCTAssertEqual(runner.state, .paused(.saveFailed))
        XCTAssertEqual(host.rows["default|a"]?["title"], .string("Trip"))
        host.rows["default|a"]?["title"] = .string("Renamed in Hermes")
        let writes = host.writes.count

        failingWrite = nil
        let resumed = makeRunner()
        await resumed.resume()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(host.writes.count, writes, "Nothing is resent")
        XCTAssertEqual(host.rows["default|a"]?["title"], .string("Renamed in Hermes"))
        XCTAssertEqual(report.changesUnconfirmed.map(\.id), ["a"])
    }

    /// A torn last line is either an outcome after a complete intent, which stays in flight and
    /// is only settled, or an intent whose write never finished, which was never sent.
    func testATornLastLineKeepsACompleteIntentInFlightAndDropsAnUnfinishedOne() async throws {
        exports("a", "b")
        failingWrite = { if case .event(.changed) = $0 { true } else { false } }
        await makeRunner().start(review([entry("a", title: "Trip")]))
        host.rows["default|a"]?["title"] = .null
        try appendRaw(#"{"seq":99,"event":{"changed":{"_0":{"id":"a""#)

        failingWrite = nil
        let settled = makeRunner()
        await settled.resume()
        guard case .finished(let report) = settled.state else { return XCTFail("Expected finished, got \(settled.state)") }
        XCTAssertEqual(report.changesUnconfirmed.map(\.id), ["a"], "The complete intent is settled, not resent")
        XCTAssertEqual(host.writes.filter { $0.id == "a" }.count, 1)
        guard case .ready = MoveToHermesJournal.open(folder) else {
            return XCTFail("The torn tail is cut off, so lines written after it stay readable")
        }

        // An intent cut off mid-write was never acted on, so the write still goes out once.
        try FileManager.default.removeItem(at: root)
        host = MoveHermesHost()
        failingWrite = { if case .event(.changing) = $0 { true } else { false } }
        await makeRunner().start(review([entry("b", title: "Notes")]))
        let count = journalEvents().count
        try appendRaw(#"{"seq":\#(count + 1),"event":{"changing":{"_0":{"id":"b""#)
        failingWrite = nil
        let applied = makeRunner()
        await applied.resume()
        guard case .finished(let second) = applied.state else { return XCTFail("Expected finished, got \(applied.state)") }
        XCTAssertEqual(second.changesApplied, 1)
        XCTAssertEqual(host.rows["default|b"]?["title"], .string("Notes"))
    }

    // MARK: Damaged and unreadable journals

    func testADamagedLineStopsAllWorkAndAFreshStartRecovers() async throws {
        exports("a")
        host.failingReads = ["a"]
        let runner = makeRunner()
        await runner.start(review([entry("a", title: "Trip")]))
        XCTAssertEqual(runner.state, .paused(.workLeft))
        var lines = try logText().split(separator: "\n").map(String.init)
        lines.insert(#"{"seq":2,"event":{"importing":{"profile":"default","ids":["not-in-plan"],"attempt":"\#(UUID().uuidString)"}}}"#, at: 1)
        try (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        host.failingReads = []
        let calls = host.calls

        let damaged = makeRunner()
        await damaged.resume()
        XCTAssertEqual(damaged.state, .paused(.damaged))
        XCTAssertEqual(host.calls, calls, "Nothing is read or sent from a damaged journal")
        XCTAssertEqual(MoveToHermesPending.all(in: auth.servers, root: root).map(\.status), [.damaged])

        // Starting over is Copy Missing Chats Again: it fills only what it confirms copying, and
        // a chat that landed earlier is one Hermes already has.
        host.rows["default|a"] = ["id": .string("a")]
        let recovery = makeRunner()
        await recovery.start(review([entry("a", title: "Trip")]))
        guard case .finished(let report) = recovery.state else { return XCTFail("Expected finished, got \(recovery.state)") }
        XCTAssertTrue(report.recovered)
        XCTAssertEqual(report.alreadyThere, ["a"])
        XCTAssertEqual(report.changesApplied, 0)
    }

    /// A planned write that names another chat than its plan's is damage, never a write.
    func testAPlanNamingAnotherChatIsDamaged() async throws {
        exports("a")
        host.failingReads = ["a"]
        await makeRunner().start(review([entry("a"), entry("b", location: .present(profile: "default"))]))
        let count = journalEvents().count
        let line = #"{"seq":\#(count + 1),"event":{"planned":{"_0":{"a":{"plan":{"_0":{"target":{"chat":{"id":"a","profile":"default","archived":false,"pinned":false},"profile":"default","copied":true},"operations":[{"id":"b","profile":"default","change":{"pinned":{"from":false,"to":true}}}]}}}}}}}"#
        try appendRaw(line + "\n")
        host.failingReads = []
        let calls = host.calls

        let runner = makeRunner()
        await runner.resume()

        XCTAssertEqual(runner.state, .paused(.damaged))
        XCTAssertEqual(host.calls, calls)
    }

    /// A repeat move keeps the record's mapping even when Review no longer lists its Profile;
    /// an unconfirmed import to it is the runner's own history, not damage.
    func testARepeatMoveToAProfileReviewNoLongerListsResumes() async throws {
        exports("a", "b")
        let first = makeRunner()
        await first.start(review([entry("a")]))
        first.acknowledge()
        host.loseNextImportReply = true
        let again = makeRunner()
        await again.start(review([entry("b")], hermesProfiles: ["work"]))
        XCTAssertEqual(again.state, .paused(.workLeft))

        let resumed = makeRunner()
        await resumed.resume()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(report.sentUnconfirmed + report.presentUnconfirmed + report.copied, ["b"])
    }

    /// A plan whose log is gone has lost the record of what was sent.
    func testAMissingLogIsDamaged() async throws {
        exports("a")
        host.failingReads = ["a"]
        await makeRunner().start(review([entry("a")]))
        try FileManager.default.removeItem(at: logURL)
        let calls = host.calls

        let runner = makeRunner()
        await runner.resume()

        XCTAssertEqual(runner.state, .paused(.damaged))
        XCTAssertEqual(host.calls, calls)
    }

    func testAJournalFromANewerBuildIsKeptAndNeverActedOn() async throws {
        exports("a")
        host.failingReads = ["a"]
        await makeRunner().start(review([entry("a", title: "Trip")]))
        let plan = folder.appendingPathComponent("plan.json")
        try Data(#"{"version":99}"#.utf8).write(to: plan)
        let calls = host.calls

        let runner = makeRunner()
        await runner.resume()

        XCTAssertEqual(runner.state, .paused(.unreadable))
        XCTAssertEqual(host.calls, calls)
        XCTAssertEqual(MoveToHermesPending.all(in: auth.servers, root: root).map(\.status), [.unreadable])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))
    }

    func testAMissingJournalForAnUnfinishedMoveNeedsAFreshScan() async throws {
        exports("a")
        host.failingReads = ["a"]
        await makeRunner().start(review([entry("a")]))
        try FileManager.default.removeItem(at: folder)

        let runner = makeRunner()
        await runner.resume()

        XCTAssertEqual(runner.state, .paused(.needsRescan))
        XCTAssertEqual(MoveToHermesPending.all(in: auth.servers, root: root).map(\.status), [.needsRescan])
    }

    func testOrphanJournalsAreDeletedUnlessARunnerHoldsThem() throws {
        let orphan = MoveToHermesJournal.folder(source: "https://gone.example", destination: hermes.absoluteString, in: root)
        let held = MoveToHermesJournal.folder(source: "https://held.example", destination: hermes.absoluteString, in: root)
        for folder in [orphan, held] { _ = try MoveToHermesJournal.create(frozen([entry("a")]), at: folder) }
        XCTAssertTrue(MoveToHermesJournal.claim(held))
        defer { MoveToHermesJournal.release(held) }

        XCTAssertEqual(MoveToHermesPending.all(in: auth.servers, root: root), [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
    }

    // MARK: Finishing

    func testTheReportIsOnDiskBeforeTheRecordCompletesAndSurvivesAFailedRecordSave() async throws {
        exports("a")
        failingWrite = { if case .event(.finished) = $0 { true } else { false } }
        let runner = makeRunner()
        await runner.start(review([entry("a")]))
        XCTAssertEqual(runner.state, .paused(.saveFailed))
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString)?.record.completedAt)

        failingWrite = nil
        keychain.failingKeys = [.servers]
        let unsaved = makeRunner()
        await unsaved.resume()
        XCTAssertEqual(unsaved.state, .paused(.saveFailed))
        XCTAssertNil(auth.moveRecord(forSource: webui.absoluteString)?.record.completedAt)
        guard case .finished(let logged)? = journalEvents().last else { return XCTFail("The report is logged first") }

        keychain.failingKeys = []
        let resumed = makeRunner()
        await resumed.resume()
        XCTAssertEqual(resumed.state, .finished(logged))
        XCTAssertNotNil(auth.moveRecord(forSource: webui.absoluteString)?.record.completedAt)
        XCTAssertEqual(MoveToHermesPending.all(in: auth.servers, root: root).map(\.status), [.finished(logged)])
    }

    func testFinishingEarlyReportsWhatIsLeftWithoutSendingAnything() async throws {
        exports("a", "b")
        host.failingReads = ["b"]
        await drafts.seed([sourceDraft("a"): ChatDraft(text: "unsent")])
        let runner = makeRunner()
        await runner.start(review([entry("a"), entry("b"), entry("c", location: .unknown),
                                   entry("kept", profile: "ops")]))
        XCTAssertEqual(runner.state, .paused(.workLeft), "b's recheck failed, so Resume can try it")
        let calls = host.calls

        await runner.finishEarly()

        guard case .finished(let report) = runner.state else { return XCTFail("Expected finished, got \(runner.state)") }
        XCTAssertTrue(report.finishedEarly)
        XCTAssertEqual(report.copied, ["a"])
        XCTAssertEqual(report.unchecked.sorted(), ["b", "c"])
        XCTAssertEqual(report.keptOnWebui, ["kept"])
        XCTAssertEqual(host.calls, calls)
        let summary = try XCTUnwrap(auth.moveRecord(forSource: webui.absoluteString)?.record.report)
        XCTAssertEqual(summary.remaining, 1, "Only chats confirmed missing count as remaining")
        XCTAssertEqual(summary.unchecked, 2)
    }

    /// The destination's removal is part way through while a chat's row is read for its draft:
    /// its drafts are discarded but its entry is still there. The draft stays on the webui.
    func testADraftReadWhileTheDestinationIsBeingRemovedStaysOnTheWebui() async throws {
        root = MoveToHermesJournal.defaultRoot
        host.rows["default|had"] = ["id": .string("had"), "title": .string("Mine")]
        await drafts.seed([sourceDraft("had"): ChatDraft(text: "unsent")])
        var reads = 0
        var removal: Task<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let held = expectation(description: "Removal held after discarding drafts")
        duringRemoval = {
            held.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        host.onRead = { [unowned self] key in
            guard key == "had" else { return }
            reads += 1
            // The second read is the draft step's; the first is planning's.
            guard reads == 2, let destination = self.auth.servers.first(where: { $0.id == self.hermes.absoluteString }) else { return }
            removal = Task { await self.auth.removeServer(destination) }
            await self.fulfillment(of: [held], timeout: 5)
        }
        let runner = makeRunner()

        await runner.start(review([entry("had", location: .present(profile: "default"))]))
        XCTAssertNotNil(auth.servers.first { $0.id == hermes.absoluteString }, "The entry is still there mid-removal")
        release?.resume()
        await removal?.value

        XCTAssertEqual(runner.state, .paused(.destinationRemoved))
        let saved = await drafts.values
        XCTAssertEqual(saved[sourceDraft("had")]?.text, "unsent")
        XCTAssertNil(saved[hermesDraft("had")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// Each chat's draft result is saved before the next chat's transfer, so a stop part way
    /// through keeps the results of drafts already moved.
    func testADraftResultIsSavedBeforeTheNextChatsTransfer() async throws {
        exports("a", "b")
        await drafts.seed([sourceDraft("a"): ChatDraft(text: "first"), sourceDraft("b"): ChatDraft(text: "second")])
        var draftLines = 0
        failingWrite = { write in
            guard case .event(.drafts) = write else { return false }
            draftLines += 1
            return draftLines == 2
        }
        let runner = makeRunner()
        await runner.start(review([entry("a"), entry("b")]))
        XCTAssertEqual(runner.state, .paused(.saveFailed))

        failingWrite = nil
        let resumed = makeRunner()
        await resumed.resume()

        guard case .finished(let report) = resumed.state else { return XCTFail("Expected finished, got \(resumed.state)") }
        XCTAssertEqual(report.draftsMoved, 1, "a's result was saved; b's moved before its line was lost")
        let saved = await drafts.values
        XCTAssertEqual(saved[hermesDraft("a")]?.text, "first")
        XCTAssertEqual(saved[hermesDraft("b")]?.text, "second")
    }

    func testAConflictingDraftIsKeptOnBothSides() async throws {
        exports("a")
        await drafts.seed([sourceDraft("a"): ChatDraft(text: "webui"), hermesDraft("a"): ChatDraft(text: "hermes")])
        let runner = makeRunner()

        await runner.start(review([entry("a")]))

        guard case .finished(let report) = runner.state else { return XCTFail("Expected finished, got \(runner.state)") }
        XCTAssertEqual(report.draftConflicts, ["a"])
        let saved = await drafts.values
        XCTAssertEqual(saved[sourceDraft("a")]?.text, "webui")
        XCTAssertEqual(saved[hermesDraft("a")]?.text, "hermes")
    }

    // MARK: Repeat moves and removal

    func testCopyMissingChatsAgainKeepsTheRecordsMappingAndFillsOnlyWhatItCopies() async throws {
        exports("a")
        let first = makeRunner()
        await first.start(review([entry("a")]))
        first.acknowledge()
        host.rows["default|had"] = ["id": .string("had")]
        exports("new")

        let again = makeRunner()
        let remapped = [MovedWebuiProfile(source: "default", destination: .hermes(profile: "work"))]
        await again.start(review([entry("had", title: "Webui", location: .present(profile: "default")), entry("new", title: "New")],
                                 profiles: remapped))

        guard case .finished(let report) = again.state else { return XCTFail("Expected finished, got \(again.state)") }
        XCTAssertEqual(report.copied, ["new"])
        XCTAssertEqual(host.imports.last?.profile, "default", "The record's mapping, not Review's")
        XCTAssertEqual(host.rows["default|new"]?["title"], .string("New"))
        XCTAssertNil(host.rows["default|had"]?["title"], "A chat Hermes had is left alone on a repeat")
    }

    func testRemovingTheDestinationDeletesItsJournalAndTheMoveStops() async throws {
        root = MoveToHermesJournal.defaultRoot
        exports("a")
        host.failingReads = ["a"]
        await makeRunner().start(review([entry("a")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let destination = try XCTUnwrap(auth.servers.first { $0.id == hermes.absoluteString })

        await auth.removeServer(destination)
        let calls = host.calls
        let runner = makeRunner()
        await runner.resume()

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(runner.state, .idle)
        XCTAssertEqual(host.calls, calls)
    }

    // MARK: Helpers

    private var folder: URL {
        MoveToHermesJournal.folder(source: webui.absoluteString, destination: hermes.absoluteString, in: root)
    }

    private var logURL: URL { folder.appendingPathComponent("log.jsonl") }

    private func makeRunner() -> MoveToHermesRunner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoveWebuiFixture.self]
        var environment = MoveToHermesRunner.Environment()
        environment.root = root
        let registrar = registrar!
        environment.destination = { [host = host!] _ in MoveToHermesDestination(transport: host, readPairing: {
            registrar.read()
            return PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: String(repeating: "a", count: 64),
                        previewKey: "key")
        }, close: {}) }
        environment.webuiConfiguration = configuration
        environment.cookies = { _ in [] }
        environment.registrar = { registrar }
        let store = ChatDraftStore(persistence: drafts)
        environment.drafts = { store }
        environment.willWrite = { [weak self] write in
            if self?.failingWrite?(write) == true { throw CocoaError(.fileWriteOutOfSpace) }
        }
        return MoveToHermesRunner(auth: auth, sourceServerID: webui.absoluteString, destinationID: hermes.absoluteString,
                                  environment: environment)
    }

    private func review(_ entries: [MoveToHermesScan.Entry], profiles: [MovedWebuiProfile]? = nil,
                        hermesProfiles: [String] = ["default", "work"]) -> MoveToHermesRunner.Review {
        MoveToHermesRunner.Review(
            source: auth.servers.first { $0.id == webui.absoluteString }!,
            connection: BotConnection(id: connectionID, name: "Hermes", address: hermes, username: "me", password: "secret"),
            profiles: profiles ?? mapping, hermesProfiles: hermesProfiles,
            scan: MoveToHermesScan.Result(entries: entries, onlyProfile: nil))
    }

    private var mapping: [MovedWebuiProfile] {
        [MovedWebuiProfile(source: "default", destination: .hermes(profile: "default")),
         MovedWebuiProfile(source: "ops", destination: .keepOnWebui)]
    }

    private func frozen(_ entries: [MoveToHermesScan.Entry]) -> MoveToHermesReview {
        MoveToHermesReview(firstMove: true, profiles: mapping, hermesProfiles: ["default"], entries: entries, onlyProfile: nil)
    }

    private func entry(_ id: String, title: String? = nil, profile: String = "default", pinned: Bool = false,
                       workspace: String? = nil, location: MoveToHermesLocation = .missing) -> MoveToHermesScan.Entry {
        MoveToHermesScan.Entry(chat: MoveToHermesSourceChat(id: id, profile: profile, title: title, pinned: pinned,
                                                            workspace: workspace), location: location)
    }

    private func exports(_ ids: String...) {
        for id in ids {
            let export = BotJSON.object(["session_id": .string(id), "messages": .array([
                .object(["role": .string("user"), "content": .string("hi")]),
            ])])
            MoveWebuiFixture.exports[id] = try? JSONEncoder().encode(export)
        }
    }

    private func sourceDraft(_ id: String) -> ChatDraftKey { .session(server: webui, sessionID: id) }

    private func hermesDraft(_ id: String) -> ChatDraftKey {
        .hermesSession(server: hermes, connectionID: connectionID, profile: "default", key: id)
    }

    private func journalEvents() -> [MoveToHermesEvent] {
        guard case .ready(let journal) = MoveToHermesJournal.open(folder) else { return [] }
        return journal.events
    }

    private func logText() throws -> String { try String(contentsOf: logURL, encoding: .utf8) }

    /// Appends bytes as a write cut short by a crash leaves them: no newline.
    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

/// The scripted Hermes host the Move to Hermes tests share: Profiles, scan listings, rows by
/// `profile|id`, imports, the title, pin and folder writes, and the failures a test asks for.
@MainActor final class MoveHermesHost: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var profiles = ["default", "research"]
    /// The Profile `profiles.list` marks `is_default`.
    var defaultProfile: String?
    var connectFailure: BotFailure?
    /// Ids each Profile's scan listing shows; a listed id without a row reads as a bare row.
    var listed: [String: [String]] = [:]
    var rows: [String: [String: BotJSON]] = [:]
    /// Ids whose reads fail.
    var failingReads: Set<String> = []
    var titlesInUse: Set<String> = []
    var missingFolders: Set<String> = []
    /// Ids whose next write loses its reply: true when the write still landed.
    var lostReplies: [String: Bool] = [:]
    /// Ids whose next write the host's write fence refuses (#1300); nothing is written.
    var fenceRefusals: [String: HermesSessionFenceRefusal] = [:]
    /// The next import lands but its reply is lost.
    var loseNextImportReply = false
    /// Runs inside each row read, before it answers.
    var onRead: (@MainActor (String) async -> Void)?
    /// Runs as each import arrives, before it is answered.
    var onImport: (() -> Void)?
    /// Runs as each write arrives, with its field, before it is answered.
    var onWrite: ((String) -> Void)?
    private(set) var imports: [(profile: String, ids: [String])] = []
    var writes: [(id: String, field: String)] = []
    private(set) var connects = 0
    /// Every read and write the host answered.
    private(set) var calls = 0

    func connect() async throws {
        connects += 1
        if let connectFailure { throw connectFailure }
    }

    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        calls += 1
        switch call {
        case .profilesList:
            return .object(["profiles": .array(profiles.map { .object(["name": .string($0), "is_default": .bool($0 == defaultProfile)]) })])
        case .sessionWorkspaceMove(let profile, let key, let cwd):
            try write(key, profile: profile, field: "folder", value: .string(cwd)) {
                if self.missingFolders.contains(cwd) { throw BotSettingFailure.rejected(4017, "working directory does not exist: \(cwd)") }
            }
            return .object(["cwd": .string(cwd)])
        default:
            throw BotFailure.unsupported
        }
    }

    func sessionScanPage(profile: String, offset: Int) async throws -> HermesScanPage {
        let ids = listed[profile] ?? []
        return HermesScanPage(ids: Array(ids.dropFirst(offset)), total: ids.count)
    }

    func sessionRow(key: String, profile: String) async throws -> BotJSON? {
        calls += 1
        await onRead?(key)
        if failingReads.contains(key) { throw BotFailure.transport }
        if listed[profile]?.contains(key) == true, rows["\(profile)|\(key)"] == nil { return .object(["id": .string(key)]) }
        return rows["\(profile)|\(key)"].map(BotJSON.object)
    }

    func importSessions(body: Data) async throws -> BotJSON {
        calls += 1
        onImport?()
        let request = try JSONDecoder().decode(BotJSON.self, from: body)
        let profile = request["profile"].text ?? ""
        let ids = request["sessions"].list?.compactMap { $0["id"].text } ?? []
        imports.append((profile, ids))
        let skipped = ids.filter { rows["\(profile)|\($0)"] != nil }
        let imported = ids.filter { !skipped.contains($0) }
        for id in imported { rows["\(profile)|\(id)"] = ["id": .string(id), "pinned": .bool(false)] }
        if loseNextImportReply {
            loseNextImportReply = false
            throw BotFailure.transport
        }
        return .object(["imported_ids": .array(imported.map(BotJSON.string)), "skipped_ids": .array(skipped.map(BotJSON.string))])
    }

    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        calls += 1
        switch change {
        case .title(let title):
            try write(key, profile: profile, field: "title", value: .string(title)) {
                if self.titlesInUse.contains(title) {
                    throw HermesSessionRefusal(message: "Title '\(title)' is already in use by session other")
                }
            }
            return title
        case .pinned(let pinned):
            try write(key, profile: profile, field: "pinned", value: .bool(pinned))
        case .archived, .unread:
            XCTFail("a move never writes \(change)")
        }
        return nil
    }

    private func write(_ key: String, profile: String, field: String, value: BotJSON, check: () throws -> Void = {}) throws {
        writes.append((key, field))
        onWrite?(field)
        try check()
        if let refusal = fenceRefusals.removeValue(forKey: key) { throw refusal }
        let column = field == "folder" ? "cwd" : field
        if let lands = lostReplies.removeValue(forKey: key) {
            if lands { rows["\(profile)|\(key)"]?[column] = value }
            throw BotFailure.transport
        }
        rows["\(profile)|\(key)"]?[column] = value
    }
}

/// The registrar's side of the pairing carry, counting host reads.
@MainActor private final class RunnerRegistrar: PushPairingCopying {
    var sourcePaired = false
    private(set) var reads = 0
    var onRead: (() -> Void)?

    func pairing(for server: URL) -> PushPairing? {
        guard sourcePaired, server.host == "webui.example" else { return nil }
        return PushPairing(relayURL: URL(string: "https://relay.example")!, installKey: String(repeating: "a", count: 64),
                           previewKey: "key")
    }

    func copyPairing(from source: URL, to destination: URL, matching install: PushPairing,
                     isConfigured: @escaping @MainActor (URL) -> Bool) async throws -> MovePushPairingOutcome {
        .copied
    }

    /// Counted through `readPairing` when the runner reads the host.
    func read() {
        reads += 1
        onRead?()
    }
}

/// Drafts on "disk".
private actor RunnerDrafts: ChatDraftPersisting {
    private(set) var values: [ChatDraftKey: ChatDraft] = [:]

    func seed(_ drafts: [ChatDraftKey: ChatDraft]) { values = drafts }
    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) throws { values = drafts }
}
