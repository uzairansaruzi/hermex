import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesSessionListTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionListTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOrdinaryAndScheduledPagesStartTogetherAndCancelWithTheirOwner() async {
        let wire = HermesSessionListWire()
        wire.holdsPages = true
        wire.holdsScheduledPages = true
        let list = makeList(wire)
        defer { list.closeHermes() }
        let loading = Task { await list.openHermes() }
        await waitUntil("both independent pages started") { wire.pageReads.count == 1 && wire.scheduledReads.count == 1 }
        loading.cancel()
        await loading.value
        XCTAssertTrue(list.sessions.isEmpty)
        XCTAssertFalse(list.isLoading)
        XCTAssertNil(list.errorMessage)
    }

    func testScheduledLoadMoreDuringAnOrdinaryRefreshKeepsItsRows() async {
        let wire = HermesSessionListWire()
        let first = (0..<100).map { HermesSessionRow(id: "job-\($0)", source: "cron") }
        wire.scheduledPages["default"] = [0: HermesSessionPage(rows: first, total: 101),
                                           100: HermesSessionPage(rows: [HermesSessionRow(id: "last-job", source: "cron")], total: 101)]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        wire.holdsPages = true
        wire.emit("sessions.changed")
        await waitUntil("refresh has read scheduled rows while ordinary is parked") {
            wire.pageReads.count == 2 && wire.scheduledReads.count == 2
        }
        await list.loadMoreHermesScheduledSessions()
        XCTAssertEqual(list.sessions.count, 101)
        wire.holdsPages = false
        wire.release()
        await waitUntil("refresh has extended to the newly loaded page") { wire.scheduledReads.count == 4 }
        await waitUntil("refresh applied") { wire.calls.filter { $0.method == "session.active_list" }.count == 2 }
        XCTAssertEqual(list.sessions.count, 101)
        await list.openHermes()
        XCTAssertEqual(list.sessions.count, 101)
        XCTAssertTrue(list.sessions.contains { $0.sessionId == "last-job" })
        XCTAssertFalse(list.hasMoreScheduledSessions)
    }

    func testScheduledSectionLoadsGroupsCountsAndFollowsProfile() async throws {
        let wire = HermesSessionListWire()
        let rows = (0..<7).map { HermesSessionRow(id: "job-\($0)", title: "Job \($0)", lastActive: Double($0), profile: "default", source: "cron") }
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: rows, total: 207)],
                               "research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "research-job", source: "cron")], total: 1)]]
        wire.pages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "ordinary")])]]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        let groups = list.scheduledSessionGroups(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(groups.ordinary.map(\.sessionId), ["ordinary"])
        XCTAssertEqual(groups.scheduledPreview.compactMap(\.sessionId), ["job-6", "job-5", "job-4", "job-3", "job-2"])
        XCTAssertEqual(groups.totalScheduledCount, 207, "Badge includes unread pages")
        XCTAssertTrue(groups.showsDisclosure(isSearchActive: false))
        await list.selectHermesProfile("research")
        XCTAssertEqual(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).scheduled.compactMap(\.sessionId), ["research-job"])
        XCTAssertEqual(wire.scheduledReads.map(\.profile), ["default", "research"])
        await list.selectHermesProfile("empty")
        XCTAssertFalse(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).showsDisclosure(isSearchActive: false))
    }

    func testScheduledContentSearchIsSeparateFromOrdinaryMatches() async throws {
        let wire = HermesSessionListWire()
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "loaded-job", title: "Other", source: "cron")], total: 1)]]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "ordinary", title: "Other"), snippet: ">>>needle<<<", role: "user")]
        wire.scheduledResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "past-page-job", title: "Other", source: "cron"), snippet: ">>>needle<<<", role: "user"),
                                 HermesSessionSearchResult(row: HermesSessionRow(id: "archived-job", archived: true, source: "cron"))]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        await list.searchSessions(query: "needle", debounceNanoseconds: 0)
        let groups = list.scheduledSessionGroups(searchText: "needle", selectedProjectID: nil)
        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["ordinary"])
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), ["past-page-job"])
        XCTAssertEqual(wire.scheduledSearches.map(\.query), ["needle"])
        var cronHidden = AutomatedSessionVisibility.showAll
        cronHidden.showsCron = false
        let hidden = list.scheduledSessionGroups(searchText: "needle", selectedProjectID: nil, automatedVisibility: cronHidden)
        XCTAssertEqual(hidden.ordinary.compactMap(\.sessionId), ["ordinary"])
        XCTAssertTrue(hidden.scheduled.isEmpty)
    }

    func testScheduledPagesLoadIndependentlyAndKeepTotalCount() async throws {
        let wire = HermesSessionListWire()
        let first = (0..<100).map { HermesSessionRow(id: "job-\($0)", lastActive: Double(200 - $0), source: "cron") }
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: first, total: 107),
                                         100: HermesSessionPage(rows: [HermesSessionRow(id: "last-job", source: "cron")], total: 107)]]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        XCTAssertTrue(list.hasMoreScheduledSessions)
        XCTAssertFalse(list.hasMoreSessions)
        await list.loadMoreHermesScheduledSessions()
        XCTAssertEqual(wire.scheduledReads.map(\.offset), [0, 100])
        XCTAssertFalse(list.hasMoreScheduledSessions)
        XCTAssertEqual(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).totalScheduledCount, 107)
        XCTAssertEqual(list.sessions.count, 101)
    }

    func testAFailedListReadDuringScheduledLoadMoreLeavesItUsable() async throws {
        let wire = HermesSessionListWire()
        let first = (0..<100).map { HermesSessionRow(id: "job-\($0)", lastActive: Double(200 - $0), source: "cron") }
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: first, total: 101),
                                         100: HermesSessionPage(rows: [HermesSessionRow(id: "last-job", source: "cron")], total: 101)]]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()

        wire.holdsScheduledPages = true
        let more = Task { await list.loadMoreHermesScheduledSessions() }
        await waitUntil("scheduled page parked") { wire.scheduledReads.count == 2 }
        wire.pageFailure = .rejected(500)
        wire.emit("sessions.changed")
        await waitUntil("list read failed") { list.errorMessage != nil }
        wire.holdsScheduledPages = false
        wire.release()
        await more.value

        XCTAssertFalse(list.isLoadingMoreScheduledSessions, "the failed read let go of the scheduled Load more")
        let earlierReads = wire.scheduledReads.count
        await list.loadMoreHermesScheduledSessions()
        XCTAssertEqual(wire.scheduledReads.dropFirst(earlierReads).map(\.offset), [100])
        XCTAssertTrue(list.sessions.contains { $0.sessionId == "last-job" })
        XCTAssertFalse(list.hasMoreScheduledSessions)
    }

    func testARefusedScheduledLoadMoreClearsOnceARetryLoads() async {
        let wire = HermesSessionListWire()
        wire.scheduledPages = ["default": [0: page(rows(0..<100)), 100: page(rows(100..<101))]]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()

        wire.pageFailure = .rejected(403)
        await list.loadMoreHermesScheduledSessions()
        XCTAssertNotNil(list.hermesRefusalOverRows)
        await list.loadMoreHermesScheduledSessions()
        XCTAssertNil(list.hermesRefusalOverRows, "the loaded page answers the refusal")
    }

    func testScheduledSearchRequestAndOrdinaryRequestsKeepSeparateSourceScopes() throws {
        let calls: [HermesREST] = [.sessionList(profile: "default", offset: 0, scheduled: true),
                                  .sessionList(profile: "default", offset: 100, scheduled: true),
                                  .sessionSearch(query: "sapphire", profile: "research", limit: 100, scheduled: true),
                                  .sessionList(profile: "default", offset: 0),
                                  .sessionSearch(query: "sapphire", profile: "default", limit: 100)]
        for (index, call) in calls.enumerated() {
            let url = try XCTUnwrap(try call.request(base: server).url)
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["sources"], index < 3 ? "cron" : nil)
            XCTAssertEqual(query["exclude_sources"], index < 3 ? "kanban,oneshot,subagent,tool" : "cron,kanban,oneshot,subagent,tool")
            if index == 2 { XCTAssertEqual(query["profile"], "research"); XCTAssertEqual(query["q"], "sapphire") }
            if index == 1 { XCTAssertEqual(query["offset"], "100"); XCTAssertEqual(query["archived"], "exclude") }
        }
    }

    func testScheduledSourceIsDecodedWithoutRelyingOnAnIDPrefix() throws {
        let row = try JSONDecoder().decode(HermesSessionRow.self, from: Data(#"{"id":"20261014_job","source":"cron","profile":"research"}"#.utf8))
        XCTAssertTrue(row.summary(in: "research").isCronSession)
        let search = try JSONDecoder().decode(HermesSessionSearch.self, from: Data(#"{"results":[{"session_id":"20261014_job","source":"cron","profile":"research"}]}"#.utf8))
        XCTAssertTrue(try XCTUnwrap(search.results.first).row.summary(in: "research").isCronSession)
    }

    func testArchivingAScheduledRowLeavesTheSectionAndItsCount() async throws {
        let wire = HermesSessionListWire()
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "job-a", lastActive: 2, source: "cron"),
                                                                       HermesSessionRow(id: "job-b", lastActive: 1, source: "cron")], total: 2)]]
        wire.pages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "ordinary")])]]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        let job = try XCTUnwrap(list.sessions.first { $0.sessionId == "job-a" })

        let archived = await list.archive(job)

        XCTAssertTrue(archived)
        XCTAssertEqual(wire.changes, [.archived(true)])
        let groups = list.scheduledSessionGroups(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(groups.scheduled.compactMap(\.sessionId), ["job-b"])
        XCTAssertEqual(groups.totalScheduledCount, 1)
        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["ordinary"])
    }

    func testPagesLoadInTurnAndAShortPageEndsTheList() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)

        await list.openHermes()
        XCTAssertTrue(list.hasMoreSessions)
        await list.loadMoreHermesSessions()
        await list.loadMoreHermesSessions()

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    func testPinnedBackFillShowsOnceAndArchivedPinnedRowsNever() async {
        let wire = HermesSessionListWire()
        let pinned = HermesSessionRow(id: "pinned", lastActive: 1, pinned: true)
        let archived = HermesSessionRow(id: "archived", lastActive: 2, pinned: true, archived: true)
        wire.pages["default"] = [0: page(rows(0..<100) + [pinned, archived]),
                                 100: page([pinned, archived] + rows(100..<110))]
        let list = makeList(wire)

        await list.openHermes()
        await list.loadMoreHermesSessions()

        let shown = list.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId)
        XCTAssertEqual(shown.count, 111)
        XCTAssertEqual(shown.first, "pinned")
        XCTAssertEqual(shown.filter { $0 == "pinned" }.count, 1)
        XCTAssertFalse(shown.contains("archived"))
    }

    func testAListReadDuringLoadMoreReadsThatPageItself() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<130))]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        let more = Task { await list.loadMoreHermesSessions() }
        await waitUntil("next page parked") { wire.pageReads.count == 2 }
        wire.emit("sessions.changed")
        await waitUntil("list read parked") { wire.pageReads.count == 3 }
        XCTAssertTrue(list.isLoadingMoreSessions, "the next page is still on its way")
        wire.holdsPages = false
        wire.release()
        await more.value
        await waitUntil("both pages applied") { !list.isLoadingMoreSessions }

        XCTAssertEqual(wire.pageReads.map(\.offset), [0, 100, 0, 100])
        XCTAssertEqual(list.sessions.count, 130)
        XCTAssertFalse(list.hasMoreSessions)
    }

    func testMovingBetweenTheListAndViewAllKeepsLiveUpdates() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        var covers = HermesSessionListCovers()

        covers.showingScheduled = true
        await list.openHermes()
        covers.listDisappeared(list)
        var reads = wire.pageReads.count
        wire.emit("sessions.changed")
        await waitUntil("View all read the change") { wire.pageReads.count > reads }

        covers.showingScheduled = false
        await list.openHermes()
        covers.scheduledDisappeared(list)
        reads = wire.pageReads.count
        wire.emit("sessions.changed")
        await waitUntil("the list read the change") { wire.pageReads.count > reads }

        covers.showingScheduled = true
        await list.openHermes()
        covers.listDisappeared(list)
        covers.chat = HermesSessionChat(server: server, connection: connection, target: .session(profile: "default", key: "a"))
        covers.scheduledDisappeared(list)
        XCTAssertTrue(list.isHermesConnected)
    }

    func testForegroundReopensOnlyAListWhoseRowsAreShowing() {
        var covers = HermesSessionListCovers()
        covers.showingScheduled = true
        XCTAssertTrue(covers.reopensOnForeground(usesSplit: false), "View all on a phone")

        covers.chat = HermesSessionChat(server: server, connection: connection, target: .session(profile: "default", key: "a"))
        XCTAssertFalse(covers.reopensOnForeground(usesSplit: false), "a chat over View all")
        XCTAssertTrue(covers.reopensOnForeground(usesSplit: true), "a split's sidebar beside the chat")

        covers = HermesSessionListCovers()
        covers.showingArchived = true
        XCTAssertFalse(covers.reopensOnForeground(usesSplit: false), "another screen over the list")
    }

    func testTitlesAndPreviewsDropAttachmentReferences() {
        let image = "[The user attached an image: dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let examine = "[Examine it with the vision_analyze tool using image_url: /h/.hermes/images/dashboard_20261005_120000_0123abcd_IMG_2041.jpg]"
        let rows: [(text: String, shown: String?)] = [
            (image + "\n" + examine, "IMG_2041.jpg"),
            (image + " " + examine, "IMG_2041.jpg"),
            ("[The user attached an image: dashboard_20261005_120000_0123a...", nil),
            ("[The user attached an image…", nil),
            ("What breed is this?\n\n" + image + "\n" + examine, "What breed is this?"),
            ("What breed is this?  [The user attached an image: dashboard_202...", "What breed is this?"),
            ("@file:`/Users/someone/.hermes/attachments/1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed-report.pdf`", "report.pdf"),
            ("Summarize report.pdf @file:`/Users/someone/.hermes/attach...", "Summarize report.pdf"),
            ("Plan the launch for the new pricing page and draft the e...", "Plan the launch for the new pricing page and draft the e..."),
            ("Email bob@example.com about [the plan]", "Email bob@example.com about [the plan]"),
            ("What is this?  [Image attached at: /private/var/folders/sk/6...", "What is this?"),
            ("What do you see in this image?  [Image attached at: /h/.hermes/cache/documents/native-inputs/3f/"
                + "dashboard_20261111_194223_195f8b19_cat.png] [screenshot]", "cat.png"),
            ("[The user sent an image~ Here's what I can see: A small red square on a white...", nil)
        ]
        for row in rows {
            XCTAssertEqual(MessageAttachment.hermesTitle(row.text), row.shown, row.text)
        }

        let untitled = HermesSessionRow(id: "a", preview: "What breed is this?  [The user attached an image: dashb...")
        XCTAssertEqual(SessionRowView.displayTitle(for: untitled.summary(in: "default")), "What breed is this?")
        let photoOnly = HermesSessionRow(id: "b", title: "[The user attached an image…",
                                         preview: "[The user attached an image: dashboard_20261005_120000_0123a...")
        XCTAssertEqual(SessionRowView.displayTitle(for: photoOnly.summary(in: "default")), "Untitled Session")
    }

    func testOpeningARowMarksItReadAndARefusedWriteShowsItUnreadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true, profile: "default")])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)
        XCTAssertTrue(list.isUnread(row))

        wire.holdsUnread = true
        wire.unreadFails = true
        list.beginViewing(row)
        XCTAssertFalse(list.isUnread(row), "the dot clears before the host answers")
        await waitUntil("write sent") { wire.unreadWrites.count == 1 }
        XCTAssertEqual(wire.unreadWrites.first, .init(key: "a", profile: "default", unread: false))
        wire.release()
        await waitUntil("rolled back") { list.isUnread(row) }
    }

    func testASessionsMarksReachTheHostInTheOrderTheyWereMade() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false)])]
        let list = makeList(wire)
        await list.openHermes()
        let row = try XCTUnwrap(list.sessions.first)

        wire.holdsUnread = true
        list.toggleUnread(row)
        await waitUntil("unread mark sent") { wire.unreadWrites.count == 1 }
        list.beginViewing(row)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(wire.unreadWrites.count, 1, "the read mark waits while the unread mark is out")
        XCTAssertFalse(list.isUnread(row), "the newer mark shows at once")

        wire.holdsUnread = false
        wire.release()
        await waitUntil("read mark sent") { wire.unreadWrites.count == 2 }
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [true, false])
        XCTAssertFalse(list.isUnread(row))
    }

    func testReturningFromAChatMarksItReadAgain() async throws {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: false), HermesSessionRow(id: "b", unread: true)])]
        let list = makeList(wire)
        await list.openHermes()
        list.beginViewing(try XCTUnwrap(list.sessions.first { $0.sessionId == "a" }))
        list.pauseHermes()
        await waitUntil("open write") { wire.unreadWrites.count == 1 }

        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", unread: true), HermesSessionRow(id: "b", unread: true)])]
        list.noteHermesReturn(from: "a")
        await list.openHermes()
        await waitUntil("marked read again") { wire.unreadWrites.count == 2 }

        XCTAssertEqual(wire.unreadWrites.map(\.key), ["a", "a"])
        XCTAssertEqual(wire.unreadWrites.map(\.unread), [false, false])
        XCTAssertEqual(list.sessions.map { list.isUnread($0) }, [false, true])
    }

    func testLiveStatesMarkListedRowsBySessionKey() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(["a", "b", "c"].map { HermesSessionRow(id: $0) })]
        wire.active = [live("a", "streaming"), live("b", "waiting"), live("b", "working"), live("c", "idle"),
                       live("elsewhere", "working")]
        let list = makeList(wire)

        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working, "b": .input])
    }

    func testWaitingRowsTellApprovalFromInput() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(["approve", "ask", "work"].map { HermesSessionRow(id: $0) })]
        wire.active = [live("approve", "waiting"), live("ask", "waiting"), live("work", "working")]
        wire.approvals["runtime-approve"] = [.object(["request_id": .string("r1")])]
        wire.holdsApprovals = true
        let list = makeList(wire)
        defer { list.closeHermes() }

        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }
        XCTAssertEqual(list.attentionStatesBySessionID, ["approve": .input, "ask": .input, "work": .working])

        wire.holdsApprovals = false
        wire.release()
        await waitUntil("approvals read") { list.attentionStatesBySessionID["approve"] == .approval }
        XCTAssertEqual(list.attentionStatesBySessionID, ["approve": .approval, "ask": .input, "work": .working])
        XCTAssertEqual(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).needsYou.compactMap(\.sessionId),
                       ["approve", "ask"])

        wire.active = [live("approve", "waiting"), live("approve", "waiting", runtime: "runtime-approve-2"),
                       live("ask", "waiting"), live("work", "working")]
        wire.approvals = ["runtime-ask": [.object(["request_id": .string("r2")])]]
        wire.failingApprovals = ["runtime-approve-2"]
        wire.emit("sessions.changed")
        await waitUntil("approvals read again") { list.attentionStatesBySessionID["ask"] == .approval }
        XCTAssertEqual(list.attentionStatesBySessionID["approve"], .approval)
    }

    func testTheArchivedRowCountsTheListedProfile() async {
        let wire = HermesSessionListWire()
        wire.archivedTotals = ["default": 3, "research": 5]
        wire.holdsProjects = ["default"]
        wire.holdsArchivedCount = true
        let list = makeList(wire)
        defer { list.closeHermes() }

        let open = Task { await list.openHermes() }
        await waitUntil("default's lanes held") { wire.calls.contains { $0.method == "projects.tree" } }
        await list.selectHermesProfile("research")
        wire.pages["research"] = [0: page([HermesSessionRow(id: "new")])]
        wire.emit("sessions.changed")
        await waitUntil("the change read past the held count") { list.sessions.map(\.sessionId) == ["new"] }
        wire.releaseProjects()
        await open.value
        XCTAssertNil(list.archivedCount)

        wire.holdsArchivedCount = false
        wire.release()
        await waitUntil("count read") { list.archivedCount != nil }
        XCTAssertEqual(list.archivedCount, 5)

        await list.showAllHermesProfiles()
        XCTAssertNil(list.archivedCount)
    }

    func testBackgroundWorkKeepsAnEndedTurnWorking() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([
            HermesSessionRow(id: "delegating"), HermesSessionRow(id: "tip", lineageRootID: "root"),
            HermesSessionRow(id: "approve"), HermesSessionRow(id: "done"), HermesSessionRow(id: "plain")
        ])]
        wire.active = [live("delegating", "idle"), live("approve", "waiting")]
        wire.approvals["runtime-approve"] = [.object(["request_id": .string("r1")])]
        wire.roster["default"] = [rosterEntry("delegating", subagents: 2), rosterEntry("root", background: 1),
                                  rosterEntry("approve", subagents: 1), rosterEntry("done"),
                                  rosterEntry("elsewhere", subagents: 1)]
        let list = makeList(wire)
        defer { list.closeHermes() }
        func state(_ id: String) -> SessionRowAttentionState? {
            list.sessions.first { $0.sessionId == id }.flatMap { list.attentionState(for: $0) }
        }

        await list.openHermes()
        await waitUntil("roster read") { state("delegating") == .working && state("approve") == .approval }
        XCTAssertEqual(state("tip"), .working, "matched by its lineage root")
        XCTAssertNil(state("done"))
        XCTAssertNil(state("plain"))
        XCTAssertEqual(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).needsYou.compactMap(\.sessionId),
                       ["approve"])

        wire.roster["default"] = []
        wire.emit("sessions.changed")
        await waitUntil("work ended") { state("delegating") == nil }
        XCTAssertNil(state("tip"))
        XCTAssertEqual(state("approve"), .approval)
    }

    func testBackgroundWorkMarksARowLoadMoreBringsIn() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page(rows(0..<100)), 100: page(rows(100..<101))]
        wire.roster["default"] = [rosterEntry("s0", subagents: 1), rosterEntry("s100", background: 1)]
        let list = makeList(wire)
        defer { list.closeHermes() }
        func state(_ id: String) -> SessionRowAttentionState? {
            list.sessions.first { $0.sessionId == id }.flatMap { list.attentionState(for: $0) }
        }

        await list.openHermes()
        await waitUntil("roster read") { state("s0") == .working }
        await list.loadMoreHermesSessions()

        XCTAssertEqual(state("s100"), .working)
        XCTAssertEqual(wire.calls.filter { $0.method == "subagent.roster" }.count, 1)
    }

    func testTheRosterIsReadOncePerListRead() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        wire.active = [live("a", "working")]
        wire.holdsActive = true
        let list = makeList(wire, statusPollInterval: .zero)
        defer { list.closeHermes(); wire.holdsActive = false; wire.release() }
        func count(_ method: String) -> Int { wire.calls.filter { $0.method == method }.count }

        await list.openHermes()
        for tick in 1...3 {
            await waitUntil("status read \(tick)") { count("session.active_list") == tick }
            wire.release()
        }
        await waitUntil("status re-read") { count("session.active_list") == 4 }
        XCTAssertEqual(count("subagent.roster"), 1)

        wire.emit("sessions.changed")
        await waitUntil("list read again") { count("subagent.roster") == 2 }
    }

    func testAHostWithoutTheRosterShowsOnlyTheActiveListStates() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a"), HermesSessionRow(id: "b")])]
        wire.active = [live("a", "working"), live("b", "idle")]
        wire.roster["default"] = [rosterEntry("b", background: 1)]
        let list = makeList(wire)
        defer { list.closeHermes() }
        func state(_ id: String) -> SessionRowAttentionState? {
            list.sessions.first { $0.sessionId == id }.flatMap { list.attentionState(for: $0) }
        }
        func count(_ method: String) -> Int { wire.calls.filter { $0.method == method }.count }

        await list.openHermes()
        await waitUntil("roster read") { state("b") == .working }

        wire.lacksRoster = true
        wire.emit("sessions.changed")
        await waitUntil("roster refused") { state("b") == nil }
        XCTAssertEqual(state("a"), .working)
        XCTAssertEqual(count("subagent.roster"), 2)

        wire.emit("sessions.changed")
        await waitUntil("list read again") { count("session.active_list") == 3 }
        XCTAssertEqual(count("subagent.roster"), 2)
        XCTAssertNil(state("b"))
    }

    func testHostIdleCheckReadsTheHostFresh() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire)
        let notLive = await list.hermesHostIsIdle()
        XCTAssertNil(notLive)

        await list.openHermes()
        wire.active = [live("a", "idle")]
        let idle = await list.hermesHostIsIdle()
        XCTAssertEqual(idle, true)
        wire.active = [live("elsewhere", "working")]
        let busy = await list.hermesHostIsIdle()
        XCTAssertEqual(busy, false)
        wire.active = [live("a", "paused")]
        let unknown = await list.hermesHostIsIdle()
        XCTAssertEqual(unknown, false, "a status the app doesn't know is not idle")
    }

    func testWaitingRowsLiftIntoNeedsYouUntilAnswered() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([
            HermesSessionRow(id: "pinned-idle", title: "Row", lastActive: 1, pinned: true),
            HermesSessionRow(id: "pinned-waiting", title: "Row", lastActive: 2, pinned: true),
            HermesSessionRow(id: "working", title: "Row", lastActive: 5),
            HermesSessionRow(id: "waiting", title: "Row", lastActive: 4),
            HermesSessionRow(id: "idle", title: "Row", lastActive: 3)
        ])]
        wire.scheduledPages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "job", source: "cron")], total: 1)]]
        wire.projectTree = .object(["projects": .array([.object([
            "id": .string("p_1"), "label": .string("Launch"), "path": .string("/launch"), "isAuto": .bool(false),
            "isNoProject": .bool(false), "sessionCount": .number(2), "sessionIds": .array([.string("waiting"), .string("idle")])
        ])])])
        wire.active = [live("pinned-waiting", "waiting"), live("working", "working"), live("waiting", "waiting"), live("job", "waiting")]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }
        func ids(_ rows: [SessionSummary]) -> [String] { rows.compactMap(\.sessionId) }

        let groups = list.scheduledSessionGroups(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(ids(groups.needsYou), ["pinned-waiting", "waiting"])
        XCTAssertEqual(ids(groups.ordinary), ["pinned-idle", "working", "idle"])
        XCTAssertEqual(ids(list.scheduledSessionGroups(searchText: "", selectedProjectID: "p_1").needsYou), ["waiting"])
        XCTAssertEqual(list.scheduledSessionGroups(searchText: "row", selectedProjectID: nil).needsYou, [], "a search keeps list order")

        wire.active = [live("working", "working")]
        wire.emit("sessions.changed")
        await waitUntil("answered") { list.attentionStatesBySessionID["waiting"] == nil }
        XCTAssertEqual(ids(list.scheduledSessionGroups(searchText: "", selectedProjectID: nil).ordinary),
                       ["pinned-waiting", "pinned-idle", "working", "waiting", "idle"])
    }

    func testHidingCliAndMessagingSessionsDropsChippedRows() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([
            HermesSessionRow(id: "cli", title: "Row", lastActive: 3, source: "cli"),
            HermesSessionRow(id: "telegram", title: "Row", lastActive: 2, source: "telegram"),
            HermesSessionRow(id: "hermex", title: "Row", lastActive: 1, source: "gui")
        ])]
        wire.active = [live("telegram", "waiting")]
        let list = makeList(wire)
        defer { list.closeHermes() }
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }
        var hidden = AutomatedSessionVisibility.showAll
        hidden.showsCli = false

        let groups = list.scheduledSessionGroups(searchText: "", selectedProjectID: nil, automatedVisibility: hidden)

        XCTAssertEqual(groups.needsYou, [])
        XCTAssertEqual(groups.ordinary.compactMap(\.sessionId), ["hermex"])
    }

    func testSessionsChangedBurstsReadOnceAndQueueOneMore() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "First")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        for _ in 0..<3 { wire.emit("sessions.changed") }
        await waitUntil("burst read parked") { wire.pageReads.count == 2 }
        for _ in 0..<3 { wire.emit("sessions.changed") }
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Latest")])]
        wire.holdsPages = false
        wire.release()
        await waitUntil("trailing read applied") { list.sessions.first?.title == "Latest" }

        XCTAssertEqual(wire.pageReads.count, 3, "open, the burst's read and exactly one more")
    }

    func testOnlyTheNewestReadApplies() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsPages = true
        wire.emit("sessions.changed")
        await waitUntil("stale read parked") { wire.pageReads.count == 2 }
        wire.holdsPages = false
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        XCTAssertEqual(list.sessions.first?.title, "New")

        wire.release()
        await waitUntil("stale read answered") { wire.answeredPages == 3 }
        XCTAssertEqual(list.sessions.first?.title, "New")
    }

    func testOnlyALostSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.onDisconnect?(BotFailure.transport)
        await waitUntil("reconnected") { wire.connects == 2 }
        XCTAssertNil(list.sessionLoadError)

        wire.onDisconnect?(BotFailure.outdated("0.20.0"))
        XCTAssertFalse(list.isHermesConnected)
        XCTAssertEqual(list.sessionLoadError as? BotFailure, .outdated("0.20.0"))
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a"], "the rows stay")
    }

    func testALostSocketKeepsTheLastKnownStatesUntilTheHostAnswersAgain() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        wire.active = [live("a", "working")]
        let list = makeList(wire)
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        wire.onDisconnect?(BotFailure.transport)
        XCTAssertTrue(list.isHermesReconnecting)
        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working], "the last known states stay")
        XCTAssertTrue(list.attentionStatesAreStale)

        wire.holdsActive = true
        wire.active = [live("a", "waiting")]
        list.reconnectNow()
        await waitUntil("rows read") { wire.connects == 2 && !list.isHermesReconnecting }
        XCTAssertTrue(list.attentionStatesAreStale, "rows vouch for no run")
        wire.holdsActive = false
        wire.release()
        await waitUntil("states read") { !list.attentionStatesAreStale }
        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .input])

        wire.onDisconnect?(BotFailure.outdated("0.20.0"))
        XCTAssertEqual(list.attentionStatesBySessionID, [:], "a refusal leaves nothing to reconnect to")
    }

    func testAFailedReadAfterAReconnectRecoversAsALostSocket() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        wire.active = [live("a", "working")]
        let list = makeList(wire)
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        wire.onDisconnect?(BotFailure.transport)
        wire.pageFailure = .rejected(503)
        list.reconnectNow()
        await waitUntil("the read failed") { wire.connects == 2 && wire.closes == 2 }
        XCTAssertTrue(list.isHermesReconnecting)

        wire.pageFailure = .rejected(403)
        list.reconnectNow()
        await waitUntil("reconnected and refused") { wire.connects == 3 && !list.isHermesReconnecting }
        XCTAssertEqual(list.attentionStatesBySessionID, [:])
        XCTAssertNotNil(list.hermesRefusalOverRows, "the refusal shows over the rows")
    }

    func testAnOfflinePathMarksTheStatesStaleBeforeTheSocketDrops() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        wire.active = [live("a", "working")]
        var online = true
        let list = makeList(wire, isNetworkAvailable: { online })
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        online = false
        list.networkPathDidChange()
        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working])
        XCTAssertTrue(list.attentionStatesAreStale)
        XCTAssertEqual(HomeConnectionStatus(list.hermesConnection, isOnline: false), .offline)
    }

    func testALostListReconnectsAtOnceWhenTheNetworkReturns() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        var online = true
        let list = makeList(wire, isNetworkAvailable: { online })
        await list.openHermes()

        wire.onDisconnect?(BotFailure.transport)
        online = false
        list.networkPathDidChange()
        online = true
        list.networkPathDidChange()
        await waitUntil("reconnected") { wire.connects == 2 }

        online = false
        wire.onDisconnect?(BotFailure.transport)
        list.pauseHermes()
        online = true
        list.networkPathDidChange()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(wire.connects, 2, "a list a chat covers stays down")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["a"], "the rows stay")
    }

    func testAClientThatLeftTheSocketReconnects() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "Old")])]
        let list = makeList(wire, reconnectDelays: [.zero])
        await list.openHermes()

        wire.pageFailure = .stale
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a", title: "New")])]
        await list.openHermes()
        await waitUntil("reconnected and read") { list.sessions.first?.title == "New" }

        XCTAssertEqual(wire.connects, 2)
    }

    func testSwitchingProfileListsItsSessionsAndSavesThePick() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d")])], "research": [0: page([HermesSessionRow(id: "r")])]]
        let list = makeList(wire)
        await list.openHermes()
        XCTAssertEqual(list.hermesProfiles, ["default", "research"])

        await list.selectHermesProfile("research")

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertEqual(wire.calls.last { $0.method == "session.most_recent" }?.profile, "research",
                       "the host watches the new Profile's store")
        XCTAssertEqual(defaults.string(forKey: HermesProfilePreference.key(for: server)), "research",
                       "the composer's Profile chip shares the pick")
    }

    func testARemovedProfileMovesToTheHostsCurrentProfile() async {
        let wire = HermesSessionListWire()
        wire.removed = ["gone"]
        wire.current = "research"
        wire.pages = ["research": [0: page([HermesSessionRow(id: "r")])]]
        HermesProfilePreference.save("gone", for: server, in: defaults)
        let list = makeList(wire, profile: "gone")

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertNil(list.errorMessage)
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)))
    }

    func testAllProfilesListsEveryProfileUntilOneIsPicked() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d", lastActive: 1)])],
                      "research": [0: page([HermesSessionRow(id: "r", lastActive: 2)])]]
        let list = makeList(wire)
        await list.openHermes()

        await list.showAllHermesProfiles()

        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map { "\($0.sessionId!)@\($0.profile!)" },
                       ["r@research", "d@default"])
        XCTAssertEqual(Set(wire.calls.filter { $0.method == "session.most_recent" }.compactMap(\.profile)), ["default", "research"])
        XCTAssertTrue(HermesProfilePreference.showsAllProfiles(for: server, in: defaults))
        XCTAssertEqual(list.hermesProfile, "default", "New Session still opens in the pick")

        await list.selectHermesProfile("research")

        XCTAssertFalse(list.hermesShowsAllProfiles)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertFalse(HermesProfilePreference.showsAllProfiles(for: server, in: defaults))
    }

    func testNewSessionStartsInTheSelectedLanesFolderUntilAllProfiles() async {
        let wire = HermesSessionListWire()
        wire.projectTree = .object(["projects": .array([.object([
            "id": .string("p_1"), "label": .string("Launch"), "path": .string("/launch"), "isAuto": .bool(false),
            "isNoProject": .bool(false), "sessionCount": .number(0), "sessionIds": .array([])
        ])])])
        let list = makeList(wire)
        await list.openHermes()

        XCTAssertEqual(list.hermesNewSessionFolder(lane: "p_1"), "/launch")
        XCTAssertNil(list.hermesNewSessionFolder(lane: nil))

        await list.showAllHermesProfiles()

        XCTAssertNil(list.hermesNewSessionFolder(lane: "p_1"))
    }

    func testAllProfilesHoldsBackOlderRowsUntilTheNextPagesAreIn() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page(rows(0..<100)), 100: page(rows(100..<110))],
                      "research": [0: page([HermesSessionRow(id: "new", lastActive: 20_000),
                                            HermesSessionRow(id: "old", lastActive: 1),
                                            HermesSessionRow(id: "pinned", lastActive: 0, pinned: true)])]]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)

        await list.openHermes()

        var shown = Set(list.sessions.compactMap(\.sessionId))
        XCTAssertTrue(shown.isSuperset(of: ["new", "pinned"]))
        XCTAssertFalse(shown.contains("old"), "the default Profile's next page may hold newer rows")
        XCTAssertEqual(shown.count, 102)
        XCTAssertTrue(list.hasMoreSessions)

        await list.loadMoreHermesSessions()

        shown = Set(list.sessions.compactMap(\.sessionId))
        XCTAssertTrue(shown.contains("old"))
        XCTAssertEqual(shown.count, 113)
        XCTAssertFalse(list.hasMoreSessions)
        XCTAssertEqual(wire.pageReads.filter { $0.profile == "research" }.map(\.offset), [0])
    }

    func testRefreshingAllProfilesListsAProfileAddedElsewhere() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([HermesSessionRow(id: "d", lastActive: 1)])],
                      "research": [0: page([])], "ops": [0: page([HermesSessionRow(id: "o", lastActive: 3)])]]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)
        await list.openHermes()
        XCTAssertEqual(list.sessions.map(\.sessionId), ["d"])

        wire.profiles = ["default", "research", "ops"]
        await list.refreshHermes()

        XCTAssertEqual(Set(list.sessions.compactMap(\.sessionId)), ["d", "o"])
        XCTAssertEqual(wire.calls.last { $0.method == "session.most_recent" && $0.profile == "ops" }?.profile, "ops")
    }

    func testAllProfilesMovesOffAPickTheHostNoLongerHas() async {
        let wire = HermesSessionListWire()
        wire.current = "research"
        wire.pages = ["default": [0: page([])], "research": [0: page([])]]
        HermesProfilePreference.save("gone", for: server, in: defaults)
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire, profile: "gone")

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)))
        XCTAssertTrue(list.hermesShowsAllProfiles)
    }

    func testAListWithoutAProfileOpensOnTheHostsCurrentProfile() async {
        let wire = HermesSessionListWire()
        wire.current = "research"
        wire.pages = ["research": [0: page([HermesSessionRow(id: "r")])]]
        let list = makeList(wire, profile: nil)

        await list.openHermes()

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
    }

    func testAllProfilesSearchesEveryProfile() async {
        let wire = HermesSessionListWire()
        wire.pages = ["default": [0: page([])], "research": [0: page([])]]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "far", title: "Nimbus plan"))]
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let list = makeList(wire)
        await list.openHermes()

        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)

        XCTAssertEqual(wire.searches.map(\.profile).sorted(), ["default", "research"])
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["far"])
    }

    func testANewChatWaitsAgainAfterTheListLosesTheHost() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire)
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        let request = HermesNewChatDestination(server: server, profile: "research")
        let chat = { request.chat(on: entry, listed: list.hermesProfile, isLive: list.isHermesLive) }
        await list.openHermes()
        XCTAssertTrue(list.isHermesLive)

        list.closeHermes()
        XCTAssertFalse(list.isHermesLive)
        XCTAssertNil(chat(), "Held once the list closes its connection")
        await list.openHermes()
        XCTAssertEqual(chat()?.target, .new(profile: "research"))

        wire.onDisconnect?(BotFailure.transport)
        XCTAssertFalse(list.isHermesLive)
        XCTAssertNil(chat(), "Held once the list's socket drops")
        await list.openHermes()
        XCTAssertEqual(chat()?.target, .new(profile: "research"))
    }

    func testAHeldNewChatOverACachedChatOpensAfterTheListReadsAgain() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        wire.connectFailure = BotFailure.transport
        let list = makeList(wire)
        await list.openHermes()
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        var covers = HermesSessionListCovers()
        covers.chat = HermesSessionChat(server: server, connection: connection, target: .session(profile: "default", key: "a"))
        list.pauseHermes()
        let request = HermesNewChatDestination(server: server, profile: "research")

        XCTAssertFalse(covers.open(request, on: entry, listed: list.hermesProfile, isLive: list.isHermesLive))
        XCTAssertNil(covers.chat, "The cached chat closes before the list is live")

        wire.connectFailure = nil
        await list.openHermes()
        XCTAssertTrue(covers.open(request, on: entry, listed: list.hermesProfile, isLive: list.isHermesLive))
        XCTAssertEqual(covers.chat?.target, .new(profile: "research"))
    }

    func testAShareOverAChatTheBackgroundClosedOpensAfterTheListReadsAgain() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire)
        await list.openHermes()
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        var covers = HermesSessionListCovers()
        covers.chat = HermesSessionChat(server: server, connection: connection, target: .new(profile: "default"))
        list.pauseHermes()
        list.closeHermes()
        let share = SharedImportReservation(itemID: "item", reservationID: "reservation", createdAt: Date(),
                                            sharedImport: SharedImport(draft: "Read this", attachments: []))

        XCTAssertNil(covers.open(share, on: entry, listed: list.hermesProfile, isLive: list.isHermesLive))
        XCTAssertNil(covers.chat, "The covering chat closes before the list is live")

        await list.openHermes()
        guard case .chat(let chat)? = covers.open(share, on: entry, listed: list.hermesProfile,
                                                   isLive: list.isHermesLive) else {
            return XCTFail("The share opens a new session once the list reads the host")
        }
        XCTAssertEqual(chat.target, .new(profile: "default"))
    }

    func testAShortcutsProfileDeletedWhileAChatCoveredTheListIsReportedMissing() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([HermesSessionRow(id: "a")])]
        let list = makeList(wire)
        await list.openHermes()
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        var covers = HermesSessionListCovers()
        covers.chat = HermesSessionChat(server: server, connection: connection, target: .session(profile: "default", key: "a"))
        list.pauseHermes()
        wire.profiles = ["default"]
        let share = SharedImportReservation(
            itemID: "shortcut-1", reservationID: "reservation", createdAt: Date(),
            sharedImport: SharedImport(draft: "Hi", attachments: [],
                                       shortcut: SharedShortcutDestination(server: server, profile: "research"))
        )

        guard case .chat(let chat)? = covers.open(share, on: entry, listed: list.hermesProfile, isLive: list.isHermesLive) else {
            return XCTFail("The paused list is still live")
        }
        let confirmed = await share.confirmingProfile(of: chat, readProfiles: list.readHostProfiles)
        XCTAssertEqual(confirmed, .missingProfile("research"))
    }

    func testAShortcutTextHeldPastItsLifetimeOpensNoChat() {
        let entry = HermesSessionListEntry(server: server, connection: connection, profile: "default")
        var covers = HermesSessionListCovers()
        let share = SharedImportReservation(
            itemID: "shortcut-1", reservationID: "reservation",
            createdAt: Date().addingTimeInterval(-HermesShareDraft.shortcutTextLifetime - 60),
            sharedImport: SharedImport(draft: "Hi", attachments: [], shortcut: SharedShortcutDestination(server: server, profile: nil))
        )

        XCTAssertEqual(covers.open(share, on: entry, listed: "default", isLive: true), .nothing)
    }

    private func launchLane(sessionIDs: [String]) -> BotJSON {
        .object(["projects": .array([.object([
            "id": .string("p_1"), "label": .string("Launch"), "path": .string("/launch"), "isAuto": .bool(false),
            "isNoProject": .bool(false), "sessionCount": .number(Double(sessionIDs.count)),
            "sessionIds": .array(sessionIDs.map { .string($0) })
        ])])])
    }

    func testTheStatusFiltersKeepOnlyMatchingRowsInTheLane() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page([
            HermesSessionRow(id: "a", lastActive: 5, unread: true), HermesSessionRow(id: "b", lastActive: 4, unread: false),
            HermesSessionRow(id: "c", lastActive: 3, unread: true), HermesSessionRow(id: "tip", lastActive: 2, lineageRootID: "root"),
        ])]
        wire.projectTree = launchLane(sessionIDs: ["a", "b", "tip"])
        wire.active = [live("b", "streaming"), live("c", "streaming")]
        let list = makeList(wire)
        await list.openHermes()
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }
        func ids(_ filter: HermesSessionStatusFilter, drafts: Set<ChatDraftStore.DraftRow> = []) -> [String] {
            list.visibleSessions(searchText: "", selectedProjectID: "p_1", statusFilter: filter, draftRows: drafts)
                .compactMap(\.sessionId)
        }

        XCTAssertEqual(ids(.unread), ["a"], "c is unread but outside the lane")
        XCTAssertEqual(ids(.working), ["b"])
        XCTAssertEqual(ids(.draft, drafts: [.init(profile: "default", key: "root"), .init(profile: "research", key: "a")]), ["tip"])
        XCTAssertEqual(ids(.all), ["a", "b", "tip"])
    }

    func testMarkAllAsReadWritesOnlyTheScopesUnreadRowsAndCountsWhatTheHostTook() async throws {
        let wire = HermesSessionListWire()
        wire.pages = [
            "default": [0: page([
                HermesSessionRow(id: "a", lastActive: 6, unread: true), HermesSessionRow(id: "b", lastActive: 5, unread: true),
                HermesSessionRow(id: "seen", lastActive: 4, unread: false), HermesSessionRow(id: "out", lastActive: 3, unread: true),
            ])],
            "research": [0: page([HermesSessionRow(id: "elsewhere", lastActive: 9, unread: true)])],
        ]
        wire.projectTree = launchLane(sessionIDs: ["a", "b", "seen"])
        wire.failingUnreadKeys = ["b"]
        let list = makeList(wire)
        await list.openHermes()
        let rows = list.unreadRowsInScope(selectedProjectID: "p_1")
        XCTAssertEqual(Set(rows.compactMap(\.sessionId)), ["a", "b"])

        let marked = await list.markAllHermesRead(rows: rows)

        XCTAssertEqual(marked, 1)
        XCTAssertEqual(Set(wire.unreadWrites), [.init(key: "a", profile: "default", unread: false),
                                                .init(key: "b", profile: "default", unread: false)])
        let state = Dictionary(uniqueKeysWithValues: list.sessions.map { ($0.sessionId!, list.isUnread($0)) })
        XCTAssertEqual(state, ["a": false, "b": true, "seen": false, "out": true])
    }

    func testMarkAllAsReadSendsAtMostFourWritesAtOnce() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page((0..<6).map { HermesSessionRow(id: "u\($0)", lastActive: Double(10 - $0), unread: true) })]
        let list = makeList(wire)
        await list.openHermes()
        wire.holdsUnread = true

        let marking = Task { await list.markAllHermesRead(rows: list.unreadRowsInScope(selectedProjectID: nil)) }
        await waitUntil("four writes out") { wire.unreadWrites.count == 4 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(wire.unreadWrites.count, 4)

        wire.holdsUnread = false
        wire.release()
        let marked = await marking.value

        XCTAssertEqual(marked, 6)
        XCTAssertEqual(wire.unreadWrites.count, 6)
    }

    func testMarkAllAsReadIgnoresARepeatWhileItsWritesAreOut() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: page((0..<6).map { HermesSessionRow(id: "u\($0)", lastActive: Double(10 - $0), unread: true) })]
        let list = makeList(wire)
        await list.openHermes()
        wire.holdsUnread = true
        let rows = list.unreadRowsInScope(selectedProjectID: nil)

        let first = Task { await list.markAllHermesRead(rows: rows) }
        await waitUntil("four writes out") { wire.unreadWrites.count == 4 }
        let second = Task { await list.markAllHermesRead(rows: list.unreadRowsInScope(selectedProjectID: nil)) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(wire.unreadWrites.count, 4)

        wire.holdsUnread = false
        wire.release()
        let firstMarked = await first.value
        let secondMarked = await second.value

        XCTAssertEqual(firstMarked, 6)
        XCTAssertEqual(secondMarked, 0)
        XCTAssertEqual(wire.unreadWrites.count, 6, "no row is written twice")
    }

    private func makeList(_ wire: HermesSessionListWire, profile: String? = "default",
                          reconnectDelays: [Duration] = [.seconds(3600)], statusPollInterval: Duration = .seconds(3600),
                          isNetworkAvailable: @escaping @MainActor () -> Bool = { true }) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: profile, makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: statusPollInterval, reconnectDelays: reconnectDelays,
            isNetworkAvailable: isNetworkAvailable
        ))
    }

    private func page(_ rows: [HermesSessionRow]) -> HermesSessionPage { HermesSessionPage(rows: rows) }

    private func rows(_ range: Range<Int>) -> [HermesSessionRow] {
        range.map { HermesSessionRow(id: "s\($0)", lastActive: Double(10_000 - $0)) }
    }

    private func rosterEntry(_ id: String, subagents: Int = 0, background: Int = 0) -> BotJSON {
        .object(["session_id": .string(id), "subagents": .number(Double(subagents)), "background": .number(Double(background))])
    }

    private func live(_ key: String, _ status: String, runtime: String? = nil) -> BotJSON {
        .object(["id": .string(runtime ?? "runtime-" + key), "session_key": .string(key), "status": .string(status),
                 "last_active": .number(100), "started_at": .number(90), "message_count": .number(2),
                 "model": .string("m"), "preview": .string(""), "title": .string(""), "current": .bool(false)])
    }
}

@MainActor final class HermesSessionSearchTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesSessionSearchTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheSearchAsksForTheQueryInTheListedProfile() throws {
        let request = try HermesREST.sessionSearch(query: "c++ nimb", profile: "research")
            .request(base: URL(string: "https://hermes.example/base")!)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/base/api/sessions/search")
        XCTAssertEqual(request.url?.query, "q=c%2B%2B%20nimb&profile=research&limit=50&exclude_sources=cron,kanban,oneshot,subagent,tool")
        XCTAssertThrowsError(try HermesREST.sessionSearch(query: "", profile: "research").request(base: server))
        XCTAssertThrowsError(try HermesREST.sessionSearch(query: "nimb", profile: "").request(base: server))
    }

    func testResultsReadAsRowsWithTheirSnippetsAndRecency() throws {
        let reply = Data(#"""
        {"results": [
          {"snippet": "Plan the >>>Nimbus<<< cloud migration", "role": "user", "source": "cli", "model": "hermex-stub",
           "session_started": 1791400926.3, "last_active": 1791400927.2, "session_id": "tip", "lineage_root": "root",
           "profile": "default", "id": "tip", "title": null, "started_at": 1791400926.3, "message_count": 4,
           "preview": "Plan the Nimbus cloud migration", "parent_session_id": null, "archived": false},
          {"snippet": "Draft release notes", "role": null, "session_started": 1791400930.9, "last_active": 1791400931.6,
           "session_id": "20261007_152208_588bfb", "lineage_root": "20261007_152208_588bfb", "profile": "default",
           "title": "Release notes", "archived": true},
          {"snippet": "the >>>nimbus<<< cluster", "role": "assistant", "session_started": 1791400900, "last_active": null,
           "session_id": "orphan", "lineage_root": "orphan", "profile": "default"},
          {"snippet": "no id", "role": "user"}
        ]}
        """#.utf8)

        let results = try JSONDecoder().decode(HermesSessionSearch.self, from: reply).results

        XCTAssertEqual(results.map(\.row.id), ["tip", "20261007_152208_588bfb", "orphan"])
        XCTAssertEqual(results.map(\.row.identity), ["root", "20261007_152208_588bfb", "orphan"])
        XCTAssertEqual(results.map(\.snippet), ["Plan the >>>Nimbus<<< cloud migration", nil, "the >>>nimbus<<< cluster"])
        XCTAssertEqual(results.map(\.row.lastActive), [1_791_400_927.2, 1_791_400_931.6, 1_791_400_900])
        XCTAssertEqual(results.map(\.row.archived), [false, true, nil])
        XCTAssertEqual(results[0].row.preview, "Plan the Nimbus cloud migration")
        XCTAssertEqual(results[0].row.messageCount, 4)
    }

    func testHostMatchesMergeByLineageRootWithTheLoadedRows() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [
            HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 30),
            HermesSessionRow(id: "tip", title: "Deploy notes", lastActive: 20, pinned: true, unread: true, lineageRootID: "root"),
            HermesSessionRow(id: "lunch", title: "Lunch", lastActive: 10)
        ])]
        wire.searchResults = [
            HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", lastActive: 1, profile: "default",
                                                            lineageRootID: "old"), snippet: "the >>>nimbus<<< cluster"),
            HermesSessionSearchResult(row: HermesSessionRow(id: "tip", title: "Deploy notes", profile: "default", lineageRootID: "root"),
                                      snippet: ">>>Nimbus<<< rollout"),
            HermesSessionSearchResult(row: HermesSessionRow(id: "plan", title: "Nimbus plan", profile: "default", lineageRootID: "plan"))
        ]
        let list = makeList(wire)
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"],
                       "the loaded rows filter before the host answers")
        await list.searchSessions(query: " Nimbus ", debounceNanoseconds: 0)

        let shown = list.visibleSessions(searchText: "Nimbus", selectedProjectID: nil)
        XCTAssertEqual(shown.compactMap(\.sessionId), ["plan", "old", "tip"])
        XCTAssertEqual(wire.searches.map(\.query), ["nimbus"])
        XCTAssertEqual(wire.searches.map(\.profile), ["default"])
        let tip = shown[2]
        XCTAssertEqual(tip.pinned, true)
        XCTAssertTrue(list.isUnread(tip))
        XCTAssertEqual(list.searchExcerpt(for: tip, searchText: "Nimbus")?.text, "Nimbus rollout")
        XCTAssertEqual(list.searchExcerpt(for: shown[1], searchText: "Nimbus")?.text, "the nimbus cluster")
        XCTAssertNil(list.searchExcerpt(for: shown[0], searchText: "Nimbus"), "an id or title match has no excerpt")
        XCTAssertNil(list.searchExcerpt(for: tip, searchText: "rollout"), "another screen's query shows none")
    }

    func testArchivedAndBotChatMatchesAreLabeledAndRouted() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = [
            HermesSessionSearchResult(row: HermesSessionRow(id: "gone", title: "Old launch", archived: true, profile: "default")),
            HermesSessionSearchResult(row: HermesSessionRow(id: "bot", title: "Bot Chat", hidden: true, profile: "default"))
        ]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "launch", debounceNanoseconds: 0)

        let shown = list.visibleSessions(searchText: "launch", selectedProjectID: nil)
        let archived = try XCTUnwrap(shown.first { $0.sessionId == "gone" })
        XCTAssertTrue(SessionRowView.accessibilityStateLabels(for: archived, isViewingCachedData: false, labelsArchived: true)
            .contains("Archived"))
        XCTAssertFalse(SessionRowView.accessibilityStateLabels(for: archived, isViewingCachedData: false).contains("Archived"),
                       "the Archived screen's rows go unlabeled")
        XCTAssertEqual(archived.hermesTarget(listedIn: "default"), .session(profile: "default", key: "gone"))
        XCTAssertNil(archived.hermesBot(on: server, connectionID: connection.id))
        XCTAssertTrue(SessionRowActionPolicy.offersMutationActions(for: archived))
        XCTAssertFalse(SessionRowActionPolicy.offersArchive(for: archived), "the Archived screen restores it")

        let bot = try XCTUnwrap(shown.first { $0.sessionId == "bot" })
        XCTAssertEqual(SessionRowView.displayTitle(for: bot), "Bot Chat · default")
        XCTAssertEqual(bot.hermesBot(on: server, connectionID: connection.id),
                       BotDestination(server: server, connectionID: connection.id, profile: "default"))
        XCTAssertFalse(SessionRowActionPolicy.offersMutationActions(for: bot), "pinning would unhide it")
        XCTAssertFalse(list.canToggleUnread(bot), "the Bots inbox keeps its own read mark")
        XCTAssertTrue(list.canToggleUnread(archived))
    }

    func testARoomSessionIsNeverASearchMatch() throws {
        let reply = """
        {"results": [
          {"session_id": "room", "title": "Group: room-1", "snippet": ">>>nimbus<<<", "role": "user"},
          {"session_id": "desktop-room", "title": "Group: Launch · Ops", "snippet": ">>>nimbus<<<", "role": "assistant"},
          {"session_id": "bot", "title": "Bot Chat", "snippet": ">>>nimbus<<<", "role": "assistant"},
          {"session_id": "plan", "title": "Plan", "snippet": ">>>nimbus<<<", "role": "user"}
        ]}
        """
        let search = try JSONDecoder().decode(HermesSessionSearch.self, from: Data(reply.utf8))
        XCTAssertEqual(search.results.map(\.row.id), ["bot", "plan"])
    }

    func testAMatchChangedHereShowsTheChange() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "old", "draft"].map { id in
            HermesSessionSearchResult(row: HermesSessionRow(id: id, title: "Plan \(id)", profile: "default"), snippet: ">>>nimbus<<<")
        }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        let shown = list.visibleSessions(searchText: "nimbus", selectedProjectID: nil)
        XCTAssertEqual(shown.compactMap(\.sessionId), ["gone", "old", "draft"])

        let deleted = await list.delete(shown[0])
        let archived = await list.archive(shown[1])
        let renamed = await list.rename(shown[2], to: "Nimbus draft")

        XCTAssertEqual([deleted, archived, renamed], [true, true, true])
        XCTAssertEqual(wire.changes, [.archived(true), .title("Nimbus draft")])
        let after = list.visibleSessions(searchText: "nimbus", selectedProjectID: nil)
        XCTAssertEqual(after.compactMap(\.sessionId), ["old", "draft"])
        XCTAssertEqual(after.map(\.archived), [true, nil])
        XCTAssertEqual(after.map(\.title), ["Plan old", "Nimbus draft"])
        XCTAssertEqual(wire.searches.count, 1)
    }

    func testASearchBeforeTheSocketIsAttachedRunsOnceItIs() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        wire.holdsConnect = true
        let list = makeList(wire)
        let open = Task { await list.openHermes() }
        await waitUntil("connecting") { wire.connects == 1 }

        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil), [])
        XCTAssertNil(list.searchErrorMessage)

        wire.release()
        await open.value

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["old"])
        XCTAssertEqual(wire.searches.map(\.query), ["old"])
    }

    func testMatchesFollowTheProjectLanesReadAfterTheSearch() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: "p_1"), [])

        wire.projectTree = .object(["projects": .array([.object([
            "id": .string("p_1"), "label": .string("Launch"), "path": .string("/Users/me/launch"), "isAuto": .bool(false),
            "isNoProject": .bool(false), "sessionCount": .number(1), "sessionIds": .array([.string("old")])
        ])])])
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: "p_1").compactMap(\.sessionId), ["old"])
    }

    func testClearingTheSearchRestoresTheList() async {
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a", title: "Alpha", lastActive: 2),
                                                             HermesSessionRow(id: "b", title: "Beta", lastActive: 1)])]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"),
                                                        snippet: ">>>alpha<<<")]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "alpha", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "alpha", selectedProjectID: nil).compactMap(\.sessionId), ["a", "old"])

        await list.searchSessions(query: "", debounceNanoseconds: 0)

        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).compactMap(\.sessionId), ["a", "b"])
        XCTAssertEqual(wire.searches.count, 1, "an empty query never asks the host")
    }

    func testRepeatingTheSearchKeepsItsMatchesUntilTheHostAnswers() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)

        wire.holdsSearch = true
        let again = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 2 }
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["old"])
        wire.release()
        await again.value

        let other = Task { await list.searchSessions(query: "older", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 3 }
        XCTAssertEqual(list.visibleSessions(searchText: "older", selectedProjectID: nil), [])
        wire.release()
        await other.value
    }

    func testAWriteConfirmedDuringARepeatedSearchIsNotUndoneByItsAnswer() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "kept"].map { HermesSessionSearchResult(row: HermesSessionRow(id: $0, title: "Old \($0)", profile: "default")) }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)
        let gone = try XCTUnwrap(list.visibleSessions(searchText: "old", selectedProjectID: nil).first)

        wire.holdsSearch = true
        let again = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 2 }
        let deleted = await list.delete(gone)
        wire.searchResults.removeFirst()
        wire.holdsSearch = false
        wire.release()
        await again.value

        XCTAssertTrue(deleted)
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["kept"])
        XCTAssertEqual(wire.searches.count, 3)
    }

    func testAReconnectSearchesAgainSoAMatchDeletedElsewhereGoes() async throws {
        let wire = HermesSessionListWire()
        wire.searchResults = ["gone", "kept"].map { HermesSessionSearchResult(row: HermesSessionRow(id: $0, title: "Old \($0)", profile: "default")) }
        let list = makeList(wire)
        await list.openHermes()
        await list.searchSessions(query: "old", debounceNanoseconds: 0)

        wire.searchResults.removeFirst()
        wire.onDisconnect?(BotFailure.transport)
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil).compactMap(\.sessionId), ["kept"])
        XCTAssertEqual(wire.searches.count, 2)
    }

    func testASearchAnotherProfileReplacedIsDropped() async {
        let wire = HermesSessionListWire()
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes()

        wire.holdsSearch = true
        let search = Task { await list.searchSessions(query: "old", debounceNanoseconds: 0) }
        await waitUntil("search parked") { wire.searches.count == 1 }
        await list.selectHermesProfile("research")
        wire.release()
        await search.value

        XCTAssertEqual(list.hermesProfile, "research")
        XCTAssertEqual(list.visibleSessions(searchText: "old", selectedProjectID: nil), [])
    }

    private func makeList(_ wire: HermesSessionListWire) -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: "default", makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }
}

@MainActor @Observable final class HermesSessionListWire: BotTransport {
    struct UnreadWrite: Hashable { let key: String; let profile: String; let unread: Bool }

    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var pages: [String: [Int: HermesSessionPage]] = [:]
    var active: [BotJSON] = []
    var archivedTotals: [String: Int] = [:]
    var approvals: [String: [BotJSON]] = [:]
    var roster: [String: [BotJSON]] = [:]
    var lacksRoster = false
    var holdsActive = false
    var holdsApprovals = false
    var holdsArchivedCount = false
    var holdsProjects: Set<String> = []
    var failingApprovals: Set<String> = []
    var profiles = ["default", "research"]
    var current = "default"
    var removed: Set<String> = []
    var holdsPages = false
    var holdsUnread = false
    var unreadFails = false
    var failingUnreadKeys: Set<String> = []
    var pageFailure: BotFailure?
    var scheduledPages: [String: [Int: HermesSessionPage]] = [:]
    var scheduledResults: [HermesSessionSearchResult] = []
    var holdsScheduledPages = false
    private(set) var scheduledReads: [(profile: String, offset: Int)] = []
    private(set) var scheduledSearches: [(query: String, profile: String)] = []
    var searchResults: [HermesSessionSearchResult] = []
    var holdsSearch = false
    var holdsConnect = false
    var connectFailure: Error?
    var projectTree: BotJSON?
    private(set) var attached = false
    private(set) var searches: [(query: String, profile: String)] = []
    private(set) var connects = 0
    private(set) var closes = 0
    private(set) var pageReads: [(profile: String, offset: Int)] = []
    private(set) var answeredPages = 0
    private(set) var unreadWrites: [UnreadWrite] = []
    private(set) var changes: [HermesSessionChange] = []
    private(set) var calls: [(method: String, profile: String?)] = []
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var heldPages: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var heldProjects: [CheckedContinuation<Void, Never>] = []

    private func parkPage() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { heldPages[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.heldPages.removeValue(forKey: id)?.resume() }
        }
        try Task.checkCancellation()
    }

    func connect() async throws {
        connects += 1
        if holdsConnect { await withCheckedContinuation { held.append($0) } }
        if let connectFailure { throw connectFailure }
        attached = true
    }
    func close() { closes += 1 }

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        let params = try call.params()
        calls.append((call.method, params["profile"]?.text))
        switch call.method {
        case "session.most_recent":
            if removed.contains(params["profile"]?.text ?? "") { throw BotFailure.rejected(4064) }
            return .object(["session_id": .null])
        case "session.active_list":
            if holdsActive { await withCheckedContinuation { held.append($0) } }
            return .object(["sessions": .array(active)])
        case "approval.pending":
            if holdsApprovals { await withCheckedContinuation { held.append($0) } }
            let runtime = params["session_id"]?.text ?? ""
            if failingApprovals.contains(runtime) { throw BotFailure.rejected(500) }
            return .object(["approvals": .array(approvals[runtime] ?? [])])
        case "subagent.roster":
            if lacksRoster { throw BotFailure.rejected(-32601) }
            return .object(["sessions": .array(roster[params["profile"]?.text ?? ""] ?? [])])
        case "profiles.list": return .object(["profiles": .array(profiles.map { .object(["name": .string($0)]) })])
        case "session.delete": return .object([:])
        case "projects.tree":
            if holdsProjects.contains(params["profile"]?.text ?? "") {
                await withCheckedContinuation { heldProjects.append($0) }
            }
            guard let projectTree else { throw BotFailure.unsupported }
            return projectTree
        default: throw BotFailure.unsupported
        }
    }

    func currentProfile() async throws -> String { current }

    func sessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        guard attached else { throw BotFailure.stale }
        pageReads.append((profile, offset))
        let reply = pages[profile]?[offset] ?? HermesSessionPage(rows: [])
        if holdsPages { try await parkPage() }
        answeredPages += 1
        if let failure = pageFailure { pageFailure = nil; throw failure }
        if removed.contains(profile) { throw BotFailure.rejected(404) }
        return reply
    }

    func scheduledSessionPage(profile: String, offset: Int, archived: Bool) async throws -> HermesSessionPage {
        guard attached else { throw BotFailure.stale }
        scheduledReads.append((profile, offset))
        let reply = scheduledPages[profile]?[offset] ?? HermesSessionPage(rows: [])
        if holdsScheduledPages { try await parkPage() }
        if let failure = pageFailure { pageFailure = nil; throw failure }
        return reply
    }

    func archivedSessionCount(profile: String) async throws -> Int {
        if holdsArchivedCount { await withCheckedContinuation { held.append($0) } }
        guard let total = archivedTotals[profile] else { throw BotFailure.unsupported }
        return total
    }

    func searchScheduledSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        scheduledSearches.append((query, profile))
        return scheduledResults
    }

    func updateSession(_ change: HermesSessionChange, key: String, profile: String) async throws -> String? {
        guard case .unread(let unread) = change else { changes.append(change); return nil }
        unreadWrites.append(UnreadWrite(key: key, profile: profile, unread: unread))
        if holdsUnread { await withCheckedContinuation { held.append($0) } }
        if unreadFails { throw BotFailure.rejected(500) }
        if failingUnreadKeys.contains(key) { throw BotFailure.rejected(500) }
        return nil
    }

    func searchSessions(query: String, profile: String, limit: Int) async throws -> [HermesSessionSearchResult] {
        guard attached else { throw BotFailure.stale }
        searches.append((query, profile))
        let reply = searchResults
        if holdsSearch { await withCheckedContinuation { held.append($0) } }
        return reply
    }

    func release() {
        let pages = heldPages
        heldPages = [:]
        for continuation in pages.values { continuation.resume() }
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func releaseProjects() {
        let waiting = heldProjects
        heldProjects = []
        for continuation in waiting { continuation.resume() }
    }

    func emit(_ type: String) {
        onEvent?(.object(["type": .string(type), "session_id": .string("")]))
    }
}
