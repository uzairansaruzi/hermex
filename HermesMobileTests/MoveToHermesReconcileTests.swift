import XCTest
@testable import HermesMobile

/// Move to Hermes's reconcile (#1214): fill-only metadata from recorded starting values,
/// report-only settling of writes with unknown results, and draft moves that keep both sides.
@MainActor
final class MoveToHermesReconcileTests: XCTestCase {
    private typealias Reconcile = MoveToHermesReconcile

    private let webui = URL(string: "https://webui.example")!
    private let hermes = URL(string: "https://hermes.example")!
    private let connection = UUID()

    // MARK: Planning

    func testPlanRecordsSnapshotValuesAndFillsOnlyEmptyFields() async {
        let wire = MoveHermesHost()
        wire.rows["dev|copied"] = ["id": .string("copied"), "title": .null, "pinned": .number(0), "cwd": .string("")]
        wire.rows["dev|present"] = ["id": .string("present"), "title": .string("Kept"), "pinned": .number(0),
                                    "archived": .number(0), "cwd": .string("/srv/own")]
        let copied = target("copied", title: "  Trip\n plan ", pinned: true, workspace: "/srv/trip")
        let present = target("present", title: "Webui name", pinned: true, archived: true, workspace: "/srv/other", copied: false)

        let planned = await Reconcile.plan([copied, present], on: wire)

        XCTAssertEqual(planned["copied"], .plan(.init(target: copied, draftSession: "copied", operations: [
            .init(id: "copied", profile: "dev", change: .title(from: nil, to: "Trip plan")),
            .init(id: "copied", profile: "dev", change: .pinned(from: false, to: true)),
            .init(id: "copied", profile: "dev", change: .folder(from: nil, to: "/srv/trip")),
        ])))
        // A chat Hermes already had keeps its title, folder, pin and archive state.
        XCTAssertEqual(planned["present"], .plan(.init(target: present, draftSession: "present", operations: [])))
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testPlanGivesHiddenAndParentedRowsNoVerifiedDraftKey() async {
        let wire = MoveHermesHost()
        wire.rows["dev|hidden"] = ["id": .string("hidden"), "hidden": .number(1)]
        wire.rows["dev|child"] = ["id": .string("child"), "parent_session_id": .string("root")]
        wire.rows["dev|prefix"] = ["id": .string("prefix-longer")]
        wire.failingReads = ["unreadable"]
        let hidden = target("hidden", title: "Hidden", pinned: true)
        let child = target("child")

        let planned = await Reconcile.plan([hidden, child, target("prefix"), target("unreadable"), target("gone")], on: wire)

        XCTAssertEqual(planned["hidden"], .plan(.init(target: hidden, draftSession: nil, operations: [])))
        XCTAssertEqual(planned["child"], .plan(.init(target: child, draftSession: nil, operations: [])))
        XCTAssertEqual(planned["prefix"], .missing)
        XCTAssertEqual(planned["unreadable"], .unread)
        XCTAssertEqual(planned["gone"], .missing)
    }

    func testTargetsTakeChatsHermesHadOnlyOnTheFirstMove() {
        let entries = ["new", "had", "skipped", "lost"].map { id in
            MoveToHermesScan.Entry(chat: .init(id: id, profile: "default"),
                                   location: id == "had" ? .present(profile: "work") : .missing)
        }
        let outcomes: [String: WebuiSessionTransfer.Outcome] = [
            "new": .imported(profile: "dev"), "skipped": .alreadyPresent(profile: "dev"), "lost": .uncertain(profile: "dev"),
        ]

        let first = Reconcile.targets(entries, outcomes: outcomes, firstMove: true)
        XCTAssertEqual(first.map(\.chat.id), ["new", "had", "skipped"])
        XCTAssertEqual(first.map(\.copied), [true, false, false])
        XCTAssertEqual(first.map(\.profile), ["dev", "work", "dev"])
        XCTAssertEqual(Reconcile.targets(entries, outcomes: outcomes, firstMove: false).map(\.chat.id), ["new"])
    }

    func testTitlesFillCleanedAndCappedAndSkipThePlaceholder() {
        XCTAssertNil(Reconcile.fillTitle("Untitled"))
        XCTAssertNil(Reconcile.fillTitle(" \u{200B}\n "))
        XCTAssertEqual(Reconcile.fillTitle("a\u{7}b\t\tc"), "ab c")
        XCTAssertEqual(Reconcile.fillTitle(String(repeating: "é", count: 150))?.unicodeScalars.count, 100)
        let suffixed = Reconcile.suffixed(String(repeating: "x", count: 100), id: "0123456789ab")
        XCTAssertEqual(suffixed.unicodeScalars.count, 100)
        XCTAssertTrue(suffixed.hasSuffix("x (6789ab)"))
    }

    // MARK: Applying

    func testApplyRecordsEachWriteBeforeSendingIt() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a"), "pinned": .bool(false)]
        let operations = await plannedOperations(target("a", title: "Notes", pinned: true, workspace: "/srv/a"), on: wire)
        var log: [String] = []
        wire.onWrite = { log.append("write \($0)") }

        let outcomes = await Reconcile.apply(operations, on: wire) { log.append("record \($0.change.label)") }

        XCTAssertEqual(log, ["record title", "write title", "record pinned", "write pinned", "record folder", "write folder"])
        XCTAssertEqual(Array(outcomes.values), Array(repeating: .applied, count: 3))
        XCTAssertEqual(wire.rows["dev|a"]?["title"], .string("Notes"))
        XCTAssertEqual(wire.rows["dev|a"]?["cwd"], .string("/srv/a"))
    }

    func testApplySkipsFieldsChangedInHermesSincePlanning() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        let operations = await plannedOperations(target("a", title: "Notes", pinned: true, workspace: "/srv/a"), on: wire)
        // Between planning and dispatch, the user names it, pins it and moves it.
        wire.rows["dev|a"] = ["id": .string("a"), "title": .string("Mine"), "pinned": .number(1), "cwd": .string("/srv/mine")]
        var recorded: [Reconcile.Operation] = []

        let outcomes = await Reconcile.apply(operations, on: wire) { recorded.append($0) }

        XCTAssertEqual(outcomes[operations[0]], .changed)
        XCTAssertEqual(outcomes[operations[1]], .applied, "already pinned, so nothing to send")
        XCTAssertEqual(outcomes[operations[2]], .changed)
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testApplyLeavesARowHiddenSincePlanningUntouched() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        let operations = await plannedOperations(target("a", title: "Notes", pinned: true), on: wire)
        wire.rows["dev|a"]?["hidden"] = .number(1)

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in }

        XCTAssertEqual(Array(outcomes.values), [.changed, .changed])
        XCTAssertTrue(wire.writes.isEmpty, "pinned: true would unhide it")
    }

    func testFailedRecordStopsAllSending() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        wire.rows["dev|b"] = ["id": .string("b")]
        var operations = await plannedOperations(target("a", title: "A", workspace: "/a"), on: wire)
        operations += await plannedOperations(target("b", title: "B"), on: wire)

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in throw ChatDraftStorageError.unavailable }

        XCTAssertEqual(Array(outcomes.values), Array(repeating: .notSent, count: 3))
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testTitleCollisionRetriesOnceWithACappedSuffixThenReports() async {
        let wire = MoveHermesHost()
        wire.rows["dev|0123456789ab"] = ["id": .string("0123456789ab")]
        let long = String(repeating: "t", count: 100)
        let operations = await plannedOperations(target("0123456789ab", title: long), on: wire)
        wire.titlesInUse = [long, String(repeating: "t", count: 91) + " (6789ab)"]
        var recorded: [Reconcile.Change] = []

        let outcomes = await Reconcile.apply(operations, on: wire) { recorded.append($0.change) }

        XCTAssertEqual(recorded, [.title(from: nil, to: long), .title(from: nil, to: String(repeating: "t", count: 91) + " (6789ab)")])
        guard case .rejected(let reason)? = outcomes[operations[0]] else { return XCTFail("\(String(describing: outcomes))") }
        XCTAssertTrue(reason.contains("already in use"))
        XCTAssertEqual(wire.writes.count, 2)

        wire.titlesInUse = ["Notes"]
        let notes = await plannedOperations(target("0123456789ab", title: "Notes"), on: wire)
        let renamed = await Reconcile.apply(notes, on: wire) { _ in }
        XCTAssertEqual(renamed[notes[0]], .applied)
        XCTAssertEqual(wire.rows["dev|0123456789ab"]?["title"], .string("Notes (6789ab)"))
    }

    func testMissingFolderIsReported() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        wire.missingFolders = ["/gone"]
        let operations = await plannedOperations(target("a", workspace: "/gone"), on: wire)

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in }

        XCTAssertEqual(outcomes[operations[0]], .folderMissing)
        XCTAssertNil(wire.rows["dev|a"]?["cwd"])
    }

    func testLostReplyIsAppliedOnlyWhenHermesHoldsTheValueAndIsNeverResent() async {
        let wire = MoveHermesHost()
        wire.rows["dev|landed"] = ["id": .string("landed")]
        wire.rows["dev|lost"] = ["id": .string("lost")]
        var operations = await plannedOperations(target("landed", pinned: true), on: wire)
        operations += await plannedOperations(target("lost", pinned: true), on: wire)
        wire.lostReplies = ["landed": true, "lost": false]

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in }

        XCTAssertEqual(outcomes[operations[0]], .applied)
        XCTAssertEqual(outcomes[operations[1]], .uncertain)
        XCTAssertEqual(wire.writes.count, 2, "one send each; the unconfirmed one isn't sent again")
    }

    /// A write the fence refused (#1300) is never resent in the run: a busy session reports why,
    /// and a stale revision, which wrote nothing, is left for the next run to apply.
    func testFenceRefusalIsNeverResent() async {
        let wire = MoveHermesHost()
        wire.rows["dev|busy"] = ["id": .string("busy")]
        wire.rows["dev|stale"] = ["id": .string("stale")]
        var operations = await plannedOperations(target("busy", pinned: true), on: wire)
        operations += await plannedOperations(target("stale", pinned: true), on: wire)
        wire.fenceRefusals = ["busy": .busy, "stale": .changed]

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in }

        XCTAssertEqual(outcomes[operations[0]], .rejected(reason: HermesSessionFenceRefusal.busy.localizedDescription))
        XCTAssertEqual(outcomes[operations[1]], .notSent)
        XCTAssertEqual(wire.writes.count, 2)
    }

    func testUnreadableRowSendsNothing() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        let operations = await plannedOperations(target("a", title: "A"), on: wire)
        wire.failingReads = ["a"]
        var recorded = 0

        let outcomes = await Reconcile.apply(operations, on: wire) { _ in recorded += 1 }

        XCTAssertEqual(outcomes[operations[0]], .notSent)
        XCTAssertEqual(recorded, 0)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    // MARK: Settling

    /// The success/acknowledgement gap: each write landed, the journal never heard, and the user
    /// then undid it in Hermes. Resuming must report it, not send it again.
    func testResumeAfterRemoteSuccessAndExternalEditsReportsUncertainWithoutWriting() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]
        let operations = await plannedOperations(target("a", title: "Notes", pinned: true, workspace: "/srv/a"), on: wire)
        _ = await Reconcile.apply(operations, on: wire) { _ in }
        wire.writes = []
        // The user unpins it, renames it and moves it back to having no folder.
        wire.rows["dev|a"] = ["id": .string("a"), "title": .string("Renamed"), "pinned": .bool(false), "cwd": .null]

        let settled = await Reconcile.settle(operations, on: wire)

        XCTAssertEqual(settled[operations[0]], .uncertain)
        XCTAssertEqual(settled[operations[1]], .uncertain, "back at its starting value, still not resent")
        XCTAssertEqual(settled[operations[2]], .uncertain)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testSettleFindsLandedWritesAndLeavesUnreadableOnesForLater() async {
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a"), "pinned": .number(1), "cwd": .string("/srv/a/")]
        let landed = [Reconcile.Operation(id: "a", profile: "dev", change: .pinned(from: false, to: true)),
                      Reconcile.Operation(id: "a", profile: "dev", change: .folder(from: nil, to: "/srv/a"))]
        let unread = Reconcile.Operation(id: "b", profile: "dev", change: .title(from: nil, to: "B"))
        let gone = Reconcile.Operation(id: "c", profile: "dev", change: .title(from: nil, to: "C"))
        wire.failingReads = ["b"]

        let settled = await Reconcile.settle(landed + [unread, gone], on: wire)

        XCTAssertEqual(settled[landed[0]], .applied)
        XCTAssertEqual(settled[landed[1]], .applied)
        XCTAssertNil(settled[unread])
        XCTAssertEqual(settled[gone], .missing)
        XCTAssertTrue(wire.writes.isEmpty)
    }

    // MARK: Drafts

    func testDraftMovesToTheVerifiedSessionKeyWithoutItsSettings() async throws {
        let quote = ComposerQuote(text: "quoted")
        let persistence = ReconcileDrafts(values: [
            source("a"): ChatDraft(text: "unsent", quotes: [quote], settings: ChatDraftSettings(modelID: "webui-model")),
        ])
        let store = ChatDraftStore(persistence: persistence)
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]

        let outcomes = await Reconcile.moveDrafts([plan("a", draftSession: "a")], webui: webui, hermes: hermes,
                                                  connectionID: connection, store: store, on: wire)

        XCTAssertEqual(outcomes["a"], .moved(.moved))
        let saved = await persistence.values
        XCTAssertNil(saved[source("a")])
        XCTAssertEqual(saved[destination("a")]?.text, "unsent")
        XCTAssertEqual(saved[destination("a")]?.quotes, [quote])
        XCTAssertNil(saved[destination("a")]?.settings)
    }

    func testUnverifiedDraftKeyLeavesTheDraftOnTheWebui() async {
        let persistence = ReconcileDrafts(values: [source("child"): ChatDraft(text: "unsent")])
        let store = ChatDraftStore(persistence: persistence)
        let wire = MoveHermesHost()

        let outcomes = await Reconcile.moveDrafts([plan("child", draftSession: nil), plan("empty", draftSession: nil)],
                                                  webui: webui, hermes: hermes, connectionID: connection, store: store, on: wire)

        XCTAssertEqual(outcomes["child"], .unverified)
        XCTAssertEqual(outcomes["empty"], .moved(.nothingToMove))
        let saved = await persistence.values
        XCTAssertEqual(saved[source("child")]?.text, "unsent")
        XCTAssertEqual(saved.count, 1)
    }

    /// A plan can be old: the session may since be deleted, hidden or continued, or unreadable.
    func testDraftStaysWhenTheSessionChangedSincePlanning() async {
        let ids = ["gone", "hidden", "child", "unreadable"]
        let persistence = ReconcileDrafts(values: Dictionary(uniqueKeysWithValues: ids.map { (source($0), ChatDraft(text: $0)) }))
        let store = ChatDraftStore(persistence: persistence)
        let wire = MoveHermesHost()
        wire.rows["dev|hidden"] = ["id": .string("hidden"), "hidden": .bool(true)]
        wire.rows["dev|child"] = ["id": .string("child"), "parent_session_id": .string("root")]
        wire.failingReads = ["unreadable"]

        let outcomes = await Reconcile.moveDrafts(ids.map { plan($0, draftSession: $0) }, webui: webui, hermes: hermes,
                                                  connectionID: connection, store: store, on: wire)

        XCTAssertEqual(outcomes, ["gone": .missing, "hidden": .unverified, "child": .unverified, "unreadable": .failed])
        let saved = await persistence.values
        XCTAssertEqual(Set(saved.keys), Set(ids.map(source)))
    }

    func testFailedCopySaveKeepsTheSourceAndAddsNothing() async {
        let persistence = ReconcileDrafts(values: [source("a"): ChatDraft(text: "unsent")])
        await persistence.failWrites(1)
        let store = ChatDraftStore(persistence: persistence)
        let wire = MoveHermesHost()
        wire.rows["dev|a"] = ["id": .string("a")]

        let outcomes = await Reconcile.moveDrafts([plan("a", draftSession: "a")], webui: webui, hermes: hermes,
                                                  connectionID: connection, store: store, on: wire)

        XCTAssertEqual(outcomes["a"], .failed)
        let saved = await persistence.values
        XCTAssertEqual(saved[source("a")]?.text, "unsent")
        XCTAssertNil(saved[destination("a")])
    }

    /// A failed save of the source's removal, like a quit between copy and delete, leaves the
    /// draft in both places; the next move finishes it.
    func testFailedRemovalKeepsBothAndTheNextMoveFinishes() async throws {
        let persistence = ReconcileDrafts(values: [source("a"): ChatDraft(text: "unsent")])
        let store = ChatDraftStore(persistence: persistence)
        await persistence.failWrites(2)

        do {
            _ = try await store.transferDraft(from: source("a"), to: destination("a"))
            XCTFail("expected the removal's save to throw")
        } catch {}
        var saved = await persistence.values
        XCTAssertEqual(saved[source("a")]?.text, "unsent")
        XCTAssertEqual(saved[destination("a")]?.text, "unsent")

        let again = try await store.transferDraft(from: source("a"), to: destination("a"))

        XCTAssertEqual(again, .alreadyMoved)
        saved = await persistence.values
        XCTAssertNil(saved[source("a")])
        XCTAssertEqual(saved[destination("a")]?.text, "unsent")
    }

    // MARK: Helpers

    private func target(_ id: String, title: String? = nil, pinned: Bool = false, archived: Bool = false,
                        workspace: String? = nil, copied: Bool = true) -> Reconcile.Target {
        Reconcile.Target(chat: MoveToHermesSourceChat(id: id, profile: "default", title: title, archived: archived,
                                                      pinned: pinned, workspace: workspace),
                         profile: "dev", copied: copied)
    }

    private func plannedOperations(_ target: Reconcile.Target, on wire: MoveHermesHost) async -> [Reconcile.Operation] {
        guard case .plan(let plan)? = await Reconcile.plan([target], on: wire)[target.chat.id] else {
            XCTFail("no plan for \(target.chat.id)")
            return []
        }
        return plan.operations
    }

    private func plan(_ id: String, draftSession: String?) -> Reconcile.Plan {
        Reconcile.Plan(target: target(id), draftSession: draftSession, operations: [])
    }

    private func source(_ id: String) -> ChatDraftKey { .session(server: webui, sessionID: id) }

    private func destination(_ id: String) -> ChatDraftKey {
        .hermesSession(server: hermes, connectionID: connection, profile: "dev", key: id)
    }
}

private extension MoveToHermesReconcile.Change {
    var label: String {
        switch self {
        case .title: return "title"
        case .pinned: return "pinned"
        case .folder: return "folder"
        }
    }
}

/// Drafts on "disk", with the next writes failing on request.
private actor ReconcileDrafts: ChatDraftPersisting {
    private(set) var values: [ChatDraftKey: ChatDraft]
    /// The write, counting from 1 after `failWrites`, that throws.
    private var failingWrite: Int?
    private var writesSinceArmed = 0

    init(values: [ChatDraftKey: ChatDraft]) { self.values = values }

    func failWrites(_ nth: Int) {
        failingWrite = nth
        writesSinceArmed = 0
    }

    func load() -> [ChatDraftKey: ChatDraft] { values }

    func write(_ drafts: [ChatDraftKey: ChatDraft]) throws {
        writesSinceArmed += 1
        if writesSinceArmed == failingWrite { throw ChatDraftStorageError.unavailable }
        values = drafts
    }
}
