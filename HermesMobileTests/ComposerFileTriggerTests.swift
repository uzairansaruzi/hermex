import XCTest

@testable import HermesMobile

final class ComposerFileTriggerTests: XCTestCase {
    // MARK: - Detection

    func testDetectsTriggerAtStartOfDraft() {
        let trigger = ComposerFileTrigger.detect(in: "@src", selection: caret(4))

        XCTAssertEqual(trigger?.text, "@src")
        XCTAssertEqual(trigger?.query, "src")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 4))
    }

    func testDetectsABareAtWithNothingTypedYet() {
        let trigger = ComposerFileTrigger.detect(in: "@", selection: caret(1))

        XCTAssertEqual(trigger?.text, "@")
        XCTAssertEqual(trigger?.query, "")
    }

    func testDetectsTriggerMidSentence() {
        let trigger = ComposerFileTrigger.detect(in: "please read @src/Chat", selection: caret(21))

        XCTAssertEqual(trigger?.text, "@src/Chat")
        XCTAssertEqual(trigger?.query, "src/Chat")
        XCTAssertEqual(trigger?.range, NSRange(location: 12, length: 9))
    }

    func testDetectsTriggerAfterANewline() {
        let trigger = ComposerFileTrigger.detect(in: "hello\n@README", selection: caret(13))

        XCTAssertEqual(trigger?.text, "@README")
    }

    func testAnEmailAddressIsNotATrigger() {
        XCTAssertNil(ComposerFileTrigger.detect(in: "mail me@example.com", selection: caret(19)))
        XCTAssertNil(ComposerFileTrigger.detect(in: "me@example.com", selection: caret(14)))
    }

    func testTheTriggerEndsAtWhitespace() {
        // The caret has moved past the reference, so there is nothing to complete.
        XCTAssertNil(ComposerFileTrigger.detect(in: "@src/main.swift now", selection: caret(19)))
        XCTAssertNil(ComposerFileTrigger.detect(in: "@src/main.swift ", selection: caret(16)))
    }

    func testTheTriggerStopsAtTheCaretRatherThanTheEndOfTheWord() {
        let trigger = ComposerFileTrigger.detect(in: "@src/main.swift", selection: caret(4))

        XCTAssertEqual(trigger?.text, "@src")
        XCTAssertEqual(trigger?.range, NSRange(location: 0, length: 4))
    }

    func testASelectionIsNeverATrigger() {
        XCTAssertNil(
            ComposerFileTrigger.detect(in: "@src", selection: NSRange(location: 1, length: 3))
        )
    }

    func testADraftWithoutAnAtHasNoTrigger() {
        XCTAssertNil(ComposerFileTrigger.detect(in: "no references here", selection: caret(18)))
        XCTAssertNil(ComposerFileTrigger.detect(in: "", selection: caret(0)))
    }

    // MARK: - Accepting a row

    func testApplyingReplacesOnlyTheTriggerAndLeavesTheCaretAfterIt() throws {
        let draft = "please read @src and stop"
        let trigger = try XCTUnwrap(ComposerFileTrigger.detect(in: draft, selection: caret(16)))
        let completed = trigger.applying("@src/main.swift ", to: draft)

        XCTAssertEqual(completed.draft, "please read @src/main.swift and stop")
        XCTAssertEqual(completed.selection, caret(28))
    }

    func testApplyingCollapsesADoubleSpaceAndStepsOverTheExistingOne() throws {
        let draft = "read @src now"
        let trigger = try XCTUnwrap(ComposerFileTrigger.detect(in: draft, selection: caret(9)))
        let completed = trigger.applying("@README.md ", to: draft)

        XCTAssertEqual(completed.draft, "read @README.md now")
        XCTAssertEqual(completed.selection, caret(16))
    }

    func testApplyingAnEmptyReplacementRemovesTheTrigger() throws {
        let draft = "read @src now"
        let trigger = try XCTUnwrap(ComposerFileTrigger.detect(in: draft, selection: caret(9)))
        let completed = trigger.applying("", to: draft)

        XCTAssertEqual(completed.draft, "read  now")
        XCTAssertEqual(completed.selection, caret(5))
    }

    func testApplyingAFolderKeepsTheCaretInsideTheReference() throws {
        let draft = "@sr"
        let trigger = try XCTUnwrap(ComposerFileTrigger.detect(in: draft, selection: caret(3)))
        let completed = trigger.applying("@src/", to: draft)

        XCTAssertEqual(completed.draft, "@src/")
        XCTAssertEqual(completed.selection, caret(5))
    }

    private func caret(_ location: Int) -> NSRange {
        NSRange(location: location, length: 0)
    }
}
