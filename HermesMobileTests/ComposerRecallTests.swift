import UIKit
import XCTest
@testable import HermesMobile

final class ComposerRecallTests: XCTestCase {
    private static let steerOpenLine = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]"
    private static let steerCloseLine = "[/OUT-OF-BAND USER MESSAGE]"

    private func message(_ role: String, _ content: String?, displayKind: String? = nil) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: UUID().uuidString, displayKind: displayKind)
    }

    // MARK: - The rule

    func testTheNewestUserMessageWinsOverLaterAssistantAndToolRows() {
        let messages = [
            message("user", "first question"),
            message("assistant", "first answer"),
            message("user", "check @README.md with /ask-matt"),
            message("assistant", "Looking."),
            message("tool", "{\"ok\":true}"),
            message("assistant", "Done.")
        ]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "check @README.md with /ask-matt")
    }

    func testTheAttachmentMarkerIsStripped() {
        let messages = [message("user", "Summarize it\n\n[Attached files: /tmp/workspace/report.pdf]")]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "Summarize it")
    }

    /// Sessions sends an attachment-only message as the web UI does, with text
    /// that names the files, so it carries nothing the user typed.
    func testAnAttachmentOnlySendIsSkippedForTheTextMessageBeforeIt() {
        let messages = [
            message("user", "the text I typed"),
            message("assistant", "ok"),
            message("user", "I've uploaded 2 file(s): /tmp/workspace/photo.jpg, /tmp/workspace/report.pdf"),
            message("user", "\n\n[Attached files: /tmp/workspace/notes.md]")
        ]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "the text I typed")
    }

    func testASteerIsRecalledWithoutItsWrapper() {
        let wrapped = "\(Self.steerOpenLine)\nfocus on the tests\n\(Self.steerCloseLine)"
        let messages = [
            message("user", "fix the build"),
            message("user", wrapped, displayKind: ChatMessage.steerDisplayKind)
        ]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "focus on the tests")
    }

    /// Bot Chat marks system deliveries (cron output, delegation results) as
    /// user rows with a display kind; the user never typed them.
    func testAUserRowWithANonSteerDisplayKindIsSkipped() {
        let messages = [
            message("user", "what I sent"),
            message("user", "Cron job finished: 3 new emails", displayKind: "cron_delivery")
        ]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "what I sent")
    }

    /// A compaction mid-turn can append a user-role task-list snapshot, or a
    /// user-role summary, after the user's message. The transcript draws both
    /// as cards; the user never typed them.
    func testCompactionMarkerRowsAreSkipped() {
        let messages = [
            message("user", "fix the build"),
            message("assistant", "Working."),
            message("user", "[Your active task list was preserved across context compression]\n- [ ] run the tests"),
            message("user", "[CONTEXT COMPACTION] Earlier turns were summarized."),
            message("assistant", "Still working.")
        ]

        XCTAssertEqual(ComposerRecall.lastSentText(in: messages), "fix the build")
    }

    /// Bot Chat appends one `\n\n` block per attachment to the prompt it sends:
    /// the image routing note, or `file.attach`'s ref to the UUID-prefixed copy.
    func testBotChatAttachmentRefsAreStrippedAndAnAttachmentOnlySendIsSkipped() {
        let image = BotAttachmentUpload.imageReference(path: "/home/hermes/.hermes/images/photo.jpg")
        let messages = [
            message("user", "hello"),
            message("assistant", "Hi."),
            message("user", "\n\n" + image),
            message("user", "@file:/home/hermes/.hermes/attachments/3F2504E0-4F89-41D3-9A0C-0305E82C3301-report.pdf")
        ]
        let typedAndAttached = [message(
            "user",
            "compare these\n\n@file:`attachments/0B6B4C1E-2D7A-4E8F-9C3B-5A1D2E3F4A5B-my notes.md`\n\n" + image
        )]

        XCTAssertEqual(
            ComposerRecall.lastSentText(in: messages, typedText: BotAttachmentUpload.typedText(of:)), "hello"
        )
        XCTAssertEqual(
            ComposerRecall.lastSentText(in: typedAndAttached, typedText: BotAttachmentUpload.typedText(of:)),
            "compare these"
        )
    }

    /// Only the refs the send added go: a `@file:` line the user typed stays.
    func testATypedFileReferenceInBotChatIsKept() {
        let messages = [message("user", "read this\n\n@file:docs/notes.md")]

        XCTAssertEqual(
            ComposerRecall.lastSentText(in: messages, typedText: BotAttachmentUpload.typedText(of:)),
            "read this\n\n@file:docs/notes.md"
        )
    }

    func testNoUserMessageReturnsNil() {
        XCTAssertNil(ComposerRecall.lastSentText(in: []))
        XCTAssertNil(ComposerRecall.lastSentText(in: [message("assistant", "Hi, how can I help?")]))
    }

    // MARK: - The ↑ command

    private func recallCommand(in textView: ComposerChipTextView) -> UIKeyCommand? {
        textView.keyCommands?.first { $0.input == UIKeyCommand.inputUpArrow }
    }

    func testUpArrowIsAnUnmodifiedCommandThatTakesPriorityOverCaretMovement() throws {
        let textView = ComposerChipTextView()
        textView.recallLastSentText = { "last" }

        let command = try XCTUnwrap(recallCommand(in: textView))

        XCTAssertEqual(command.modifierFlags, [])
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        XCTAssertEqual(command.title, "Recall Last Message")
    }

    /// Bot rooms pass no closure, so ↑ is never claimed there.
    func testWithoutARecallSourceUpArrowIsNotClaimed() {
        let textView = ComposerChipTextView()

        XCTAssertNil(recallCommand(in: textView))
    }

    func testRecallIsAvailableOnlyInAnEmptyEditorWithTextToRecall() throws {
        let textView = ComposerChipTextView()
        var recalled: String? = "last"
        textView.recallLastSentText = { recalled }
        let action = try XCTUnwrap(recallCommand(in: textView)?.action)

        XCTAssertTrue(textView.canPerformAction(action, withSender: nil))

        textView.replaceDocument(with: "a")
        XCTAssertFalse(textView.canPerformAction(action, withSender: nil), "Text in the editor: ↑ moves the caret")

        textView.replaceDocument(with: "")
        textView.quotes = [ComposerQuote(text: "quoted")]
        XCTAssertFalse(textView.canPerformAction(action, withSender: nil), "A quote counts as a draft")

        textView.quotes = []
        recalled = nil
        XCTAssertFalse(textView.canPerformAction(action, withSender: nil), "Nothing sent in this chat")
    }

    func testRecallFillsTheEditorWithTheCaretAtTheEnd() throws {
        let textView = ComposerChipTextView()
        textView.recallLastSentText = { "check @README.md" }
        let action = try XCTUnwrap(recallCommand(in: textView)?.action)

        textView.perform(action, with: nil)

        XCTAssertEqual(textView.sourceText, "check @README.md")
        XCTAssertEqual(textView.sourceSelection, NSRange(location: 16, length: 0))
    }

    /// Drawing a recalled chip replaces the document, which clears the undo
    /// stack; the recall has to stay undoable anyway.
    func testUndoEmptiesARecalledDraftThatDrewAChip() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let textView = ComposerChipTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        window.addSubview(textView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        textView.chipFilePaths = ["README.md"]
        textView.recallLastSentText = { "check @README.md " }
        let action = try XCTUnwrap(recallCommand(in: textView)?.action)

        textView.perform(action, with: nil)
        XCTAssertEqual(textView.renderedTokens.map(\.source), ["@README.md"])

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()

        XCTAssertEqual(textView.sourceText, "")
    }
}
