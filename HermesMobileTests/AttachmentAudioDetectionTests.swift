import XCTest
@testable import HermesMobile

final class AttachmentAudioDetectionTests: XCTestCase {

    func testMimeAudioPrefixIsAudio() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: "audio/mpeg", name: nil, path: nil))
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: "AUDIO/WEBM", name: "voice", path: nil))
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: false, mime: "audio/mp4", name: "clip.bin", path: nil))
    }

    func testKnownAudioExtensionsAreAudio() {
        for ext in ["m4a", "mp3", "wav", "aac", "caf", "ogg", "oga", "opus", "flac"] {
            XCTAssertTrue(
                AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "clip.\(ext)", path: nil),
                "Expected .\(ext) to be detected as audio"
            )
        }
    }

    func testExtensionDetectionIsCaseInsensitive() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "VOICE.M4A", path: nil))
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "Song.Mp3", path: nil))
    }

    func testUnknownExtensionIsNotAudio() {
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "archive.zip", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "image.png", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "noextension", path: nil))
    }

    func testDisplayNameWithoutExtensionFallsBackToPath() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "Voice note", path: "/ws/clip.m4a"))
        XCTAssertTrue(MessageAttachment(name: "Voice note", path: "/ws/clip.m4a").inferredIsAudio)
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "Voice note", path: "/ws/clip.pdf"))
    }

    func testExplicitImageFlagWinsOverAudioSignals() {
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: true, mime: "audio/mpeg", name: "weird.mp3", path: nil))
    }

    func testDurationFormatting() {
        XCTAssertEqual(AudioDurationFormatter.string(from: 0), "0:00")
        XCTAssertEqual(AudioDurationFormatter.string(from: 5), "0:05")
        XCTAssertEqual(AudioDurationFormatter.string(from: 65), "1:05")
        XCTAssertEqual(AudioDurationFormatter.string(from: 600), "10:00")
        XCTAssertEqual(AudioDurationFormatter.string(from: 3661), "1:01:01")
    }

    func testDurationFormattingClampsInvalidInput() {
        XCTAssertEqual(AudioDurationFormatter.string(from: -5), "0:00")
        XCTAssertEqual(AudioDurationFormatter.string(from: .nan), "0:00")
        XCTAssertEqual(AudioDurationFormatter.string(from: .infinity), "0:00")
    }

    @MainActor
    func testCancelledLoadResetsToIdleForRetry() async {
        let model = InlineAudioPlayerModel()
        let task = Task { @MainActor in
            await model.loadIfNeeded(using: {
                await Task.yield()
                return nil
            })
        }
        task.cancel()
        await task.value
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor
    func testGenuineLoadFailureShowsFailedState() async {
        let model = InlineAudioPlayerModel()
        await model.loadIfNeeded(using: { nil })
        XCTAssertEqual(model.phase, .failed)
    }

    @MainActor
    func testAFailedLoadRetriesOnlyUnderANewKey() async {
        let model = InlineAudioPlayerModel()
        var loads = 0
        await model.loadIfNeeded(key: 1, using: { loads += 1; return nil })
        await model.loadIfNeeded(key: 1, using: { loads += 1; return nil })
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(loads, 1)

        await model.loadIfNeeded(key: 2, using: { loads += 1; return nil })
        XCTAssertEqual(loads, 2)
    }
}
