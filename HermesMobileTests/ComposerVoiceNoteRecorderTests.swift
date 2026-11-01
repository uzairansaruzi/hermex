import AVFoundation
import XCTest
@testable import HermesMobile

final class ComposerVoiceNoteRecorderTests: XCTestCase {
    // MARK: - Filename

    func testGenerateFilenameIsM4AVoiceNote() {
        let uuid = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let name = VoiceNoteFilename.generate(uuid: uuid)

        XCTAssertTrue(name.hasPrefix("voice-note-"))
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertEqual(name, "voice-note-abcdef01.m4a")
        XCTAssertTrue(VoiceNoteFilename.isVoiceNote(name))
    }

    func testIsVoiceNoteRejectsOtherFiles() {
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("photo.jpg"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("voice-note-123.wav"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("note.m4a"))
    }

    // MARK: - Gesture

    func testCancelArmsOnlyWhenSlidUpPastThreshold() {
        let threshold = ComposerVoiceNoteGesture.cancelTranslationThreshold

        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: 0))
        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -10))
        // Sliding down (positive height) never cancels.
        XCTAssertFalse(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: 200))
        XCTAssertTrue(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -threshold))
        XCTAssertTrue(ComposerVoiceNoteGesture.isCancelArmed(dragTranslationHeight: -200))
    }

    // MARK: - Policy
}
