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
                label: "ask-matt"
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

    func testMayContainReferenceSpotsACandidateWithoutTheCatalog() {
        XCTAssertTrue(ComposerChipTokenizer.mayContainReference("/ask-matt hello"))
        XCTAssertTrue(ComposerChipTokenizer.mayContainReference("please run /x"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference("no references here"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference("docs/ask-matt"))
        XCTAssertFalse(ComposerChipTokenizer.mayContainReference(""))
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
                    source: "/ask-matt",
                    label: "ask-matt",
                    image: UIImage(),
                    baselineOffset: 0
                )
            )
        )
        result.append(NSAttributedString(string: " now"))
        return result
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
