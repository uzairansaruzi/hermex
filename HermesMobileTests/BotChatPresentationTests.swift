import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import HermesMobile

@MainActor final class BotChatPresentationTests: XCTestCase {
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
        XCTAssertTrue(text.contains("@all"), text)
        XCTAssertTrue(text.contains("@everyone"), text)
        XCTAssertNil(selected, "Rendering suggestions must not insert a mention")
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
        XCTAssertTrue(descendants(window).contains { $0 is UITextView }, "Participant has the shared text editor")
        XCTAssertTrue(text.contains("Message Comms"), text)
        wire.driverStatus = RoomFixture.status(running: 1, actions: [RoomFixture.approval])
        await reader.poll()
        await renderFrames(8)
        let approval = try screenshot(window, name: "527-room-approval")
        XCTAssertTrue(approval.contains("Approval required"), approval)
        await reader.stop()
        await renderFrames(8)
        let stopping = try screenshot(window, name: "527-room-stopping")
        XCTAssertTrue(stopping.contains("Stopping"), stopping)
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
        let empty = try show(BotSearchView(inbox: inbox, cache: cache, query: "Message 20") { _ in }
            .environment(\.scenePhase, .active))
        await renderFrames(40)
        let before = try screenshot(empty, name: "528-before-opening-room")
        XCTAssertTrue(before.contains("No saved messages found"), before)
        close(empty)
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
        wire.listFailure = BotFailure.transport
        await inbox.open()
        await renderFrames(40)
        let offline = try screenshot(window, name: "528-room-search-list-unavailable")
        XCTAssertTrue(offline.contains("Comms"), offline)
        XCTAssertTrue(offline.contains("chief-of-staff"), offline)
        XCTAssertFalse(offline.contains("No saved messages found"), offline)
    }

    func testRoomSearchHitScrollsToItsSequenceAndDoesNotFollowNewMessages() async throws {
        let server = URL(string: "https://room.example")!
        let connection = BotConnection(id: UUID(), name: "Fixture", address: server, username: "fixture", password: "fixture")
        let wire = RoomWire(); wire.latest = 80; wire.kind = "message.member"
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 80)))
        let reader = BotRoomReader(key: BotRoomKey(server: server, connectionID: connection.id, roomID: room.id),
            connection: connection, room: room, cache: BotHistoryCache(), initialSequence: 20, makeWire: { _ in wire })
        let window = try show(NavigationStack {
            BotRoomView(reader: reader, roster: [], avatars: [:])
        }.environment(\.scenePhase, .inactive))
        defer { reader.close(); close(window) }
        await renderFrames(4)
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

    func testLatestArrowLayoutAboveAndAtTheBottom() async throws {
        let wire = BotFixtureWire()
        wire.history = (0..<30).map { index in
            .object(["role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                     "text": .string("Message \(index): A saved conversation with enough history to scroll.")])
        }
        let model = make(wire)
        await model.recover()
        let window = try show(BotChatView(model: model)
            .environment(\.scenePhase, .inactive))
        window.overrideUserInterfaceStyle = .dark
        defer { close(window); model.suspend() }
        await renderFrames(30)
        let observer = try XCTUnwrap(descendants(window).compactMap { $0 as? ChatScrollObserver.ObserverView }.first)
        // Model the drag that takes the reader into history. A bare UIKit offset
        // write leaves auto-follow armed while SwiftUI's lazy rows finish sizing.
        let coordinator = try XCTUnwrap(observer.coordinator)
        coordinator.onFollowEvent(.userScrollBegin)
        await renderFrames()
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > 300 && $0.contentSize.height > $0.bounds.height
        })
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        await renderFrames(30)
        XCTAssertLessThan(scroll.contentOffset.y, 1)
        let above = try screenshot(window, name: "479-latest-arrow-above-bottom")
        XCTAssertFalse(above.contains("Latest"), above)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        await renderFrames(30)
        let distance = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y
        XCTAssertLessThanOrEqual(distance, ChatScrollPolicy.followReArmThreshold)
        _ = try screenshot(window, name: "479-latest-arrow-hidden-at-bottom")
    }

    func testMissingUsageUsesTheSessionsRing() async throws {
        let settings = BotChatControls()
        let window = try show(BotComposerSettings(settings: settings, preparePresentation: {}, dismissPresentation: {}))
        defer { close(window) }
        await renderFrames()
        let text = try screenshot(window, name: "479-missing-context-ring")
        XCTAssertFalse(text.contains("Usage"), text)
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

    func testAttachmentComposerUsesSessionsCardAndPillPresentation() async throws {
        let wire = BotFixtureWire(); let model = make(wire)
        await model.recover()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemPink.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        }
        await model.attachments.stage(data: photo, filename: "photo.jpg")
        await model.attachments.stage(data: Data("%PDF-fixture".utf8), filename: "Report.pdf")
        let window = try show(VStack {
            Spacer()
            BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {})
        })
        window.overrideUserInterfaceStyle = .dark
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.becomeFirstResponder())
        await renderFrames()
        let expanded = try screenshot(window, name: "478-composer-attachments-expanded")
        XCTAssertTrue(expanded.contains("Report.pdf"), expanded)
        XCTAssertFalse(expanded.contains("Photos"), expanded)
        XCTAssertFalse(expanded.contains("Files"), expanded)
        XCTAssertGreaterThanOrEqual(descendants(window).compactMap { $0 as? UIButton }.filter { $0.menu != nil }.count, 1)
        editor.resignFirstResponder()
        await renderFrames()
        _ = try screenshot(window, name: "478-composer-attachments-collapsed")
        XCTAssertTrue(descendants(window).contains { $0 === editor })
        XCTAssertEqual(model.attachments.items.count, 2)
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

    func testBusyComposerShowsSteerAndRequiresExplicitSendAfterIdle() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire); await model.recover(); model.editDraft("Focus on reconnect")
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        let busy = try screenshot(window, name: "480-busy-steer")
        XCTAssertTrue(busy.contains("Steer"), busy)
        XCTAssertTrue(busy.contains("Focus on reconnect"), busy)
        wire.running = false
        await model.recover()
        await renderFrames()
        XCTAssertFalse(editor.isKeyboardSendEnabled)
        XCTAssertEqual(model.draft, "Focus on reconnect")
        let idle = try screenshot(window, name: "480-idle-explicit-send")
        XCTAssertTrue(idle.contains("Choose Send"), idle)
        XCTAssertFalse(wire.calls.contains { ["prompt.submit", "session.steer", "session.redirect"].contains($0.0) })
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
        XCTAssertTrue(editor.isKeyboardSendEnabled, "Command-Return uses the visible Steer action while working")
        XCTAssertTrue(editor.isEditable, "Unsent drafts remain editable while the Bot works")
        XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "prompt.submit" && $0.0 != "session.interrupt" })
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

    /// A secret prompt shows the host's own words and the name the value is
    /// saved under, so the user knows which key to paste.
    func testSecretCardNamesTheVariableItWillBeSavedAs() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .inactive))
        defer { model.suspend(); close(window) }
        await model.recover()
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("secret.request"),
            "payload": .object(["request_id": .string("sec-1"), "env_var": .string("TAVILY_API_KEY"),
                                "prompt": .string("Paste your Tavily key")])
        ]))
        await awaitSnapshot(model)
        await renderFrames()
        let shown = try screenshot(window, name: "bot-secret-card")
        XCTAssertTrue(shown.contains("Secret needed"), shown)
        XCTAssertTrue(shown.contains("Paste your Tavily key"), shown)
        XCTAssertTrue(shown.contains("TAVILY_API_KEY"), shown)
    }

    /// A Desktop-renderer task has no input because there is no answer a person
    /// gives — here or at the Mac. It says so, and keeps Stop.
    func testDesktopTaskCardReportsTheWaitInsteadOfSendingTheUserToADesk() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .inactive))
        defer { model.suspend(); close(window) }
        await model.recover()
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("terminal.read.request"),
            "payload": .object(["request_id": .string("term-1")])
        ]))
        // Stop only becomes offerable once the snapshot settles on needs-attention.
        await awaitSnapshot(model)
        await renderFrames()
        XCTAssertTrue(model.mayStop)
        let shown = try screenshot(window, name: "bot-desktop-task-card")
        XCTAssertTrue(shown.contains("Hermes Desktop is handling this"), shown)
        XCTAssertTrue(shown.contains("reading a terminal"), shown)
        XCTAssertTrue(shown.contains("nothing to do"), shown)
        XCTAssertTrue(shown.contains("Stop current work"), shown)
        XCTAssertFalse(shown.contains("Type a response"), shown)
        XCTAssertFalse(shown.contains("Allow once"), shown)
        XCTAssertFalse(model.mayAnswer)
    }

    /// The MCP setup card is the one Desktop task with a way out that is not
    /// Stop: skipping calls off the request and leaves the bot's work running.
    func testMCPSetupCardOffersSkipAlongsideStop() async throws {
        let wire = BotFixtureWire(); wire.running = true
        let model = make(wire)
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .inactive))
        defer { model.suspend(); close(window) }
        await model.recover()
        wire.onEvent?(.object([
            "session_id": .string("runtime"), "seq": .number(1), "type": .string("mcp.setup.request"),
            "payload": .object(["request_id": .string("mcp-1"), "server": .string("tavily")])
        ]))
        await awaitSnapshot(model)
        await renderFrames()
        let shown = try screenshot(window, name: "bot-mcp-setup-card")
        XCTAssertTrue(shown.contains("Waiting on Hermes Desktop"), shown)
        XCTAssertTrue(shown.contains("Skip it here"), shown)
        XCTAssertTrue(shown.contains("Skip this setup"), shown)
        XCTAssertTrue(shown.contains("Stop current work"), shown)
        XCTAssertTrue(model.mayDecline)
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

    func testBotFixturesAcrossAppearanceKeyboardAndLargerText() async throws {
        for dark in [false, true] {
            for large in [false, true] {
                let wire = BotFixtureWire()
                wire.history = [
                    .object(["role": .string("user"), "text": .string("Summarize the inbox and list the next steps.")]),
                    .object(["role": .string("assistant"), "text": .string("Three messages need a reply.\n\n**Next steps**\n1. Confirm the delivery date.\n2. Send the updated estimate.\n3. Reply to the meeting request.\n\nThe remaining messages can wait.")])
                ]
                let model = make(wire)
                let window = try show(NavigationStack { BotChatView(model: model) }
                    .environment(\.scenePhase, .active)
                    .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
                    .preferredColorScheme(dark ? .dark : .light))
                defer { model.suspend(); close(window) }
                await model.recover()
                await renderFrames()
                let name = "bot-\(dark ? "dark" : "light")-\(large ? "large" : "default")"
                _ = try screenshot(window, name: name + "-closed")
                let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
                XCTAssertTrue(editor.becomeFirstResponder())
                await renderFrames()
                editor.insertText("Draft a short reply.")
                await renderFrames()
                _ = try screenshot(window, name: name + "-keyboard")
                XCTAssertEqual(model.draft, "Draft a short reply.")
                XCTAssertTrue(wire.calls.allSatisfy { $0.0 != "prompt.submit" && $0.0 != "session.interrupt" })
                close(window)
                await renderFrames()
                let focus = SessionFixtureFocus()
                let reference = try show(NavigationStack { SessionChatPresentationFixture(focus: focus, messages: model.messages) }
                    .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
                    .preferredColorScheme(dark ? .dark : .light))
                defer { close(reference) }
                await renderFrames()
                _ = try screenshot(reference, name: name.replacingOccurrences(of: "bot-", with: "sessions-") + "-closed")
                let referenceEditor = try XCTUnwrap(descendants(reference).compactMap { $0 as? ComposerChipTextView }.first)
                XCTAssertTrue(referenceEditor.acceptsAttachments)
                focus.isFocused = true
                await renderFrames()
                XCTAssertTrue(referenceEditor.isFirstResponder)
                XCTAssertGreaterThan(referenceEditor.bounds.height, 44)
                referenceEditor.insertText("Draft a short reply.")
                await renderFrames()
                _ = try screenshot(reference, name: name.replacingOccurrences(of: "bot-", with: "sessions-") + "-keyboard")
            }
        }
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
        let window = try show(NavigationStack { BotChatView(model: model) }.environment(\.scenePhase, .active))
        defer { model.suspend(); close(window) }
        // Let the view own its one recovery. Starting another here can race
        // the view's .task and erase the live event after this test sends it.
        let connected = expectation(description: "view recovered")
        func observeConnection() {
            if model.connectionState == .connected { connected.fulfill(); return }
            withObservationTracking {
                _ = model.connectionState
            } onChange: {
                Task { @MainActor in observeConnection() }
            }
        }
        observeConnection()
        await fulfillment(of: [connected], timeout: 3)
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
        // Static comparisons must not capture an intermediate composer spring frame.
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
    private func screenshot(_ window: UIWindow, name: String, inspecting: ((UIImage) -> Void)? = nil) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        inspecting?(image)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    }
}

/// The actual Sessions presentation components with inert fixture callbacks.
/// No APIClient, active account or server data participates in these captures.
@MainActor @Observable private final class SessionFixtureFocus {
    var isFocused = false
}

private struct SessionChatPresentationFixture: View {
    @Bindable var focus: SessionFixtureFocus
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = ""
    @State private var quotes: [ComposerQuote] = []
    @State private var paths = ComposerFilePathSearch()
    @State private var git = GitWorkspaceAvailabilityViewModel(
        session: SessionSummary(), server: URL(string: "https://webui.example")!
    )
    let messages: [ChatMessage]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in MessageBubbleView(message: message) }
            }
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 20 : 16)
            .padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("inbox-triage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
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
            onPhotoItemSelected: { _ in }, onFileURLsSelected: { _ in }, onPasteFileProviders: { _ in },
            onPasteFileURLs: { _ in }, onPasteImageProviders: { _ in }, onPasteImages: { _ in },
            onRemoveAttachment: { _ in }, onPreviewAttachment: { _ in }, onDismissUploadAttachmentError: {},
            onSelectFileReference: { _ in }, onOpenFileReference: { _ in }, onSelectGitBranch: { _ in },
            onCreateGitBranch: { _ in }, onRefreshGitBranches: {}
        )
    }
}
