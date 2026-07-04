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

    func testUnsupportedSVGIsNotRasterImageCandidate() {
        let segments = TranscriptMediaParser.segments(in: "MEDIA:/tmp/vector.svg")
        let media = mediaReferences(in: segments).first

        XCTAssertEqual(media?.rawReference, "/tmp/vector.svg")
        XCTAssertEqual(media?.isRasterImageCandidate, false)
    }

    func testAudioMediaReferencesAreAudioCandidates() throws {
        let segments = TranscriptMediaParser.segments(
            in: "Listen: MEDIA:/tmp/zora-output.mp3 and MEDIA:https://cdn.example.test/audio/voice.M4A?download=1"
        )
        let media = mediaReferences(in: segments)

        XCTAssertEqual(media.map(\.rawReference), [
            "/tmp/zora-output.mp3",
            "https://cdn.example.test/audio/voice.M4A?download=1"
        ])
        XCTAssertTrue(try XCTUnwrap(media.first).isAudioCandidate)
        XCTAssertFalse(try XCTUnwrap(media.first).isRasterImageCandidate)
        XCTAssertTrue(try XCTUnwrap(media.last).isAudioCandidate)
    }

    func testMarkdownMediaReferencesAreTextDocumentCandidates() throws {
        let segments = TranscriptMediaParser.segments(in: "Report: MEDIA:/tmp/cron-prompt-audit-2026-07-04.md")
        let media = try XCTUnwrap(mediaReferences(in: segments).first)

        XCTAssertEqual(media.rawReference, "/tmp/cron-prompt-audit-2026-07-04.md")
        XCTAssertTrue(media.isTextDocumentCandidate)
        XCTAssertFalse(media.isRasterImageCandidate)
        XCTAssertFalse(media.isAudioCandidate)
    }

    func testNonAudioMediaReferenceIsNotAudioCandidate() {
        let segments = TranscriptMediaParser.segments(in: "MEDIA:/tmp/result.png MEDIA:/tmp/report.pdf")
        let media = mediaReferences(in: segments)

        XCTAssertEqual(media.map(\.isAudioCandidate), [false, false])
    }

    func testEmptyReferenceDisplayNameFallsBackToMedia() {
        XCTAssertEqual(TranscriptMediaReference(rawReference: "").displayName, "Media")
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
