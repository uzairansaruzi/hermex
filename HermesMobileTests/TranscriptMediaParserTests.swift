import XCTest
@testable import HermesMobile

final class TranscriptMediaParserTests: XCTestCase {
    func testParsesLocalPathToken() {
        let segments = TranscriptMediaParser.segments(
            in: "Screenshot: MEDIA:/Users/hermes/.hermes/browser_screenshots/example.png loaded"
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text("Screenshot: "))
        XCTAssertEqual(
            segments[1],
            .media(.init(rawReference: "/Users/hermes/.hermes/browser_screenshots/example.png"))
        )
        XCTAssertEqual(segments[2], .text(" loaded"))
    }

    func testParsesHTTPSURLToken() throws {
        let segments = TranscriptMediaParser.segments(
            in: "Generated MEDIA:https://cdn.example.test/output/image.png?variant=small"
        )

        let media = try XCTUnwrap(mediaReferences(in: segments).first)
        XCTAssertEqual(media.rawReference, "https://cdn.example.test/output/image.png?variant=small")
        XCTAssertEqual(media.source, .remoteURL(try XCTUnwrap(URL(string: media.rawReference))))
        XCTAssertTrue(media.isRasterImageCandidate)
    }

    func testKeepsSentencePunctuationOutsideToken() {
        let segments = TranscriptMediaParser.segments(
            in: "Open MEDIA:/tmp/result.png, then MEDIA:/tmp/second.webp."
        )

        XCTAssertEqual(
            segments,
            [
                .text("Open "),
                .media(.init(rawReference: "/tmp/result.png")),
                .text(", then "),
                .media(.init(rawReference: "/tmp/second.webp")),
                .text(".")
            ]
        )
    }

    func testStopsAtMarkdownLinkAndParenBoundaries() {
        let segments = TranscriptMediaParser.segments(
            in: "[view](MEDIA:/tmp/result.png) and [MEDIA:/tmp/other.jpg]"
        )

        XCTAssertEqual(
            segments,
            [
                .text("[view]("),
                .media(.init(rawReference: "/tmp/result.png")),
                .text(") and ["),
                .media(.init(rawReference: "/tmp/other.jpg")),
                .text("]")
            ]
        )
    }

    func testKeepsClosingMarkdownEmphasisOutsideToken() {
        let segments = TranscriptMediaParser.segments(
            in: "**MEDIA:/tmp/agyloop-plan.md** and _MEDIA:/tmp/trade_journal.csv_"
        )

        XCTAssertEqual(
            segments,
            [
                .text("**"),
                .media(.init(rawReference: "/tmp/agyloop-plan.md")),
                .text("** and _"),
                .media(.init(rawReference: "/tmp/trade_journal.csv")),
                .text("_")
            ]
        )
    }

    func testParsesMultipleTokens() {
        let segments = TranscriptMediaParser.segments(
            in: "A MEDIA:/tmp/a.png\nB MEDIA:/tmp/b.jpg"
        )

        XCTAssertEqual(
            mediaReferences(in: segments).map(\.rawReference),
            ["/tmp/a.png", "/tmp/b.jpg"]
        )
    }

    func testFencedCodeKeepsLiteralMediaText() {
        let markdown = """
        Before
        ```swift
        let path = "MEDIA:/tmp/inside.png"
        ```
        After MEDIA:/tmp/outside.png
        """

        let segments = TranscriptMediaParser.segments(in: markdown)

        XCTAssertEqual(mediaReferences(in: segments).map(\.rawReference), ["/tmp/outside.png"])
        XCTAssertTrue(textSegments(in: segments).joined().contains("MEDIA:/tmp/inside.png"))
    }

    func testParsesBareFileURLsAtLineStartOrAfterWhitespace() {
        let segments = TranscriptMediaParser.segments(
            in: "file:///tmp/report.csv ready\nImage file:///tmp/chart.png."
        )

        XCTAssertEqual(
            segments,
            [
                .media(.init(rawReference: "/tmp/report.csv")),
                .text(" ready\nImage "),
                .media(.init(rawReference: "/tmp/chart.png")),
                .text(".")
            ]
        )
    }

    func testBareFileURLDecodesPercentEscapedPathComponents() {
        let segments = TranscriptMediaParser.segments(
            in: "Created file:///Users/hermes/workspace/Q3%20report%20%28final%29.csv"
        )

        XCTAssertEqual(
            mediaReferences(in: segments).map(\.rawReference),
            ["/Users/hermes/workspace/Q3 report (final).csv"]
        )
    }

    func testBareFileURLKeepsSurroundingProseAndPunctuation() {
        let segments = TranscriptMediaParser.segments(
            in: "Created file:///tmp/report.csv, then shared file:///tmp/chart.webp!"
        )

        XCTAssertEqual(
            segments,
            [
                .text("Created "),
                .media(.init(rawReference: "/tmp/report.csv")),
                .text(", then shared "),
                .media(.init(rawReference: "/tmp/chart.webp")),
                .text("!")
            ]
        )
    }

    func testBareFileURLRequiresWhitespaceOrLineStart() {
        let markdown = "prefixfile:///tmp/hidden.txt and [report](file:///tmp/report.csv)"
        let segments = TranscriptMediaParser.segments(in: markdown)

        XCTAssertEqual(segments, [.text(markdown)])
    }

    func testBareFileURLInsideInlineOrFencedCodeStaysLiteral() {
        let markdown = """
        Before `open file:///tmp/inline.csv` after file:///tmp/outside.csv
        ```text
        file:///tmp/fenced.png
        ```
        """

        let segments = TranscriptMediaParser.segments(in: markdown)

        XCTAssertEqual(mediaReferences(in: segments).map(\.rawReference), ["/tmp/outside.csv"])
        let text = textSegments(in: segments).joined()
        XCTAssertTrue(text.contains("file:///tmp/inline.csv"))
        XCTAssertTrue(text.contains("file:///tmp/fenced.png"))
    }

    func testBareFileURLUsesExistingMediaKindClassification() {
        let segments = TranscriptMediaParser.segments(
            in: "file:///tmp/image.png file:///tmp/audio.m4a file:///tmp/video.mp4 file:///tmp/data.zip"
        )

        XCTAssertEqual(
            mediaReferences(in: segments).map(\.mediaKind),
            [.image, .audio, .video, .unsupported]
        )
    }

    func testBareFileURLSupportDoesNotChangeExistingMediaOrHTTPSBehavior() throws {
        let segments = TranscriptMediaParser.segments(
            in: "MEDIA:/tmp/local.png MEDIA:https://cdn.example.test/image.png"
        )
        let references = mediaReferences(in: segments)

        XCTAssertEqual(references.map(\.rawReference), [
            "/tmp/local.png",
            "https://cdn.example.test/image.png"
        ])
        XCTAssertEqual(references[0].source, .localPath("/tmp/local.png"))
        XCTAssertEqual(
            references[1].source,
            .remoteURL(try XCTUnwrap(URL(string: "https://cdn.example.test/image.png")))
        )
    }

    func testUnsupportedSVGIsNotRasterImageCandidate() {
        let segments = TranscriptMediaParser.segments(in: "MEDIA:/tmp/vector.svg")
        let media = mediaReferences(in: segments).first

        XCTAssertEqual(media?.rawReference, "/tmp/vector.svg")
        XCTAssertEqual(media?.isRasterImageCandidate, false)
    }

    func testDetectsAudioAndVideoMediaKinds() {
        let references = [
            TranscriptMediaReference(rawReference: "/tmp/output.mp3"),
            TranscriptMediaReference(rawReference: "/tmp/output.m4a"),
            TranscriptMediaReference(rawReference: "/tmp/output.wav"),
            TranscriptMediaReference(rawReference: "/tmp/output.aac"),
            TranscriptMediaReference(rawReference: "/tmp/output.caf"),
            TranscriptMediaReference(rawReference: "https://cdn.example.test/output.mp4?download=1"),
            TranscriptMediaReference(rawReference: "/tmp/output.mov"),
            TranscriptMediaReference(rawReference: "/tmp/output.m4v")
        ]

        XCTAssertEqual(references[0].mediaKind, .audio)
        XCTAssertEqual(references[1].mediaKind, .audio)
        XCTAssertEqual(references[2].mediaKind, .audio)
        XCTAssertEqual(references[3].mediaKind, .audio)
        XCTAssertEqual(references[4].mediaKind, .audio)
        XCTAssertEqual(references[5].mediaKind, .video)
        XCTAssertEqual(references[6].mediaKind, .video)
        XCTAssertEqual(references[7].mediaKind, .video)
    }

    func testUnsupportedTextAndDataFilesAreClassifiedAsUnsupported() {
        let references = [
            TranscriptMediaReference(rawReference: "/tmp/report.txt"),
            TranscriptMediaReference(rawReference: "/tmp/data.csv"),
            TranscriptMediaReference(rawReference: "/tmp/notes.md"),
            TranscriptMediaReference(rawReference: "/tmp/config.json"),
            TranscriptMediaReference(rawReference: "/tmp/archive.zip"),
        ]

        for reference in references {
            XCTAssertEqual(reference.mediaKind, .unsupported, "\(reference.rawReference) must be .unsupported")
        }
    }

    func testUnsupportedFileExportPayloadKeepsOriginalNameAndExtension() {
        let reference = TranscriptMediaReference(rawReference: "/tmp/report.txt")
        let data = "hello".data(using: .utf8)!

        let payload = TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: .data
        )

        XCTAssertEqual(payload.filename, "report.txt")
        XCTAssertEqual(payload.data, data)
        XCTAssertFalse(payload.isImage)
        XCTAssertFalse(payload.isVideo)
    }

    func testParsedGenericFileURLExportKeepsDecodedOriginalNameAndExtension() throws {
        let segments = TranscriptMediaParser.segments(
            in: "file:///tmp/final%20report.csv"
        )
        let reference = try XCTUnwrap(mediaReferences(in: segments).first)
        let data = Data("heading,value".utf8)

        let payload = TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: .data
        )

        XCTAssertEqual(reference.rawReference, "/tmp/final report.csv")
        XCTAssertEqual(payload.filename, "final report.csv")
        XCTAssertEqual(payload.data, data)
    }

    func testExtensionlessUnsupportedFileExportsAsDataNotVideo() {
        let reference = TranscriptMediaReference(rawReference: "/tmp/results")
        let data = "binary".data(using: .utf8)!

        let payload = TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: .data
        )

        XCTAssertEqual(payload.filename, "results.bin")
        XCTAssertEqual(payload.contentType, .data)
        XCTAssertFalse(payload.isImage)
        XCTAssertFalse(payload.isVideo)
    }

    func testExtensionlessRemoteReferenceRemainsImageCandidateButCanFallbackToMedia() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/media/abc123"))
        let reference = TranscriptMediaReference(rawReference: remoteURL.absoluteString)

        XCTAssertEqual(reference.source, .remoteURL(remoteURL))
        XCTAssertEqual(reference.mediaKind, .image)
        XCTAssertTrue(reference.isRasterImageCandidate)
        XCTAssertTrue(reference.isExtensionlessRemoteMediaCandidate)
    }

    func testEmptyReferenceDisplayNameFallsBackToMedia() {
        XCTAssertEqual(TranscriptMediaReference(rawReference: "").displayName, "Media")
    }

    func testImageCacheKeySeparatesSameReferenceAcrossSessions() {
        let reference = TranscriptMediaReference(rawReference: "/tmp/result.png")

        let firstSessionKey = TranscriptMediaImageCacheKey(
            namespace: "https://one.example.test|session-a",
            reference: reference
        )
        let secondSessionKey = TranscriptMediaImageCacheKey(
            namespace: "https://one.example.test|session-b",
            reference: reference
        )
        let secondServerKey = TranscriptMediaImageCacheKey(
            namespace: "https://two.example.test|session-a",
            reference: reference
        )

        XCTAssertNotEqual(firstSessionKey, secondSessionKey)
        XCTAssertNotEqual(firstSessionKey, secondServerKey)
    }

    private func mediaReferences(in segments: [TranscriptMediaSegment]) -> [TranscriptMediaReference] {
        segments.compactMap { segment in
            if case let .media(reference) = segment {
                return reference
            }
            return nil
        }
    }

    private func textSegments(in segments: [TranscriptMediaSegment]) -> [String] {
        segments.compactMap { segment in
            if case let .text(text) = segment {
                return text
            }
            return nil
        }
    }
}
