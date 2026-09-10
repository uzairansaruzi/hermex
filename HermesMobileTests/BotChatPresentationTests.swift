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
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}))
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
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}))
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
        let window = try show(BotChatComposerView(model: model, onStop: {}, onReconnect: {}, onResolveHeldMessage: {}))
        defer { model.suspend(); close(window) }
        await renderFrames()
        let status = try screenshot(window, name: "attention-over-uncertain-stop")
        XCTAssertTrue(status.contains("Needs attention"))
        XCTAssertFalse(status.contains("Outcome unknown"))
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

    private func renderFrames() async {
        let rendered = expectation(description: "Layout committed")
        let driver = BotRenderFrameDriver { rendered.fulfill() }
        driver.start()
        await fulfillment(of: [rendered], timeout: 10)
        driver.stop()
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
