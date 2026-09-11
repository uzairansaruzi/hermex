import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import HermesMobile

@MainActor final class BotChatPresentationTests: XCTestCase {
    private func make(_ wire: BotFixtureWire) -> BotConversation {
        BotConversation(
            server: URL(string: "https://webui.example")!,
            connection: BotConnection(id: UUID(), name: "Fixture Mac", address: URL(string: "http://hermes.local:9120")!, username: "fixture", password: "fixture"),
            profile: BotProfile(.object(["name": .string("inbox-triage")]))!,
            wire: wire, drafts: ChatDraftStore(persistence: BotMemoryDrafts())
        )
    }

    func testReadyHasNoStatusAndDisconnectShowsRecoveryAboveComposer() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        await model.recover()
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let ready = try screenshot(window, name: "ready-no-status")
        XCTAssertFalse(ready.contains("Connected"))
        XCTAssertFalse(ready.contains("Ready"))
        XCTAssertTrue(ready.contains("Message bot"))
        wire.onDisconnect?(BotFailure.transport)
        await renderFrames()
        let disconnected = try screenshot(window, name: "disconnected-status")
        XCTAssertTrue(disconnected.contains("Disconnected"))
        XCTAssertTrue(disconnected.contains("Reconnect"))
        XCTAssertFalse(model.maySend)
    }

    func testBotEditorKeepsIdentityDraftAndKeyboardRulesThroughFocusAndWork() async throws {
        let wire = BotFixtureWire()
        let model = make(wire)
        XCTAssertFalse(model.mayEditDraft)
        await model.recover()
        model.editDraft("Persistent text")
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}, onShowRequest: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? ComposerChipTextView }.first)
        XCTAssertFalse(editor.acceptsAttachments)
        XCTAssertTrue(editor.isKeyboardSendEnabled)
        XCTAssertEqual(editor.accessibilityLabel, "Message bot")
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
        XCTAssertFalse(editor.isKeyboardSendEnabled, "Bot work never turns Command-Return into Stop or queued Send")
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
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}, onShowRequest: {}))
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
        await model.recover()
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
    private func screenshot(_ window: UIWindow, name: String) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
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
