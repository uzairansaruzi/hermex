import UIKit
import XCTest

@testable import HermesMobile

final class ComposerChipTokenizerTests: XCTestCase {
    private let catalog = ComposerChipCatalog(skills: [
        SkillSlashSuggestion(name: "ask-matt", category: nil, description: nil),
        SkillSlashSuggestion(name: "babysit-pr", category: nil, description: nil)
    ])

    func testReferenceFollowedByASpaceBecomesAChip() {
        let tokens = ComposerChipTokenizer.tokens(in: "/ask-matt what now", catalog: catalog)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.range, NSRange(location: 0, length: 9))
        XCTAssertEqual(tokens.first?.source, "/ask-matt")
        XCTAssertEqual(tokens.first?.label, "ask-matt")
    }

    func testHalfTypedReferenceStaysPlainText() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "/ask-ma", catalog: catalog).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "/ask-matt", catalog: catalog).isEmpty)
    }

    func testUnknownSlugStaysPlainText() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "/unknown-skill hello", catalog: catalog).isEmpty)
    }

    func testBuiltInCommandIsNeverAChip() {
        let catalog = ComposerChipCatalog(skills: [
            SkillSlashSuggestion(name: "model", category: nil, description: nil)
        ])

        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "/model gpt-5 ", catalog: catalog).isEmpty)
    }

    func testReferenceGluedToPrecedingTextIsNotAChip() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "docs/ask-matt now", catalog: catalog).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "~/proj/ask-matt now", catalog: catalog).isEmpty)
    }

    func testFindsEveryReferenceInTheDraft() {
        let tokens = ComposerChipTokenizer.tokens(
            in: "run /ask-matt then /babysit-pr please",
            catalog: catalog
        )

        XCTAssertEqual(tokens.map(\.source), ["/ask-matt", "/babysit-pr"])
        XCTAssertEqual(tokens.first?.range, NSRange(location: 4, length: 9))
        XCTAssertEqual(tokens.last?.range, NSRange(location: 19, length: 11))
    }

    func testNewlineClosesAReference() {
        let tokens = ComposerChipTokenizer.tokens(in: "/ask-matt\nwhat now", catalog: catalog)

        XCTAssertEqual(tokens.map(\.source), ["/ask-matt"])
    }

    func testTrailingChipSurvivesDeletingTheSpaceAfterIt() {
        let confirmed = ComposerChipTokenizer.tokens(in: "/ask-matt ", catalog: catalog)
        XCTAssertEqual(confirmed.map(\.source), ["/ask-matt"])

        let afterBackspace = ComposerChipTokenizer.tokens(
            in: "/ask-matt",
            catalog: catalog,
            preservingTrailing: confirmed
        )
        XCTAssertEqual(afterBackspace.map(\.source), ["/ask-matt"])
    }

    func testPreservationOnlyAppliesToTheEndOfTheDraft() {
        let confirmed = [
            ComposerChipToken(
                range: NSRange(location: 0, length: 9),
                source: "/ask-matt",
                label: "ask-matt",
                kind: .skill
            )
        ]

        let tokens = ComposerChipTokenizer.tokens(
            in: "/ask-mattress",
            catalog: catalog,
            preservingTrailing: confirmed
        )
        XCTAssertTrue(tokens.isEmpty)
    }

    func testAnEmptyCatalogDrawsNothing() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "/ask-matt hi", catalog: .empty).isEmpty)
    }

    func testFileReferenceCandidatesSkipTheOneStillBeingTyped() {
        XCTAssertEqual(
            ComposerChipTokenizer.fileReferenceCandidates(in: "read @a/b.md and @c.md now"),
            ["a/b.md", "c.md"]
        )
        XCTAssertEqual(ComposerChipTokenizer.fileReferenceCandidates(in: "read @a/b"), [])
        XCTAssertEqual(
            ComposerChipTokenizer.fileReferenceCandidates(in: "read @a/b", isComplete: true),
            ["a/b"]
        )
    }

    func testFileReferenceCandidatesIgnoreAnEmailAddressAndRepeats() {
        XCTAssertEqual(ComposerChipTokenizer.fileReferenceCandidates(in: "me@example.com now"), [])
        XCTAssertEqual(
            ComposerChipTokenizer.fileReferenceCandidates(in: "@a.md and @a.md again"),
            ["a.md"]
        )
    }

    /// A candidate ends at whitespace by construction, so a path holding a space
    /// can never be produced as one — which is why the panel does not offer such
    /// a path in the first place.
    func testAPathWithASpaceIsNeverOneCandidate() {
        let candidates = ComposerChipTokenizer.fileReferenceCandidates(
            in: "open @src/My File.swift now",
            isComplete: true
        )

        XCTAssertEqual(candidates, ["src/My"])
        XCTAssertFalse(candidates.contains { $0.contains(where: \.isWhitespace) })
        XCTAssertTrue(
            ComposerChipTokenizer.tokens(
                in: "open @src/My File.swift now",
                catalog: ComposerChipCatalog(skills: [], filePaths: ["src/My File.swift"])
            ).isEmpty
        )
    }

    func testMayContainReferenceSpotsACandidateWithoutTheCatalog() {
        XCTAssertTrue(ComposerChipTokenizer.mayContainReference("/ask-matt hello"))
        XCTAssertTrue(ComposerChipTokenizer.mayContainReference("please run /x"))
        XCTAssertTrue(ComposerChipTokenizer.mayContainReference("open @src/main.swift"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference("no references here"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference("docs/ask-matt"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference("mail me at me@example.com"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference(""))
    }
}

extension ComposerChipTokenizerTests {
    // MARK: - Workspace file references

    private var fileCatalog: ComposerChipCatalog {
        ComposerChipCatalog(
            skills: [SkillSlashSuggestion(name: "ask-matt", category: nil, description: nil)],
            filePaths: ["src/Chat/ChatView.swift", "README.md"]
        )
    }

    func testFileReferenceInTheCatalogBecomesAChipLabelledByItsFilename() {
        let tokens = ComposerChipTokenizer.tokens(in: "read @src/Chat/ChatView.swift now", catalog: fileCatalog)

        XCTAssertEqual(tokens.map(\.source), ["@src/Chat/ChatView.swift"])
        XCTAssertEqual(tokens.first?.label, "ChatView.swift")
        XCTAssertEqual(tokens.first?.kind, .file)
        XCTAssertEqual(tokens.first?.filePath, "src/Chat/ChatView.swift")
        XCTAssertEqual(tokens.first?.range, NSRange(location: 5, length: 24))
    }

    func testFilePathOutsideTheCatalogStaysPlainText() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@src/Other.swift now", catalog: fileCatalog).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@README.md here", catalog: .empty).isEmpty)
    }

    func testHalfTypedFilePathStaysPlainText() {
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@src/Chat/ChatVie", catalog: fileCatalog).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@README.md", catalog: fileCatalog).isEmpty)
    }

    func testAnEmailAddressIsNeverAFileChip() {
        let catalog = ComposerChipCatalog(skills: [], filePaths: ["example.com"])

        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "mail me@example.com now", catalog: catalog).isEmpty)
    }

    func testSkillAndFileReferencesCoexistInOneDraft() {
        let draft = "/ask-matt about @README.md please"
        let tokens = ComposerChipTokenizer.tokens(in: draft, catalog: fileCatalog)

        XCTAssertEqual(tokens.map(\.source), ["/ask-matt", "@README.md"])
        XCTAssertEqual(tokens.map(\.kind), [.skill, .file])
        XCTAssertEqual(
            ComposerChipTokenizer.spokenText(in: draft, tokens: tokens),
            "ask-matt about README.md please"
        )
    }

    func testSentMessageEndingInAFileReferenceDrawsAChip() {
        let tokens = ComposerChipTokenizer.tokens(
            in: "look at @README.md",
            catalog: fileCatalog,
            isComplete: true
        )

        XCTAssertEqual(tokens.map(\.source), ["@README.md"])
    }

    func testAFileChipDrawsItsOwnFileTypeGlyph() {
        let tokens = ComposerChipTokenizer.tokens(in: "@src/Chat/ChatView.swift ", catalog: fileCatalog)

        XCTAssertEqual(tokens.first?.icon, .asset(FileIcon.swift.assetName))
        XCTAssertEqual(
            ComposerChipTokenizer.tokens(in: "/ask-matt ", catalog: fileCatalog).first?.icon,
            .symbol("hammer")
        )
    }
}

extension ComposerChipTokenizerTests {
    // MARK: - Sent messages (the transcript bubble, issue #388)

    func testSentMessageEndingInAReferenceDrawsAChip() {
        let tokens = ComposerChipTokenizer.tokens(in: "please run /ask-matt", catalog: catalog, isComplete: true)

        XCTAssertEqual(tokens.map(\.source), ["/ask-matt"])
        XCTAssertEqual(tokens.first?.range, NSRange(location: 11, length: 9))
    }

    func testSentMessageStillNeedsAKnownSlug() {
        XCTAssertTrue(
            ComposerChipTokenizer.tokens(in: "please run /ask-mat", catalog: catalog, isComplete: true).isEmpty
        )
        XCTAssertTrue(
            ComposerChipTokenizer.tokens(in: "please run /ask-matt", catalog: .empty, isComplete: true).isEmpty
        )
    }

    func testSentMessageKeepsTheMidSentenceRules() {
        XCTAssertTrue(
            ComposerChipTokenizer.tokens(in: "see docs/ask-matt", catalog: catalog, isComplete: true).isEmpty
        )
    }

    // MARK: - Drawing the line (shared by the collapsed pill and the bubble)

    func testStaleChipsAreDroppedRatherThanDrawnInTheWrongPlace() {
        let tokens = ComposerChipTokenizer.tokens(in: "/ask-matt now", catalog: catalog)

        XCTAssertEqual(ComposerChipTextLine.validTokens(tokens, in: "/ask-matt now"), tokens)
        XCTAssertTrue(ComposerChipTextLine.validTokens(tokens, in: "hi").isEmpty)
        XCTAssertTrue(ComposerChipTextLine.validTokens(tokens, in: "/babysit-pr now").isEmpty)
    }
}

extension ComposerChipTokenizerTests {
    // MARK: - Spoken form (the collapsed composer's VoiceOver label)

    func testSpokenTextReadsChipsByTheirLabel() {
        let draft = "Hello /ask-matt test"
        let tokens = ComposerChipTokenizer.tokens(in: draft, catalog: catalog)

        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(ComposerChipTokenizer.spokenText(in: draft, tokens: tokens), "Hello ask-matt test")
    }

    func testSpokenTextLeavesADraftWithoutChipsAlone() {
        XCTAssertEqual(
            ComposerChipTokenizer.spokenText(in: "check the /tmp folder", tokens: []),
            "check the /tmp folder"
        )
    }

    func testSpokenTextKeepsTextOnBothSidesOfEveryChip() {
        let draft = "/ask-matt then /babysit-pr now"
        let tokens = ComposerChipTokenizer.tokens(in: draft, catalog: catalog)

        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(
            ComposerChipTokenizer.spokenText(in: draft, tokens: tokens),
            "ask-matt then babysit-pr now"
        )
    }
}

final class ComposerChipDocumentTests: XCTestCase {
    /// `run [/ask-matt] now`: 4 characters, one chip, 4 characters.
    private func document() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "run ")
        result.append(
            NSAttributedString(
                attachment: ComposerChipAttachment(
                    token: ComposerChipToken(
                        range: NSRange(location: 4, length: 9),
                        source: "/ask-matt",
                        label: "ask-matt",
                        kind: .skill
                    ),
                    image: UIImage(),
                    baselineOffset: 0
                )
            )
        )
        result.append(NSAttributedString(string: " now"))
        return result
    }

    /// The draft is what gets sent, saved, and copied, so an attachment this
    /// composer did not make contributes nothing at all — not the U+FFFC glyph
    /// standing in for it, and so nothing that a later reader could take for
    /// markup. Anything else travels to the server as a character the user
    /// never typed.
    func testAForeignAttachmentContributesNothingToTheDraft() {
        let document = NSMutableAttributedString(string: "read ")
        document.append(NSAttributedString(attachment: NSTextAttachment(image: UIImage())))
        document.append(NSAttributedString(string: " @a/b.md "))

        let source = document.composerSourceText

        XCTAssertEqual(source, "read  @a/b.md ")
        XCTAssertFalse(source.contains("\u{FFFC}"))
        XCTAssertFalse(source.contains("]("))
        XCTAssertFalse(source.contains("%3C"))
    }

    /// The caret mapping has to agree with the text: a glyph worth no draft
    /// characters must not be counted as one either.
    func testAForeignAttachmentIsWorthNoDraftOffsets() {
        let document = NSMutableAttributedString(string: "ab")
        document.append(NSAttributedString(attachment: NSTextAttachment(image: UIImage())))
        document.append(NSAttributedString(string: "cd"))

        XCTAssertEqual(document.composerSourceText, "abcd")
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 5), 4)
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 3), 2)
    }

    func testSerializesChipsBackToTheirSource() {
        XCTAssertEqual(document().composerSourceText, "run /ask-matt now")
    }

    func testSerializesOnlyTheSelectedRange() {
        // The chip plus the space after it.
        XCTAssertEqual(
            document().composerSourceText(in: NSRange(location: 4, length: 2)),
            "/ask-matt "
        )
        XCTAssertEqual(document().composerSourceText(in: NSRange(location: 0, length: 0)), "")
    }

    func testMapsDisplayOffsetsOntoTheDraft() {
        let document = document()

        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 0), 0)
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 4), 4)
        // Just after the chip.
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 5), 13)
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 9), 17)
    }

    func testMapsDraftOffsetsOntoTheDisplay() {
        let document = document()

        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 0), 0)
        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 4), 4)
        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 13), 5)
        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 17), 9)
    }

    func testAnOffsetInsideAChipResolvesToJustAfterIt() {
        XCTAssertEqual(document().composerDisplayOffset(forSourceOffset: 8), 5)
    }

    func testRangesRoundTripThroughBothCoordinateSpaces() {
        let document = document()
        let source = NSRange(location: 4, length: 10)

        let display = document.composerDisplayRange(forSourceRange: source)
        XCTAssertEqual(display, NSRange(location: 4, length: 2))
        XCTAssertEqual(document.composerSourceRange(forDisplayRange: display), source)
    }

    func testAnOffsetPastTheEndClampsToTheEnd() {
        let document = document()

        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 99), 17)
        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 99), 9)
    }

    func testQuoteMetadataIsExcludedAndTheDraftStartsAfterItsPrefix() {
        let quote = ComposerQuote(text: "Selected passage")
        let document = NSMutableAttributedString(
            attachment: ComposerQuoteAttachment(quote: quote, image: UIImage(), baselineOffset: 0)
        )
        document.append(NSAttributedString(
            string: " ",
            attributes: [.composerQuoteSpacer: true]
        ))
        document.append(NSAttributedString(string: "/ask-matt next"))

        XCTAssertEqual(document.composerSourceText, "/ask-matt next")
        XCTAssertEqual(document.composerSourceOffset(forDisplayOffset: 2), 0)
        XCTAssertEqual(document.composerDisplayOffset(forSourceOffset: 0), 2)
        XCTAssertEqual(
            document.composerDisplayRange(forSourceRange: NSRange(location: 0, length: 9)),
            NSRange(location: 2, length: 9)
        )
    }
}

final class ComposerQuoteTests: XCTestCase {
    func testFormatterPreservesFullPassagesAndOrderAsMarkdownBlockquotes() {
        let quotes = [
            ComposerQuote(text: "First line\n\nThird line"),
            ComposerQuote(text: "Repeated"),
            ComposerQuote(text: "Repeated")
        ]

        XCTAssertEqual(
            ComposerQuoteMessageFormatter.message(text: "What does this mean?", quotes: quotes),
            "> First line\n>\n> Third line\n\n> Repeated\n\n> Repeated\n\nWhat does this mean?"
        )
    }

    func testFormatterAllowsAQuoteOnlyMessage() {
        XCTAssertEqual(
            ComposerQuoteMessageFormatter.message(
                text: "",
                quotes: [ComposerQuote(text: "Keep trailing space ")]
            ),
            "> Keep trailing space "
        )
    }

    func testPreviewTruncationDoesNotChangeStoredText() {
        let text = "One\n\n" + String(repeating: "long passage ", count: 20)
        let quote = ComposerQuote(text: text)

        XCTAssertFalse(quote.preview.contains("\n"))
        XCTAssertTrue(quote.preview.hasSuffix("…"))
        XCTAssertEqual(quote.text, text)
    }

    func testTypedMarkdownDoesNotCreateQuoteMetadata() {
        let content = ComposerDraftContent(text: "> ordinary pasted quote", quotes: [])

        XCTAssertTrue(content.quotes.isEmpty)
        XCTAssertEqual(
            ComposerQuoteMessageFormatter.message(text: content.text, quotes: content.quotes),
            "> ordinary pasted quote"
        )
    }
}

@MainActor
final class ComposerChipGestureTests: XCTestCase {
    private final class TouchStub: UITouch {
        private let point: CGPoint

        init(point: CGPoint) {
            self.point = point
            super.init()
        }

        override func location(in view: UIView?) -> CGPoint {
            point
        }
    }

    private let skills = [
        SkillSlashSuggestion(name: "ask-matt", category: nil, description: nil),
        SkillSlashSuggestion(name: "babysit-pr", category: nil, description: nil)
    ]

    func testPlainTextDoesNotParticipateInChipRecognition() throws {
        let textView = makeTextView(text: "ordinary editable text")
        let recognizer = try chipRecognizer(in: textView)
        let textRange = try XCTUnwrap(textView.textRange(from: NSRange(location: 2, length: 1)))
        let textPoint = center(of: textView.firstRect(for: textRange))

        XCTAssertTrue(textView.renderedTokens.isEmpty)
        XCTAssertFalse(textView.gestureRecognizer(recognizer, shouldReceive: TouchStub(point: textPoint)))
    }

    func testOnlyTheChipGlyphParticipatesInChipRecognition() throws {
        let textView = makeTextView(text: "/ask-matt editable text")
        let recognizer = try chipRecognizer(in: textView)
        let chip = try XCTUnwrap(chipRanges(in: textView).first)

        XCTAssertTrue(
            textView.gestureRecognizer(recognizer, shouldReceive: TouchStub(point: center(of: chip.rect)))
        )

        let spaceRange = try XCTUnwrap(textView.textRange(from: NSRange(location: chip.range.upperBound, length: 1)))
        XCTAssertFalse(
            textView.gestureRecognizer(
                recognizer,
                shouldReceive: TouchStub(point: center(of: textView.firstRect(for: spaceRange)))
            )
        )
    }

    func testMultipleWrappedChipsUseTheirOwnGlyphBounds() throws {
        let textView = makeTextView(
            width: 190,
            text: "/ask-matt some text that wraps onto another line before /babysit-pr trailing text"
        )
        let recognizer = try chipRecognizer(in: textView)
        let chips = chipRanges(in: textView)

        XCTAssertEqual(chips.count, 2)
        XCTAssertNotEqual(chips[0].rect.minY, chips[1].rect.minY)
        XCTAssertTrue(
            textView.gestureRecognizer(recognizer, shouldReceive: TouchStub(point: center(of: chips[0].rect)))
        )
        XCTAssertTrue(
            textView.gestureRecognizer(recognizer, shouldReceive: TouchStub(point: center(of: chips[1].rect)))
        )

        let betweenRange = try XCTUnwrap(textView.textRange(from: NSRange(location: 2, length: 1)))
        XCTAssertFalse(
            textView.gestureRecognizer(
                recognizer,
                shouldReceive: TouchStub(point: center(of: textView.firstRect(for: betweenRange)))
            )
        )
    }

    func testChipRecognizerAllowsUIKitEditingRecognizersAlongsideIt() throws {
        let textView = makeTextView(text: "/ask-matt editable text")
        let recognizer = try chipRecognizer(in: textView)
        let editingRecognizer = UITapGestureRecognizer()

        XCTAssertTrue(recognizer.delegate === textView)
        XCTAssertTrue(
            textView.gestureRecognizer(
                recognizer,
                shouldRecognizeSimultaneouslyWith: editingRecognizer
            )
        )
    }

    func testRemovingAMiddleQuoteKeepsOrderedMetadataAndSourceBackedChipsStable() {
        let first = ComposerQuote(text: "Repeated passage")
        let middle = ComposerQuote(text: "Middle passage")
        let last = ComposerQuote(text: "Repeated passage")
        let source = "/ask-matt @Docs/Guide.md typed text"
        let caret = NSRange(location: (source as NSString).length, length: 0)
        let textView = makeTextView(
            text: source,
            quotes: [first, middle, last],
            filePaths: ["Docs/Guide.md"]
        )
        textView.sourceSelection = caret
        let displayOffsetBeforeRemoval = textView.selectedRange.location

        textView.quotes.removeAll { $0.id == middle.id }
        textView.refreshChipsIfNeeded()

        XCTAssertEqual(textView.renderedQuotes.map(\.id), [first.id, last.id])
        XCTAssertNotEqual(first.id, last.id)
        XCTAssertEqual(quoteIDs(in: textView), [first.id, last.id])
        XCTAssertEqual(textView.renderedTokens.map(\.source), ["/ask-matt", "@Docs/Guide.md"])
        XCTAssertEqual(textView.sourceText, source)
        XCTAssertEqual(textView.sourceSelection, caret)
        XCTAssertEqual(textView.selectedRange.location, displayOffsetBeforeRemoval - 2)
    }

    func testBackspaceAtDraftStartRemovesOnlyTheLastQuote() {
        let first = ComposerQuote(text: "First passage")
        let last = ComposerQuote(text: "Last passage")
        let source = "typed content"
        let textView = makeTextView(text: source, quotes: [first, last])
        textView.sourceSelection = NSRange(location: 0, length: 0)
        var removedIDs: [UUID] = []
        textView.onRemoveQuote = { id in
            removedIDs.append(id)
            textView.quotes.removeAll { $0.id == id }
            textView.refreshChipsIfNeeded()
        }

        textView.deleteBackward()

        XCTAssertEqual(removedIDs, [last.id])
        XCTAssertEqual(textView.renderedQuotes.map(\.id), [first.id])
        XCTAssertEqual(textView.sourceText, source)
        XCTAssertEqual(textView.sourceSelection, NSRange(location: 0, length: 0))
    }

    private func makeTextView(
        width: CGFloat = 320,
        text: String,
        quotes: [ComposerQuote] = [],
        filePaths: Set<String> = []
    ) -> ComposerChipTextView {
        let textView = ComposerChipTextView(frame: CGRect(x: 0, y: 0, width: width, height: 240))
        textView.font = .preferredFont(forTextStyle: .body)
        textView.chipSkills = skills
        textView.chipFilePaths = filePaths
        textView.quotes = quotes
        textView.replaceDocument(with: text)
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        return textView
    }

    private func chipRecognizer(in textView: ComposerChipTextView) throws -> UITapGestureRecognizer {
        try XCTUnwrap(
            textView.gestureRecognizers?
                .compactMap { $0 as? UITapGestureRecognizer }
                .first { $0.delegate === textView }
        )
    }

    private func chipRanges(in textView: ComposerChipTextView) -> [(range: NSRange, rect: CGRect)] {
        var chips: [(range: NSRange, rect: CGRect)] = []
        textView.textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textView.textStorage.length)
        ) { attachment, range, _ in
            guard attachment is ComposerChipAttachment,
                  let textRange = textView.textRange(from: range)
            else {
                return
            }
            chips.append((range, textView.firstRect(for: textRange)))
        }
        return chips
    }

    private func quoteIDs(in textView: ComposerChipTextView) -> [UUID] {
        var ids: [UUID] = []
        textView.textStorage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: textView.textStorage.length)
        ) { attachment, _, _ in
            if let quote = attachment as? ComposerQuoteAttachment {
                ids.append(quote.quote.id)
            }
        }
        return ids
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}

final class ComposerDropRouteTests: XCTestCase {
    func testRoutesAMixOfFilesAndImages() throws {
        let route = try XCTUnwrap(
            ComposerDropRoute(providers: [fileProvider(), imageProvider(), fileProvider()])
        )

        XCTAssertEqual(route.files.count, 2)
        XCTAssertEqual(route.images.count, 1)
    }

    func testRoutesAnImageOnlyDrop() throws {
        let route = try XCTUnwrap(ComposerDropRoute(providers: [imageProvider()]))

        XCTAssertTrue(route.files.isEmpty)
        XCTAssertEqual(route.images.count, 1)
    }

    func testLeavesADropWithAnythingUnroutableToUIKit() {
        XCTAssertNil(ComposerDropRoute(providers: [imageProvider(), NSItemProvider(object: "hello" as NSString)]))
        XCTAssertNil(ComposerDropRoute(providers: []))
    }

    private func imageProvider() -> NSItemProvider {
        NSItemProvider(object: UIImage(systemName: "star") ?? UIImage())
    }

    private func fileProvider() -> NSItemProvider {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("hi".utf8))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
