import UIKit
import XCTest

@testable import HermesMobile

final class ComposerSlashTriggerTests: XCTestCase {
    // MARK: - Detection

    func testDetectsTriggerAtStartOfDraft() {
        let trigger = ComposerSlashTrigger.detect(in: "/mod", selection: caret(4))

        XCTAssertEqual(trigger?.text, "/mod")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 4))
    }

    func testDetectsTriggerMidSentence() {
        let trigger = ComposerSlashTrigger.detect(in: "please run /mod", selection: caret(15))

        XCTAssertEqual(trigger?.text, "/mod")
        XCTAssertEqual(trigger?.range, NSRange(location: 11, length: 4))
    }

    func testTriggerStopsAtTheCaretRatherThanTheEndOfTheDraft() {
        let trigger = ComposerSlashTrigger.detect(in: "/model gpt", selection: caret(3))

        XCTAssertEqual(trigger?.text, "/mo")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 3))
    }

    func testSlashGluedToPrecedingTextIsNotATrigger() {
        XCTAssertNil(ComposerSlashTrigger.detect(in: "hermex/main", selection: caret(11)))
    }

    func testSkipsAGluedSlashAndFindsTheRealTriggerBehindIt() {
        let trigger = ComposerSlashTrigger.detect(in: "/workspace ~/proj", selection: caret(17))

        XCTAssertEqual(trigger?.text, "/workspace ~/proj")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 17))
    }

    func testTriggerNeverCrossesALineBreak() {
        XCTAssertNil(ComposerSlashTrigger.detect(in: "/model\nnow", selection: caret(10)))
    }

    func testProseAfterAnUnknownCommandClosesTheTrigger() {
        XCTAssertNil(ComposerSlashTrigger.detect(in: "check the /tmp folder", selection: caret(21)))
    }

    func testSubArgCommandKeepsTheTriggerOpenAcrossItsSpace() {
        let trigger = ComposerSlashTrigger.detect(in: "/skills rev", selection: caret(11))

        XCTAssertEqual(trigger?.text, "/skills rev")
    }

    func testSelectionWithALengthIsNeverATrigger() {
        XCTAssertNil(
            ComposerSlashTrigger.detect(in: "/model", selection: NSRange(location: 1, length: 3))
        )
    }

    func testCaretPastTheEndOfTheDraftIsNotATrigger() {
        XCTAssertNil(ComposerSlashTrigger.detect(in: "/mod", selection: caret(9)))
    }

    // MARK: - Accepting a row

    func testAcceptingReplacesOnlyTheTriggerAndParksTheCaretAfterIt() {
        let draft = "please run /mod for me"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret(15))

        let completed = trigger?.applying("/model ", to: draft)

        XCTAssertEqual(completed?.draft, "please run /model for me")
        XCTAssertEqual(completed?.selection, caret(18))
    }

    func testAcceptingKeepsTextThatFollowsTheCaret() {
        let draft = "/mo gpt-5"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret(3))

        let completed = trigger?.applying("/model ", to: draft)

        XCTAssertEqual(completed?.draft, "/model gpt-5")
        XCTAssertEqual(completed?.selection, caret(7))
    }

    func testAcceptingAtTheEndOfTheDraftKeepsItsTrailingSpace() {
        let trigger = ComposerSlashTrigger.detect(in: "/mod", selection: caret(4))

        let completed = trigger?.applying("/model ", to: "/mod")

        XCTAssertEqual(completed?.draft, "/model ")
        XCTAssertEqual(completed?.selection, caret(7))
    }

    // MARK: - Minimal edits

    func testNoEditBetweenIdenticalText() {
        XCTAssertNil(ComposerTextEdit.between(current: "/model ", target: "/model "))
    }

    func testEditTouchesOnlyWhatChanged() {
        let edit = ComposerTextEdit.between(current: "please run /mod for me", target: "please run /model for me")

        XCTAssertEqual(edit?.range, NSRange(location: 15, length: 0))
        XCTAssertEqual(edit?.replacement, "el")
    }

    func testEditNeverSplitsASurrogatePair() {
        let edit = ComposerTextEdit.between(current: "hi 👍", target: "hi 👋")

        XCTAssertEqual(edit?.range, NSRange(location: 3, length: 2))
        XCTAssertEqual(edit?.replacement, "👋")
    }

    // MARK: - IME composition (#312)

    func testABindingThatHasNotSeenTheCompositionLeavesItAlone() {
        // The user has started composing 자; the parent still holds the draft as
        // it was before the composition began.
        XCTAssertFalse(
            ComposerMarkedText.isDeliberateReplacement(
                "안녕 ",
                editorText: "안녕 ㅈ",
                marked: NSRange(location: 3, length: 1)
            )
        )
    }

    func testABindingThatMatchesTheEditorLeavesTheCompositionAlone() {
        XCTAssertFalse(
            ComposerMarkedText.isDeliberateReplacement(
                "안녕 ㅈ",
                editorText: "안녕 ㅈ",
                marked: NSRange(location: 3, length: 1)
            )
        )
    }

    func testADeliberateClearStillAppliesDuringComposition() {
        XCTAssertTrue(
            ComposerMarkedText.isDeliberateReplacement(
                "",
                editorText: "안녕 ㅈ",
                marked: NSRange(location: 3, length: 1)
            )
        )
    }

    // MARK: - Undo

    @MainActor
    func testApplyingAnEditThroughTheEditorIsUndoable() throws {
        let textView = UITextView()
        textView.text = "please run /mod for me"

        let edit = try XCTUnwrap(ComposerTextEdit.between(current: textView.text, target: "please run /model for me"))
        let range = try XCTUnwrap(textView.textRange(from: edit.range))
        textView.replace(range, withText: edit.replacement)

        XCTAssertEqual(textView.text, "please run /model for me")
        XCTAssertEqual(textView.selectedRange, caret(17))

        textView.undoManager?.undo()

        XCTAssertEqual(textView.text, "please run /mod for me")
    }

    private func caret(_ location: Int) -> NSRange {
        NSRange(location: location, length: 0)
    }
}
