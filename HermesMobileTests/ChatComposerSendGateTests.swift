import AVFoundation
import UIKit
import XCTest
@testable import HermesMobile

/// Send-button gate for the composer: text-only, attachment-only, both, or
/// neither (#403). Busy flags always disable; attachment-only sends synthesize
/// their message text in `PendingAttachment.chatMessageText`.
final class ChatComposerSendGateTests: XCTestCase {
    /// A host's level the model's list doesn't name stays on the ladder and stays current.
    func testThinkingLadderKeepsALevelTheListDoesNotName() {
        let ladder = ThinkingLadder(levels: ["low", "high"], current: "turbo")

        XCTAssertEqual(ladder.levels, ["low", "high", "turbo"])
        XCTAssertEqual(ladder.currentIndex, 2)
    }

    /// A drag lands on the nearest level, past either end included, and sends one change: none
    /// when it comes back to where it started.
    func testThinkingLadderSendsOnlyAChangeFromWhereTheDragLands() {
        let ladder = ThinkingLadder(levels: ["low", "medium", "high"], current: "medium")

        XCTAssertEqual(ladder.index(atX: -50, width: 300), 0)
        XCTAssertEqual(ladder.index(atX: 140, width: 300), 1)
        XCTAssertEqual(ladder.index(atX: 900, width: 300), 2)
        XCTAssertEqual(ladder.commit(at: 2), "high")
        XCTAssertNil(ladder.commit(at: 1))
    }

    /// A vertical swipe that starts on the control is the list scrolling, not a level change.
    func testOnlyASidewaysDragAdjustsTheThinkingLevel() {
        XCTAssertTrue(ThinkingLadder.isAdjustment(CGSize(width: 40, height: 6)))
        XCTAssertTrue(ThinkingLadder.isAdjustment(CGSize(width: -40, height: -6)))
        XCTAssertFalse(ThinkingLadder.isAdjustment(CGSize(width: 6, height: 40)))
        XCTAssertFalse(ThinkingLadder.isAdjustment(CGSize(width: -6, height: -40)))
    }

    /// VoiceOver's swipe moves one level and stops at each end.
    func testThinkingLadderAdjustsOneLevelAndStopsAtTheEnds() {
        let middle = ThinkingLadder(levels: ["low", "medium", "high"], current: "medium")
        XCTAssertEqual(middle.adjusted(by: 1), 2)
        XCTAssertEqual(middle.adjusted(by: -1), 0)
        XCTAssertNil(ThinkingLadder(levels: ["low", "high"], current: "high").adjusted(by: 1))
        XCTAssertEqual(ThinkingLadder(levels: ["low", "high"], current: nil).adjusted(by: 1), 0)
    }

    /// The Approvals row shows the state in effect: Off wins, then YOLO, then the mode. A mode
    /// newer than this app still shows, and a webui session has no mode to show.
    func testApprovalsRowShowsTheStateInEffect() {
        func approvals(yolo: Bool = false, mode: String?, mayTurnOff: Bool = true) -> ComposerApprovals {
            ComposerApprovals(isYoloOn: yolo, offersModes: mode != nil, mode: mode, mayTurnOffYolo: mayTurnOff,
                              isChanging: false, errorMessage: nil)
        }

        XCTAssertEqual(approvals(yolo: true, mode: "off", mayTurnOff: false).value, "Off")
        XCTAssertEqual(approvals(yolo: true, mode: "smart").value, "YOLO")
        XCTAssertEqual(approvals(mode: "manual").value, "Manual")
        XCTAssertEqual(approvals(mode: "cautious").value, "Cautious")
        XCTAssertNil(approvals(mode: nil).value)
        XCTAssertEqual(approvals(yolo: true, mode: nil).value, "YOLO")
        XCTAssertTrue(approvals(yolo: true, mode: "manual", mayTurnOff: false).isYoloLocked)
        XCTAssertFalse(approvals(yolo: true, mode: "manual").isYoloLocked)
    }

    /// A change's answer shows beside the row that asked, never on another row, and an
    /// old error doesn't show on a row nobody touched since the sheet opened.
    func testModelSettingsShowsAnswersOnlyBesideTheRowThatAsked() {
        func status(_ row: ModelSettingsRow, _ lastChanged: ModelSettingsRow?, updating: Bool = false,
                    error: String? = nil, notice: String? = nil) -> ModelSettingsRowStatus? {
            ModelSettingsRowStatus.resolve(row: row, lastChanged: lastChanged, isUpdating: updating,
                                           errorMessage: error, notice: notice)
        }

        XCTAssertNil(status(.model, .model, updating: true, error: "old"), "Nothing shows while a change is out")
        XCTAssertEqual(status(.model, .model, error: "Refused"), .failed("Refused"))
        XCTAssertEqual(status(.model, .model, notice: "After this response"), .notice("After this response"))
        XCTAssertNil(status(.model, .model))
        XCTAssertNil(status(.thinking, .model, error: "Refused"))
        XCTAssertNil(status(.model, nil, error: "old"))
    }

    /// A chat's settings leave the composer after its first message, and an existing chat
    /// that hasn't loaded yet never shows them.
    func testNewChatControlsShowOnlyBeforeTheFirstMessage() {
        XCTAssertTrue(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: nil, isStreaming: false))
        XCTAssertTrue(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 0, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: true, serverMessageCount: 0, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 4, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 0, isStreaming: true))
    }

    /// The header names the workspace and the Profile, whichever of them there is.
    func testHeaderSubtitleNamesWorkspaceAndProfile() {
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: "/repo/hermes", profileTitle: "Default"), "hermes · Default")
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: "/repo/hermes", profileTitle: "Profile"), "hermes")
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: "Default"), "Default")
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: nil))
    }

    /// A level shows at once and clears when answered. Levels asked for meanwhile don't pile up:
    /// only the newest goes, and a refused one falls back to the chat's own.
    @MainActor
    func testThinkingLevelsShowAtOnceAndOnlyTheNewestWaitingOneGoes() async {
        let sender = ThinkingLevelSender()
        var sent: [String] = []
        var answers: [CheckedContinuation<Bool, Never>] = []
        let waiting = expectation(description: "the first level is out")
        waiting.assertForOverFulfill = false
        let send: (String) async -> Bool = { level in
            sent.append(level)
            return await withCheckedContinuation { answers.append($0); waiting.fulfill() }
        }

        sender.request("low", send: send)
        XCTAssertEqual(sender.pendingLevel, "low")
        await fulfillment(of: [waiting], timeout: 5)

        sender.request("medium", send: send)
        sender.request("high", send: send)
        XCTAssertEqual(sender.pendingLevel, "high")
        XCTAssertEqual(sent, ["low"])

        let second = expectation(description: "the newest level is out")
        let cleared = expectation(description: "the answers are in")
        Task { @MainActor in
            answers.removeFirst().resume(returning: true)
            while answers.isEmpty { await Task.yield() }
            second.fulfill()
            answers.removeFirst().resume(returning: false)
            while sender.pendingLevel != nil { await Task.yield() }
            cleared.fulfill()
        }
        await fulfillment(of: [second, cleared], timeout: 5)

        XCTAssertEqual(sent, ["low", "high"])
        XCTAssertNil(sender.pendingLevel)
    }

    /// A run holds configuration but not `+` (#1436); offline and read-only hold both.
    func testAttachingStaysOpenDuringARunWhereConfigurationIsHeld() {
        func gate(_ session: SessionSummary = SessionSummary(sessionId: "s"), offline: Bool = false) -> ChatComposerControlGate {
            ChatComposerControlGate(
                access: ChatComposerAccess(session: session, isViewingCachedData: offline),
                isSending: false, isCompressingSession: false, isWaitingForStream: true, isUpdatingConfiguration: false
            )
        }

        XCTAssertTrue(gate().allowsAttaching)
        XCTAssertFalse(gate().allowsConfiguration)
        XCTAssertFalse(gate(offline: true).allowsAttaching)
        XCTAssertFalse(gate(SessionSummary(sessionId: "s", readOnly: true)).allowsAttaching)
    }

    func testSendFocusPreservesFailureNewEditingAndNewDraft() {
        XCTAssertEqual(ChatSendFocusPolicy.focusAfterSubmission(
            succeeded: true, dismissKeyboard: true, wasFocused: true,
            submittedRevision: 1, currentRevision: 1, hasNewDraft: false
        ), false)
        XCTAssertEqual(ChatSendFocusPolicy.focusAfterSubmission(
            succeeded: true, dismissKeyboard: false, wasFocused: true,
            submittedRevision: 1, currentRevision: 1, hasNewDraft: false
        ), true)
        for (success, revision, draft) in [(false, 1, false), (true, 2, false), (true, 1, true)] {
            XCTAssertNil(ChatSendFocusPolicy.focusAfterSubmission(
                succeeded: success, dismissKeyboard: true, wasFocused: true,
                submittedRevision: 1, currentRevision: revision, hasNewDraft: draft
            ))
        }
    }

    func testQuoteOnlyDraftShowsSendWhileStreamIsActive() {
        XCTAssertFalse(ChatComposerSendGate.showsStopButton(
            isWaitingForStream: true,
            hasText: false,
            hasQuotes: true
        ))
        XCTAssertTrue(ChatComposerSendGate.showsStopButton(
            isWaitingForStream: true,
            hasText: false,
            hasQuotes: false
        ))
    }

    /// Staged files are content (#1367): a Hermes draft holding only files mid-run
    /// queues them under every Send While Responding default instead of offering
    /// Stop, with no other choice to hold for. A webui session keeps Stop.
    func testHermesFileOnlyDraftMidRunQueuesInsteadOfStop() {
        for behavior in StreamingSendBehavior.allCases {
            let button = ChatComposerSendButton(isWaitingForStream: true, hasText: false, hasQuotes: false,
                                                defaultBehavior: behavior, stagedFilesDropSteer: true)
            XCTAssertFalse(button.showsStop, "\(behavior)")
            XCTAssertEqual(button.runningBehavior, .queue, "\(behavior)")
            XCTAssertEqual(button.choices, [], "\(behavior)")
        }
        let webui = ChatComposerSendButton(isWaitingForStream: true, hasText: false, hasQuotes: false,
                                           defaultBehavior: .queue)
        XCTAssertTrue(webui.showsStop)
    }

    /// ⌘⇧↩ (#1380) takes the other safe choice from what Send does now, never Stop and send.
    func testKeyboardAlternateIsTheOtherSafeChoiceFromTheEffectiveDefault() {
        func alternate(_ defaultBehavior: StreamingSendBehavior, waiting: Bool = true,
                       stagedFiles: Bool = false) -> StreamingSendBehavior? {
            ChatComposerSendButton(
                isWaitingForStream: waiting, hasText: true, hasQuotes: false,
                defaultBehavior: defaultBehavior, stagedFilesDropSteer: stagedFiles
            ).alternateBehavior
        }

        XCTAssertEqual(alternate(.steer), .queue)
        XCTAssertEqual(alternate(.queue), .steer)
        XCTAssertEqual(alternate(.interrupt), .steer)
        // Staged files turn a Steer default into Queue, leaving only Stop and send.
        XCTAssertNil(alternate(.steer, stagedFiles: true))
        XCTAssertNil(alternate(.steer, waiting: false))
    }

    /// A quick tap acts; the release of a hold that opened the card does not,
    /// and only that one release is dropped.
    func testHoldReleaseIsDroppedAndQuickTapActs() {
        var hold = ChatComposerSendHold()
        hold.pressBegan()
        XCTAssertTrue(hold.activate(), "a quick tap")

        hold.pressBegan()
        hold.openedChoices()
        XCTAssertFalse(hold.activate(), "the hold's own release")
        XCTAssertTrue(hold.activate(), "the next activation")
    }

    /// A hold released off Send never reaches the Button, so closing the card
    /// clears the mark. Otherwise the next VoiceOver or keyboard activation,
    /// which has no touch-down, would do nothing. A finger still down (the run
    /// ended under it) keeps its release dropped.
    func testClosingTheCardAfterLiftingOffSendKeepsTheNextActivation() {
        var liftedOff = ChatComposerSendHold()
        liftedOff.pressBegan()
        liftedOff.openedChoices()
        liftedOff.choicesClosed(isPressing: false)
        XCTAssertTrue(liftedOff.activate(), "an activation after the card closed")

        var stillHeld = ChatComposerSendHold()
        stillHeld.pressBegan()
        stillHeld.openedChoices()
        stillHeld.choicesClosed(isPressing: true)
        XCTAssertFalse(stillHeld.activate(), "the held finger's release")
    }

    func testQuoteOnlySendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasQuotes: true,
            hasStagedAttachments: false,
            block: nil
        ))
    }

    func testAttachmentOnlySendIsEnabled() {
        XCTAssertFalse(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasStagedAttachments: true,
            block: nil
        ))
    }

    func testEmptyDraftWithNoAttachmentsIsDisabled() {
        XCTAssertTrue(ChatComposerSendGate.isDisabled(
            hasText: false,
            hasStagedAttachments: false,
            block: nil
        ))
    }

    /// Each busy flag, and the offline cache (#1375), holds Send with content, and the
    /// block names what it waits on for VoiceOver.
    func testBusyFlagsDisableEvenWithContent() {
        func block(_ flag: Int) -> ChatComposerSendBlock? {
            ChatComposerSendBlock(isOffline: flag == 0, isSending: flag == 1, isCompressingSession: flag == 2,
                                  isUploadingAttachment: flag == 3, isUpdatingConfiguration: flag == 4)
        }
        let busy = (0...4).map(block)
        XCTAssertEqual(busy, [.offline, .sending, .compressingSession, .uploadingAttachment, .updatingConfiguration])
        for block in busy {
            XCTAssertTrue(ChatComposerSendGate.isDisabled(hasText: true, hasStagedAttachments: true, block: block))
        }
        XCTAssertNil(block(-1))
    }

    /// Offline, a Hermes chat's plain-text Send waits for the reconnect (#1407); quotes, files, a
    /// `/` command and a read-only session stay held, and while one waits every Send holds.
    func testOfflineHoldsEverySendButAWaitingPlainTextOne() {
        let offline = ChatComposerAccess(session: SessionSummary(profile: "default"), isViewingCachedData: true,
                                         offersWaitingSend: true)
        XCTAssertFalse(offline.holdsSendOffline(isPlainText: true))
        XCTAssertTrue(offline.holdsSendOffline(isPlainText: false))
        let readOnly = ChatComposerAccess(session: SessionSummary(profile: "default", readOnly: true),
                                          isViewingCachedData: true, offersWaitingSend: true)
        XCTAssertTrue(readOnly.holdsSendOffline(isPlainText: true))
        XCTAssertEqual(ChatComposerSendBlock(isWaitingForConnection: true, isOffline: false, isSending: false,
                                             isCompressingSession: false, isUploadingAttachment: false,
                                             isUpdatingConfiguration: false), .waitingForConnection)
    }
}

final class HermexAttachmentPickerPolicyTests: XCTestCase {
    func testSelectionPreservesOrderAndHonorsCapacity() {
        var selection: [String] = []
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "a", capacity: 2)
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "b", capacity: 2)
        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "c", capacity: 2)
        XCTAssertEqual(selection, ["a", "b"])

        selection = HermexAttachmentPickerPolicy.toggledSelection(selection, id: "a", capacity: 2)
        XCTAssertEqual(selection, ["b"])
    }

    func testLifecycleFenceRejectsLateCompletion() {
        var fence = HermexAttachmentLifecycleFence()
        let first = fence.begin()
        let second = fence.begin()
        XCTAssertFalse(fence.consume(first))
        XCTAssertTrue(fence.consume(second))
        XCTAssertFalse(fence.consume(second))

        let cancelled = fence.begin()
        fence.invalidate()
        XCTAssertFalse(fence.consume(cancelled))
    }

    /// Detaching the preview makes AVCaptureSession rebuild its graph and wait
    /// for it; on device that held the main thread for ~9 s after leaving the
    /// camera (#809). The detach must happen off the main thread.
    @MainActor
    func testCameraPreviewDetachesOffTheMainThread() {
        let controller = HermexAttachmentCameraController()
        let layer = AVCaptureVideoPreviewLayer(session: controller.session)
        let detached = expectation(description: "preview layer detached")
        var detachedOnMain: Bool?
        let observation = layer.observe(\.session, options: [.new]) { layer, _ in
            guard layer.session == nil else { return }
            detachedOnMain = Thread.isMainThread
            detached.fulfill()
        }

        controller.detachPreviewLayer(layer)

        wait(for: [detached], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(detachedOnMain, false)
        XCTAssertNil(layer.session)
    }

    @MainActor
    func testImageProcessorNormalizesSelectedMediaToBoundedJPEG() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }

        let media = try await HermexAttachmentImageProcessor.prepare(
            data: source,
            filename: "Screenshot.png"
        )

        XCTAssertEqual(media.filename, "Screenshot.jpg")
        XCTAssertFalse(media.data.isEmpty)
        XCTAssertLessThanOrEqual(media.data.count, 8 * 1_024 * 1_024)
        XCTAssertNotNil(UIImage(data: media.data))
    }

    @MainActor
    func testImageProcessorPreservesTransparency() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        }

        let media = try await HermexAttachmentImageProcessor.prepare(
            data: source,
            filename: "Transparent.png"
        )

        XCTAssertEqual(media.filename, "Transparent.png")
        XCTAssertNotNil(UIImage(data: media.data))
    }
}
