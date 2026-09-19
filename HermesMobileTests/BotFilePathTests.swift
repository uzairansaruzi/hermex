import XCTest
@testable import HermesMobile

final class BotFilePathSearchTests: XCTestCase {
    func testWordForBareTriggerListsTheRoot() {
        XCTAssertEqual(BotFilePathSearch.word(for: ""), ".")
        XCTAssertEqual(BotFilePathSearch.word(for: "src/Ch"), "src/Ch")
    }

    func testPlainAndDirectiveItemsDecodeToRows() throws {
        let reply = BotJSON.object(["items": .array([
            .object(["text": .string("src/"), "display": .string("src/"), "meta": .string("dir")]),
            .object(["text": .string("README.md"), "display": .string("README.md"), "meta": .string("")]),
            .object(["text": .string("@file:research/notes.md"), "display": .string("notes.md"), "meta": .string("research")]),
            .object(["text": .string("@folder:src/"), "display": .string("src/"), "meta": .string("dir")]),
            .object(["text": .string(".env"), "display": .string(".env"), "meta": .string("")])
        ])])

        let matches = BotFilePathSearch.matches(from: reply)

        XCTAssertEqual(matches.map(\.path), ["src", "README.md", "research/notes.md", "src", ".env"])
        XCTAssertEqual(matches.map(\.isDirectory), [true, false, false, true, false])
        XCTAssertEqual(matches[0].name, "src")
        XCTAssertEqual(matches[0].parentPath, "")
        XCTAssertEqual(matches[2].name, "notes.md")
        XCTAssertEqual(matches[2].parentPath, "research")
    }

    func testUnnameableEntriesAreDropped() {
        let reply = BotJSON.object(["items": .array([
            .object(["text": .string("@diff"), "display": .string("@diff"), "meta": .string("git diff")]),
            .object(["text": .string("@url:https://example.com"), "display": .string("example"), "meta": .string("")]),
            .object(["text": .string("my notes.md"), "display": .string("my notes.md"), "meta": .string("")]),
            .object(["text": .string("../secrets"), "display": .string(".."), "meta": .string("")]),
            .object(["text": .string("/etc/hosts"), "display": .string("hosts"), "meta": .string("")]),
            .object(["text": .string("@file:"), "display": .string(""), "meta": .string("")])
        ])])

        XCTAssertTrue(BotFilePathSearch.matches(from: reply).isEmpty)
        XCTAssertTrue(BotFilePathSearch.matches(from: .object(["items": .null])).isEmpty)
    }
}

@MainActor
final class ComposerFilePathSearchLoadTests: XCTestCase {
    func testLateReplyNeverOverwritesANewerQuery() async {
        let search = ComposerFilePathSearch()
        let gate = QueryGate()
        let started = expectation(description: "slow query started")

        let slow = Task { @MainActor in
            await search.search("slow") { _ in
                started.fulfill()
                await gate.wait()
                return [Self.match("slow.md")]
            }
        }
        await fulfillment(of: [started], timeout: 2)

        await search.search("fast") { _ in [Self.match("fast.md")] }
        XCTAssertEqual(search.matches.map(\.path), ["fast.md"])

        gate.open()
        await slow.value
        XCTAssertEqual(search.matches.map(\.path), ["fast.md"])
        XCTAssertFalse(search.isLoading)
    }

    func testResetDropsAReplyStillInFlight() async {
        let search = ComposerFilePathSearch()
        let gate = QueryGate()
        let started = expectation(description: "query started")

        let query = Task { @MainActor in
            await search.search("late") { _ in
                started.fulfill()
                await gate.wait()
                return [Self.match("late.md")]
            }
        }
        await fulfillment(of: [started], timeout: 2)

        search.reset()
        gate.open()
        await query.value

        XCTAssertTrue(search.matches.isEmpty)
        XCTAssertFalse(search.isLoading)
    }

    private static func match(_ path: String) -> ComposerFilePathSearch.Match {
        ComposerFilePathSearch.Match(path: path, name: path, parentPath: "", isDirectory: false)
    }
}

/// Holds one query's closure open until the test says otherwise, so a late
/// reply can be raced against a newer one deterministically.
@MainActor
private final class QueryGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class BotAtPanelSectionTests: XCTestCase {
    func testRosterRendersAboveFiles() {
        let sections = BotAtPanelSection.sections(
            botCompletions: [bot("research")],
            fileMatches: [match("src/App.swift")],
            isLoadingFiles: false
        )

        XCTAssertEqual(sections.count, 2)
        guard case .bots(let bots) = sections[0] else { return XCTFail("Files rendered above the roster") }
        guard case .files(let files) = sections[1] else { return XCTFail("Files section missing") }
        XCTAssertEqual(bots.map(\.tag), ["research"])
        XCTAssertEqual(files.map(\.path), ["src/App.swift"])
    }

    func testEmptyRosterShowsFilesAlone() {
        let sections = BotAtPanelSection.sections(
            botCompletions: [],
            fileMatches: [match("src/App.swift")],
            isLoadingFiles: false
        )

        XCTAssertEqual(sections.count, 1)
        guard case .files = sections[0] else { return XCTFail("A files-only panel expected") }
    }

    func testFailedLookupLeavesTheRosterStanding() {
        let sections = BotAtPanelSection.sections(
            botCompletions: [bot("research")],
            fileMatches: [],
            isLoadingFiles: false
        )

        XCTAssertEqual(sections.count, 1)
        guard case .bots(let bots) = sections[0] else { return XCTFail("The roster must survive a failed lookup") }
        XCTAssertEqual(bots.map(\.tag), ["research"])
    }

    func testNothingToShowMeansNoPanel() {
        XCTAssertTrue(BotAtPanelSection.sections(
            botCompletions: [],
            fileMatches: [],
            isLoadingFiles: false
        ).isEmpty)
    }

    func testLoadingShowsTheFilesHeadingWithNoRowsYet() {
        let sections = BotAtPanelSection.sections(
            botCompletions: [],
            fileMatches: [],
            isLoadingFiles: true
        )

        XCTAssertEqual(sections.count, 1)
        guard case .files(let files) = sections[0] else { return XCTFail("A loading files section expected") }
        XCTAssertTrue(files.isEmpty)
    }

    func testRoomMentionsStayMemberOnly() throws {
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 1)))

        XCTAssertTrue(BotRoomMentions.completions(room: room, query: "src/Ch").isEmpty)
        XCTAssertFalse(BotRoomMentions.completions(room: room, query: "").isEmpty)
    }

    func testPathShapedQueriesNeverOfferBots() {
        let profile = BotProfile(.object(["name": .string("research")]))!
        let mentions = BotMentions(roster: [profile], excluding: "dev")

        XCTAssertTrue(mentions.completions(query: "src/Ch").isEmpty)
        XCTAssertEqual(mentions.completions(query: "res").map(\.tag), ["research"])
    }

    private func bot(_ tag: String) -> BotMentions.Completion {
        BotMentions.Completion(
            profile: BotProfile(.object(["name": .string(tag)]))!,
            tag: tag
        )
    }

    private func match(_ path: String) -> ComposerFilePathSearch.Match {
        ComposerFilePathSearch.Match(path: path, name: path, parentPath: "", isDirectory: false)
    }
}

@MainActor
final class BotFilePathConversationTests: XCTestCase {
    func testCompletePathIsScopedToTheLiveRuntimeAndProfile() async throws {
        let target = BotProfile(.object(["name": .string("default")]))!
        let wire = BotFixtureWire()
        wire.settingsCall = Self.completion(items: [
            ["text": "research-notes.md", "display": "research-notes.md", "meta": ""]
        ])
        let model = make(wire, roster: [target])
        await model.recover()

        await model.searchFilePaths("res")

        let call = try XCTUnwrap(wire.calls.first { $0.0 == "complete.path" })
        XCTAssertEqual(call.1["word"], .string("res"))
        XCTAssertEqual(call.1["session_id"], .string(wire.runtimeID))
        XCTAssertEqual(call.1["profile"], .string("inbox-triage"))
        XCTAssertEqual(model.filePathSearch.matches.map(\.path), ["research-notes.md"])
        model.suspend()
    }

    func testBareQueryAsksForTheRootAndAFailedLookupPublishesNothing() async throws {
        let target = BotProfile(.object(["name": .string("default")]))!
        let wire = BotFixtureWire()
        let model = make(wire, roster: [target])
        await model.recover()

        await model.searchFilePaths("")

        XCTAssertEqual(wire.calls.last?.1["word"], .string("."))
        XCTAssertTrue(model.filePathSearch.matches.isEmpty)
        XCTAssertFalse(model.filePathSearch.isLoading)
        model.suspend()
    }

    func testDisconnectedConversationNeverAsksTheHost() async {
        let wire = BotFixtureWire()
        let model = make(wire, roster: [])

        await model.searchFilePaths("res")

        XCTAssertTrue(wire.calls.isEmpty)
        XCTAssertTrue(model.filePathSearch.matches.isEmpty)
        XCTAssertFalse(model.filePathSearch.isLoading)
    }

    func testPickedChipsAndRowsDieWithTheWorkspace() async throws {
        let target = BotProfile(.object(["name": .string("default")]))!
        let wire = BotFixtureWire()
        wire.settingsCall = Self.completion(items: [
            ["text": "src/App.swift", "display": "App.swift", "meta": "src"]
        ])
        let model = make(wire, roster: [target])
        await model.recover()

        await model.searchFilePaths("App")
        model.recordFileChipReference("src/App.swift")
        XCTAssertEqual(model.fileChipPaths, ["src/App.swift"])
        XCTAssertEqual(model.filePathSearch.matches.map(\.path), ["src/App.swift"])

        model.resetFileReferences()

        XCTAssertTrue(model.fileChipPaths.isEmpty)
        XCTAssertTrue(model.filePathSearch.matches.isEmpty)
        model.suspend()
    }

    private func make(_ wire: BotFixtureWire, roster: [BotProfile]) -> BotConversation {
        BotConversation(server: URL(string: "https://webui.example")!,
                        connection: BotConnection(id: UUID(), name: "Test", address: URL(string: "https://bot.example")!, username: "test", password: "test"),
                        profile: BotProfile(.object(["name": .string("inbox-triage")]))!, roster: roster,
                        wire: wire, drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
                        attachmentCopies: BotAttachmentCopies())
    }

    private static func completion(items: [[String: String]]) -> (String, [String: BotJSON]) -> BotJSON {
        { _, _ in
            .object(["items": .array(items.map { item in
                .object(item.mapValues { BotJSON.string($0) })
            })])
        }
    }
}
