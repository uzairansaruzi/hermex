import AVFoundation
import Speech
import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class ComposerVoiceInputServerRecordingTests: APIClientTestCase {
    func testTeardownCancelsMicrophoneTapBeforeItsTaskStarts() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true })
        controller.transcribe = makeClient { _ in
            XCTFail("A gone composer must not upload")
            throw URLError(.cancelled)
        }.dictationTranscriber
        let tap = controller.scheduleToggle(currentDraft: "Original") { _ in XCTFail("Stale draft update") }
        controller.stopBeforeSubmittingDraft()
        await tap.value
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(recorder.isRecording)
    }

    func testInterruptedRecordingRetainsClipUntilUnlockedAndTranscribesOnce() async throws {
        let previousIdlePolicy = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = false
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdlePolicy }
        let recorder = DictationTestRecorder()
        var unlocked = true
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { unlocked }
        )
        let updated = expectation(description: "Retained audio updates its draft")
        var drafts: [String] = []
        controller.transcribe = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/transcribe")
            let body = String(data: apiTestBodyData(from: request) ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("interrupted-clip"))
            XCTAssertTrue(body.contains(recorder.url.lastPathComponent))
            return apiTestJSONResponse(#"{"ok":true,"transcript":"retained words"}"#, for: request)
        }.dictationTranscriber
        await controller.toggle(currentDraft: "Please") {
            drafts.append($0)
            updated.fulfill()
        }
        XCTAssertEqual(controller.state, .serverListening)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        unlocked = false
        controller.suspend()
        controller.suspend()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
        controller.resume()
        XCTAssertEqual(drafts, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
        unlocked = true
        controller.resume()
        controller.resume()
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(drafts, ["Please retained words"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
        controller.stopBeforeSubmittingDraft()
    }

    func testLeavingOwningComposerDiscardsSuspendedClipWithoutUpdatingDraft() async throws {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true }
        )
        controller.transcribe = makeClient { _ in
            XCTFail("A discarded clip must never upload")
            throw URLError(.cancelled)
        }.dictationTranscriber
        var draft = "Original"
        await controller.toggle(currentDraft: draft) { draft = $0 }
        controller.suspend()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.url.path))
        controller.stopBeforeSubmittingDraft()
        controller.resume()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(draft, "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    func testOldPermissionReplyCannotStartReplacementRecording() async {
        let previousIdlePolicy = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = false
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdlePolicy }
        let recorder = DictationTestRecorder()
        let firstAsked = expectation(description: "Old permission request")
        let secondAsked = expectation(description: "Replacement permission request")
        var permissions: [CheckedContinuation<Bool, Never>] = []
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: {
                await withCheckedContinuation {
                    permissions.append($0)
                    if permissions.count == 1 { firstAsked.fulfill() }
                    else { secondAsked.fulfill() }
                }
            }, serverRecorder: recorder, mayRecord: { true }
        )
        controller.transcribe = makeClient { _ in throw URLError(.cancelled) }.dictationTranscriber
        let first = Task { await controller.toggle(currentDraft: "Old") { _ in XCTFail("Stale update") } }
        await fulfillment(of: [firstAsked], timeout: 2)
        controller.suspend()
        let second = Task { await controller.toggle(currentDraft: "New") { _ in XCTFail("Not transcribed") } }
        await fulfillment(of: [secondAsked], timeout: 2)
        XCTAssertEqual(controller.state, .requestingPermission)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Permission must not hold an awake lease")
        permissions[0].resume(returning: true)
        await first.value
        XCTAssertEqual(controller.state, .requestingPermission)
        XCTAssertEqual(recorder.starts, 0)
        permissions[1].resume(returning: true)
        await second.value
        XCTAssertEqual(controller.state, .serverListening)
        XCTAssertEqual(recorder.starts, 1)
        controller.stopBeforeSubmittingDraft()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func testNewComposerRetiresPreviousOwnersRetainedClip() async {
        let oldRecorder = DictationTestRecorder()
        let old = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: oldRecorder, mayRecord: { true })
        let newRecorder = DictationTestRecorder()
        let replacement = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: newRecorder, mayRecord: { true })
        let client = makeClient { _ in
            XCTFail("Neither discarded clip should upload")
            throw URLError(.cancelled)
        }
        old.transcribe = client.dictationTranscriber
        replacement.transcribe = client.dictationTranscriber
        await old.toggle(currentDraft: "Old") { _ in XCTFail("Old composer must not update") }
        old.suspend()
        await replacement.toggle(currentDraft: "New") { _ in XCTFail("Not transcribed") }
        old.resume()
        XCTAssertEqual(old.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRecorder.url.path))
        XCTAssertEqual(replacement.state, .serverListening)
        XCTAssertTrue(newRecorder.isRecording)
        old.stopBeforeSubmittingDraft()
        XCTAssertTrue(ComposerAudioCaptureState.shared.isCapturing, "Late teardown must not clear the new owner's capture")
        replacement.stopBeforeSubmittingDraft()
        XCTAssertFalse(FileManager.default.fileExists(atPath: newRecorder.url.path))
    }

    func testUnexpectedRecorderFinishReleasesProtectionAndTranscribesOnlyOnce() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true })
        controller.transcribe = makeClient { request in
            XCTAssertTrue(String(data: apiTestBodyData(from: request) ?? Data(), encoding: .utf8)?.contains("interrupted-clip") == true)
            return apiTestJSONResponse(#"{"transcript":"saved"}"#, for: request)
        }.dictationTranscriber
        let updated = expectation(description: "One final transcript")
        var drafts: [String] = []
        await controller.toggle(currentDraft: "") { drafts.append($0); updated.fulfill() }
        let finish = recorder.onFinish
        finish?()
        finish?()
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertFalse(recorder.isRecording)
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertEqual(drafts, ["saved"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    func testWithoutATranscriberNothingRecordsForTheServer() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true })
        await controller.toggle(currentDraft: "Draft") { _ in XCTFail("Nothing transcribed") }
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(controller.errorMessage, "Speech-to-text is not available right now.")
    }

    /// A Hermes host answers a quiet recording with `{ok: true, transcript: ""}` (#1071).
    func testServerSilenceLeavesTheDraftAndShowsNoError() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true })
        var uploads: [(Data, String)] = []
        controller.transcribe = { audio, filename in
            uploads.append((audio, filename))
            return TranscribeResponse(ok: true, transcript: "", error: nil)
        }
        var drafts: [String] = []
        await controller.toggle(currentDraft: "Keep this") { drafts.append($0) }
        await finishRecording(controller)
        XCTAssertEqual(uploads.map(\.0), [Data("interrupted-clip".utf8)])
        XCTAssertEqual(uploads.map(\.1), [recorder.url.lastPathComponent])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(drafts, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    /// webui's empty `{ok: true}` stays the failure it was before #1071; only a Hermes host's is silence.
    func testWebuiEmptyTranscriptStillFails() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            serverRecorder: recorder, mayRecord: { true })
        controller.transcribe = makeClient { request in
            apiTestJSONResponse(#"{"ok":true,"transcript":"  "}"#, for: request)
        }.dictationTranscriber
        await controller.toggle(currentDraft: "Draft") { _ in XCTFail("Nothing transcribed") }
        await finishRecording(controller)
        XCTAssertEqual(controller.errorMessage, "Transcription returned no text.")
    }

    /// With no on-device recognizer, the server is the only provider and its reason shows as is.
    func testServerOnlyShowsTheHostsReason() async {
        let recorder = DictationTestRecorder()
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { _ in nil }, microphonePermission: { true },
            speechAuthorization: { XCTFail("No on-device fallback"); return .denied },
            serverRecorder: recorder, mayRecord: { true })
        controller.transcribe = { _, _ in TranscribeResponse(ok: false, transcript: nil, error: "STT is disabled") }
        await controller.toggle(currentDraft: "Draft") { _ in XCTFail("Nothing transcribed") }
        await finishRecording(controller)
        XCTAssertEqual(controller.errorMessage, "STT is disabled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    /// Server first retries a refused recording on-device, which here has no speech permission.
    func testServerFirstFallsBackOnDeviceAfterTheHostRefuses() async {
        let recorder = DictationTestRecorder()
        var authorizations = 0
        let controller = ComposerVoiceInputController(
            speechRecognizerFactory: { locale in
                let recognizer = SFSpeechRecognizer(locale: locale)
                recognizer?.supportsOnDeviceRecognition = true
                return recognizer
            },
            microphonePermission: { true },
            speechAuthorization: { authorizations += 1; return .denied },
            serverRecorder: recorder, mayRecord: { true })
        controller.providerPreference = .serverFirst
        controller.transcribe = { _, _ in TranscribeResponse(ok: false, transcript: nil, error: "STT is disabled") }
        await controller.toggle(currentDraft: "Draft") { _ in XCTFail("Nothing transcribed") }
        XCTAssertEqual(controller.state, .serverListening)
        await finishRecording(controller)
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(controller.errorMessage, "Speech recognition is disabled. Enable it in Settings to use voice input.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.url.path))
    }

    /// Stops a server recording and waits for its transcription to settle.
    private func finishRecording(_ controller: ComposerVoiceInputController) async {
        controller.stopKeepingTranscript()
        XCTAssertEqual(controller.state, .transcribing)
        let settled = expectation(description: "Transcription settles")
        withObservationTracking { _ = controller.state } onChange: { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(controller.state, .idle)
    }

    func testRecordingLeaseRestoresExistingPolicyAndIgnoresDuplicateExits() {
        var idleDisabled = false
        var orientations: [UIInterfaceOrientationMask?] = []
        let lease = ComposerDictationLease(
            readIdle: { idleDisabled }, writeIdle: { idleDisabled = $0 },
            writeOrientation: { orientations.append($0) }
        )
        lease.acquire(isPhone: true, orientation: .landscapeRight)
        lease.acquire(isPhone: true, orientation: .portrait)
        XCTAssertTrue(idleDisabled)
        XCTAssertEqual(orientations, [.landscapeRight])
        lease.release()
        lease.release()
        XCTAssertFalse(idleDisabled)
        XCTAssertEqual(orientations, [.landscapeRight, nil])
        idleDisabled = true
        lease.acquire(isPhone: true, orientation: .portrait)
        lease.release()
        XCTAssertTrue(idleDisabled, "Release must preserve a preexisting awake policy")
    }

    func testIPadRecordingDoesNotOverrideAdaptivePolicy() {
        var idleDisabled = false
        var orientations: [UIInterfaceOrientationMask?] = []
        let lease = ComposerDictationLease(
            readIdle: { idleDisabled }, writeIdle: { idleDisabled = $0 },
            writeOrientation: { orientations.append($0) }
        )
        lease.acquire(isPhone: false, orientation: .portrait)
        lease.release()
        XCTAssertFalse(idleDisabled)
        XCTAssertEqual(orientations.count, 0)
    }

    func testServerRecordingSettingsAreMonoAACWithSpeechBitrate() {
        let settings = ComposerVoiceInputController.serverRecordingSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, ComposerVoiceInputController.serverRecordingBitrate)
    }

    func testServerRecordingUsesM4AContainer() {
        XCTAssertEqual(ComposerVoiceInputController.serverRecordingFileExtension, "m4a")
    }

    func testRecordingAtUploadBoundaryLoadsForServerTranscription() {
        var dataLoadCount = 0
        let expectedData = Data("recording".utf8)
        let expectedBoundary = 19 * 1_024 * 1_024

        XCTAssertEqual(
            ComposerVoiceInputController.maximumServerRecordingUploadBytes,
            expectedBoundary
        )
        XCTAssertLessThan(
            ComposerVoiceInputController.maximumServerRecordingUploadBytes,
            PendingAttachment.maximumUploadBytes
        )

        let data = ComposerVoiceInputController.loadServerRecordingForUpload(
            fileSize: expectedBoundary,
            dataLoader: {
                dataLoadCount += 1
                return expectedData
            }
        )

        XCTAssertEqual(data, expectedData)
        XCTAssertEqual(dataLoadCount, 1)
    }

    func testRecordingOneByteOverUploadBoundarySkipsDataLoadAndServerUpload() {
        var dataLoadCount = 0

        let data = ComposerVoiceInputController.loadServerRecordingForUpload(
            fileSize: ComposerVoiceInputController.maximumServerRecordingUploadBytes + 1,
            dataLoader: {
                dataLoadCount += 1
                return Data("should-not-load".utf8)
            }
        )

        XCTAssertNil(data)
        XCTAssertEqual(dataLoadCount, 0)
    }

    func testMissingRecordingFailsFileSizeInspection() {
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(
            try ComposerVoiceInputController.serverRecordingFileSize(at: missingFile)
        )
    }

    // Recording has no duration cap: it runs until the user stops it. This
    // documents why that is safe — even a 30-minute dictation at the configured
    // bitrate stays comfortably below the server's default 20 MB upload ceiling.
    func testHalfHourRecordingStaysUnderUploadCeiling() {
        let thirtyMinutesInSeconds = 30 * 60
        let approxBytes = ComposerVoiceInputController.serverRecordingBitrate / 8 * thirtyMinutesInSeconds
        XCTAssertLessThan(approxBytes, PendingAttachment.maximumUploadBytes)
    }
}

@MainActor
private final class DictationTestRecorder: ComposerServerRecording {
    var onFinish: (() -> Void)?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
    var isRecording = false
    var starts = 0
    func start() throws -> URL {
        starts += 1
        isRecording = true
        try Data("interrupted-clip".utf8).write(to: url)
        return url
    }
    func stop() { isRecording = false }
}
