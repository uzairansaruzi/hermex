import AVFoundation
import XCTest
@testable import HermesMobile

@MainActor
final class ComposerVoiceInputServerRecordingTests: XCTestCase {
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
