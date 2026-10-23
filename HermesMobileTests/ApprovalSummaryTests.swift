import XCTest
import SwiftUI
import Vision
import Observation
@testable import HermesMobile

@MainActor final class ApprovalSummaryTests: XCTestCase {
    private let server = URL(string: "https://hermes.example")!
    private let connectionID = UUID()

    private func key(chat: String = "chat-a", approval: String = "approval-1") -> ApprovalSummaries.Key {
        .init(scope: .init(server: server, connectionID: connectionID,
                           conversation: .session(profile: "default", key: chat)), request: .approval(approval))
    }

    func testLoadingKeepsTheCommandAndChoicesAndFailureQuietlyRemovesTheLine() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let started = expectation(description: "model request started")
        let hidden = expectation(description: "failed summary removed from the real card")
        var reply: CheckedContinuation<String, Error>?
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(view)
        defer { close(window) }
        await fulfillment(of: [started], timeout: 2)
        let loading = try capture(window, name: "loading")
        XCTAssertEqual(summaries.states[key], .loading)
        XCTAssertTrue(loading.contains("./draft.txt") && loading.lowercased().contains("allow once") && loading.contains("Deny"), loading)
        XCTAssertTrue(loading.contains("Summarizing"), loading)
        withObservationTracking { _ = summaries.states[key] } onChange: { hidden.fulfill() }
        reply?.resume(throwing: BotFailure.transport)
        await fulfillment(of: [hidden], timeout: 2)
        await settle(window)
        XCTAssertEqual(summaries.states[key], .unavailable)
        let failed = try capture(window, name: "failure-hidden")
        XCTAssertFalse(failed.contains("In plain words") || failed.contains("Summarizing"), failed)
        XCTAssertTrue(failed.contains("./draft.txt") && failed.lowercased().contains("allow once") && failed.contains("Deny"), failed)
    }

    func testSwitchOffShowsTheUnchangedCardAndNeverAsksTheModel() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let suite = "approval-summary-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: ApprovalSummaries.enabledKey)
        var calls = 0
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) { calls += 1; return "Not shown" }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(view.defaultAppStorage(defaults))
        await settle(window)
        let text = try capture(window, name: "switch-off-card")
        XCTAssertFalse(text.contains("AI summary") || text.contains("Summarizing"), text)
        assertRawCommand(in: view)
        XCTAssertTrue(text.contains("./draft.txt") && text.contains("Allow once") && text.contains("Deny"), text)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(summaries.states[key])
        close(window)
        let settings = try await host(NavigationStack {
            List { ApprovalSummarySettingsSection() }.navigationTitle("Chat")
        }.defaultAppStorage(defaults))
        defer { close(settings) }
        _ = try capture(settings, name: "switch-off-setting")
    }

    func testACardWithoutADirectConnectionHasNoSummarySlot() async throws {
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {})
        let window = try await host(view)
        defer { close(window) }
        let text = try capture(window, name: "no-direct-connection")
        XCTAssertFalse(text.contains("AI summary") || text.contains("Summarizing"), text)
        assertRawCommand(in: view)
        XCTAssertTrue(text.contains("./draft.txt") && text.contains("Allow once") && text.contains("Deny"), text)
    }

    func testTheSharedBotCardShowsTheSameExplanation() async throws {
        let summaries = ApprovalSummaries(), key = key()
        await summaries.show(key) { "Removes the draft file." }
        let approval = try XCTUnwrap(BotApprovalRequest(.object([
            "request_id": .string("fixture-approval"), "command": .string("rm ./draft.txt"),
            "description": .string("Deletes a file"), "choices": .array([.string("once"), .string("deny")])
        ])))
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries, load: { "Unused" })
        let view = BotPendingRequestCard(request: .approval(approval), identity: "Fixture bot · Local test host",
            isEnabled: true, canStop: true, isAnswering: false, resolution: nil,
            onApprove: { _ in }, onAnswer: { _ in }, onSkip: {}, onCredential: { _ in }, onStop: {}, onConnection: { _ in },
            summary: presentation)
            .padding().background(Color(.systemBackground))
        let window = try await host(view)
        defer { close(window) }
        let text = try capture(window, name: "bot-card-summary")
        XCTAssertTrue(text.contains("Removes the draft file."), text)
        XCTAssertTrue(text.lowercased().contains("allow once") && text.contains("Deny"), text)
    }

    func testTurningTheGlobalSwitchOffCancelsTheVisibleCardsRequest() async throws {
        let summaries = ApprovalSummaries(), key = key()
        let suite = "approval-summary-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ApprovalSummaries.enabledKey)
        let started = expectation(description: "summary started")
        let cancelled = expectation(description: "turning off cancelled the actual load")
        var reply: CheckedContinuation<String, Never>?
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { reply = $0; started.fulfill() }
            } onCancel: { cancelled.fulfill() }
        }
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
            onChoice: { _ in }, onSkipAll: {}, summary: presentation).defaultAppStorage(defaults)
        let window = try await host(view)
        defer { close(window) }
        await fulfillment(of: [started], timeout: 2)
        defaults.set(false, forKey: ApprovalSummaries.enabledKey)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(summaries.states[key], .unavailable)
        reply?.resume(returning: "A late explanation")
        await settle(window)
        let text = try capture(window, name: "switch-off-cancels")
        XCTAssertFalse(text.contains("In plain words") || text.contains("A late explanation"), text)
    }

    func testEqualIDsOnDifferentServersAndConnectionsNeverShare() async {
        let summaries = ApprovalSummaries(), first = key()
        let otherServer = ApprovalSummaries.Key(scope: .init(server: URL(string: "https://other.example")!,
            connectionID: connectionID, conversation: first.scope.conversation), request: first.request)
        let otherConnection = ApprovalSummaries.Key(scope: .init(server: server,
            connectionID: UUID(), conversation: first.scope.conversation), request: first.request)
        await summaries.show(first) { "First server" }
        await summaries.show(otherServer) { "Second server" }
        await summaries.show(otherConnection) { "Replacement connection" }
        XCTAssertEqual(summaries.states[first], .ready("First server"))
        XCTAssertEqual(summaries.states[otherServer], .ready("Second server"))
        XCTAssertEqual(summaries.states[otherConnection], .ready("Replacement connection"))
    }

    func testTheRealOverlayShowsTheCompletedSummary() async throws {
        let summaries = ApprovalSummaries(), key = key()
        await summaries.show(key) { "Removes the draft file." }
        let presentation = ApprovalSummaryPresentation(key: key, summaries: summaries, load: { "Unused" })
        let view = ApprovalRequestOverlay(content: content, isResponding: false, errorMessage: nil,
                                          onChoice: { _ in }, onSkipAll: {}, summary: presentation)
        let window = try await host(view)
        defer { close(window) }
        let text = try capture(window, name: "summary-shown")
        XCTAssertTrue(text.contains("Removes the draft file."), text)
    }

    /// Inspect the Text emitted by the overlay's actual body, not the input model or
    /// OCR's transcription of shell punctuation/spacing. The native capture separately
    /// checks the command's visible filename, buttons and absent summary. No private
    /// SwiftUI field names are used.
    private func assertRawCommand(in view: ApprovalRequestOverlay, file: StaticString = #filePath, line: UInt = #line) {
        let command = Text(verbatim: "rm ./draft.txt").font(.system(.footnote, design: .monospaced))
        func containsCommand(_ value: Any) -> Bool {
            if let text = value as? Text { return text == command }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class else { return false }
            return mirror.children.contains { containsCommand($0.value) }
        }
        XCTAssertTrue(containsCommand(view.body), "The card must contain the exact raw command Text", file: file, line: line)
    }

    private var content: ApprovalOverlayContent {
        .init(description: "Deletes a file", command: "rm ./draft.txt", scopeLine: nil,
              pendingCount: 1, choices: [.once, .deny])
    }

    private func host<V: View>(_ view: V) async throws -> UIWindow {
        let appeared = expectation(description: "real card appeared")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.onAppear { appeared.fulfill() })
        window.makeKeyAndVisible()
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Native rendering of the real live SwiftUI card; these images are evidence only,
    /// never displayed by the app. Kept in the xcresult and exported after the test run.
    private func capture(_ window: UIWindow, name: String) throws -> String {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("u1022b-approval-summary")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    func testAnOldReplyCannotTakeOverAReusedApprovalIDAfterItWasRemoved() async {
        let summaries = ApprovalSummaries(), key = key()
        let oldStarted = expectation(description: "old request started")
        var oldReply: CheckedContinuation<String, Never>?
        let old = Task {
            await summaries.show(key) { await withCheckedContinuation { oldReply = $0; oldStarted.fulfill() } }
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        summaries.retain([], in: key.scope)
        let newStarted = expectation(description: "new approval started")
        var newReply: CheckedContinuation<String, Never>?
        let new = Task {
            await summaries.show(key) { await withCheckedContinuation { newReply = $0; newStarted.fulfill() } }
        }
        await fulfillment(of: [newStarted], timeout: 2)
        oldReply?.resume(returning: "Old command")
        await old.value
        XCTAssertEqual(summaries.states[key], .loading, "an ended request cannot settle a new lifetime")
        newReply?.resume(returning: "New command")
        await new.value
        XCTAssertEqual(summaries.states[key], .ready("New command"))
    }

    func testAnsweringCancelsUnfinishedWorkAndRejectsItsLateResult() async {
        let summaries = ApprovalSummaries(), key = key()
        let started = expectation(description: "model request started")
        var reply: CheckedContinuation<String, Never>?
        var cancelled = false
        let show = Task {
            await summaries.show(key) {
                let text = await withCheckedContinuation { reply = $0; started.fulfill() }
                cancelled = Task.isCancelled
                return text
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(summaries.states[key], .loading)
        summaries.cancel(key)
        XCTAssertEqual(summaries.states[key], .unavailable)
        reply?.resume(returning: "Late summary")
        await show.value
        XCTAssertTrue(cancelled, "the actual in-flight load must be cancelled")
        XCTAssertEqual(summaries.states[key], .unavailable)
    }

    func testOnlyAnAuthoritativePendingSetDropsTheResultForThatConversation() async {
        let summaries = ApprovalSummaries(), first = key(), second = key(chat: "chat-b")
        await summaries.show(first) { "First" }
        await summaries.show(second) { "Second" }
        summaries.retain([], in: first.scope)
        XCTAssertNil(summaries.states[first])
        XCTAssertEqual(summaries.states[second], .ready("Second"))
    }

    func testEqualApprovalIDsInTwoChatsNeverShareAnExplanation() async {
        let summaries = ApprovalSummaries(), first = key(), second = key(chat: "chat-b")
        await summaries.show(first) { "First" }
        await summaries.show(second) { "Second" }
        XCTAssertEqual(summaries.states[first], .ready("First"))
        XCTAssertEqual(summaries.states[second], .ready("Second"))
    }

    func testAFailedRequestLeavesNoSummaryAndIsNotRetriedOnReturn() async {
        let summaries = ApprovalSummaries(), key = key()
        await summaries.show(key) { throw BotFailure.transport }
        XCTAssertEqual(summaries.states[key], .unavailable)
        var retried = false
        await summaries.show(key) { retried = true; return "Retry" }
        XCTAssertFalse(retried)
        XCTAssertEqual(summaries.states[key], .unavailable)
    }

    func testACompletedExplanationIsShownWhenTheCardReturnsWithoutAnotherRequest() async {
        let summaries = ApprovalSummaries(), key = key()
        var calls = 0
        await summaries.show(key) { calls += 1; return "Removes the draft file." }
        XCTAssertEqual(summaries.states[key], .ready("Removes the draft file."))
        await summaries.show(key) { calls += 1; return "A second explanation." }
        XCTAssertEqual(summaries.states[key], .ready("Removes the draft file."))
        XCTAssertEqual(calls, 1)
    }
}
