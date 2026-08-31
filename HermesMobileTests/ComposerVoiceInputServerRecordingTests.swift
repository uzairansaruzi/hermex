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

    func testRecordingAtUploadBoundaryLoadsForServerTranscription() throws {
        var dataLoadCount = 0
        let expectedData = Data("recording".utf8)

        let preparation = try ComposerVoiceInputController.prepareServerRecordingUpload(
            fileSize: { ComposerVoiceInputController.maximumServerRecordingUploadBytes },
            dataLoader: {
                dataLoadCount += 1
                return expectedData
            }
        )

        XCTAssertEqual(preparation, .upload(expectedData))
        XCTAssertEqual(dataLoadCount, 1)
    }

    func testRecordingOneByteOverUploadBoundarySkipsDataLoadAndServerUpload() throws {
        var dataLoadCount = 0

        let preparation = try ComposerVoiceInputController.prepareServerRecordingUpload(
            fileSize: { ComposerVoiceInputController.maximumServerRecordingUploadBytes + 1 },
            dataLoader: {
                dataLoadCount += 1
                return Data("should-not-load".utf8)
            }
        )

        XCTAssertEqual(preparation, .onDeviceFallback)
        XCTAssertEqual(dataLoadCount, 0)
    }

    func testFileSizeFailureSkipsDataLoad() {
        var dataLoadCount = 0

        XCTAssertThrowsError(
            try ComposerVoiceInputController.prepareServerRecordingUpload(
                fileSize: { throw TestFileError.metadataUnavailable },
                dataLoader: {
                    dataLoadCount += 1
                    return Data("should-not-load".utf8)
                }
            )
        ) { error in
            guard case .fileSize = error as? ComposerVoiceInputController.ServerRecordingUploadPreparationError else {
                return XCTFail("Expected file-size error, got \(error)")
            }
        }

        XCTAssertEqual(dataLoadCount, 0)
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

private enum TestFileError: Error {
    case metadataUnavailable
}
