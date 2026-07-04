import XCTest
@testable import HermesMobile

final class AttachmentAudioDetectionTests: XCTestCase {

    // MARK: - MIME detection

    func testMimeAudioPrefixIsAudio() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: "audio/mpeg", name: nil, path: nil))
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: "AUDIO/WEBM", name: "voice", path: nil))
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: false, mime: "audio/mp4", name: "clip.bin", path: nil))
    }

    func testNonAudioMimeIsNotAudio() {
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: "image/png", name: "pic.png", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: "text/plain", name: "notes.txt", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: "application/pdf", name: "doc.pdf", path: nil))
    }

    // MARK: - Extension detection

    func testKnownAudioExtensionsAreAudio() {
        for ext in ["m4a", "mp3", "wav", "aac", "caf", "ogg", "oga", "opus", "flac", "webm", "weba"] {
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

    func testExtensionDetectionWorksOnFullPaths() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "/workspace/voice/note.m4a", path: nil))
    }

    func testUnknownExtensionIsNotAudio() {
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "archive.zip", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "image.png", path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "noextension", path: nil))
    }

    /// A human display name carries no extension, but the path does — detection
    /// should fall back to the path instead of giving up on the name alone.
    func testDisplayNameWithoutExtensionFallsBackToPath() {
        XCTAssertTrue(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "Voice note", path: "/ws/clip.m4a"))
        XCTAssertTrue(MessageAttachment(name: "Voice note", path: "/ws/clip.m4a").inferredIsAudio)
        // But a non-audio path is still not audio.
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "Voice note", path: "/ws/clip.pdf"))
    }

    // MARK: - isImage precedence

    func testExplicitImageFlagWinsOverAudioSignals() {
        // Contradictory inputs: the explicit server image flag always wins.
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: true, mime: "audio/mpeg", name: "weird.mp3", path: nil))
    }

    func testNilAndEmptyInputsAreNotAudio() {
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: nil, path: nil))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: nil, name: "", path: ""))
        XCTAssertFalse(AttachmentAudioDetection.isAudio(isImage: nil, mime: "", name: "", path: ""))
    }

    // MARK: - MessageAttachment convenience

    func testMessageAttachmentInferredIsAudio() {
        XCTAssertTrue(MessageAttachment(name: "note.m4a").inferredIsAudio)
        XCTAssertTrue(MessageAttachment(name: nil, path: "/ws/voice.mp3").inferredIsAudio)
        XCTAssertTrue(MessageAttachment(name: "blob", mime: "audio/ogg").inferredIsAudio)
        XCTAssertFalse(MessageAttachment(name: "photo.png", isImage: true).inferredIsAudio)
        XCTAssertFalse(MessageAttachment(name: "data.json").inferredIsAudio)
    }

    // MARK: - Duration formatting

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

    // MARK: - Inline player load state

    /// When the row scrolls off-screen mid-load the `.task` is cancelled and the
    /// loader returns nil; the player must reset to `.idle` (retryable) rather
    /// than getting stuck on the `.failed` error state.
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

    /// A genuine load failure (not cancellation) still surfaces the error state.
    @MainActor
    func testGenuineLoadFailureShowsFailedState() async {
        let model = InlineAudioPlayerModel()
        await model.loadIfNeeded(using: { nil })
        XCTAssertEqual(model.phase, .failed)
    }
}
