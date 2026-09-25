import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import HermesMobile

@MainActor final class BotChatPresentationTests: XCTestCase {
    func testAttachmentOverlayReceivesOwningSceneLifecycle() async throws {
        let model = AttachmentSceneHarnessModel()
        let window = try show(AttachmentSceneHarnessView(model: model))
        defer { close(window) }
        await renderFrames()
        model.isPresented = true
        await renderFrames()
        XCTAssertEqual(model.observedPhase, .active, "Camera startup must see the presenting scene's active phase")

        model.phase = .background
        await renderFrames()
        XCTAssertEqual(model.observedPhase, .background, "A backgrounded scene must stop camera access")
        model.phase = .active
        await renderFrames()
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
        await renderFrames(4)
        await reader.open()
        window.overrideUserInterfaceStyle = .dark
        let stopping = try await screenshot(window, name: "529-room-profile", awaiting: ["Comms", "Finishing stop"])
        XCTAssertTrue(stopping.contains("Finishing stop"), stopping)
        XCTAssertFalse(reader.mayDisband)
        XCTAssertTrue(descendants(window).contains { $0 is UITextField }, "Local room name is editable")
        wire.authority = "foreign"
        await reader.poll(); await renderFrames(8)
        let foreign = try screenshot(window, name: "529-foreign-room-profile")
        XCTAssertTrue(foreign.contains("Managed by another Hermes"), foreign)
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
        await renderFrames(8)
        let text = try screenshot(window, name: "527-room-mention-avatars") { image in
            XCTAssertEqual(Self.roomAvatarColorBands(image), [
                ["orange", "green"], ["orange"], ["green"], ["orange", "green"], ["orange", "green"]
            ], "Header and broadcast rows show both avatars; each member row shows only its own")
        }
        XCTAssertEqual(completions.map(\.tag), names + ["all", "everyone"])
        XCTAssertTrue(text.contains("@everyone Everyone"), text)
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
        await renderFrames(8)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        let scrollViews = descendants(window).compactMap { $0 as? UIScrollView }.filter { !($0 is UITextView) }
        let transcript = try XCTUnwrap(scrollViews.first {
            $0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory
        }, "Transcript scroll modes: \(scrollViews.map { $0.keyboardDismissMode.rawValue })")
        XCTAssertFalse(editor.isDescendant(of: transcript), "The dismissal gesture belongs to the transcript, not the composer")
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        editor.insertText("Unsent room draft")
        await renderFrames()

        view.dismissKeyboard()
        await renderFrames()
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertEqual(reader.draft, "Unsent room draft")
        XCTAssertEqual(editor.sourceText, reader.draft)
        XCTAssertTrue(descendants(window).contains { $0 === editor })
        XCTAssertTrue(editor.becomeFirstResponder(), "The same editor can be focused again after dismissal")
        await renderFrames()
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
        await renderFrames(8)
        let text = try await screenshot(window, name: "527-room-participant", awaiting: ["Comms", "Message Comms"])
        XCTAssertTrue(text.contains("Comms"), text)
        XCTAssertTrue(text.contains("chief-of-staff"), text)
        XCTAssertTrue(text.contains("Message 3"), text)
        XCTAssertTrue(text.contains("Message Comms"), text)
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertFalse(editor.acceptsAttachments)
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
        let window = try show(BotSearchView(inbox: inbox, cache: cache, query: "Message 20") { _ in }
            .environment(\.scenePhase, .active))
        defer { close(window) }
        await renderFrames(40)
        let after = try screenshot(window, name: "528-after-opening-room")
        XCTAssertTrue(after.contains("Comms"), after)
        XCTAssertTrue(after.contains("chief-of-staff"), after)
        XCTAssertFalse(after.contains("No saved messages found"), after)
    }

    func testWarmRoomBuildsOnlyTheNewestPageOfReplies() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 300)))
        let cache = BotHistoryCache()
        let key = BotRoomKey(server: server, connectionID: connection.id, roomID: room.id)
        var log = BotRoomLog()
        log.apply(RoomFixture.page((1...300).map { RoomFixture.event($0, kind: "message.member") }, cursor: 300))
        cache.recent.save(.room(log), for: .room(key), owner: cache.recent.begin(.room(key)))
        let reader = BotRoomReader(key: key, connection: connection, room: room, cache: cache, makeWire: { _ in RoomWire() })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await renderFrames(4)
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
            cache.recent.save(.room(log), for: .room(key), owner: cache.recent.begin(.room(key)))
        }
        let reader = BotRoomReader(key: key,
            connection: connection, room: room, cache: cache, initialSequence: 20, makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await renderFrames(4)
        if warm {
            let beforeNetwork = try screenshot(window, name: "563-warm-room-search")
            XCTAssertTrue(beforeNetwork.contains("Message 20"), beforeNetwork)
            XCTAssertFalse(beforeNetwork.contains("Message 80"), beforeNetwork)
        }
        await reader.open()
        await renderFrames(8)
        let selected = try screenshot(window, name: "528-room-search-target")
        XCTAssertTrue(selected.contains("Message 20"), selected)
        XCTAssertFalse(selected.contains("Message 80"), selected)
        wire.latest = 81; await reader.poll()
        await renderFrames(8)
        let updated = try screenshot(window, name: "528-room-search-target-after-update")
        XCTAssertTrue(updated.contains("Message 20"), updated)
        XCTAssertFalse(updated.contains("Message 81"), updated)
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
        let window = try show(BotSearchView(inbox: inbox, cache: cache) { _ in XCTFail("Browsing cannot select a bot") }
            .environment(\.scenePhase, .active))
        window.overrideUserInterfaceStyle = .dark
        defer { close(window); inbox.close() }
        await renderFrames(8)
        let text = try screenshot(window, name: "481-bot-search")
        XCTAssertTrue(text.contains("Apartments"), text)
        XCTAssertTrue(text.contains("Inbox"), text)
        XCTAssertNotNil(descendants(window).compactMap { $0 as? UITextField }.first { $0.isFirstResponder })
        XCTAssertEqual(wire.calls.map { $0.0 }, ["profiles.list", "groups.capabilities"])
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
        await renderFrames(8)
        let text = try screenshot(window, name: "481-message-search-empty-state")
        XCTAssertTrue(text.contains("Newport"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("No bots found"), text)
    }

    func testCachedMessageReaderShowsTheSelectedSavedMessage() async throws {
        let server = URL(string: "https://search.example")!
        let scope = BotHistoryCache.Scope(server: server, connectionID: UUID())
        let cache = BotHistoryCache()
        let messages = (0..<40).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant",
                        content: index == 20 ? "Newport viewing confirmed" : "Saved conversation row \(index)",
                        timestamp: nil, messageId: "root/\(index)")
        }
        try await cache.replace(scope: scope, profileID: "inbox", root: "root", tip: "tip", messages: messages)
        let hits = try await cache.search("Newport", scope: scope, profileIDs: ["inbox"])
        let hit = try XCTUnwrap(hits.first)
        let profile = BotProfile(.object(["name": .string("inbox"), "display_name": .string("Inbox")]))!
        let window = try show(BotCachedHistoryView(hit: hit, profile: profile))
        window.overrideUserInterfaceStyle = .dark
        defer { close(window) }
        await renderFrames(8)
        let text = try screenshot(window, name: "481-cached-message-reader")
        XCTAssertTrue(text.contains("Newport viewing confirmed"), text)
    }

    private func make(_ wire: BotFixtureWire) -> BotConversation {
        BotConversation(
            server: URL(string: "https://webui.example")!,
            connection: BotConnection(id: UUID(), name: "Fixture Mac", address: URL(string: "http://hermes.local:9120")!, username: "fixture", password: "fixture"),
            profile: BotProfile(.object(["name": .string("inbox-triage")]))!,
            wire: wire, drafts: ChatDraftStore(persistence: BotMemoryDrafts()), attachmentCopies: BotAttachmentCopies()
        )
    }

    func testBotComposerUsesSessionsModelAndEffortRow() async throws {
        let wire = BotFixtureWire()
        wire.settingsCall = { method, _ in
            if method == "model.options" {
                return .object(["model": .string("Model Alpha"), "provider": .string("anthropic"),
                    "providers": .array([.object(["slug": .string("anthropic"), "models": .array([.string("Model Alpha")])])])])
            }
            return .object(["control": .object([:])])
        }
        let model = make(wire)
        await model.recover()
        model.chatControls.snapshot(.object(["cwd": .string("/workspace"), "reasoning_effort": .string("high"),
            "fast": .bool(false), "usage": .object(["context_used": .number(24000), "context_max": .number(100000)])]), idle: true)
        let window = try show(VStack {
            Spacer()
            BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {})
        })
        window.overrideUserInterfaceStyle = .dark
        defer { close(window); model.suspend() }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames(30)
        let text = try screenshot(window, name: "479-sessions-model-row")
        XCTAssertTrue(text.contains("Model Alpha"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("high"), text)
    }

    func testRecoveredDraftIsEditableWithoutHeldMessageWarningOrConfirmation() async throws {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover(); model.editDraft("Test")
        wire.submitFailure = .transport
        await model.send(); await model.recover()
        XCTAssertFalse(model.uncertainSend)
        let window = try show(NavigationStack {
            BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {})
        })
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        editor.insertText(" edited")
        XCTAssertTrue(model.draft.contains("edited"))
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        let restored = try screenshot(window, name: "479-silently-restored-draft")
        XCTAssertFalse(restored.contains("not confirmed"), restored)
        XCTAssertFalse(restored.contains("Resolve held"), restored)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 1)
        wire.submitFailure = nil
        let sent = expectation(description: "Explicit keyboard send reaches host")
        wire.beforeSubmit = { sent.fulfill() }
        editor.onKeyboardSend()
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertEqual(wire.calls.filter { $0.0 == "prompt.submit" }.count, 2)
    }

    func testAttachmentPickerOverlayRetainsKeyboardFocus() async throws {
        let model = AttachmentOverlayHarnessModel()
        let window = try show(AttachmentOverlayHarnessView(model: model))
        defer { close(window) }
        await renderFrames()

        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()

        model.isPresented = true
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder, "Opening attachment choices must retain keyboard focus.")
        let overlay = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        })
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(overlay.superview === rootView.superview)
        XCTAssertFalse(overlay.isDescendant(of: rootView))

        model.isPresented = false
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder, "Closing attachment choices must retain keyboard focus.")
        XCTAssertFalse(descendants(window).contains {
            $0.accessibilityIdentifier == HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier
        })
    }

    func testFocusedAttachmentSendKeepsRenderingWhileUploadIsPending() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        await model.attachments.stage(data: photo, filename: "photo.jpg")
        let window = try show(NavigationStack {
            BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {})
        })
        var finishUpload: CheckedContinuation<String, Error>?
        let uploadStarted = expectation(description: "upload started")
        wire.imageUpload = { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                finishUpload = continuation
                uploadStarted.fulfill()
            }
        }
        defer {
            finishUpload?.resume(throwing: CancellationError())
            model.suspend(); close(window)
        }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        let send = Task { await model.send() }
        await fulfillment(of: [uploadStarted], timeout: 3)
        // A display-link callback cannot fire when setEditable re-enters SwiftUI
        // during updateUIView. This reaches the focused, hosted Send transition.
        await renderFrames()
        XCTAssertTrue(model.isUploadingAttachments)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(editor.isFirstResponder)
        finishUpload?.resume(returning: "/images/photo.jpg"); finishUpload = nil
        await send.value
        await renderFrames()
        XCTAssertTrue(model.attachments.items.isEmpty)
    }

    /// While the bot works, Send does not write anything: it opens the choice
    /// card, and the card lists only what the host will take for this draft.
    func testSendOnAWorkingBotAsksSteerQueueOrInterruptBeforeWriting() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover(); model.editDraft("Focus on reconnect")
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        XCTAssertFalse(accessibilityLabels(in: window).contains { $0.hasPrefix("Message action") },
                       "no mode control lives in the toolbar any more")

        // Keyboard send and the arrow button share one path. The card mounts on
        // the next run loop and fades in, so wait on its rows, not a frame count.
        editor.onKeyboardSend()
        // The rendered rows are the check; the overlay host's accessibility tree
        // is not always materialized on the CI runner, so no label assertion here.
        let card = try await screenshot(window, name: "busy-send-choices", awaiting: ["Steer", "Queue", "Interrupt"])
        for choice in ["Steer", "Queue", "Interrupt"] { XCTAssertTrue(card.contains(choice), card) }
        XCTAssertFalse(wire.calls.contains { ["prompt.submit", "session.steer", "session.redirect"].contains($0.0) })
        XCTAssertEqual(model.draft, "Focus on reconnect")

        // Idle again: the card is gone and Send is a plain send, still needing a tap.
        wire.running = false
        await model.recover()
        await renderFrames(8)
        let idle = try screenshot(window, name: "busy-send-choices-gone")
        XCTAssertFalse(idle.contains("Interrupt"), idle)
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        XCTAssertFalse(wire.calls.contains { ["prompt.submit", "session.steer", "session.redirect"].contains($0.0) })
    }

    func testBusyChoicesDropSteerWhenTheDraftHasAttachments() {
        XCTAssertEqual(BotPromptMode.busyChoices(hasAttachments: false), [.steer, .queue, .redirect])
        XCTAssertEqual(BotPromptMode.busyChoices(hasAttachments: true), [.queue, .redirect])
    }

    func testOnlyUserMessagesAndTurnEndingRepliesCarryAFooterTime() {
        let messages = [
            botRow("u1", "user", at: 1_000),
            botRow("a1", "assistant", at: 1_010),
            botRow("s1", "user", at: 1_020, displayKind: ChatMessage.steerDisplayKind),
            botRow("a2", "assistant", at: 1_030),
            botRow("d1", "delegation_completion", at: 1_040),
            botRow("a3", "assistant", at: 1_050),
            botRow("u2", "user", at: 1_060),
            botRow("a4", "assistant", at: nil),
            botRow("u3", "user", at: 1_080),
            botRow("a5", "assistant", at: 1_090)
        ]
        let idle = BotTranscriptTimes(messages: messages, start: 0, livePrompt: nil, turnStartedAt: nil, isMidTurn: false)
        XCTAssertEqual(idle.footerTimes, ["u1": 1_000, "a2": 1_030, "a3": 1_050, "u2": 1_060, "u3": 1_080, "a5": 1_090],
                       "interim replies, steers, delegation cards and unstamped rows get no time; a delivery ends the turn before it")

        let interrupted = [
            botRow("u1", "user", at: 1_000),
            botRow("a1", "assistant", at: 1_010),
            ChatMessage(role: "assistant", content: "", timestamp: 1_020, messageId: "a2"),
            botRow("u2", "user", at: 1_030)
        ]
        let stopped = BotTranscriptTimes(messages: interrupted, start: 0, livePrompt: nil, turnStartedAt: nil, isMidTurn: false)
        XCTAssertEqual(stopped.footerTimes, ["u1": 1_000, "a1": 1_010, "u2": 1_030],
                       "a text-less reasoning row gets no time and the visible reply before it ends the turn")

        let lateSteer = [
            botRow("u1", "user", at: 1_000),
            botRow("a1", "assistant", at: 1_010),
            botRow("s1", "user", at: 1_020, displayKind: ChatMessage.steerDisplayKind),
            botRow("u2", "user", at: 1_030)
        ]
        let steered = BotTranscriptTimes(messages: lateSteer, start: 0, livePrompt: nil, turnStartedAt: nil, isMidTurn: false)
        XCTAssertEqual(steered.footerTimes["a1"], 1_010, "a steer the turn never answered doesn't make its last reply interim")

        let running = BotTranscriptTimes(messages: messages, start: 0, livePrompt: nil, turnStartedAt: 1_085, isMidTurn: true)
        XCTAssertNil(running.footerTimes["a5"], "the last reply of a turn still running is interim")
        let answeringNext = BotTranscriptTimes(messages: messages, start: 0, livePrompt: livePrompt,
                                               turnStartedAt: 1_100, isMidTurn: true)
        XCTAssertEqual(answeringNext.footerTimes["a5"], 1_090, "a live prompt means the settled turn ended")

        let windowed = BotTranscriptTimes(messages: messages, start: 8, livePrompt: nil, turnStartedAt: nil, isMidTurn: false)
        XCTAssertEqual(windowed.footerTimes, ["u3": 1_080, "a5": 1_090], "only the window's rows are worked out")
        XCTAssertEqual(windowed.gapStarts, ["u3"], "the window's first stamped row is dated")
    }

    func testLivePromptIsDatedByTheHostTurnStartAfterAThirtyMinuteGap() {
        let messages = [botRow("u1", "user", at: 1_000), botRow("a1", "assistant", at: 1_010)]
        let soon = BotTranscriptTimes(messages: messages, start: 0, livePrompt: livePrompt,
                                      turnStartedAt: 1_010 + 1_799, isMidTurn: true)
        XCTAssertNil(soon.livePromptSeparator)
        let later = BotTranscriptTimes(messages: messages, start: 0, livePrompt: livePrompt,
                                       turnStartedAt: 1_010 + 1_800, isMidTurn: true)
        XCTAssertEqual(later.livePromptSeparator, 1_010 + 1_800)
        XCTAssertEqual(later.gapStarts, ["u1", "live-user"])
        let undated = BotTranscriptTimes(messages: messages, start: 0, livePrompt: livePrompt,
                                         turnStartedAt: nil, isMidTurn: true)
        XCTAssertNil(undated.livePromptSeparator, "no host start time means no separator, never the phone clock")
    }

    private var livePrompt: ChatMessage {
        ChatMessage(role: "user", content: "Again", timestamp: nil, messageId: "live-user")
    }

    private func botRow(_ id: String, _ role: String, at timestamp: Double?, displayKind: String? = nil) -> ChatMessage {
        ChatMessage(role: role, content: "Text \(id)", timestamp: timestamp, messageId: id, displayKind: displayKind)
    }

    func testTransientDisconnectRemainsQuietAboveComposer() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let ready = try screenshot(window, name: "ready-no-status")
        XCTAssertFalse(ready.contains("Connected"))
        XCTAssertFalse(ready.contains("Ready"))
        XCTAssertTrue(ready.contains("Ask anything"))
        wire.onDisconnect?(BotFailure.transport)
        await renderFrames()
        let disconnected = try screenshot(window, name: "disconnected-status")
        XCTAssertFalse(disconnected.contains("Disconnected"), disconnected)
        XCTAssertFalse(disconnected.contains("Reconnect"), disconnected)
        XCTAssertFalse(model.maySend)
    }

    func testBotEditorKeepsIdentityDraftAndKeyboardRulesThroughFocusAndWork() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        XCTAssertFalse(model.mayEditDraft)
        await model.recover()
        model.editDraft("Persistent text")
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.acceptsAttachments)
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        XCTAssertEqual(editor.accessibilityLabel, "Ask anything...")
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder)
        editor.insertText(" survives focus")
        await renderFrames()
        XCTAssertEqual(model.draft, "Persistent text survives focus")
        editor.resignFirstResponder()
        await renderFrames()
        XCTAssertTrue(descendants(window).contains { $0 === editor })
        XCTAssertEqual(editor.sourceText, model.draft)
        wire.running = true
        await model.recover()
        await renderFrames()
        XCTAssertTrue(editor.isKeyboardSendEnabled, "Command-Return opens the send-choice card while working")
        XCTAssertTrue(editor.isEditable, "Unsent drafts remain editable while the Bot works")
        XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "prompt.submit" && $0.0 != "session.interrupt" })
    }

    /// Typing `/` in a Bot chat opens the panel with this connection's skills.
    /// Commands stay out: nothing on the phone can run one, so a `/model` row
    /// would be text the agent only reads literally.
    ///
    /// Only the row names are read back. The detail column is right-aligned and
    /// truncates with the window width, so asserting on it reads differently on
    /// a narrower runner; ranking and filtering belong to `BotSlashCommandTests`.
    func testSlashPanelOffersConnectionSkillsAndNeverCommands() async throws {
        let wire = BotFixtureWire()
        wire.catalog = .object([
            "skills": .object([
                "/write-tests": .object(["origin": .string("bundled")]),
                "/triage-inbox": .object(["origin": .string("user")])
            ]),
            "pairs": .array([
                .array([.string("/model"), .string("Picks the chat model")]),
                .array([.string("/write-tests"), .string("Adds focused XCTests")]),
                .array([.string("/triage-inbox"), .string("Sorts the morning mail")])
            ]),
            "canon": .object(["/model": .string("/model")]), "commands": .object([:])
        ])
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        XCTAssertEqual(model.slashSkills.map(\.name), ["triage-inbox", "write-tests"])
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()

        editor.insertText("/")
        let browsing = try await screenshot(window, name: "551-bot-slash-panel", awaiting: ["triage-inbox", "write-tests"])
        XCTAssertTrue(browsing.contains("triage-inbox"), browsing)
        XCTAssertTrue(browsing.contains("write-tests"), browsing)
        XCTAssertFalse(browsing.contains("Picks"), "A command row would insert text nothing runs")

        // Past the name the user is writing the skill's argument, so the panel
        // closes and the accepted name becomes an atomic chip.
        editor.insertText("triage-inbox yesterday's mail")
        await renderFrames(4)
        XCTAssertEqual(model.draft, "/triage-inbox yesterday's mail")
        XCTAssertEqual(
            ComposerChipTokenizer.tokens(in: model.draft, catalog: ComposerChipCatalog(skills: model.slashSkills))
                .map { (model.draft as NSString).substring(with: $0.range) },
            ["/triage-inbox"])
    }

    func testScrolledSlashSkillsStayInsideTheCard() async throws {
        let suggestions = (0..<30).map {
            SkillSlashSuggestion(name: "skill-\($0)", category: nil, description: nil)
        }
        let window = try show(VStack {
            Spacer()
            AdaptiveGlassContainer {
                BotSlashAutocompleteView(suggestions: suggestions, onSelect: { _ in })
            }
            .padding(.horizontal, 16)
            Spacer()
        })
        defer { close(window) }
        await renderFrames()
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first)
        drag(scroll, to: 300)
        await renderFrames(8)

        let card = scroll.convert(scroll.bounds, to: window)
        let image = capture(window, name: "551-scrolled-skills-clipped")
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let rows = (request.results ?? []).filter {
            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains("skill") == true
        }
        XCTAssertFalse(rows.isEmpty, "The scrolled panel must still show skill rows")
        for row in rows {
            let top = (1 - row.boundingBox.maxY) * window.bounds.height
            let bottom = (1 - row.boundingBox.minY) * window.bounds.height
            XCTAssertGreaterThanOrEqual(top, card.minY - 1, "Skill text escaped above the card")
            XCTAssertLessThanOrEqual(bottom, card.maxY + 1, "Skill text escaped below the card")
        }
    }

    func testComposerPillShowsOneThingHighestPriorityFirst() {
        let voice = ComposerVoiceStatus(text: "Listening...", systemImage: "waveform", isError: false)
        XCTAssertEqual(BotComposerPill.resolve(requestText: "Waiting for your answer", requestHasCard: true, errorText: "Send failed",
                                               voiceStatus: voice, offersReconnect: true, isUploading: true),
                       .request("Waiting for your answer"))
        XCTAssertEqual(BotComposerPill.resolve(requestText: "Needs attention", requestHasCard: false, errorText: nil,
                                               voiceStatus: nil, offersReconnect: false, isUploading: false),
                       .notice("Needs attention"), "no card to jump to means no button")
        XCTAssertEqual(BotComposerPill.resolve(requestText: nil, requestHasCard: false, errorText: "Send failed", voiceStatus: voice,
                                               offersReconnect: true, isUploading: true), .error("Send failed"))
        XCTAssertEqual(BotComposerPill.resolve(requestText: nil, requestHasCard: false, errorText: nil, voiceStatus: voice,
                                               offersReconnect: true, isUploading: true), .voice(voice))
        XCTAssertEqual(BotComposerPill.resolve(requestText: nil, requestHasCard: false, errorText: nil, voiceStatus: nil,
                                               offersReconnect: true, isUploading: true), .reconnect)
        XCTAssertEqual(BotComposerPill.resolve(requestText: nil, requestHasCard: false, errorText: nil, voiceStatus: nil,
                                               offersReconnect: false, isUploading: true), .uploading)
        XCTAssertNil(BotComposerPill.resolve(requestText: nil, requestHasCard: false, errorText: nil, voiceStatus: nil,
                                             offersReconnect: false, isUploading: false),
                     "a connected, idle or working bot shows no text above the composer")
    }

    func testPendingRequestOutranksUncertainStopInStatus() async throws {
        // A Stop whose acknowledgement was lost stays uncertain; if the next snapshot
        // still carries a pending approval, the Desktop instruction must stay visible.
        let wire = BotFixtureWire(); wire.running = true; wire.attention = true; wire.stopFailure = .transport
        let model = make(wire)
        await model.recover()
        await model.stop(try XCTUnwrap(model.prepareStop()))
        await model.recover()
        XCTAssertTrue(model.uncertainStop)
        XCTAssertEqual(model.turn, .needsAttention)
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let status = try screenshot(window, name: "attention-over-uncertain-stop")
        XCTAssertTrue(status.contains("Waiting for your answer"))
        XCTAssertFalse(status.contains("Outcome unknown"))
    }

    /// The approval card offers exactly what the host offered: this request was
    /// smart-denied, so there is no session or permanent allow to hand out.
    func testApprovalCardShowsOnlyTheHostsChoicesAndGoesInertOnceAnswered() async throws {
        let wire = BotFixtureWire(); wire.running = true
        wire.pendingApproval = BotFixtureWire.approval(command: "rm -rf build", choices: ["once", "deny"])
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .active))
        defer { model.suspend(); close(window) }
        await model.recover()
        await renderFrames()
        let shown = try screenshot(window, name: "bot-approval-card")
        XCTAssertTrue(shown.contains("Approval required"), shown)
        XCTAssertTrue(shown.contains("recursive delete"), shown)
        XCTAssertTrue(shown.contains("Allow once"), shown)
        XCTAssertTrue(shown.contains("Deny"), shown)
        XCTAssertFalse(shown.contains("Always allow"), shown)
        XCTAssertFalse(shown.contains("Allow session"), shown)
        // Identity, so two hosts with equal Profile names never look alike.
        XCTAssertTrue(shown.contains("Fixture Mac"), shown)

        wire.approvalResolved = 0
        await model.respond(try XCTUnwrap(model.prepareAnswer()), choice: .once)
        await renderFrames()
        let answered = try screenshot(window, name: "bot-approval-card-already-answered")
        XCTAssertTrue(answered.contains("already answered"), answered)
        XCTAssertFalse(model.mayAnswer)
    }

    /// The question card is the Sessions clarification vocabulary: the question
    /// block, the host's choices, and a free-text response field.
    func testQuestionCardShowsChoicesWithoutTheHostsPresentationLabel() async throws {
        let wire = BotFixtureWire(); wire.running = true
        wire.pendingClarify = BotFixtureWire.clarify()
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .active))
        defer { model.suspend(); close(window) }
        await model.recover()
        await renderFrames()
        let shown = try screenshot(window, name: "bot-question-card")
        XCTAssertTrue(shown.contains("Clarification Required"), shown)
        XCTAssertTrue(shown.contains("Which mailbox first?"), shown)
        XCTAssertTrue(shown.contains("Primary"), shown)
        XCTAssertTrue(shown.contains("Follow-ups"), shown)
        XCTAssertTrue(shown.contains("Type a response"), shown)
        // "(Recommended)" is the host's presentation suffix, shown as a tag.
        XCTAssertFalse(shown.contains("Primary (Recommended)"), shown)
    }

    /// A sudo prompt is answered here, not at the Mac: a masked field, a Skip,
    /// and the handling line stated before anything is typed.
    func testSudoCardOffersAMaskedFieldAndSaysWhereTheValueGoes() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire)
        // Inactive so the view's own recovery task cannot race the injected event:
        // a credential prompt lives only in the stream, so a reconnect drops it.
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .inactive))
        defer { model.suspend(); close(window) }
        await model.recover()
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("sudo.request"),
            "payload": .object(["request_id": .string("sudo-1")])
        ]))
        // The event only puts the turn in doubt; the coalesced snapshot settles it.
        await awaitSnapshot(model)
        await renderFrames()
        let shown = try screenshot(window, name: "bot-sudo-card")
        XCTAssertTrue(shown.contains("Administrator password needed"), shown)
        XCTAssertTrue(shown.contains("never saves it"), shown)
        XCTAssertTrue(shown.contains("Skip"), shown)
        XCTAssertTrue(shown.contains("Fixture Mac"), shown)
        // Nothing here tells the user to go and find a desk.
        XCTAssertFalse(shown.contains("Only Hermes Desktop"), shown)
        XCTAssertTrue(model.mayAnswer)

        let fields = descendants(window).compactMap { $0 as? UITextField }
        XCTAssertFalse(fields.isEmpty, "Expected the credential field")
        XCTAssertTrue(fields.allSatisfy(\.isSecureTextEntry), "A credential field is never in the clear")
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

    func testTranscriptComposerEditsDraftAtAccessibilitySizeWithoutSending() async throws {
        let wire = BotFixtureWire()
        wire.history = [
            .object(["role": .string("user"), "text": .string("Summarize the inbox.")]),
            .object(["role": .string("assistant"), "text": .string("Three messages need a reply.")])
        ]
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }
            .environment(\.scenePhase, .inactive)
            .environment(\.dynamicTypeSize, .accessibility1)
            .preferredColorScheme(.dark))
        defer { model.suspend(); close(window) }
        await model.recover()
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        editor.insertText("Draft a short reply.")
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(model.draft, "Draft a short reply.")
        XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "prompt.submit" && $0.0 != "session.interrupt" })
    }

    func testSessionsComposerRetainsFocusAndAttachmentsAtAccessibilitySize() async throws {
        let focus = SessionFixtureFocus()
        let window = try show(SessionChatPresentationFixture(focus: focus)
            .environment(\.dynamicTypeSize, .accessibility1))
        defer { close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.acceptsAttachments)
        focus.isFocused = true
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertGreaterThan(editor.bounds.height, 44)
        editor.insertText("Draft a short reply.")
        await renderFrames()
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertEqual(editor.sourceText, "Draft a short reply.")
    }

    /// ChatView keeps the draft out of its own body so a keystroke never re-runs
    /// the transcript derivations. The composer reports each edit for
    /// persistence, and scans the draft for `@path` references only when a
    /// finished one comes or goes. A get/set draft binding (the old wiring)
    /// re-runs the owner on every keystroke and fails the pass count.
    func testSessionsComposerScansFileReferencesWithoutReRunningItsOwnerPerKeystroke() async throws {
        let focus = SessionFixtureFocus()
        let probe = SessionFixtureProbe()
        let window = try show(SessionChatPresentationFixture(focus: focus, probe: probe))
        defer { close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        focus.isFocused = true
        await renderFrames()
        let ownerPasses = probe.ownerPasses

        for keystroke in ["read ", "@a.md", " ", "and more"] {
            editor.insertText(keystroke)
            await renderFrames()
        }

        XCTAssertEqual(editor.sourceText, "read @a.md and more")
        XCTAssertEqual(probe.ownerPasses, ownerPasses, "A keystroke must not re-run the composer's owner")
        XCTAssertEqual(probe.scannedDrafts, ["", "read @a.md "])
        XCTAssertEqual(probe.editedDrafts, ["read ", "read @a.md", "read @a.md ", "read @a.md and more"])
        XCTAssertEqual(probe.draftSeenOnAppear, "")
    }

    /// The activity rows are the Sessions log rows, whose only motion is
    /// `ChatMotion.disclosure`, which is nil under Reduce Motion (covered in
    /// `TranscriptDisplayModelTests`); the Bot views add no animation of their own.
    func testActivityRowsRenderAndFollowTheCardsSetting() async throws {
        let defaults = UserDefaults.standard
        let key = ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(true, forKey: key)
        let wire = BotFixtureWire(); wire.running = true
        wire.history = [
            .object(["role": .string("user"), "text": .string("Summarize yesterday's inbox.")]),
            .object(["role": .string("tool"), "name": .string("terminal"), "args": .object(["command": .string("himalaya list")])]),
            .object(["role": .string("assistant"), "text": .string("Three messages need a reply."), "reasoning": .string("Three threads need replies")])
        ]
        wire.inflight = .object(["user": .string("Clear the inbox."), "assistant": .string("Archived 14 newsletters.")])
        wire.todoState = .object(["revision": .number(1), "todos": .array([
            .object(["id": .string("a"), "content": .string("Archive newsletters"), "status": .string("completed")]),
            .object(["id": .string("b"), "content": .string("Draft the estimate reply"), "status": .string("in_progress")])
        ])])
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .inactive))
        defer { model.suspend(); close(window) }
        // This test owns recovery so the view's startup task cannot race the
        // injected activity event. Connection lifecycle is covered separately.
        await model.recover()
        XCTAssertEqual(model.connectionState, .connected)
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("tool.start"),
            "payload": .object(["tool_id": .string("t1"), "name": .string("write_file"), "args": .object(["path": .string("reply-delivery.md")])])
        ]))
        // A live tool row lands without a following snapshot (activity events
        // during known work skip the refresh), so nothing signals when the
        // LazyVStack has materialized it — any fixed frame count is a guess.
        let shown = try await screenshot(window, name: "bot-activity-cards-on",
                                         awaiting: ["Ran", "Thinking", "Updated", "Plan"])
        XCTAssertTrue(shown.contains("Ran"), shown)
        XCTAssertTrue(shown.contains("Thinking"), shown)
        XCTAssertTrue(shown.contains("Updated"), shown)
        XCTAssertTrue(shown.contains("Plan"), shown)
        XCTAssertTrue(shown.contains("1 of 2"), shown)
        defaults.set(false, forKey: key)
        await renderFrames(12)
        let hidden = try screenshot(window, name: "bot-activity-cards-off")
        XCTAssertFalse(hidden.contains("Thinking"), hidden)
        XCTAssertFalse(hidden.contains("Updated"), hidden)
        XCTAssertTrue(hidden.contains("Plan"), "work progress stays visible with cards off: " + hidden)
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
            displayKind: BotDelegationCompletion.displayKind,
            displayMetadata: [
                "delegation_id": .string("deleg_fixture"),
                "task_count": .number(2),
                "completed_count": .number(2),
                "failed_count": .number(0),
                "duration_seconds": .number(8.48)
            ]
        )
        let completion = try XCTUnwrap(BotDelegationCompletion(message))

        let card = try show(VStack {
            BotDelegationCompletionCard(completion: completion)
                .padding(16)
            Spacer()
        })
        card.overrideUserInterfaceStyle = .dark
        let compact = try screenshot(card, name: "477-delegation-completion-card")
        XCTAssertTrue(compact.contains("2 workers completed"), compact)
        XCTAssertTrue(compact.contains("View results"), compact)
        XCTAssertFalse(compact.contains("Unique full worker result body"), compact)
        close(card)

        let sheet = try show(BotDelegationResultsSheet(completion: completion))
        sheet.overrideUserInterfaceStyle = .dark
        defer { close(sheet) }
        await renderFrames(8)
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
            await renderFrames(4)
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

    /// Waits for the conversation's coalesced snapshot read to land. Every
    /// `applySnapshot` republishes the turn state, so it is the arrival signal.
    private func awaitSnapshot(_ model: BotConversation) async {
        let applied = expectation(description: "Snapshot applied")
        withObservationTracking { _ = String(describing: model.turn) } onChange: { applied.fulfill() }
        await fulfillment(of: [applied], timeout: 5)
    }

    private func renderFrames(_ target: Int = 3) async {
        let rendered = expectation(description: "Layout committed")
        let driver = BotRenderFrameDriver(target: target) { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
    }

    /// Captures once layout has produced every `expected` string, or gives up
    /// and returns the last read so the assertion fails with what was on screen.
    /// Rows that arrive without a state change to wait on settle at their own
    /// pace, so this waits on the content under test instead of a frame count.
    private func screenshot(_ window: UIWindow, name: String,
                            awaiting expected: [String]) async throws -> String {
        var text = ""
        for _ in 0..<8 {
            await renderFrames(4)
            text = try screenshot(window, name: name)
            if expected.allSatisfy(text.contains) { break }
        }
        return text
    }

    @discardableResult
    private func screenshot(_ window: UIWindow, name: String, croppedTo bounds: CGRect? = nil, literalText: Bool = false,
                            inspecting: ((UIImage) -> Void)? = nil) throws -> String {
        let image = capture(window, name: name)
        inspecting?(image)
        var pixels = try XCTUnwrap(image.cgImage)
        if let bounds {
            let rect = bounds.intersection(window.bounds).applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
            pixels = try XCTUnwrap(pixels.cropping(to: rect))
        }
        let request = VNRecognizeTextRequest()
        // Tests render in English and assert literal UI copy, including filenames.
        // Language correction can turn Report.pdf into Report.odf; do not ask
        // OCR to rewrite what was rendered.
        if literalText {
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
        }
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    }

    /// Captures pixels for OCR and layout assertions; retain the JPEG only when
    /// the test fails so successful runs do not accumulate screenshot evidence.
    @discardableResult
    private func capture(_ window: UIWindow, name: String) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image, quality: .medium)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        return image
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

/// Holds the Sessions composer's external focus binding for hosted integration tests.
@MainActor @Observable private final class SessionFixtureFocus {
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
    @Bindable var focus: SessionFixtureFocus
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
            configurationErrorMessage: nil, contextWindowSnapshot: nil, gitViewModel: git,
            modelGroups: [], selectedModelID: nil, selectedModelProviderID: nil, selectedModelTitle: "Model",
            workspaceRoots: [], selectedWorkspacePath: nil, workspaceSuggestions: [], workspaceManagementServer: nil,
            personalitySuggestions: [], skillSuggestions: [], hasLoadedSkillSuggestions: true,
            agentCommands: [], profileOptions: [], isSingleProfileMode: true,
            selectedProfileName: nil, selectedProfileTitle: "Default", selectedReasoningEffort: nil,
            supportedReasoningEfforts: nil, supportsReasoningEffort: false, showsReasoningControl: false,
            isUpdatingConfiguration: false, pendingAttachments: [], isUploadingAttachment: false,
            attachmentUploadCount: 0, attachmentUploadGeneration: 0, isSendingVoiceNote: false,
            autoStartsVoiceInput: false, apiClient: nil, sessionID: nil, chipFilePaths: [],
            filePathSearch: paths, uploadAttachmentErrorMessage: nil,
            onSend: {}, onSendVoiceNote: { _, _ in }, onCancel: {}, onSelectModel: { _ in },
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

final class BotTranscriptWindowTests: XCTestCase {
    func testShowsTheLatestPageAndGrowsByOnePageAtATime() {
        var window = BotTranscriptWindow()
        XCTAssertEqual(window.start(count: 40), 0)
        XCTAssertFalse(window.hasEarlier(count: 40))
        XCTAssertEqual(window.start(count: 130), 80, "Before seeding, the first frame must already be bounded")

        window.seed(count: 130)
        window.loadEarlier()
        XCTAssertEqual(window.start(count: 130), 30)
        window.loadEarlier()
        XCTAssertEqual(window.start(count: 130), 0)
        XCTAssertFalse(window.hasEarlier(count: 130))
    }

    func testMessagesThatSettleAfterOpeningNeverPushRowsOffTheTop() {
        var window = BotTranscriptWindow()
        window.seed(count: 130)
        window.seed(count: 140)
        XCTAssertEqual(window.start(count: 140), 80)
        XCTAssertEqual(window.start(count: 60), 10, "A compacted history clamps instead of indexing past its end")
    }
}
