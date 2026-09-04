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

    func testAnAbsolutePathArgumentBelongsToTheCommandInFrontOfIt() {
        let draft = "/workspace /Users/me/app"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret(24))

        XCTAssertEqual(trigger?.text, draft)
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 24))
    }

    func testTheOutermostTriggerWinsOnlyWhenItHoldsUp() {
        let trigger = ComposerSlashTrigger.detect(in: "notes /rough draft /mod", selection: caret(23))

        XCTAssertEqual(trigger?.text, "/mod")
        XCTAssertEqual(trigger?.range, NSRange(location: 19, length: 4))
    }

    func testTypingPastASubArgumentClosesTheTrigger() {
        XCTAssertNil(
            ComposerSlashTrigger.detect(in: "use /reasoning high for this task", selection: caret(33))
        )
    }

    func testAnEmptySubArgumentKeepsTheTriggerOpen() {
        let trigger = ComposerSlashTrigger.detect(in: "/workspace ", selection: caret(11))

        XCTAssertEqual(trigger?.text, "/workspace ")
    }

    func testAWorkspacePathContainingASpaceKeepsTheTriggerOpen() {
        let draft = "/workspace /Users/me/My App"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret((draft as NSString).length))

        XCTAssertEqual(trigger?.text, draft)
    }

    func testAMultiWordSkillQueryKeepsTheTriggerOpen() {
        let draft = "/skills read files"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret((draft as NSString).length))

        XCTAssertEqual(trigger?.text, draft)
    }

    func testAPersonalityNameContainingASpaceKeepsTheTriggerOpen() {
        let draft = "/personality Terse Reviewer"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret((draft as NSString).length))

        XCTAssertEqual(trigger?.text, draft)
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

    func testAcceptingBeforeALineBreakKeepsTheCompletionsSpace() {
        let draft = "/mod\nnext line"
        let trigger = ComposerSlashTrigger.detect(in: draft, selection: caret(4))

        let completed = trigger?.applying("/model ", to: draft)

        XCTAssertEqual(completed?.draft, "/model \nnext line")
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
                marked: NSRange(location: 3, length: 1),
                isCurrent: false
            )
        )
    }

    func testABindingThatMatchesTheEditorLeavesTheCompositionAlone() {
        XCTAssertFalse(
            ComposerMarkedText.isDeliberateReplacement(
                "안녕 ㅈ",
                editorText: "안녕 ㅈ",
                marked: NSRange(location: 3, length: 1),
                isCurrent: true
            )
        )
    }

    func testADeliberateClearStillAppliesDuringComposition() {
        XCTAssertTrue(
            ComposerMarkedText.isDeliberateReplacement(
                "",
                editorText: "안녕 ㅈ",
                marked: NSRange(location: 3, length: 1),
                isCurrent: true
            )
        )
    }

    func testClearingTheDraftAppliesEvenWhenTheCompositionIsTheWholeDraft() {
        // Sending while the whole draft is one composition: the parent has seen
        // the composition and is emptying the composer on purpose.
        XCTAssertTrue(
            ComposerMarkedText.isDeliberateReplacement(
                "",
                editorText: "\u{3148}",
                marked: NSRange(location: 0, length: 1),
                isCurrent: true
            )
        )
    }

    func testAStaleEmptyBindingNeverErasesAWholeDraftComposition() {
        // The same two strings as the send above, but the parent is still on the
        // empty composer it rendered before the user started composing, so this
        // is an echo rather than a clear.
        XCTAssertFalse(
            ComposerMarkedText.isDeliberateReplacement(
                "",
                editorText: "\u{3148}",
                marked: NSRange(location: 0, length: 1),
                isCurrent: false
            )
        )
    }

    func testADeliberateCaretMoveKeepsThePublishGeneration() {
        let published = ComposerSelection(range: NSRange(location: 3, length: 0), publishGeneration: 7)

        XCTAssertEqual(published.moved(to: NSRange(location: 5, length: 0)).publishGeneration, 7)
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
