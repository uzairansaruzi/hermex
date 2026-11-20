import Observation
import SwiftData
import XCTest
@testable import HermesMobile

@MainActor final class HermesOfflineCacheTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "HermesOfflineCacheTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAnUnreachableHostShowsTheCachedListUntilAReadSucceeds() async throws {
        let context = try makeContext()
        let rows = [
            HermesSessionRow(id: "new", title: "Newest", lastActive: 30, unread: true),
            HermesSessionRow(id: "tip", title: "Chain", lastActive: 20, lineageRootID: "root"),
            HermesSessionRow(id: "pin", title: "Pinned", lastActive: 10, pinned: true)
        ]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertTrue(list.showsOfflineCache, "the rows shown while connecting become the offline state")
        XCTAssertNil(list.errorMessage)
        let shown = list.visibleSessions(searchText: "", selectedProjectID: nil)
        XCTAssertEqual(shown.map(\.title), ["Pinned", "Newest", "Chain"])
        XCTAssertTrue(SessionRowView.accessibilityStateLabels(for: shown[0], isViewingCachedData: true,
                                                              isCachedCopyProvisional: list.isCachedCopyProvisional).contains("Cached"))
        XCTAssertTrue(list.isUnread(shown[1]))
        XCTAssertEqual(shown[2].id, "root")
        XCTAssertEqual(shown[2].hermesTarget(listedIn: "default"), .session(profile: "default", key: "tip"))
        let renamed = await list.rename(shown[1], to: "Offline title")
        XCTAssertFalse(renamed)
        XCTAssertEqual(wire.changes, [])

        wire.connectFailure = nil
        wire.pages["default"] = [0: HermesSessionPage(rows: rows + [HermesSessionRow(id: "later", title: "Later", lastActive: 40)])]
        await list.openHermes()

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map(\.title),
                       ["Pinned", "Later", "Newest", "Chain"])
    }

    func testAnUnreachableReconnectKeepsTheLiveRowsReconnecting() async throws {
        let context = try makeContext()
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a")])]
        wire.active = [.object(["session_key": .string("a"), "status": .string("working")])]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        await waitUntil("states read") { !list.attentionStatesBySessionID.isEmpty }

        wire.onDisconnect?(BotFailure.transport)
        wire.connectFailure = URLError(.cannotConnectToHost)
        list.reconnectNow()
        await waitUntil("reconnect failed") { wire.connects == 2 }

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.attentionStatesBySessionID, ["a": .working])
        XCTAssertEqual(HomeConnectionStatus(list.hermesConnection, isOnline: true), .reconnecting)
    }

    func testASearchWhileCachedReachesTheHostOnceItAnswers() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 20)]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", profile: "default"),
                                                        snippet: "the >>>nimbus<<< cluster")]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"])

        wire.connectFailure = nil
        wire.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await list.openHermes()

        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "old"])
        XCTAssertEqual(wire.searches.map(\.query), ["nimbus"])
    }

    func testARefreshThatFallsBackToTheCacheDropsTheHostsMatchesUntilItSearchesAgain() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "plan", title: "Nimbus plan", lastActive: 20)]
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: rows)]
        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "old", title: "Old chat", profile: "default"))]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        await list.searchSessions(query: "nimbus", debounceNanoseconds: 0)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "old"])

        wire.pageFailure = .rejected(502)
        await list.refreshHermes()
        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan"])

        wire.searchResults = [HermesSessionSearchResult(row: HermesSessionRow(id: "newer", title: "Newer chat", profile: "default"))]
        await list.refreshHermes()

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "nimbus", selectedProjectID: nil).compactMap(\.sessionId), ["plan", "newer"])
    }

    func testAListShowsItsCachedRowsWhileItConnects() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "a", title: "A", lastActive: 20), HermesSessionRow(id: "b", title: "B", lastActive: 10)]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.holdsConnect = true
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "c", title: "C", lastActive: 30)] + rows)]
        let list = makeList(wire)
        let open = Task { await list.openHermes(modelContext: context) }
        await waitUntil("the cached rows show") { wire.connects == 1 && !list.sessions.isEmpty }

        XCTAssertEqual(list.sessions.map(\.title), ["A", "B"])
        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertTrue(list.isCachedCopyProvisional)
        XCTAssertFalse(list.showsOfflineCache)
        XCTAssertFalse(list.isLoading)
        XCTAssertFalse(SessionRowView.accessibilityStateLabels(for: list.sessions[0], isViewingCachedData: true,
                                                               isCachedCopyProvisional: true).contains("Cached"))
        let renamed = await list.rename(list.sessions[0], to: "Too soon")
        XCTAssertFalse(renamed)

        wire.release()
        await open.value

        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertFalse(list.isCachedCopyProvisional)
        XCTAssertEqual(list.sessions.map(\.title), ["C", "A", "B"])
    }

    func testARefreshWhileConnectingKeepsTheCachedRowsAndTheConnect() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "a", title: "A", lastActive: 20)]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.holdsConnect = true
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "c", title: "C", lastActive: 30)] + rows)]
        let list = makeList(wire)
        let open = Task { await list.openHermes(modelContext: context) }
        await waitUntil("the cached rows show") { wire.connects == 1 && !list.sessions.isEmpty }

        await list.refreshHermes(modelContext: context)

        XCTAssertEqual(list.sessions.map(\.title), ["A"])
        XCTAssertNil(list.sessionLoadError)
        XCTAssertNil(list.errorMessage)
        XCTAssertFalse(list.isHermesReconnecting)

        wire.release()
        await open.value

        XCTAssertEqual(wire.connects, 1)
        XCTAssertNil(list.sessionLoadError)
        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.sessions.map(\.title), ["C", "A"])
    }

    func testARefusedConnectDropsTheRowsShownWhileConnecting() async throws {
        let context = try makeContext()
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a", title: "A", lastActive: 1)])]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.connectFailure = BotFailure.rejected(401)
        let list = makeList(wire)
        await list.openHermes(modelContext: context)

        XCTAssertEqual(list.sessions, [])
        XCTAssertFalse(list.isViewingCachedData)
        XCTAssertEqual(list.errorMessage, "Hermes didn't accept the username or password.")
    }

    func testAListWithoutAPickShowsTheProfileItLastReadWhileItConnects() async throws {
        let context = try makeContext()
        let online = HermesSessionListWire()
        online.pages = ["research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "r", title: "R", lastActive: 2)])]]
        await makeList(online, profile: "research").openHermes(modelContext: context)
        XCTAssertNil(defaults.string(forKey: HermesProfilePreference.key(for: server)), "reading a Profile is not picking it")

        let wire = HermesSessionListWire()
        wire.holdsConnect = true
        wire.pages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "d", title: "D", lastActive: 1)])]]
        let list = makeList(wire, profile: nil)
        let open = Task { await list.openHermes(modelContext: context) }
        await waitUntil("the cached rows show") { wire.connects == 1 && !list.sessions.isEmpty }

        XCTAssertEqual(list.sessions.map(\.title), ["R"])
        XCTAssertTrue(list.isCachedCopyProvisional)
        XCTAssertNil(list.hermesProfile)

        wire.release()
        await open.value

        XCTAssertEqual(list.hermesProfile, "default")
        XCTAssertEqual(list.sessions.map(\.title), ["D"])
        XCTAssertEqual(HermesProfilePreference.lastListed(for: server, in: defaults), "default")
    }

    func testRowsShownWhileConnectingWriteNoReadMark() async throws {
        let context = try makeContext()
        let rows = [HermesSessionRow(id: "a", title: "A", lastActive: 1, unread: true)]
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: rows)]
        await makeList(online).openHermes(modelContext: context)

        let wire = HermesSessionListWire()
        wire.holdsPages = true
        wire.pages["default"] = [0: HermesSessionPage(rows: rows)]
        let list = makeList(wire)
        let open = Task { await list.openHermes(modelContext: context) }
        await waitUntil("the socket is up and the page read waits") { wire.pageReads.count == 1 }
        let cached = try XCTUnwrap(list.sessions.first)

        XCTAssertTrue(list.isCachedCopyProvisional)
        XCTAssertFalse(list.canToggleUnread(cached))
        list.toggleUnread(cached)
        list.beginViewing(cached)
        XCTAssertTrue(list.isUnread(cached))
        XCTAssertEqual(wire.unreadWrites, [])

        wire.release()
        await open.value

        XCTAssertTrue(list.canToggleUnread(try XCTUnwrap(list.sessions.first)))
    }

    func testArchivingOrDeletingARowDropsItsCachedCopy() async throws {
        let context = try makeContext()
        let others = (0..<100).map { HermesSessionRow(id: "s\($0)", title: "S\($0)", lastActive: Double(1_000 - $0)) }
        let wire = HermesSessionListWire()
        wire.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "a", title: "A", lastActive: 2_000),
                                                             HermesSessionRow(id: "b", title: "B", lastActive: 1_999)]
                                                       + others.prefix(98))]
        let list = makeList(wire)
        await list.openHermes(modelContext: context)
        let a = try XCTUnwrap(list.sessions.first { $0.sessionId == "a" })
        let b = try XCTUnwrap(list.sessions.first { $0.sessionId == "b" })

        wire.pages["default"] = [0: HermesSessionPage(rows: others)]
        let archived = await list.archive(a)
        let deleted = await list.delete(b)
        XCTAssertTrue(archived)
        XCTAssertTrue(deleted)
        await waitUntil("the list read again") { list.sessions.count == 100 && list.sessions.first?.sessionId == "s0" }

        let cached = try CacheStore.cachedHermesSessions(serverURL: server, profile: "default", in: context)
        XCTAssertEqual(cached.compactMap(\.sessionId), others.map(\.id))
    }

    func testScheduledRowsALoadMoreReadAreCached() async throws {
        let context = try makeContext()
        let first = (0..<100).map { HermesSessionRow(id: "job-\($0)", lastActive: Double(1_000 - $0), source: "cron") }
        let online = HermesSessionListWire()
        online.pages["default"] = [0: HermesSessionPage(rows: [HermesSessionRow(id: "ordinary", lastActive: 2_000)])]
        online.scheduledPages = ["default": [0: HermesSessionPage(rows: first, total: 101),
                                           100: HermesSessionPage(rows: [HermesSessionRow(id: "last-job", lastActive: 1, source: "cron")], total: 101)]]
        let list = makeList(online)
        await list.openHermes(modelContext: context)
        await list.loadMoreHermesScheduledSessions()
        XCTAssertTrue(list.sessions.contains { $0.sessionId == "last-job" })
        list.closeHermes()

        let cached = try CacheStore.cachedHermesSessions(serverURL: server, profile: "default", in: context)
        XCTAssertTrue(cached.contains { $0.sessionId == "last-job" }, "the paged-in scheduled row is cached")
        let offline = HermesSessionListWire()
        offline.connectFailure = URLError(.cannotConnectToHost)
        let shown = makeList(offline)
        await shown.openHermes(modelContext: context)
        XCTAssertTrue(shown.isViewingCachedData)
        XCTAssertTrue(shown.sessions.contains { $0.sessionId == "last-job" })
        XCTAssertEqual(shown.sessions.count, 102)
    }

    func testAnUnreachableSessionShowsItsCachedTranscriptUntilItReconnects() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)
        XCTAssertEqual(visit.model.messages.map(\.content), ["Hi", "Hello."])

        let wire = HermesOfflineWire(rows: [])
        wire.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertTrue(chat.model.showsOfflineCache, "the transcript shown while connecting becomes the offline state")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertEqual(chat.model.messages.map(\.rowID), [1, 2])
        let sent = await chat.model.sendMessage("Still there?")
        XCTAssertFalse(sent)
        XCTAssertEqual(chat.model.sendErrorMessage, "Reconnect to the server to send a message.")

        wire.connectFailure = nil
        wire.rows = [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")]
        chat.reconnect.open()
        await waitUntil("reattached") { !chat.model.isViewingCachedData }

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
        XCTAssertFalse(wire.methods.contains("prompt.submit"))
    }

    func testASessionShowsItsCachedTranscriptWhileItConnects() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        let connected = Gate()
        wire.connectGate = connected
        let chat = makeChat(wire)
        let load = Task { await chat.model.loadMessages(modelContext: context) }
        await waitUntil("the cached transcript shows") { !chat.model.messages.isEmpty }

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertTrue(chat.model.isCachedCopyProvisional)
        XCTAssertFalse(chat.model.showsOfflineCache)
        XCTAssertFalse(chat.model.isLoading)
        XCTAssertTrue(ChatComposerAccess(session: SessionSummary(profile: "default"),
                                         isViewingCachedData: chat.model.showsOfflineCache).allowsHostControls)
        let sent = await chat.model.sendMessage("Too soon")
        XCTAssertFalse(sent)
        XCTAssertNil(chat.model.sendErrorMessage)

        connected.open()
        await load.value

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertFalse(chat.model.isCachedCopyProvisional)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
        XCTAssertFalse(wire.methods.contains("prompt.submit"))
    }

    func testASessionShowsItsCachedTranscriptBeforeItsAppearanceCompletes() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        let chat = makeChat(wire)
        chat.model.prepareInitialMessageLoad(modelContext: context)

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertTrue(chat.model.isCachedCopyProvisional)
        XCTAssertEqual(wire.methods, [])

        await chat.model.loadMessages(modelContext: context, usesInitialPrefetch: true)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    func testAFailedFirstHistoryReadKeepsTheRunningReply() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.running = true
        wire.messagesFailure = BotFailure.rejected(500)
        wire.onRead = { [weak wire] in
            wire?.onRead = nil
            wire?.onEvent?(Self.delta(1, "Working"))
        }
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertEqual(chat.model.messages.map(\.messageId), [chat.model.streamingAssistantMessageID],
                       "the reply's row is the only one, and still streaming")
        XCTAssertNotNil(chat.model.errorMessage)
        wire.onEvent?(Self.delta(2, " on it"))
        await waitUntil("the reply streams") { chat.model.messages.last?.content == "Working on it" }

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Working on it"])
    }

    func testAnAttachThatFailsMidwayStillReadsTheHostsRowsOnReconnect() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.replayFailure = BotFailure.transport
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        wire.replayFailure = nil
        chat.reconnect.open()
        await waitUntil("reattached") { !chat.model.isViewingCachedData }

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    func testAFailedHistoryReadKeepsTheCachedTranscriptUntilARetry() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertTrue(chat.model.isViewingCachedData)

        wire.connectFailure = nil
        wire.messagesFailure = BotFailure.rejected(502)
        chat.reconnect.open()
        await waitUntil("reattached") { chat.model.errorMessage != nil }

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        wire.messagesFailure = nil
        await chat.model.loadMessages(modelContext: context)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    func testAVisitAfterAnUndoDropsTheUndoneRows() async throws {
        let context = try makeContext()
        let rows = [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Undo me"), row(4, "assistant", "Undone.")]
        let visit = makeChat(HermesOfflineWire(rows: rows))
        await visit.model.loadMessages(modelContext: context)
        let afterUndo = makeChat(HermesOfflineWire(rows: Array(rows.prefix(2))))
        await afterUndo.model.loadMessages(modelContext: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 10).map(\.content), ["Hi", "Hello."])
    }

    func testARefusalShowsNoCachedTranscript() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.connectFailure = BotFailure.rejected(401)
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.model.errorMessage, "Hermes didn't accept the username or password.")
    }

    func testAChainsTranscriptIsCachedUnderItsLineageRoot() async throws {
        let context = try makeContext()
        try CacheStore.cacheHermesSessions([HermesSessionRow(id: "tip", lineageRootID: "root").summary(in: "default")],
                                           profile: "default", reachedEnd: true, serverURL: server, in: context)
        let chat = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]))
        await chat.model.loadMessages(modelContext: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "root",
                                                           in: context, limit: 10).map(\.content), ["Hi"])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 10), [])
    }

    func testALinkedChainsTranscriptIsCachedUnderTheRootItsLookupFound() async throws {
        let context = try makeContext()
        let chat = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), lineageRoot: "root")
        await chat.model.loadMessages(modelContext: context)

        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "root",
                                                           in: context, limit: 10).map(\.content), ["Hi"])
        XCTAssertEqual(try CacheStore.cachedHermesMessages(serverURL: server, profile: "default", lineageRoot: "tip",
                                                           in: context, limit: 10), [])
    }

    func testAllProfilesShowsEveryProfilesCachedRowsOffline() async throws {
        let context = try makeContext()
        HermesProfilePreference.saveShowsAllProfiles(true, for: server, in: defaults)
        let online = HermesSessionListWire()
        online.pages = ["default": [0: HermesSessionPage(rows: [HermesSessionRow(id: "d", lastActive: 1)])],
                        "research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "r", lastActive: 2)])]]
        await makeList(online).openHermes(modelContext: context)
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: server, profile: "research", in: context).map(\.sessionId), ["r"])

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire, profile: nil)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.visibleSessions(searchText: "", selectedProjectID: nil).map { "\($0.sessionId!)@\($0.profile!)" },
                       ["r@research", "d@default"])
    }

    func testAListWithoutAProfileShowsThePicksCachedRowsOffline() async throws {
        let context = try makeContext()
        let online = HermesSessionListWire()
        online.pages = ["research": [0: HermesSessionPage(rows: [HermesSessionRow(id: "r", lastActive: 2)])]]
        await makeList(online, profile: "research").openHermes(modelContext: context)
        HermesProfilePreference.save("research", for: server, in: defaults)

        let wire = HermesSessionListWire()
        wire.connectFailure = URLError(.cannotConnectToHost)
        let list = makeList(wire, profile: nil)
        await list.openHermes(modelContext: context)

        XCTAssertTrue(list.isViewingCachedData)
        XCTAssertEqual(list.sessions.map(\.sessionId), ["r"])
        XCTAssertEqual(list.hermesProfile, "research", "its rows open, and New Session starts, in the pick")
    }

    func testABotChatShowsItsCachedTranscriptBeforeTheAttach() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                             target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)
        XCTAssertEqual(visit.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertEqual(try CacheStore.cachedHermesSessions(serverURL: server, profile: nil, in: context), [])

        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Sent from Desktop")])
        wire.tip = "compacted"
        let connected = Gate()
        wire.connectGate = connected
        let chat = makeChat(wire, target: .canonicalChat(profile: "default"))
        let load = Task { await chat.model.loadMessages(modelContext: context) }
        await waitUntil("the cached transcript shows") { !chat.model.messages.isEmpty }

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertFalse(chat.model.showsOfflineCache, "no offline banner while it connects")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertEqual(wire.methods, [])

        connected.open()
        await load.value

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertFalse(chat.model.isCachedCopyProvisional)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Sent from Desktop"])
    }

    func testAnAttachBeforeTheFirstLoadStillCachesWhatItReads() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                             target: .canonicalChat(profile: "default"))
        await visit.model.reconnectStreamIfNeeded(modelContext: context)
        await visit.model.loadMessages(modelContext: context)
        XCTAssertEqual(visit.model.messages.map(\.content), ["Hi", "Hello."])

        XCTAssertEqual(try botChatMessages(in: context), ["Hi", "Hello."])
    }

    func testABotChatRefusedBeforeItsCacheShowsShowsItOffline() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.connectFailure = BotFailure.rejected(401)
        let chat = makeChat(wire, target: .canonicalChat(profile: "default"))
        await chat.model.reconnectStreamIfNeeded(modelContext: context)
        chat.model.prepareInitialMessageLoad(modelContext: context)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi"])
        XCTAssertTrue(chat.model.showsOfflineCache)
        XCTAssertFalse(chat.model.isCachedCopyProvisional)
    }

    func testAProfileTheWebappDoesntServeOffersNoTryAgain() async throws {
        let context = try makeContext()
        let reason = HermesStandaloneReason(hostText: "profile(s) 'dev' (pid 42) still run their own gateway")
        for (failure, retries) in [(BotFailure.profileNotServed("dev", reason), false), (.upgradeRefused(403), true)] {
            let wire = HermesOfflineWire(rows: [])
            wire.connectFailure = failure
            let chat = makeChat(wire, target: .session(profile: "dev", key: "tip"))
            await chat.model.reconnectStreamIfNeeded(modelContext: context)
            chat.model.prepareInitialMessageLoad(modelContext: context)
            await chat.model.loadMessages(modelContext: context)
            XCTAssertEqual(chat.model.errorMessage, failure.localizedDescription, "\(failure)")
            XCTAssertEqual(chat.model.errorMayRetry, retries, "\(failure)")
            XCTAssertEqual(chat.model.errorUnserved, retries ? nil : HermesUnservedProfile(profile: "dev", hostReason: reason.hostText), "\(failure)")
        }

        let shown = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .session(profile: "dev", key: "tip"))
        await shown.model.loadMessages(modelContext: context)
        let unserved = HermesUnservedProfile(profile: "dev", hostReason: reason.hostText)
        shown.model.hermesConnectionDidChange(failure: "not served", unserved: unserved, mayRetry: false)
        XCTAssertEqual(shown.model.sendErrorMessage, "not served")
        XCTAssertEqual(shown.model.errorUnserved, unserved)
    }

    func testABotChatAttachedBeforeItsCacheShowsKeepsItWhenHistoryFails() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.messagesFailure = BotFailure.rejected(500)
        let chat = makeChat(wire, target: .canonicalChat(profile: "default"))
        await chat.model.reconnectStreamIfNeeded(modelContext: context)
        chat.model.prepareInitialMessageLoad(modelContext: context)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi"])
        XCTAssertTrue(chat.model.showsOfflineCache)
        XCTAssertFalse(chat.model.isCachedCopyProvisional)
    }

    func testABotChatsCacheStaysWithItsServer() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let elsewhere = HermesOfflineWire(rows: [])
        elsewhere.connectFailure = URLError(.cannotConnectToHost)
        let other = makeChat(elsewhere, target: .canonicalChat(profile: "default"), server: URL(string: "https://other.example")!)
        await other.model.loadMessages(modelContext: context)
        XCTAssertFalse(other.model.isViewingCachedData)
        XCTAssertEqual(other.model.messages, [])

        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let same = makeChat(offline, target: .canonicalChat(profile: "default"))
        await same.model.loadMessages(modelContext: context)
        XCTAssertTrue(same.model.isViewingCachedData)
        XCTAssertEqual(same.model.messages.map(\.content), ["Hi"])
    }

    func testEveryBotRouteShowsItsBotChatsCachedTranscriptOffline() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                             target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let bot = try XCTUnwrap(BotProfile(.object(["name": .string("default")])))
        let destination = BotDestination(server: server, connectionID: connection.id, profile: "default", conversation: "root")
        var linked = BotInboxSelection()
        linked.open(destination, connection: connection, profiles: [bot])
        for selection in [BotInboxSelection(profile: bot), linked] {
            let opened = try XCTUnwrap(selection.chat(server: server, connection: connection))
            let offline = HermesOfflineWire(rows: [])
            offline.connectFailure = URLError(.cannotConnectToHost)
            let chat = makeChat(offline, target: opened.target, linkedRoot: opened.linkedRoot)
            await chat.model.loadMessages(modelContext: context)
            XCTAssertTrue(chat.model.isViewingCachedData)
            XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        }

        var replaced = BotInboxSelection()
        replaced.open(BotDestination(server: server, connectionID: connection.id, profile: "default", conversation: "old-root"),
                      connection: connection, profiles: [bot])
        let opened = try XCTUnwrap(replaced.chat(server: server, connection: connection))
        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(offline, target: opened.target, linkedRoot: opened.linkedRoot)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages, [])
    }

    func testANewCanonicalRootDiscardsTheCachedTranscript() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let wire = HermesOfflineWire(rows: [])
        wire.canonicalRoot = "remade"
        wire.messagesFailure = BotFailure.rejected(502)
        let connected = Gate()
        wire.connectGate = connected
        let chat = makeChat(wire, target: .canonicalChat(profile: "default"))
        let load = Task { await chat.model.loadMessages(modelContext: context) }
        await waitUntil("the cached transcript shows") { !chat.model.messages.isEmpty }
        connected.open()
        await load.value

        XCTAssertFalse(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages, [], "the failure and its retry show")
        XCTAssertNotNil(chat.model.errorMessage)
        let held = await chat.model.sendMessage("Continue")
        XCTAssertFalse(held)

        let failing = HermesOfflineWire(rows: [])
        failing.canonicalRoot = "remade"
        failing.messagesFailure = BotFailure.rejected(502)
        let reopened = makeChat(failing, target: .canonicalChat(profile: "default"))
        await reopened.model.reconnectStreamIfNeeded(modelContext: context)
        XCTAssertTrue(failing.methods.contains("session.list"), "attached before any load")
        let heldAgain = await reopened.model.sendMessage("Continue")
        XCTAssertFalse(heldAgain)
        XCTAssertFalse(failing.methods.contains("prompt.submit"))

        wire.messagesFailure = nil
        await chat.model.loadMessages(modelContext: context)
        XCTAssertEqual(chat.model.messages.map(\.role), ["local_notice"])
        XCTAssertFalse(wire.methods.contains("prompt.submit"))
        let sent = await chat.model.sendMessage("Continue")
        XCTAssertTrue(sent)
        XCTAssertEqual(wire.methods.filter { $0 == "prompt.submit" }.count, 1)
    }

    func testAnArchivedBotChatShowsItsBotsCachedTranscriptOffline() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                             target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let archived = HermesSessionRow(id: "tip", title: HermesCall.botChatTitle, archived: true, hidden: true, lineageRootID: "root")
        let opened = try XCTUnwrap(archived.summary(in: "default").hermesChat(on: server, connection: connection, listedIn: "default"))
        XCTAssertEqual(opened.target, .session(profile: "default", key: "tip"))
        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(offline, target: opened.target, botChatRoot: opened.botChatRoot)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
    }

    func testAnArchivedContinuedBotChatShowsItsBotsCachedTranscriptOffline() async throws {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                             target: .canonicalChat(profile: "default"))
        await visit.model.loadMessages(modelContext: context)

        let archived = HermesSessionRow(id: "tip", title: "Bot Chat (continued)", archived: true, hidden: true, lineageRootID: "root")
        let opened = try XCTUnwrap(archived.summary(in: "default").hermesChat(on: server, connection: connection, listedIn: "default"))
        XCTAssertEqual(opened.target, .session(profile: "default", key: "tip"))
        XCTAssertEqual(opened.botChatRoot, "root")
        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let chat = makeChat(offline, target: opened.target, botChatRoot: opened.botChatRoot)
        await chat.model.loadMessages(modelContext: context)

        XCTAssertTrue(chat.model.isViewingCachedData)
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])

        let other = HermesSessionRow(id: "tip", title: "Notes (continued)", archived: true, hidden: true, lineageRootID: "root")
        XCTAssertNil(other.summary(in: "default").hermesChat(on: server, connection: connection, listedIn: "default")?.botChatRoot)
    }

    func testAnOlderArchivedBotChatNeitherPreviewsForNorGoesWithItsBot() async throws {
        let context = try makeContext()
        await makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                       target: .canonicalChat(profile: "default")).model.loadMessages(modelContext: context)
        await makeChat(HermesOfflineWire(rows: [row(1, "user", "Old question"), row(2, "assistant", "Old answer.")]),
                       target: .session(profile: "default", key: "old-tip"), botChatRoot: "old")
            .model.loadMessages(modelContext: context)

        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let bot = makeChat(offline, target: .canonicalChat(profile: "default"))
        await bot.model.loadMessages(modelContext: context)
        XCTAssertTrue(bot.model.isViewingCachedData)
        XCTAssertEqual(bot.model.messages.map(\.content), ["Hi", "Hello."])

        await makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                       target: .canonicalChat(profile: "default")).model.loadMessages(modelContext: context)
        let archivedOffline = HermesOfflineWire(rows: [])
        archivedOffline.connectFailure = URLError(.cannotConnectToHost)
        let archived = makeChat(archivedOffline, target: .session(profile: "default", key: "old-tip"), botChatRoot: "old")
        await archived.model.loadMessages(modelContext: context)
        XCTAssertTrue(archived.model.isViewingCachedData)
        XCTAssertEqual(archived.model.messages.map(\.content), ["Old question", "Old answer."])
    }

    func testAnArchivedBotChatsEmptyReadDropsItsBotsCopyOfTheUndoneRows() async throws {
        let context = try makeContext()
        await makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]),
                       target: .canonicalChat(profile: "default")).model.loadMessages(modelContext: context)
        let undone = makeChat(HermesOfflineWire(rows: []), target: .session(profile: "default", key: "tip"), botChatRoot: "root")
        await undone.model.loadMessages(modelContext: context)
        XCTAssertEqual(undone.model.messages, [])

        let offline = HermesOfflineWire(rows: [])
        offline.connectFailure = URLError(.cannotConnectToHost)
        let archived = makeChat(offline, target: .session(profile: "default", key: "tip"), botChatRoot: "root")
        await archived.model.loadMessages(modelContext: context)
        XCTAssertFalse(archived.model.isViewingCachedData)
        XCTAssertEqual(archived.model.messages, [])
    }

    func testAReadUnderWayDuringAClearLeavesTheCacheEmpty() async throws {
        let context = try makeContext()
        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi")])
        let read = Gate()
        wire.messagesGate = read
        let asked = expectation(description: "the history read is out")
        asked.assertForOverFulfill = false
        wire.onRead = { asked.fulfill() }
        let chat = makeChat(wire, target: .canonicalChat(profile: "default"))
        let load = Task { await chat.model.loadMessages(modelContext: context) }
        await fulfillment(of: [asked], timeout: 5)
        try CacheStore.clearCache(for: server, in: context)
        read.open()
        await load.value

        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi"])
        XCTAssertEqual(try botChatMessages(in: context), [])

        await makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi")]), target: .canonicalChat(profile: "default"))
            .model.loadMessages(modelContext: context)
        XCTAssertEqual(try botChatMessages(in: context), ["Hi"])
    }

    private func botChatMessages(in context: ModelContext) throws -> [String?] {
        try CacheStore.cachedHermesMessages(serverURL: server, scope: CacheStore.hermesBotChatScope(connectionID: connection.id,
                                            profile: "default", root: "root"), in: context, limit: 100).map(\.content)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func makeList(_ wire: HermesSessionListWire, profile: String? = "default") -> SessionListViewModel {
        SessionListViewModel(server: server, unreadStore: SessionUnreadStore(defaults: defaults), hermes: HermesSessionListSource(
            connection: connection, profile: profile, makeWire: { _ in wire }, preferences: defaults,
            changeDebounce: .zero, statusPollInterval: .seconds(3600), reconnectDelays: [.seconds(3600)]
        ))
    }

    private struct Chat {
        let model: ChatViewModel
        let reconnect: Gate
    }

    private func makeChat(_ wire: HermesOfflineWire, target: ConversationTarget = .session(profile: "default", key: "tip"),
                          server: URL? = nil, botChatRoot: String? = nil, linkedRoot: String? = nil,
                          lineageRoot: String? = nil) -> Chat {
        let gate = Gate()
        let server = server ?? self.server
        let engine = HermesConversation(server: server, connection: connection, target: target, linkedRoot: linkedRoot,
                                        wire: wire, reconnectDelay: { _ in await gate.wait() })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: server, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true }))
        )
        model.hermesBotChatRoot = botChatRoot
        model.hermesLineageRoot = lineageRoot
        return Chat(model: model, reconnect: gate)
    }

    private func row(_ id: Int, _ role: String, _ content: String) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
                 "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1), "compacted": .number(0),
                 "tool_call_id": .null, "tool_calls": .null, "display_kind": .null, "display_metadata": .null])
    }

    private static func delta(_ seq: Int, _ text: String) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string("message.delta"),
                 "payload": .object(["text": .string(text)])])
    }
}

@MainActor final class HermesWaitingSendTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://hermes.example")!,
                                           username: "user", password: "secret")
    private var now = Date(timeIntervalSince1970: 1_790_000_000)
    private var deadline = Gate()
    private var returned: [(text: String, reason: HermesWaitingSend.Return)] = []

    func testAnOfflineSendWaitsThenGoesOutOnceOnReconnect() async throws {
        let (chat, wire, drafts) = try await offlineChat()
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        drafts.setDraft("Ship it", for: key)

        let outcome = await chat.model.send("Ship it", isPlainText: true)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(chat.model.waitingSendMessage?.content, "Ship it")
        let held = await drafts.draft(for: key)
        XCTAssertEqual(held?.waitingSend?.text, "Ship it")
        XCTAssertEqual(held?.text, "")
        XCTAssertEqual(wire.prompts, [])

        wire.connectFailure = nil
        let reply = Gate()
        wire.submitGate = reply
        chat.reconnect.open()
        await waitUntil("it goes out") { chat.model.messages.last?.content == "Ship it" }
        chat.model.hermesConnectionDidChange(failure: nil, unserved: nil, mayRetry: true)
        chat.model.hermesConnectionDidChange(failure: nil, unserved: nil, mayRetry: true)
        reply.open()
        await waitUntil("the host took it") { chat.model.waitingSend == nil }

        XCTAssertEqual(wire.prompts, ["Ship it"])
        let sent = await drafts.draft(for: key)
        XCTAssertNil(sent?.waitingSend)
        XCTAssertEqual(returned.count, 0)
    }

    func testASendThatFindsNoConnectionWaitsForTheReconnect() async throws {
        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi")])
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: try makeContext())
        wire.onDisconnect?(BotFailure.transport)

        let outcome = await chat.model.send("Ship it", isPlainText: true)

        XCTAssertEqual(outcome, .waiting)
        XCTAssertNil(chat.model.sendErrorMessage)
        XCTAssertEqual(wire.prompts, [])
        chat.reconnect.open()
        await waitUntil("the host took it") { chat.model.waitingSend == nil }
        XCTAssertEqual(wire.prompts, ["Ship it"])
    }

    func testALostAnswerKeepsTheTextAndNeverResends() async throws {
        let (chat, wire, drafts) = try await offlineChat()
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        _ = await chat.model.send("Ship it", isPlainText: true)

        wire.connectFailure = nil
        wire.submitFailure = URLError(.networkConnectionLost)
        let reply = Gate()
        wire.submitGate = reply
        chat.reconnect.open()
        await waitUntil("it goes out") { chat.model.messages.last?.content == "Ship it" }
        wire.connectGate = Gate()
        reply.open()
        await waitUntil("it came back") { chat.model.waitingSend == nil }

        XCTAssertEqual(returned.map(\.text), ["Ship it"])
        XCTAssertTrue(chat.model.isHermesSubmissionUncertain)
        let kept = await drafts.draft(for: key)
        XCTAssertEqual(kept?.text, "Ship it")
        XCTAssertEqual(kept?.botSubmissionUncertain, true)
        XCTAssertNil(kept?.waitingSend)
        chat.model.hermesConnectionDidChange(failure: nil, unserved: nil, mayRetry: true)
        XCTAssertEqual(wire.prompts, ["Ship it"])
    }

    func testCancelAndExpiryReturnTheTextWithoutSending() async throws {
        let (chat, wire, drafts) = try await offlineChat()
        let key = try XCTUnwrap(chat.model.hermesDraftKey)

        _ = await chat.model.send("Ship it", isPlainText: true)
        drafts.setDraft("And this", for: key)
        chat.model.cancelWaitingSend()
        XCTAssertEqual(returned.last?.text, "Ship it\n\nAnd this")
        XCTAssertEqual(returned.last?.reason, .cancelled)
        XCTAssertNil(chat.model.waitingSendMessage)

        _ = await chat.model.send("Later", isPlainText: true)
        deadline.open()
        await waitUntil("it expired") { chat.model.waitingSend == nil }
        XCTAssertEqual(returned.last?.reason, .expired)
        XCTAssertEqual(returned.last?.text, "Later\n\nShip it\n\nAnd this")

        deadline = Gate()
        _ = await chat.model.send("Much later", isPlainText: true)
        now += HermesWaitingSend.lifetime
        wire.connectFailure = nil
        chat.reconnect.open()
        await waitUntil("it expired on reconnect") { chat.model.waitingSend == nil }

        XCTAssertEqual(returned.last?.reason, .expired)
        XCTAssertEqual(wire.prompts, [])
        let draft = await drafts.draft(for: key)
        XCTAssertNil(draft?.waitingSend)
    }

    func testALeftChatsSendNeverGoesOut() async throws {
        let (chat, wire, drafts) = try await offlineChat()
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        _ = await chat.model.send("Ship it", isPlainText: true)

        chat.model.leaveWaitingSend()
        XCTAssertEqual(returned.last?.reason, .left)
        _ = await chat.model.send("Next", isPlainText: true)
        wire.connectFailure = nil
        chat.reconnect.open()
        await waitUntil("the host took the later one") { chat.model.waitingSend == nil }

        XCTAssertEqual(wire.prompts, ["Next"])
        let draft = await drafts.draft(for: key)
        XCTAssertEqual(draft?.text, "Ship it")
    }

    func testBackgroundingAClaimedDeliveryWaitsForTheForeground() async throws {
        let disk = HookedDrafts()
        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi")])
        let chat = makeChat(wire, persistence: disk)
        await chat.model.loadMessages(modelContext: try makeContext())
        wire.onDisconnect?(BotFailure.transport)
        await disk.setBeforeNextWrite { [unowned self] in
            chat.reconnect.open()
            await waitUntil("reattached") { chat.engine.connectionState == .connected }
        }

        let outcome = await chat.model.send("Ship it", isPlainText: true)
        XCTAssertEqual(outcome, .waiting)
        XCTAssertEqual(chat.model.waitingSend?.delivery, .sending)
        chat.model.suspendStreamForBackground()
        await waitUntil("it waits again") { chat.model.waitingSend?.delivery == nil }

        XCTAssertEqual(wire.prompts, [])
        XCTAssertEqual(chat.model.waitingSendMessage?.content, "Ship it")
        await chat.model.reconnectStreamIfNeeded()
        await waitUntil("the host took it") { chat.model.waitingSend == nil }
        XCTAssertEqual(wire.prompts, ["Ship it"])
    }

    func testLeavingBeforeASendFindsNoConnectionKeepsItInTheComposer() async throws {
        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi")])
        let chat = makeChat(wire)
        await chat.model.loadMessages(modelContext: try makeContext())
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        let connect = Gate()
        wire.connectGate = connect
        wire.connectFailure = URLError(.notConnectedToInternet)
        chat.model.suspendStreamForBackground()
        let reattach = Task { await chat.model.reconnectStreamIfNeeded() }
        chat.drafts.setDraft("Ship it", for: key)
        let sending = Task { await chat.model.send("Ship it", isPlainText: true) }
        await waitUntil("it waits on the attach") { chat.model.messages.last?.content == "Ship it" }

        chat.drafts.setDraft("And this", for: key)
        chat.model.leaveWaitingSend()
        connect.open()
        let outcome = await sending.value
        await reattach.value

        XCTAssertEqual(outcome, .kept)
        XCTAssertEqual(returned.last?.text, "Ship it\n\nAnd this")
        let draft = await chat.drafts.draft(for: key)
        XCTAssertEqual(draft?.text, "Ship it\n\nAnd this")
        wire.connectFailure = nil
        chat.reconnect.open()
        await waitUntil("reattached") { chat.engine.connectionState == .connected }
        XCTAssertEqual(wire.prompts, [])
    }

    func testASecondSendWhileTheFirstIsWrittenLeavesTheFirstWaiting() async throws {
        let disk = HookedDrafts()
        let (chat, wire, drafts) = try await offlineChat(persistence: disk)
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        drafts.setDraft("Ship it", for: key)
        await disk.setBeforeNextWrite { [unowned self] in
            wire.connectFailure = nil
            wire.running = true
            chat.reconnect.open()
            await waitUntil("reconnected onto the reply") { chat.model.activeStreamID != nil }
            drafts.setDraft("And this", for: key)
            Task { _ = await chat.model.submitStreamingMessage("And this", behavior: .queue) }
            await waitUntil("the second Send is refused") { chat.model.sendErrorMessage != nil }
        }

        let first = await chat.model.send("Ship it", isPlainText: true)
        await waitUntil("the host took the first") { chat.model.waitingSend == nil }

        XCTAssertEqual(first, .waiting)
        XCTAssertEqual(wire.prompts, ["Ship it"])
        let draft = await drafts.draft(for: key)
        XCTAssertEqual(draft?.text, "And this")
    }

    func testADeliveryThatExpiresBeforeItsWriteComesBack() async throws {
        let disk = HookedDrafts()
        let (chat, wire, _) = try await offlineChat(persistence: disk)
        _ = await chat.model.send("Ship it", isPlainText: true)
        await disk.setBeforeNextWrite { [unowned self] in now += HermesWaitingSend.lifetime }

        wire.connectFailure = nil
        chat.reconnect.open()
        await waitUntil("it came back") { chat.model.waitingSend == nil }

        XCTAssertEqual(returned.last?.reason, .expired)
        XCTAssertEqual(wire.prompts, [])
    }

    func testASendThatCannotBeSavedStaysInTheComposer() async throws {
        let (chat, _, drafts) = try await offlineChat(persistence: HookedDrafts(failsWrites: true))
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        drafts.setDraft("Ship it", for: key)

        let outcome = await chat.model.send("Ship it", isPlainText: true)

        XCTAssertEqual(outcome, .kept)
        XCTAssertNil(chat.model.waitingSend)
        let draft = await drafts.draft(for: key)
        XCTAssertEqual(draft?.text, "Ship it")
        XCTAssertNil(draft?.waitingSend)
    }

    private func offlineChat(persistence: any ChatDraftPersisting = BotMemoryDrafts()) async throws
        -> (Chat, HermesOfflineWire, ChatDraftStore) {
        let context = try makeContext()
        let visit = makeChat(HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]))
        await visit.model.loadMessages(modelContext: context)
        let wire = HermesOfflineWire(rows: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")])
        wire.connectFailure = URLError(.notConnectedToInternet)
        let chat = makeChat(wire, persistence: persistence)
        await chat.model.loadMessages(modelContext: context)
        XCTAssertTrue(chat.model.showsOfflineCache)
        return (chat, wire, chat.drafts)
    }

    private struct Chat {
        let model: ChatViewModel
        let engine: HermesConversation
        let drafts: ChatDraftStore
        let reconnect: Gate
    }

    private func makeChat(_ wire: HermesOfflineWire, persistence: any ChatDraftPersisting = BotMemoryDrafts()) -> Chat {
        let gate = Gate()
        let engine = HermesConversation(server: server, connection: connection, target: .session(profile: "default", key: "tip"),
                                        wire: wire, reconnectDelay: { _ in await gate.wait() })
        let drafts = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(60))
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: server, streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: drafts, backend: .hermes(HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })),
            waitingSendClock: HermesWaitingSendClock(now: { [unowned self] in now }, sleep: { [unowned self] _ in
                await deadline.wait()
            })
        )
        model.onWaitingSendReturned = { [unowned self] text, reason in returned.append((text, reason)) }
        return Chat(model: model, engine: engine, drafts: drafts, reconnect: gate)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: CachedSession.self, CachedMessage.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func row(_ id: Int, _ role: String, _ content: String) -> BotJSON {
        .object(["id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
                 "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1), "compacted": .number(0),
                 "tool_call_id": .null, "tool_calls": .null, "display_kind": .null, "display_metadata": .null])
    }
}

private actor HookedDrafts: ChatDraftPersisting {
    private let failsWrites: Bool
    private var values: [ChatDraftKey: ChatDraft] = [:]
    private var beforeNextWrite: (@MainActor @Sendable () async -> Void)?

    init(failsWrites: Bool = false) { self.failsWrites = failsWrites }

    func setBeforeNextWrite(_ hook: @escaping @MainActor @Sendable () async -> Void) { beforeNextWrite = hook }

    func load() -> [ChatDraftKey: ChatDraft] { values }

    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {
        if let hook = beforeNextWrite {
            beforeNextWrite = nil
            await hook()
        }
        if failsWrites { throw CocoaError(.fileWriteOutOfSpace) }
        values = drafts
    }
}

@MainActor private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@MainActor private final class HermesOfflineWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var canonicalRoot = "root"
    var tip = "tip"
    var connectGate: Gate?
    var connectFailure: Error?
    var replayFailure: Error?
    var messagesFailure: Error?
    var messagesGate: Gate?
    var onRead: (() -> Void)?
    var running = false
    var rows: [BotJSON]
    private(set) var methods: [String] = []
    private(set) var prompts: [String] = []
    var submitGate: Gate?
    var submitFailure: Error?

    init(rows: [BotJSON]) { self.rows = rows }

    func connect() async throws {
        await connectGate?.wait()
        if let connectFailure { throw connectFailure }
    }

    func close() {}

    func call(_ call: HermesCall, validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        methods.append(call.method)
        switch call.method {
        case "session.list":
            return .object(["sessions": .array([.object(["id": .string(canonicalRoot), "resolved_id": .string(tip)])])])
        case "session.resume":
            return .object(["session_id": .string("runtime"), "session_key": .string(tip), "running": .bool(running),
                            "messages": .array([]), "info": .object(["profile_name": .string("default")])])
        case "session.events.since":
            if let replayFailure { throw replayFailure }
            return BotFixtureWire.replay(latest: 0)
        case "prompt.submit":
            prompts.append(try call.params()["text"]?.text ?? "")
            await submitGate?.wait()
            if let submitFailure { throw submitFailure }
            return .object(["status": .string("streaming")])
        default: throw BotFailure.unsupported
        }
    }

    func sessionMessages(_ key: String, profile: String, offset: Int?) async throws -> [BotJSON]? {
        onRead?()
        await messagesGate?.wait()
        if let messagesFailure { throw messagesFailure }
        return offset == 0 ? rows : []
    }
}
