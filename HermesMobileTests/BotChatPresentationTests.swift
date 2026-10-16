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
        // A refused password takes Reconnect's slot, and keeps it once a background has
        // left the room idle, because the room does not reopen on its own (#884).
        XCTAssertEqual(BotComposerPill.room(link: .stopped, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: nil), .updateSignIn)
        XCTAssertEqual(BotComposerPill.room(link: .idle, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: nil), .updateSignIn)
        XCTAssertEqual(BotComposerPill.room(link: .stopped, blocked: false, hasActions: false, mayRetry: false,
                                            needsSignIn: true, errorText: "Hermes didn't accept the username or password."),
                       .error("Hermes didn't accept the username or password."), "the error still shows first")
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
        XCTAssertFalse(editor.acceptsAttachments, "A room's composer is text-only")
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
        XCTAssertTrue(sudoField.isSecureTextEntry, "The Mac password is never in the clear")
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

    /// Moves a SwiftUI scroll view the way a finger would. iOS 27 restores its
    /// own tracked position over a bare offset write on the next layout, so the
    /// write is bracketed with the drag callbacks SwiftUI listens for.
    private func drag(_ scroll: UIScrollView, to y: CGFloat) {
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
    }

    /// Accurate OCR of a 1x capture of `window`. Recognition at the screen's 3x
    /// scale took about twice as long, and the fast level misread copy. Tests
    /// render in English and assert literal UI copy, so language correction
    /// stays off. The capture is kept only when the test fails.
    private func screenshot(_ window: UIWindow, name: String) throws -> String {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image, quality: .medium)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
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
