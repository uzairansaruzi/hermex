import XCTest
import WatchShared
@testable import HermexWatchRoot

@MainActor
final class WatchVoiceCaptureTests: XCTestCase {
    func testTooShortRecordingFails() {
        let capture = WatchVoiceCapture()
        capture.beginRecording()
        XCTAssertEqual(capture.phase, .recording)
        XCTAssertFalse(capture.finishRecording(duration: 0.2))
        XCTAssertEqual(capture.phase, .failed(code: "tooShort"))
    }

    func testAcceptedRecordingMovesToTranscribing() {
        let capture = WatchVoiceCapture()
        capture.beginRecording()
        XCTAssertTrue(capture.finishRecording(duration: 1.5))
        XCTAssertEqual(capture.phase, .transcribing)
        capture.markSending()
        XCTAssertEqual(capture.phase, .sending)
        capture.markIdle()
        XCTAssertEqual(capture.phase, .idle)
    }

    func testFiveMinuteCapAcceptsAFullIOSLengthClip() {
        let capture = WatchVoiceCapture()
        capture.beginRecording()
        XCTAssertTrue(capture.finishRecording(duration: 240))
        XCTAssertEqual(capture.phase, .transcribing)
    }

    func testCancelReturnsToIdle() {
        let capture = WatchVoiceCapture()
        capture.beginRecording()
        capture.cancel()
        XCTAssertEqual(capture.phase, .idle)
    }

    func testPolicyBoundsMatchIOSFiveMinuteClip() {
        XCTAssertEqual(WatchVoiceCapturePolicy.minimumDuration, 0.5)
        XCTAssertEqual(WatchVoiceCapturePolicy.maximumDuration, WatchVoiceNoteAudioBudget.maximumDuration)
        XCTAssertEqual(WatchVoiceCapturePolicy.maximumDuration, 300)
        XCTAssertEqual(WatchVoiceCapturePolicy.maximumDurationPhrase, "5 minutes")
        XCTAssertTrue(WatchVoiceCapturePolicy.accept(duration: 300))
        XCTAssertTrue(WatchVoiceCapturePolicy.accept(duration: 300.4))
        XCTAssertFalse(WatchVoiceCapturePolicy.accept(duration: 0.1))
        XCTAssertFalse(WatchVoiceCapturePolicy.accept(duration: 301))
    }

    func testRecordingWaitsUntilTheAttemptIsStillCurrent() {
        let attempt = UUID()
        XCTAssertTrue(WatchVoiceStartGate.shouldBeginRecording(attempt: attempt, currentAttempt: attempt))
        XCTAssertFalse(WatchVoiceStartGate.shouldBeginRecording(attempt: attempt, currentAttempt: nil))
        XCTAssertFalse(WatchVoiceStartGate.shouldBeginRecording(attempt: attempt, currentAttempt: UUID()))
        XCTAssertTrue(WatchVoiceStartGate.shouldAcceptNewAttempt(startInFlight: false))
        XCTAssertFalse(WatchVoiceStartGate.shouldAcceptNewAttempt(startInFlight: true))
    }
}
