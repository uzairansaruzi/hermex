import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import HermesMobile

@MainActor final class BotChatPresentationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { warmUpSoftwareKeyboard() }
    }

    func testAttachmentOverlayReceivesOwningSceneLifecycle() async throws {
        let model = AttachmentSceneHarnessModel()
        let window = try show(AttachmentSceneHarnessView(model: model))
        defer { close(window) }
        await settle(window)
        model.isPresented = true
        await settle(window)
        XCTAssertEqual(model.observedPhase, .active, "Camera startup must see the presenting scene's active phase")

        model.phase = .background
        await settle(window)
        XCTAssertEqual(model.observedPhase, .background, "A backgrounded scene must stop camera access")
        model.phase = .active
        await settle(window)
        XCTAssertEqual(model.observedPhase, .active, "Returning to the scene must restart the camera")
    }

    func testRoomPillKeepsRequestsAndRecoveryReachableWithoutRoutineStatus() {
        XCTAssertNil(BotComposerPill.room(link: .connecting, blocked: false, hasActions: false, mayRetry: false, errorText: nil))
        XCTAssertNil(BotComposerPill.room(link: .live, blocked: false, hasActions: false, mayRetry: false, errorText: nil))
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: true, hasActions: true, mayRetry: false, errorText: "failed"),
                       .error("failed"), "Blocked-room actions must not hide a failed command")
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: true, hasActions: true, mayRetry: false, errorText: nil),
                       .request("Waiting for your answer"))
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: true, hasActions: true, mayRetry: true, errorText: nil),
                       .retrySend, "An uncertain send must remain recoverable while another member waits")
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: true, hasActions: false, mayRetry: false, errorText: nil),
                       .notice("Waiting on Hermes Desktop"))
        XCTAssertEqual(BotComposerPill.room(link: .stopped, blocked: true, hasActions: true, mayRetry: false, errorText: nil),
                       .reconnect, "Stale approval state must not hide connection recovery")
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: false, hasActions: false, mayRetry: true, errorText: nil), .retrySend)
        XCTAssertEqual(BotComposerPill.room(link: .live, blocked: false, hasActions: false, mayRetry: true, errorText: "Outcome unknown"),
                       .error("Outcome unknown"))
    }

    /// A refused password takes Reconnect's slot, and keeps it once a background has
    /// left the room idle, because the room does not reopen on its own (#884).
    func testRoomPillOffersUpdateSignInAfterARejectedPassword() {
        XCTAssertEqual(BotComposerPill.room(link: .stopped, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: nil), .updateSignIn)
        XCTAssertEqual(BotComposerPill.room(link: .idle, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: nil), .updateSignIn)
        XCTAssertEqual(BotComposerPill.room(link: .stopped, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: "Hermes didn't accept the username or password."),
                       .error("Hermes didn't accept the username or password."), "the error still shows first")
    }

    func testRoomManagementShowsMemberChipsAndStoppingReason() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let roster = [
            BotProfile(.object(["name": .string("chief-of-staff"), "display_name": .string("Chief of Staff")]))!,
            BotProfile(.object(["name": .string("inbox-triage"), "display_name": .string("Inbox")]))!,
            BotProfile(.object(["name": .string("dev"), "display_name": .string("Developer")]))!
        ]
        let creator = BotRoomCreator(server: server, connection: connection, roster: roster)
        creator.select(roster[0]); creator.select(roster[1])
        let picker = try show(BotRoomCreateView(creator: creator, avatars: [:], onCreated: { _ in
            XCTFail("Rendering must never create a room")
        }).environment(\.scenePhase, .inactive))
        picker.overrideUserInterfaceStyle = .dark
        let selected = try await screenshot(picker, name: "529-member-picker", awaiting: ["Chief of Staff", "Inbox"])
        XCTAssertTrue(selected.contains("Chief of Staff"), selected)
        XCTAssertTrue(selected.contains("Inbox"), selected)
        close(picker)

        let wire = RoomWire(); wire.driverStatus = RoomFixture.status(stopping: 1)
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: "fixture-room"),
            connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, cache: BotHistoryCache(), makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomProfileView(reader: reader, roster: roster, avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await settle(window)
        await reader.open()
        // Each status line is a bare `if` on one of these reader flags, which
        // `BotRoomTests` derives; the rename field coming and going shows the
        // view follows the same reader state.
        let editable = await settle(window) { descendants(window).contains { $0 is UITextField } }
        XCTAssertTrue(editable, "Local room name is editable")
        XCTAssertTrue(reader.finishingStop, "Drives the Finishing stop line")
        XCTAssertFalse(reader.mayDisband)
        wire.authority = "foreign"
        await reader.poll(); await settle(window)
        XCTAssertTrue(reader.foreignAuthority, "Drives the Managed by another Hermes line")
        XCTAssertFalse(descendants(window).contains { $0 is UITextField }, "Foreign rooms have no rename field")
        XCTAssertTrue(wire.writes.isEmpty)
    }

    func testRoomMentionPanelUsesRoomRoster() async throws {
        let names = ["chief-of-staff", "inbox-triage"]
        let roster = try names.enumerated().map { index, name in
            try XCTUnwrap(BotProfile(.object([
                "name": .string(name),
                "ui_meta": .object(["hermes-bots": .object([
                    "shape": .string(index == 0 ? "circle" : "triangle"),
                    "color": .string(index == 0 ? "#f97316" : "#22c55e")
                ])])
            ])))
        }
        var value = try XCTUnwrap(RoomFixture.room(latest: 0).fields)
        value["members"] = .array(names.enumerated().map { index, name in
            .object(["member_id": .string("member-\(index)"), "profile": .string(name),
                     "handle": .string(name), "display_name": .string(name)])
        })
        let room = try XCTUnwrap(BotGroupRoom(.object(value)))
        let completions = BotRoomMentions.completions(room: room, query: "")
        var selected: String?
        let window = try show(VStack(spacing: 24) {
            HStack {
                BotRoomAvatars(room: room, roster: roster, avatars: [:], size: 30)
                Text(verbatim: room.name)
            }
            BotMentionAutocompleteView(completions: completions, avatars: [:], room: room, roster: roster) {
                selected = $0.tag
            }
        }.padding())
        window.overrideUserInterfaceStyle = .dark
        defer { close(window) }
        await settle(window)
        // One band per drawn row is the rendered check: the header, a row per
        // member, and the two broadcast rows.
        XCTAssertEqual(Self.roomAvatarColorBands(capture(window, name: "527-room-mention-avatars")), [
            ["orange", "green"], ["orange"], ["green"], ["orange", "green"], ["orange", "green"]
        ], "Header and broadcast rows show both avatars; each member row shows only its own")
        XCTAssertEqual(completions.map(\.tag), names + ["all", "everyone"])
        XCTAssertEqual(completions.last?.profile.name, "Everyone", "The @everyone row is named for the room")
        XCTAssertNil(selected, "Rendering suggestions must not insert a mention")
    }

    func testRoomTranscriptDismissesKeyboardWithoutLosingDraft() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.latest = 3; wire.kind = "message.member"
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 3)))
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
                                   connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        let view = BotRoomView(reader: reader, roster: [], avatars: [:])
        let window = try show(NavigationStack { view }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await reader.open()
        await settle(window)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        let scrollViews = descendants(window).compactMap { $0 as? UIScrollView }.filter { !($0 is UITextView) }
        let transcript = try XCTUnwrap(scrollViews.first {
            $0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory
        }, "Transcript scroll modes: \(scrollViews.map { $0.keyboardDismissMode.rawValue })")
        XCTAssertFalse(editor.isDescendant(of: transcript), "The dismissal gesture belongs to the transcript, not the composer")
        XCTAssertTrue(editor.becomeFirstResponder())
        await settle(window)
        editor.insertText("Unsent room draft")
        await settle(window)

        view.dismissKeyboard()
        await settle(window)
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertEqual(reader.draft, "Unsent room draft")
        XCTAssertEqual(editor.sourceText, reader.draft)
        XCTAssertTrue(descendants(window).contains { $0 === editor })
        XCTAssertTrue(editor.becomeFirstResponder(), "The same editor can be focused again after dismissal")
        await settle(window)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(wire.writes.isEmpty, "Dismissing the keyboard must not send the draft")
    }

    func testRoomShowsMemberMessagesAndTextOnlyComposer() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.latest = 3; wire.kind = "message.member"
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 3)))
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
                                   connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await reader.open()
        await settle(window)
        await settle(window) { (try? replyLeaves(in: window))?.visible.contains("Message 3") == true }
        let replies = try replyLeaves(in: window)
        XCTAssertTrue(replies.visible.contains("Message 3"), "Member message on screen: \(replies)")
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertEqual(editor.accessibilityLabel, "Message Comms", "The composer names the room it writes to")
        XCTAssertFalse(editor.acceptsAttachments)
    }

    func testANewRoomShowsItsMembersUntilTheFirstMessage() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.kind = "message.member"
        let names = ["Ada", "Linus", "Grace"]
        wire.members = names.map { name in
            .object(["member_id": .string(name.lowercased()), "profile": .string(name.lowercased()), "display_name": .string(name)])
        }
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
                                   connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await reader.open()
        let prompt = "Say something to the group"
        let welcome = try await screenshot(window, name: "895-new-room-welcome", awaiting: names + [prompt])
        for text in names + [prompt] { XCTAssertTrue(welcome.contains(text), "Expected \(text) on the new room: \(welcome)") }
        XCTAssertFalse(welcome.contains("No messages yet"), welcome)
        let transcript = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            !($0 is UITextView) && ($0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory)
        })
        let visible = transcript.bounds.height - transcript.adjustedContentInset.top - transcript.adjustedContentInset.bottom
        XCTAssertEqual(transcript.contentSize.height, visible, accuracy: 1,
                       "The welcome fills the visible transcript without scrolling: \(transcript.bounds), \(transcript.adjustedContentInset)")

        wire.authority = "another-install"
        await reader.poll()
        let foreign = try await screenshot(window, name: "895-foreign-room-welcome", awaiting: names + ["Managed by another Hermes"])
        for text in names { XCTAssertTrue(foreign.contains(text), "A foreign room still shows \(text): \(foreign)") }
        XCTAssertFalse(foreign.contains(prompt), "A room this phone can't write to has no prompt: \(foreign)")

        wire.latest = 1
        await reader.poll()
        await settle(window) { (try? replyLeaves(in: window))?.visible.contains("Message 1") == true }
        XCTAssertTrue(try replyLeaves(in: window).visible.contains("Message 1"))
        let conversation = try screenshot(window, name: "895-first-message")
        for text in names { XCTAssertFalse(conversation.contains(text), "The welcome leaves with the first message: \(conversation)") }
    }

    func testANewSixMemberRoomStacksEveryMemberAtTheLargestTextSize() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.kind = "message.member"
        let names = ["Ada", "Linus", "Grace", "Alan", "Barbara", "Edsger"]
        wire.members = names.map { name in
            .object(["member_id": .string(name.lowercased()), "profile": .string(name.lowercased()), "display_name": .string(name)])
        }
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
                                   connection: connection, room: room, cache: BotHistoryCache(), makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }
        .environment(\.scenePhase, .inactive)
        .environment(\.dynamicTypeSize, .accessibility5))
        defer { reader.close(); close(window) }
        await reader.open()
        let prompt = "Say something to the group"
        await settle(window)
        let transcript = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            !($0 is UITextView) && ($0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory)
        })
        func outgrows() -> Bool {
            transcript.contentSize.height > transcript.bounds.height - transcript.adjustedContentInset.top
                - transcript.adjustedContentInset.bottom + 1
        }
        await settle(window, until: outgrows)
        XCTAssertTrue(outgrows(), "Six stacked members outgrow the transcript: \(transcript.contentSize), \(transcript.bounds)")
        drag(transcript, to: -transcript.adjustedContentInset.top)
        let top = try await screenshot(window, name: "895-largest-text-welcome-top", awaiting: [names[0]])
        drag(transcript, to: transcript.contentSize.height - transcript.bounds.height + transcript.adjustedContentInset.bottom)
        let bottom = try await screenshot(window, name: "895-largest-text-welcome-bottom", awaiting: [names[5], prompt])
        for text in names + [prompt] {
            XCTAssertTrue("\(top) \(bottom)".contains(text), "Scrolling reaches \(text): top \(top) / bottom \(bottom)")
        }
    }

    func testRoomMessageSearchShowsRoomAndSenderAfterOpeningTheRoom() async throws {
        let server = URL(string: "https://search.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let cache = BotHistoryCache(), wire = RoomWire()
        let inbox = BotInbox(server: server, store: store, historyCache: cache, makeWire: { _ in wire })
        await inbox.open()
        defer { inbox.close() }
        let room = try XCTUnwrap(inbox.rooms.first)
        let roomWire = RoomWire(); roomWire.latest = 20; roomWire.kind = "message.member"
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
            connection: connection, room: room, cache: cache, makeWire: { _ in roomWire })
        await reader.open(); reader.close()
        // The row's "room · sender" title is built from these two values. Assert them
        // directly: OCR on the hosted CI simulator misreads that line ("chier-of-statt").
        let hits = try await cache.search("Message 20", scope: .init(server: server, connectionID: connection.id),
                                          roomIDs: Set(inbox.rooms.map(\.id)))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(inbox.roomForSearch(hit)?.name, "Comms")
        XCTAssertEqual(hit.message.sender, "chief-of-staff")
        let window = try show(BotSearchView(inbox: inbox, cache: cache, query: "Message 20") { _ in }
            .environment(\.scenePhase, .active))
        defer { close(window) }
        // The view debounces its query before reading the cache, so wait for the row itself:
        // its trailing "Message" kind label draws below the section header only with a room hit.
        let header = "Messages saved on this iPhone"
        let after = try await screenshot(window, name: "528-after-opening-room") {
            $0.components(separatedBy: header).dropFirst().joined().contains("Message")
        }
        XCTAssertTrue(after.components(separatedBy: header).dropFirst().joined().contains("Message"), after)
        XCTAssertFalse(after.contains("No saved messages found"), after)
    }

    /// Room messages saved on this iPhone show as soon as the cache answers (#1146): the host's
    /// search of the bots' chats, still out here, does not hold them back.
    func testSavedRoomHitsShowWhileTheHostSearchIsPending() async throws {
        let server = URL(string: "https://search.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let wire = BotInboxFixtureWire(roster: [.object(["name": .string("inbox"), "display_name": .string("Inbox")])])
        wire.rooms = [RoomFixture.room(latest: 20)]
        wire.holdsSearch = true
        let cache = BotHistoryCache()
        let inbox = BotInbox(server: server, store: store, historyCache: cache, makeWire: { _ in wire })
        await inbox.open()
        defer { wire.release(); inbox.close() }
        let room = try XCTUnwrap(inbox.rooms.first)
        try await cache.appendRoom(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id), room: room,
                                   page: RoomFixture.page([RoomFixture.event(20)], cursor: 20), since: 0)
        let window = try show(BotSearchView(inbox: inbox, cache: cache, query: "Message 20") { _ in }
            .environment(\.scenePhase, .active))
        defer { close(window) }
        // The room row's trailing "Message" kind label draws below the section header only with a hit.
        let header = "Messages saved on this iPhone"
        let text = try await screenshot(window, name: "1146-room-hits-before-bot-hits") {
            $0.components(separatedBy: header).dropFirst().joined().contains("Message")
        }
        XCTAssertTrue(text.components(separatedBy: header).dropFirst().joined().contains("Message"), text)
        XCTAssertTrue(text.components(separatedBy: header).first?.contains("Searching") == true, "The bots' search is pending: \(text)")
        XCTAssertEqual(wire.searches.map(\.query), ["Message 20"], "The host search is still held")

        wire.release()
        let answered = try await screenshot(window, name: "1146-bot-search-answered") {
            $0.components(separatedBy: header).first?.contains("Searching") == false
        }
        XCTAssertFalse(answered.components(separatedBy: header).first?.contains("Searching") ?? true, answered)
    }

    func testThreadSearchOpensChronologicalDetailAndItsOwnComposer() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 80)))
        let cache = BotHistoryCache()
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        var log = BotRoomLog()
        let events = (1...80).map { seq -> BotJSON in
            var event = RoomFixture.event(seq, kind: seq == 1 ? "message.user" : "message.member").fields!
            event["payload"] = .object(["text": .string("Thread message \(seq)"), "thread_id": .string("desktop-thread")])
            return .object(event)
        }
        log.apply(RoomFixture.page(events, cursor: 80))
        cache.recent.save(log, for: .init(key), owner: cache.recent.begin(.init(key)))
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: cache,
                                   initialSequence: 20, makeWire: { _ in RoomWire() })
        reader.draft = "overview draft"
        reader.setDraft("thread draft", in: "desktop-thread")
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await settle(window) {
            descendants(window).compactMap { $0 as? ComposerChipTextView }
                .contains { $0.accessibilityLabel == "Reply in thread" }
        }
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }
            .first { $0.accessibilityLabel == "Reply in thread" })
        XCTAssertEqual(editor.sourceText, "thread draft")
        XCTAssertEqual(reader.draft, "overview draft")
        let replies = try replyLeaves(in: window)
        XCTAssertTrue(replies.visible.contains("Thread message 20"), "Search must materialize and reveal its actual thread: \(replies)")
        XCTAssertFalse(replies.visible.contains("Thread message 80"), "Search must keep the reading anchor")
    }

    func testWarmRoomBuildsOnlyTheNewestPageOfReplies() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 300)))
        let cache = BotHistoryCache()
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        var log = BotRoomLog()
        log.apply(RoomFixture.page((1...300).map { RoomFixture.event($0, kind: "message.member") }, cursor: 300))
        cache.recent.save(log, for: .init(key), owner: cache.recent.begin(.init(key)))
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: cache, makeWire: { _ in RoomWire() })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await settle(window)
        let hosts = descendants(window).filter { $0.next is ResponseSelectionController }
        XCTAssertEqual(reader.events.count, 300)
        XCTAssertEqual(hosts.count, BotRoomTranscriptWindow.pageSize, "Each built reply hosts one selection controller")
    }

    func testRoomSearchHitScrollsToItsSequenceAndDoesNotFollowNewMessages() async throws {
        try await assertRoomSearchTarget(warm: false)
    }

    func testWarmRoomSearchShowsItsTargetBeforeRefreshing() async throws {
        try await assertRoomSearchTarget(warm: true)
    }

    private func assertRoomSearchTarget(warm: Bool) async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.latest = 80; wire.kind = "message.member"
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 80)))
        let cache = BotHistoryCache()
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        if warm {
            var log = BotRoomLog()
            log.apply(RoomFixture.page((1...80).map { RoomFixture.event($0, kind: "message.member") }, cursor: 80))
            cache.recent.save(log, for: .init(key), owner: cache.recent.begin(.init(key)))
        }
        let reader = BotRoomReader(key: key,
            connection: connection, room: room, cache: cache, initialSequence: 20, makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await settle(window)
        // The newest reply is built in every check below, so its absence from
        // the viewport means the transcript sits on the hit, not that it is unbuilt.
        if warm {
            let beforeNetwork = try replyLeaves(in: window)
            XCTAssertTrue(beforeNetwork.visible.contains("Message 20"), "\(beforeNetwork)")
            XCTAssertTrue(beforeNetwork.built.contains("Message 80"), "\(beforeNetwork)")
            XCTAssertFalse(beforeNetwork.visible.contains("Message 80"), "\(beforeNetwork)")
        }
        await reader.open()
        await settle(window)
        let selected = try replyLeaves(in: window)
        XCTAssertTrue(selected.visible.contains("Message 20"), "\(selected)")
        XCTAssertTrue(selected.built.contains("Message 80"), "\(selected)")
        XCTAssertFalse(selected.visible.contains("Message 80"), "\(selected)")
        wire.latest = 81; await reader.poll()
        await settle(window)
        let updated = try replyLeaves(in: window)
        XCTAssertTrue(updated.visible.contains("Message 20"), "\(updated)")
        XCTAssertTrue(updated.built.contains("Message 81"), "\(updated)")
        XCTAssertFalse(updated.visible.contains("Message 81"), "\(updated)")
    }

    func testLocalBotSearchShowsBotNamesAndNeverResumesWhileBrowsing() async throws {
        let server = URL(string: "https://search.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let wire = BotInboxFixtureWire(roster: [
            .object(["name": .string("inbox"), "display_name": .string("Inbox"), "description": .string("Your email triage bot")]),
            .object(["name": .string("apartments"), "display_name": .string("Apartments"), "description": .string("Your apartment hunt specialist")])
        ])
        let inbox = BotInbox(server: server, store: store, makeWire: { _ in wire })
        await inbox.open()
        let cache = BotHistoryCache()
        // The view focuses its field from `.task`, some run-loop turns after it
        // appears, so wait for the field to begin editing, not a pass count.
        let focused = expectation(forNotification: UITextField.textDidBeginEditingNotification, object: nil)
        let window = try show(BotSearchView(inbox: inbox, cache: cache) { _ in XCTFail("Browsing cannot select a bot") }
            .environment(\.scenePhase, .active))
        window.overrideUserInterfaceStyle = .dark
        defer { close(window); inbox.close() }
        await settle(window)
        // An empty query lists every bot; the view draws exactly these rows.
        let rows = inbox.rows(matching: "")
        XCTAssertEqual((rows.pinned + rows.others + rows.hidden).map(\.name).sorted(), ["Apartments", "Inbox"])
        await fulfillment(of: [focused], timeout: callbackTimeout)
        XCTAssertNotNil(descendants(window).compactMap { $0 as? UITextField }.first { $0.isFirstResponder })
        // The status read runs beside the room read, so only the set of calls is fixed.
        XCTAssertEqual(wire.calls.map { $0.0 }.sorted(), ["groups.capabilities", "profiles.list", "session.active_list"])
    }

    func testMessageQueryDoesNotShowNoBotsFoundInAllScope() async throws {
        let server = URL(string: "https://search.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: server)
        let wire = BotInboxFixtureWire(roster: [
            .object(["name": .string("inbox"), "display_name": .string("Inbox")])
        ])
        let inbox = BotInbox(server: server, store: store, makeWire: { _ in wire })
        await inbox.open()
        let cache = BotHistoryCache()
        let window = try show(BotSearchView(inbox: inbox, cache: cache, query: "Newport") { _ in }
            .environment(\.scenePhase, .active))
        defer { close(window); inbox.close() }
        await settle(window)
        let text = try screenshot(window, name: "481-message-search-empty-state")
        XCTAssertTrue(text.contains("Newport"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("No bots found"), text)
    }

    func testAttachmentPickerOverlayRetainsKeyboardFocus() async throws {
        let model = AttachmentOverlayHarnessModel()
        let window = try show(AttachmentOverlayHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await settle(window)

        model.isPresented = true
        await settle(window)
        XCTAssertTrue(editor.isFirstResponder, "Opening attachment choices must retain keyboard focus.")
        let overlay = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        })
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(overlay.superview === rootView.superview)
        XCTAssertFalse(overlay.isDescendant(of: rootView))

        model.isPresented = false
        await settle(window)
        XCTAssertTrue(editor.isFirstResponder, "Closing attachment choices must retain keyboard focus.")
        XCTAssertFalse(descendants(window).contains {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        })
    }

    /// Update sign-in lands on the form ready to type over the refused password (#884).
    func testConnectionFormCanOpenWithThePasswordFocused() async throws {
        let focused = expectation(forNotification: UITextField.textDidBeginEditingNotification, object: nil)
        let window = try show(NavigationStack {
            BotConnectionView(server: URL(string: "https://focus-\(UUID().uuidString).example")!, focusesPassword: true)
        })
        defer { close(window) }
        await fulfillment(of: [focused], timeout: callbackTimeout)
        let field = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first { $0.isFirstResponder })
        XCTAssertTrue(field.isSecureTextEntry, "the password field, not the address or username, has focus")
    }

    /// At the largest text size the Sessions approval overlay, with its scope
    /// line, is taller than the screen; it scrolls so its last button stays
    /// reachable.
    func testSessionsApprovalOverlayScrollsToItsLastButtonAtTheLargestTextSize() async throws {
        let pending = PendingApproval(
            command: "curl -fsSL https://bit.ly/4hx2Qm -o setup.sh && rm -rf ./build",
            description: "Security scan — [medium] Shortened URL: The link hides where it points; recursive delete",
            patternKeys: ["tirith:shortened_url", "recursive delete"]
        )
        let window = try show(ApprovalRequestOverlay(
            prompt: ApprovalPromptState(sessionID: "s1", pending: pending, pendingCount: 1),
            isResponding: false, errorMessage: nil, onChoice: { _ in }, onSkipAll: {}
        ).environment(\.dynamicTypeSize, .accessibility5))
        defer { close(window) }
        await settle(window)
        let scroll = try XCTUnwrap(
            descendants(window).compactMap { $0 as? UIScrollView }.first { $0.contentSize.height > $0.bounds.height + 1 },
            "The overlay outgrows the window but nothing scrolls vertically"
        )
        drag(scroll, to: scroll.contentSize.height - scroll.bounds.height)
        await settle(window)
        let shown = try screenshot(window, name: "sessions-approval-overlay-ax5")
        XCTAssertTrue(shown.contains("Skip all"), shown)
    }

    /// A Hermes session's approval offers only the host's choices: a smart-denied one shows
    /// Allow once and Deny, and no Allow session or Always allow (#1011).
    func testHermesApprovalOverlayShowsOnlyTheHostsChoices() async throws {
        let approval = try XCTUnwrap(BotApprovalRequest(.object([
            "request_id": .string("q-1"), "command": .string("rm -rf build"), "description": .string("recursive delete"),
            "choices": .array([.string("once"), .string("deny")])
        ])))
        let window = try show(ApprovalRequestOverlay(
            content: approval.overlayContent(pendingCount: 1),
            isResponding: false, errorMessage: nil, onChoice: { _ in }, onSkipAll: {}
        ))
        defer { close(window) }
        let shown = try await screenshot(window, name: "hermes-approval-overlay", awaiting: ["Allow once", "Deny", "Skip all"])
        XCTAssertTrue(["Allow once", "Deny", "Skip all"].allSatisfy(shown.contains), shown)
        XCTAssertFalse(shown.contains("Allow session"), shown)
        XCTAssertFalse(shown.contains("Always allow"), shown)
    }

    /// A Hermes session's sudo prompt shows in the clarification's slot as the Bot credential
    /// card, measured and then shown whole, with its masked field (#1011).
    func testHermesSudoPromptShowsTheCredentialCardAboveTheComposer() async throws {
        let window = try show(VStack {
            Spacer()
            HermesRequestInset(
                request: .credential(BotCredentialRequest(kind: .sudo, requestID: "srq-s1", envVar: nil, prompt: nil)),
                identity: "default on Mac", maximumExpandedHeight: 600, isEnabled: true, isAnswering: false,
                isStopping: false, resolution: nil, isHapticsEnabled: false, onAnswer: { _ in }, onSkip: {},
                onCredential: { _ in }, onConnection: { _ in }, onStop: {}, onDismissKeyboard: {}, onFootprintChange: { _ in }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
        })
        defer { close(window) }
        let shown = try await screenshot(window, name: "hermes-sudo-inset", awaiting: ["Administrator password needed", "Skip"])
        XCTAssertTrue(shown.contains("Administrator password needed"), shown)
        XCTAssertTrue(shown.contains("Skip"), shown)
        let field = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first, "Expected the credential field")
        XCTAssertTrue(field.isSecureTextEntry)
    }

    /// With no room for a line of the card (a tall composer under the keyboard), a Hermes
    /// request falls back to its bar, as the webui clarification card does, and the collapse
    /// puts the keyboard away (#1011). With room it stays open.
    func testHermesRequestInsetFallsBackToItsBarWhenTheCardCannotFit() async throws {
        var collapses: [CGFloat: Int] = [:]
        for height: CGFloat in [40, 600] {
            let window = try show(VStack {
                Spacer()
                HermesRequestInset(
                    request: .credential(BotCredentialRequest(kind: .sudo, requestID: "srq-s1", envVar: nil, prompt: nil)),
                    identity: "default on Mac", maximumExpandedHeight: height, isEnabled: true, isAnswering: false,
                    isStopping: false, resolution: nil, isHapticsEnabled: false, onAnswer: { _ in }, onSkip: {},
                    onCredential: { _ in }, onConnection: { _ in }, onStop: {},
                    onDismissKeyboard: { collapses[height, default: 0] += 1 }, onFootprintChange: { _ in }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            })
            await settle(window) { collapses[height] != nil }
            close(window)
        }
        XCTAssertEqual(collapses, [40: 1], "only the card with no room collapses, once")
    }

    /// The secret field offers Password AutoFill, and a half-typed value never
    /// outlives its request: a sudo prompt that times out mid-typing must not
    /// leave the Mac password in the field of the secret that replaces it.
    func testCredentialFieldOffersAutoFillAndResetsForTheNextRequest() async throws {
        let harness = CredentialCardHarnessModel(request: .credential(BotCredentialRequest(
            kind: .sudo, requestID: "sudo-1", envVar: nil, prompt: nil
        )))
        let window = try show(CredentialCardHarnessView(model: harness))
        defer { close(window) }
        await settle(window)

        let sudoField = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(sudoField.becomeFirstResponder())
        sudoField.insertText("hunter2")
        await settle(window)
        XCTAssertEqual(sudoField.text, "hunter2")

        harness.request = .credential(BotCredentialRequest(
            kind: .secret, requestID: "secret-2", envVar: "OPENAI_API_KEY", prompt: nil
        ))
        await settle(window)
        let secretField = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first)
        XCTAssertEqual(secretField.text ?? "", "", "The Mac password never rides into the secret that replaces it")
        XCTAssertEqual(secretField.textContentType, .password, "The Passwords key needs a password content type")
        XCTAssertTrue(secretField.becomeFirstResponder())
        secretField.insertText("sk-1")
        await settle(window)
        XCTAssertEqual(secretField.text, "sk-1")
    }

    /// A connection row's secret field is masked and offers AutoFill, its plain
    /// field is not, and Connect hands the values over and empties the fields.
    func testConnectionCardMasksSecretsAndDropsThemOnConnect() async throws {
        var sent: [BotConnectionOperation.Answer] = []
        let operation = try XCTUnwrap(BotConnectionOperation(BotConnectionFixture.operation(targets: [BotConnectionFixture.github()])))
        let harness = CredentialCardHarnessModel(request: .connection(operation))
        let window = try show(CredentialCardHarnessView(model: harness) { sent.append($0) })
        defer { close(window) }
        await settle(window)

        let fields = descendants(window).compactMap { $0 as? UITextField }
        XCTAssertEqual(fields.count, 2)
        let secret = try XCTUnwrap(fields.first(where: \.isSecureTextEntry), "The token is never in the clear")
        XCTAssertEqual(secret.textContentType, .password)
        XCTAssertEqual(fields.filter(\.isSecureTextEntry).count, 1, "The host name is not a secret")
        let host = try XCTUnwrap(fields.first { !$0.isSecureTextEntry })
        XCTAssertEqual(host.text, "github.com", "A plain field starts at its default")

        XCTAssertTrue(secret.becomeFirstResponder())
        secret.insertText("ghp_1")
        await settle(window)
        // Return on the keyboard, which the field submits as Connect.
        secret.sendActions(for: .editingDidEndOnExit)
        await settle(window)
        XCTAssertEqual(sent, [.connect(target: "github", env: ["GITHUB_TOKEN": "ghp_1", "GITHUB_HOST": "github.com"])])
        XCTAssertEqual(secret.text ?? "", "", "The value leaves the field once it is handed over")
    }

    func testTextOnlyEditorRejectsAttachmentProviders() {
        let editor = ComposerChipTextView()
        let image = NSItemProvider(item: NSData(), typeIdentifier: UTType.png.identifier)
        let text = NSItemProvider(object: "plain text" as NSString)
        XCTAssertTrue(editor.canPasteItemProviders([image]), "Sessions retain attachment support")
        editor.acceptsAttachments = false
        XCTAssertFalse(editor.canPasteItemProviders([image]))
        XCTAssertTrue(editor.canPasteItemProviders([text]))

    }

    /// A tap can restore UIKit focus before an earlier bound blur gets its
    /// main-actor turn. That queued blur must not dismiss the new editing session.
    func testComposerRefocusSupersedesQueuedBlur() async throws {
        let focus = ComposerFixtureFocus()
        let window = try show(SessionChatPresentationFixture(focus: focus))
        defer { close(window) }
        await settle(window)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await settle(window)
        XCTAssertTrue(focus.isFocused)

        focus.isFocused = false
        window.layoutIfNeeded()
        // UIKit changes focus synchronously, before the representable's queued blur.
        XCTAssertTrue(editor.resignFirstResponder())
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertTrue(focus.isFocused)
        await settle(window)

        XCTAssertTrue(editor.isFirstResponder, "A stale bound blur must not dismiss a newly focused editor")
        XCTAssertTrue(focus.isFocused)
        editor.insertText("Still editing.")
        await settle(window)
        XCTAssertEqual(editor.sourceText, "Still editing.")

        focus.isFocused = false
        await settle(window)
        XCTAssertFalse(editor.isFirstResponder, "A current bound blur must still dismiss the editor")
        XCTAssertFalse(focus.isFocused)
    }

    func testSessionsComposerRetainsFocusAndAttachmentsAtAccessibilitySize() async throws {
        let focus = ComposerFixtureFocus()
        let window = try show(SessionChatPresentationFixture(focus: focus)
            .environment(\.dynamicTypeSize, .accessibility1))
        defer { close(window) }
        await settle(window)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.acceptsAttachments)
        focus.isFocused = true
        await settle(window)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertGreaterThan(editor.bounds.height, 44)
        editor.insertText("Draft a short reply.")
        await settle(window)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(editor.sourceText, "Draft a short reply.")
    }

    /// ChatView keeps the draft out of its own body so a keystroke never re-runs
    /// the transcript derivations. The composer reports each edit for
    /// persistence, and scans the draft for `@path` references only when a
    /// finished one comes or goes. A get/set draft binding (the old wiring)
    /// re-runs the owner on every keystroke and fails the pass count.
    func testSessionsComposerScansFileReferencesWithoutReRunningItsOwnerPerKeystroke() async throws {
        let focus = ComposerFixtureFocus()
        let probe = SessionFixtureProbe()
        let window = try show(SessionChatPresentationFixture(focus: focus, probe: probe))
        defer { close(window) }
        await settle(window)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        focus.isFocused = true
        await settle(window)
        let ownerPasses = probe.ownerPasses

        for keystroke in ["read ", "@a.md", " ", "and more"] {
            editor.insertText(keystroke)
            await settle(window)
        }

        XCTAssertEqual(editor.sourceText, "read @a.md and more")
        XCTAssertEqual(probe.ownerPasses, ownerPasses, "A keystroke must not re-run the composer's owner")
        XCTAssertEqual(probe.scannedDrafts, ["", "read @a.md "])
        XCTAssertEqual(probe.editedDrafts, ["read ", "read @a.md", "read @a.md ", "read @a.md and more"])
        XCTAssertEqual(probe.draftSeenOnAppear, "")
    }

    func testDelegationCompletionCardKeepsTheFullReportInItsSheet() async throws {
        let report = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_fixture]

        Unique full worker result body.
        """
        let message = ChatMessage(
            role: "delegation_completion",
            content: report,
            timestamp: nil,
            messageId: "delivery",
            displayKind: HermesDelegationCompletion.displayKind,
            displayMetadata: [
                "delegation_id": .string("deleg_fixture"),
                "task_count": .number(2),
                "completed_count": .number(2),
                "failed_count": .number(0),
                "duration_seconds": .number(8.48)
            ]
        )
        let completion = try XCTUnwrap(HermesDelegationCompletion(message))

        let card = try show(VStack {
            HermesDelegationCompletionCard(completion: completion)
                .padding(16)
            Spacer()
        })
        card.overrideUserInterfaceStyle = .dark
        let compact = try screenshot(card, name: "477-delegation-completion-card")
        XCTAssertTrue(compact.contains("2 workers completed"), compact)
        XCTAssertTrue(compact.contains("View results"), compact)
        XCTAssertFalse(compact.contains("Unique full worker result body"), compact)
        close(card)

        let sheet = try show(HermesDelegationResultsSheet(completion: completion))
        sheet.overrideUserInterfaceStyle = .dark
        defer { close(sheet) }
        await settle(sheet)
        let expanded = try screenshot(sheet, name: "477-delegation-results-sheet")
        XCTAssertTrue(expanded.contains("Delegated work"), expanded)
        XCTAssertTrue(expanded.contains("Unique full worker result body"), expanded)
        // The toolbar's backing differs by build SDK: the button can surface
        // as a labeled hosted view, as a bar button item, or as a bare
        // accessibility node. VoiceOver reads any of them, so accept any.
        // Like the OCR reads above, wait for the label to land instead of
        // asserting on the first pass.
        var labels: [String] = []
        for _ in 0..<8 {
            labels = accessibilityLabels(in: sheet)
            if labels.contains("Copy") { break }
            await settle(sheet)
        }
        // Some build SDKs never publish the accessibility tree in-process
        // (no labels anywhere, not even sheet content), so there is nothing
        // to check the toolbar against. Where the tree is published, the
        // icon-only action must stay named.
        try XCTSkipUnless(!labels.isEmpty, "No accessibility tree is published in-process on this toolchain.")
        XCTAssertTrue(labels.contains("Copy"),
                      "The icon-only toolbar action must remain named for VoiceOver, found: \(labels)")
    }

    /// Finds the fixture's saturated avatar colors by row, without depending on
    /// glyph pixels or exact screen coordinates. Short glass reflections are
    /// excluded; full-height color bands identify each header or suggestion.
    private static func roomAvatarColorBands(_ image: UIImage) -> [[String]] {
        guard let cgImage = image.cgImage else { return [] }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var bands: [[String]] = []
        var colors = Set<String>()
        var bandHeight = 0
        let minimumHeight = Int(12 * image.scale)
        for y in 0..<height {
            var orange = 0, green = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = pixels[offset], g = pixels[offset + 1], blue = pixels[offset + 2]
                if red > 180, g > 90, g < 145, blue < 90 { orange += 1 }
                if red < 100, g > 130, blue < 150 { green += 1 }
            }
            if orange > 3 || green > 3 {
                bandHeight += 1
                if orange > 3 { colors.insert("orange") }
                if green > 3 { colors.insert("green") }
            } else if !colors.isEmpty {
                if bandHeight >= minimumHeight { bands.append(["orange", "green"].filter(colors.contains)) }
                colors.removeAll()
                bandHeight = 0
            }
        }
        if bandHeight >= minimumHeight { bands.append(["orange", "green"].filter(colors.contains)) }
        return bands
    }

    /// Safety net only: these waits end on a notification or callback, and the
    /// class warms the keyboard first. UIKit's own keyboard work can still hold
    /// the main thread for seconds on a hosted runner.
    private let callbackTimeout: TimeInterval = 30

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Layout assertions must not capture an intermediate composer spring frame.
        window.rootViewController = UIHostingController(rootView: view.transaction { $0.disablesAnimations = true })
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// Lays the window out until `condition` holds, for UIKit views that SwiftUI
    /// installs or removes on a later run-loop turn with no model change to
    /// await. Bounded, so a view that never arrives fails the caller's assertion.
    @discardableResult
    private func settle(_ window: UIWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<8 {
            if condition() { return true }
            await settle(window)
        }
        return condition()
    }

    /// The room transcript's member replies without OCR. Each built reply mounts
    /// a `ResponseSelectionLeafView` per paragraph whose `text` is the paragraph
    /// and whose frame is the paragraph's, so a reply is visible when that frame
    /// meets the transcript's visible bounds.
    private func replyLeaves(in window: UIWindow) throws -> (built: [String], visible: [String]) {
        let views = descendants(window)
        let transcript = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first {
            !($0 is UITextView) && ($0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory)
        }, "Expected the room transcript's scroll view")
        let viewport = transcript.convert(transcript.bounds, to: window).intersection(window.bounds)
        let leaves = views.compactMap { $0 as? ResponseSelectionLeafView }.filter { $0.isDescendant(of: transcript) }
        return (leaves.map(\.text), leaves.filter { $0.convert($0.bounds, to: window).intersects(viewport) }.map(\.text))
    }

    /// True while a keyboard-retaining overlay (the send-choice card or the
    /// attachment picker) has its host installed in the window.
    private func hasOverlayHost(in window: UIWindow) -> Bool {
        descendants(window).contains {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        }
    }

    /// The composer's scroll views other than its text editors; the slash panel
    /// is the one that `/` adds.
    private func panelCandidates(in window: UIWindow) -> [UIScrollView] {
        descendants(window).compactMap { $0 as? UIScrollView }.filter { !($0 is UITextView) }
    }

    /// Every accessibility label exposed under a view: hosted view labels,
    /// explicit accessibility elements (which need not be views), and the bar
    /// button items behind a UIKit-backed toolbar.
    private func accessibilityLabels(in root: UIView) -> [String] {
        var labels: [String] = []
        var queue = [root]
        var seen: Set<ObjectIdentifier> = []
        while let view = queue.popLast() {
            guard seen.insert(ObjectIdentifier(view)).inserted else { continue }
            if let label = view.accessibilityLabel { labels.append(label) }
            for element in view.accessibilityElements ?? [] {
                if let elementView = element as? UIView {
                    queue.append(elementView)
                } else {
                    labels += accessibilityLabel(of: element)
                }
            }
            let count = view.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    let element = view.accessibilityElement(at: index)
                    if let elementView = element as? UIView {
                        queue.append(elementView)
                    } else {
                        labels += accessibilityLabel(of: element)
                    }
                }
            }
            if let bar = view as? UINavigationBar, let top = bar.topItem {
                labels += (top.leftBarButtonItems ?? []).compactMap(\.accessibilityLabel)
                labels += (top.rightBarButtonItems ?? []).compactMap(\.accessibilityLabel)
            }
            if let toolbar = view as? UIToolbar {
                labels += (toolbar.items ?? []).compactMap(\.accessibilityLabel)
            }
            queue += view.subviews
        }
        return labels
    }

    private func accessibilityLabel(of element: Any?) -> [String] {
        if let node = element as? UIAccessibilityElement { return node.accessibilityLabel.map { [$0] } ?? [] }
        if let object = element as? NSObject,
           let label = object.value(forKey: "accessibilityLabel") as? String {
            return [label]
        }
        return []
    }

    /// Moves a SwiftUI scroll view the way a finger would. iOS 27 restores its
    /// own tracked position over a bare offset write on the next layout, so the
    /// write is bracketed with the drag callbacks SwiftUI listens for.
    private func drag(_ scroll: UIScrollView, to y: CGFloat) {
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
    }

    /// Captures once layout has produced every `expected` string, or gives up
    /// and returns the last read so the assertion fails with what was on screen.
    /// Rows that arrive without a state change to wait on settle at their own
    /// pace, so this waits on the content under test instead of a pass count.
    private func screenshot(_ window: UIWindow, name: String,
                            awaiting expected: [String]) async throws -> String {
        try await screenshot(window, name: name) { text in expected.allSatisfy(text.contains) }
    }

    /// OCR reads of `window`, settling between passes until `done` accepts one
    /// or the bounded passes run out; returns the last read.
    private func screenshot(_ window: UIWindow, name: String, until done: (String) -> Bool) async throws -> String {
        var text = ""
        for _ in 0..<8 {
            await settle(window)
            text = try screenshot(window, name: name)
            if done(text) { break }
        }
        return text
    }

    @discardableResult
    private func screenshot(_ window: UIWindow, name: String) throws -> String {
        try recognizedText(in: capture(window, name: name, scale: 1))
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Accurate OCR of a capture. Text reads pass 1x captures: recognition at
    /// the screen's 3x scale took about twice as long for the same assertions,
    /// and the fast level misread copy. Checks on where text lands keep the
    /// screen's scale, since 1x boxes round to whole points. Tests render in
    /// English and assert literal UI copy, including filenames, so language
    /// correction stays off: it can turn Report.pdf into Report.odf.
    private func recognizedText(in image: UIImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results ?? []
    }

    /// Captures pixels for OCR and layout assertions, at the screen's scale
    /// unless `scale` is given; retain the JPEG only when the test fails so
    /// successful runs do not accumulate screenshot evidence.
    @discardableResult
    private func capture(_ window: UIWindow, name: String, scale: CGFloat? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        if let scale { format.scale = scale }
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image, quality: .medium)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        return image
    }
}

/// Swaps the request under one mounted card, the way a chat's request slot does
/// under its constant anchor.
@MainActor @Observable private final class CredentialCardHarnessModel {
    var request: BotPendingRequest
    init(request: BotPendingRequest) { self.request = request }
}

private struct CredentialCardHarnessView: View {
    let model: CredentialCardHarnessModel
    var onCredential: (String) -> Void = { _ in }
    var onConnection: (BotConnectionOperation.Answer) -> Void = { _ in }
    var body: some View {
        BotPendingRequestCard(
            request: model.request, identity: "Fixture Mac", isEnabled: true, canStop: true,
            isAnswering: false, resolution: nil, onApprove: { _ in }, onAnswer: { _ in }, onSkip: {},
            onCredential: onCredential, onStop: {}, onConnection: onConnection
        )
    }
}

@MainActor @Observable
private final class AttachmentOverlayHarnessModel {
    var isPresented = false
}

@MainActor @Observable private final class AttachmentSceneHarnessModel {
    var isPresented = false
    var phase = ScenePhase.active
    var observedPhase: ScenePhase?
}

private struct AttachmentSceneHarnessView: View {
    @Bindable var model: AttachmentSceneHarnessModel
    var body: some View {
        Color.clear.background {
            HermexKeyboardRetainingOverlay(isPresented: model.isPresented) {
                AttachmentSceneProbe { model.observedPhase = $0 }
            }
        }
        .environment(\.scenePhase, model.phase)
    }
}

private struct AttachmentSceneProbe: View {
    @Environment(\.scenePhase) private var phase
    let report: (ScenePhase) -> Void
    var body: some View {
        Color.clear.onChange(of: phase, initial: true) { _, value in report(value) }
    }
}

private struct AttachmentOverlayHarnessView: View {
    @Bindable var model: AttachmentOverlayHarnessModel
    @State private var message = ""

    var body: some View {
        VStack {
            Spacer()
            TextField("Message", text: $message)
                .textFieldStyle(.roundedBorder)
                .padding()
        }
        .background {
            HermexKeyboardRetainingOverlay(isPresented: model.isPresented) {
                HermexAttachmentPickerView(
                    imageCapacity: 1,
                    onChooseFiles: {},
                    onAdd: { _ in },
                    onDismiss: { model.isPresented = false }
                )
            }
            .frame(width: 0, height: 0)
        }
    }
}

/// Holds a composer's screen-owned focus binding for hosted integration tests.
@MainActor @Observable private final class ComposerFixtureFocus {
    var isFocused = false
}

/// Counts the Sessions fixture's own body passes, and records the drafts its
/// composer asked to scan for `@path` references and reported as edits.
@MainActor private final class SessionFixtureProbe {
    var ownerPasses = 0
    var scannedDrafts: [String] = []
    var editedDrafts: [String] = []
    var draftSeenOnAppear: String?
}

private struct SessionChatPresentationFixture: View {
    @Bindable var focus: ComposerFixtureFocus
    var probe = SessionFixtureProbe()
    @State private var draft = ""
    @State private var quotes: [ComposerQuote] = []
    @State private var paths = ComposerFilePathSearch()
    @State private var git = GitWorkspaceAvailabilityViewModel(
        session: SessionSummary(), server: URL(string: "https://webui.example")!
    )

    var body: some View {
        probe.ownerPasses += 1
        return VStack {
            Spacer()
            composer
        }
        // ChatView reads the draft outside body (tasks, actions); that must not
        // make it depend on the draft either.
        .task { probe.draftSeenOnAppear = draft }
    }

    private var composer: some View {
        // Wired like ChatView: a plain `$state` draft the body never reads,
        // with edits reported for persistence.
        MessageComposerView(
            draftMessage: $draft, quotes: $quotes, isFocused: $focus.isFocused,
            isSending: false, isCompressingSession: false, isWaitingForStream: false,
            isCancellingStream: false, readOnlyMessage: nil, errorMessage: nil,
            errorFixPrompt: nil, configurationErrorMessage: nil, contextWindowSnapshot: nil, gitViewModel: git,
            modelGroups: [], selectedModelID: nil, selectedModelProviderID: nil, selectedModelTitle: "Model",
            workspaceRoots: [], selectedWorkspacePath: nil, workspaceSuggestions: [], workspaceManagementServer: nil,
            personalitySuggestions: [], skillSuggestions: [], hasLoadedSkillSuggestions: true,
            agentCommands: [], profileOptions: [], isSingleProfileMode: true,
            selectedProfileName: nil, selectedProfileTitle: "Default", selectedReasoningEffort: nil,
            supportedReasoningEfforts: nil, supportsReasoningEffort: false, showsReasoningControl: false,
            isUpdatingConfiguration: false, pendingAttachments: [], isUploadingAttachment: false,
            attachmentUploadCount: 0, attachmentUploadGeneration: 0, isSendingVoiceNote: false,
            autoStartsVoiceInput: false, apiClient: nil, sessionID: nil, searchFilePaths: nil, chipFilePaths: [],
            filePathSearch: paths, uploadAttachmentErrorMessage: nil, steerFailure: nil,
            streamingSendBehavior: .steer, onSend: {}, onSendWithBehavior: { _ in },
            onSendVoiceNote: { _, _ in }, onCancel: {}, onSelectModel: { _ in },
            onModelPickerOpen: {}, onSelectReasoningEffort: { _ in }, onLoadWorkspaceSuggestions: { _ in },
            onWorkspaceRegistryChanged: {}, onLoadPersonalitySuggestions: {}, onLoadSkillSuggestions: {},
            onSelectWorkspace: { _ in }, onSelectProfile: { _ in }, onHeightChange: { _ in },
            onPhotoMediaSelected: { _ in }, onFileURLsSelected: { _ in }, onPasteFileProviders: { _ in },
            onPasteFileURLs: { _ in }, onPasteImageProviders: { _ in }, onPasteImages: { _ in },
            onRemoveAttachment: { _ in }, onPreviewAttachment: { _ in }, onDismissUploadAttachmentError: {},
            onSelectFileReference: { _ in }, onFileReferenceCandidatesChange: { probe.scannedDrafts.append($0) },
            onDraftEdit: { probe.editedDrafts.append($0) },
            onOpenFileReference: { _ in }, onSelectGitBranch: { _ in },
            onCreateGitBranch: { _ in }, onRefreshGitBranches: {}
        )
    }
}
