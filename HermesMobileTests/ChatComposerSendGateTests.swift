import AVFoundation
import os
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class ChatComposerSendGateTests: XCTestCase {
    func testAShortViewportHoldsTheEditorToItsMinimumWhateverTheSizeClass() {
        XCTAssertEqual(
            ComposerTextInputHeight.expanded(measured: 160, verticalSizeClass: .regular, isViewportShort: true),
            ComposerTextInputHeight.shortViewportMinimum)
        XCTAssertEqual(ComposerTextInputHeight.expanded(measured: 160, verticalSizeClass: .regular, isViewportShort: false), 160)
    }

    func testThinkingLadderKeepsALevelTheListDoesNotName() {
        let ladder = ThinkingLadder(levels: ["low", "high"], current: "turbo")

        XCTAssertEqual(ladder.levels, ["low", "high", "turbo"])
        XCTAssertEqual(ladder.currentIndex, 2)
    }

    func testThinkingLadderSendsOnlyAChangeFromWhereTheDragLands() {
        let ladder = ThinkingLadder(levels: ["low", "medium", "high"], current: "medium")

        XCTAssertEqual(ladder.index(atPosition: ThinkingLadder.position(atX: -50, width: 300)), 0)
        XCTAssertEqual(ladder.index(atPosition: ThinkingLadder.position(atX: 140, width: 300)), 1)
        XCTAssertEqual(ladder.index(atPosition: ThinkingLadder.position(atX: 900, width: 300)), 2)
        XCTAssertEqual(ladder.commit(at: 2), "high")
        XCTAssertNil(ladder.commit(at: 1))
    }

    func testThinkingSliderDragTicksPerLevelAndPicksOnceOnRelease() {
        let ladder = ThinkingLadder(levels: ["low", "medium", "high"], current: "low")
        var drag = ThinkingSliderDrag()

        XCTAssertFalse(drag.move(to: 0.1, on: ladder), "Still on the current level")
        XCTAssertTrue(drag.move(to: 0.5, on: ladder))
        XCTAssertFalse(drag.move(to: 0.6, on: ladder), "Still on the same level")
        XCTAssertTrue(drag.move(to: 1, on: ladder))
        XCTAssertEqual(drag.end(on: ladder), 2)
        XCTAssertEqual(drag.position, 1, "The thumb must not head back before the pick reaches the ladder")
        XCTAssertNil(drag.end(on: ladder), "One release, one pick")

        _ = drag.move(to: 1, on: ladder)
        _ = drag.move(to: 0, on: ladder)
        XCTAssertNil(drag.end(on: ladder), "Back on the current level")
        XCTAssertNil(drag.position)

        _ = drag.move(to: 1, on: ladder)
        drag.cancel()
        XCTAssertNil(drag.position)
        XCTAssertNil(drag.end(on: ladder))
    }

    func testOnlyASidewaysDragAdjustsTheThinkingLevel() {
        XCTAssertTrue(ThinkingLadder.isAdjustment(CGSize(width: 40, height: 6)))
        XCTAssertTrue(ThinkingLadder.isAdjustment(CGSize(width: -40, height: -6)))
        XCTAssertFalse(ThinkingLadder.isAdjustment(CGSize(width: 6, height: 40)))
        XCTAssertFalse(ThinkingLadder.isAdjustment(CGSize(width: -6, height: -40)))
    }

    func testThinkingSliderSnapsWithNoTimePassingUnderReduceMotion() {
        let store = ThinkingSliderStore(), size = CGSize(width: 348, height: 56)
        _ = store.advance(time: 100, target: 0, followsFinger: false, size: size, isStill: true)
        let frame = store.advance(time: 200, target: 1, followsFinger: false, size: size, isStill: true)

        XCTAssertEqual(frame.level, 1)
        XCTAssertEqual(frame.delta, 0)
        XCTAssertEqual(frame.thumbX, 348 - ThinkingSliderMetrics.inset)
    }

    func testThinkingSliderFollowsTheFingerAndResumesWithoutAJump() {
        let size = CGSize(width: 348, height: 56)
        func step(followsFinger: Bool) -> Double {
            let store = ThinkingSliderStore()
            _ = store.advance(time: 100, target: 0, followsFinger: followsFinger, size: size, isStill: false)
            return store.advance(time: 100 + 1.0 / 60, target: 1, followsFinger: followsFinger, size: size, isStill: false).level
        }
        XCTAssertGreaterThan(step(followsFinger: true), step(followsFinger: false))

        let store = ThinkingSliderStore()
        _ = store.advance(time: 100, target: 0, followsFinger: false, size: size, isStill: false)
        let resumed = store.advance(time: 1000, target: 0, followsFinger: false, size: size, isStill: false)
        XCTAssertEqual(resumed.delta, 0.05)
    }

    @MainActor
    func testEveryThinkingSliderLookDrawsAtAnyLevelAndWidth() throws {
        for look in ThinkingSliderLook.allCases {
            for width in [348.0, 1.0] {
                let store = ThinkingSliderStore()
                let levels = [0.0, 1, 0.5, 0, 1, 0.14]
                let canvas = Canvas { context, size in
                    for (step, level) in levels.enumerated() {
                        let frame = store.advance(
                            time: Double(step) * 0.04, target: level, followsFinger: true, size: size, isStill: false
                        )
                        var track = context
                        look.drawTrack(&track, frame, store)
                        look.drawThumb(&track, frame)
                    }
                }
                .frame(width: width, height: ThinkingSliderMetrics.height)
                let image = try XCTUnwrap(ImageRenderer(content: canvas).uiImage, look.name)
                XCTAssertEqual(image.size.width, width, look.name)
                XCTAssertNotNil(store.level, "\(look.name) never drew")
            }
        }
    }

    func testThinkingLadderAdjustsOneLevelAndStopsAtTheEnds() {
        let middle = ThinkingLadder(levels: ["low", "medium", "high"], current: "medium")
        XCTAssertEqual(middle.adjusted(by: 1), 2)
        XCTAssertEqual(middle.adjusted(by: -1), 0)
        XCTAssertNil(ThinkingLadder(levels: ["low", "high"], current: "high").adjusted(by: 1))
        XCTAssertEqual(ThinkingLadder(levels: ["low", "high"], current: nil).adjusted(by: 1), 0)
    }

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

    func testNewChatControlsShowOnlyBeforeTheFirstMessage() {
        XCTAssertTrue(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: nil, isStreaming: false))
        XCTAssertTrue(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 0, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: true, serverMessageCount: 0, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 4, isStreaming: false))
        XCTAssertFalse(ChatComposerNewChatPolicy.showsControls(hasMessages: false, serverMessageCount: 0, isStreaming: true))
    }

    func testHeaderSubtitleNamesWorkspaceAndProfile() {
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: "/repo/hermes", profileTitle: "Default"), "hermes · Default")
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: "/repo/hermes", profileTitle: "Profile"), "hermes")
        XCTAssertEqual(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: "Default"), "Default")
        XCTAssertNil(ChatToolbarSubtitleResolver.subtitle(workspacePath: nil, profileTitle: nil))
    }

    @MainActor
    func testThinkingLevelsShowAtOnceAndOnlyTheNewestWaitingOneGoes() async {
        let sender = ThinkingLevelSender()
        var sent: [String] = []
        var answers: [CheckedContinuation<Bool, Never>] = []
        let firstOut = expectation(description: "the first level is out")
        let newestOut = expectation(description: "the newest level is out")
        let send: (String) async -> Bool = { level in
            sent.append(level)
            return await withCheckedContinuation {
                answers.append($0)
                (level == "low" ? firstOut : newestOut).fulfill()
            }
        }

        sender.request("low", send: send)
        XCTAssertEqual(sender.pendingLevel, "low")
        await fulfillment(of: [firstOut], timeout: 5)

        sender.request("medium", send: send)
        sender.request("high", send: send)
        XCTAssertEqual(sender.pendingLevel, "high")
        XCTAssertEqual(sent, ["low"])

        answers.removeFirst().resume(returning: true)
        await fulfillment(of: [newestOut], timeout: 5)
        answers.removeFirst().resume(returning: false)
        await waitUntil("a refused level clears") { sender.pendingLevel == nil }

        XCTAssertEqual(sent, ["low", "high"])
    }

    @MainActor
    func testAnAcceptedThinkingLevelOutlastsTheAnswer() async {
        let holding = ThinkingLevelSender(settleDelay: .seconds(60))
        holding.request("high") { _ in true }
        await waitUntil("the host answered") { !holding.isSending }
        XCTAssertEqual(holding.pendingLevel, "high")

        let settled = ThinkingLevelSender(settleDelay: .zero)
        settled.request("high") { _ in true }
        await waitUntil("the level lets go") { settled.pendingLevel == nil }
    }

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

    func testModelSettingsOpensDuringARunOnlyToTurnYoloOff() {
        func allows(yolo: Bool, mayTurnOff: Bool = true, offline: Bool = false, running: Bool = true) -> Bool {
            ChatComposerControlGate(
                access: ChatComposerAccess(session: SessionSummary(sessionId: "s"), isViewingCachedData: offline),
                isSending: false, isCompressingSession: false, isWaitingForStream: running, isUpdatingConfiguration: false
            ).allowsModelSettings(approvals: ComposerApprovals(
                isYoloOn: yolo, offersModes: true, mode: "manual", mayTurnOffYolo: mayTurnOff,
                isChanging: false, errorMessage: nil
            ))
        }

        XCTAssertTrue(allows(yolo: false, running: false))
        XCTAssertTrue(allows(yolo: true))
        XCTAssertFalse(allows(yolo: false), "Nothing to turn off, so the run holds it")
        XCTAssertFalse(allows(yolo: true, mayTurnOff: false), "The host holds YOLO on")
        XCTAssertFalse(allows(yolo: true, offline: true))
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
        XCTAssertNil(alternate(.steer, stagedFiles: true))
        XCTAssertNil(alternate(.steer, waiting: false))
    }

    func testHoldReleaseIsDroppedAndQuickTapActs() {
        var hold = ChatComposerSendHold()
        hold.pressBegan()
        XCTAssertTrue(hold.activate(), "a quick tap")

        hold.pressBegan()
        hold.openedChoices()
        XCTAssertFalse(hold.activate(), "the hold's own release")
        XCTAssertTrue(hold.activate(), "the next activation")
    }

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
    private static func opaquePNG(width: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 40), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 40))
        }
    }

    func testPickedPhotosImportInSelectionOrder() async throws {
        let first = Self.opaquePNG(width: 30)
        let second = Self.opaquePNG(width: 90)

        let media = try await HermexPickedPhotoImporter.prepare(
            [{ first }, { second }],
            batchName: "photo_1"
        )

        XCTAssertEqual(media.compactMap { UIImage(data: $0.data)?.size.width }, [30, 90])
    }

    func testUnreadablePickedPhotoFailsTheWholeImport() async {
        let image = Self.opaquePNG(width: 30)
        do {
            _ = try await HermexPickedPhotoImporter.prepare([{ image }, { nil }], batchName: "photo_1")
            XCTFail("Expected the import to fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancelledImportStopsBeforeLoadingTheRest() async {
        let image = Self.opaquePNG(width: 30)
        let secondLoaded = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await HermexPickedPhotoImporter.prepare(
                [
                    { withUnsafeCurrentTask { $0?.cancel() }; return image },
                    { secondLoaded.withLock { $0 = true }; return image }
                ],
                batchName: "photo_1"
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(secondLoaded.withLock { $0 })
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
