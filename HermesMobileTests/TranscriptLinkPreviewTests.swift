import XCTest
@testable import HermesMobile

final class TranscriptLinkPreviewTests: XCTestCase {
    func testExtractsFirstValidWebURL() throws {
        let url = try XCTUnwrap(
            TranscriptLinkPreviewExtractor.firstWebURL(in: "Read https://example.com/docs for details.")
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/docs")
    }

    func testMultipleURLsChooseFirstValidWebURL() throws {
        let url = try XCTUnwrap(
            TranscriptLinkPreviewExtractor.firstWebURL(
                in: "First https://first.example/path, then https://second.example/path."
            )
        )

        XCTAssertEqual(url.absoluteString, "https://first.example/path")
    }

    func testInlineCodeURLsAreIgnored() throws {
        let url = try XCTUnwrap(
            TranscriptLinkPreviewExtractor.firstWebURL(
                in: "Do not preview `https://internal.example/token`; use https://public.example instead."
            )
        )

        XCTAssertEqual(url.absoluteString, "https://public.example")
    }

    func testFencedCodeURLsAreIgnored() throws {
        let markdown = """
        Before
        ```json
        {"url": "https://internal.example/token"}
        ```
        After https://public.example
        """

        let url = try XCTUnwrap(TranscriptLinkPreviewExtractor.firstWebURL(in: markdown))

        XCTAssertEqual(url.absoluteString, "https://public.example")
    }

    func testNonWebSchemesAreIgnored() {
        XCTAssertNil(
            TranscriptLinkPreviewExtractor.firstWebURL(
                in: "Open file:///tmp/report.txt, ssh://server.test, and hermes-agent://session/1."
            )
        )
    }

    func testJSONLogStackTraceAndCodeSnippetURLsAreIgnored() {
        let transcript = """
        {"url": "https://json.example/item"}
        ERROR failed to fetch https://logs.example/error
        at fetchThing (https://stack.example/app.js:10:2)
        let callbackURL = "https://code.example/callback"
        """

        XCTAssertNil(TranscriptLinkPreviewExtractor.firstWebURL(in: transcript))
    }

    func testMarkdownLinkURLIsEligible() throws {
        let url = try XCTUnwrap(
            TranscriptLinkPreviewExtractor.firstWebURL(in: "Open [the docs](https://docs.example/guide).")
        )

        XCTAssertEqual(url.absoluteString, "https://docs.example/guide")
    }

    func testUserMessageIsEligible() throws {
        let message = ChatMessage(
            role: "user",
            content: "Look at https://example.com",
            timestamp: nil,
            messageId: "user-1"
        )

        let url = try XCTUnwrap(TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: false))

        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func testAssistantMessageIsEligibleAfterStreamingCompletes() throws {
        let message = ChatMessage(
            role: "assistant",
            content: "Reference: https://example.com/result",
            timestamp: nil,
            messageId: "assistant-1"
        )

        let url = try XCTUnwrap(TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: false))

        XCTAssertEqual(url.absoluteString, "https://example.com/result")
    }

    func testStreamingAssistantMessageReservesPreviewSpaceWithoutLoadingPreview() {
        let message = ChatMessage(
            role: "assistant",
            content: "Still streaming https://example.com/result",
            timestamp: nil,
            messageId: "assistant-1"
        )

        XCTAssertNil(TranscriptLinkPreviewEligibility.previewURL(for: message, isStreaming: true))
        XCTAssertTrue(TranscriptLinkPreviewEligibility.shouldReservePreviewSpace(for: message, isStreaming: true))
    }

    func testStreamingAssistantMessageWithoutURLDoesNotReservePreviewSpace() {
        let message = ChatMessage(
            role: "assistant",
            content: "Still streaming plain text",
            timestamp: nil,
            messageId: "assistant-1"
        )

        XCTAssertFalse(TranscriptLinkPreviewEligibility.shouldReservePreviewSpace(for: message, isStreaming: true))
    }

    func testPreviewCacheReturnsStoredSnapshotForNormalizedURL() async throws {
        let cache = TranscriptLinkPreviewCache(maximumEntryCount: 4)
        let sourceURL = try XCTUnwrap(URL(string: "https://Example.com:443/path#section"))
        let lookupURL = try XCTUnwrap(URL(string: "https://example.com/path"))
        let snapshot = TranscriptLinkPreviewSnapshot(
            title: "Example",
            displayURL: sourceURL,
            imageData: Data([1, 2, 3])
        )

        await cache.store(snapshot, for: sourceURL)

        let cachedSnapshot = await cache.snapshot(for: lookupURL)
        XCTAssertEqual(cachedSnapshot, snapshot)
    }

    func testPreviewCacheEvictsLeastRecentlyUsedEntry() async throws {
        let cache = TranscriptLinkPreviewCache(maximumEntryCount: 2)
        let firstURL = try XCTUnwrap(URL(string: "https://first.example"))
        let secondURL = try XCTUnwrap(URL(string: "https://second.example"))
        let thirdURL = try XCTUnwrap(URL(string: "https://third.example"))

        await cache.store(TranscriptLinkPreviewSnapshot(title: "First"), for: firstURL)
        await cache.store(TranscriptLinkPreviewSnapshot(title: "Second"), for: secondURL)
        _ = await cache.snapshot(for: firstURL)
        await cache.store(TranscriptLinkPreviewSnapshot(title: "Third"), for: thirdURL)

        let firstSnapshot = await cache.snapshot(for: firstURL)
        let secondSnapshot = await cache.snapshot(for: secondURL)
        let thirdSnapshot = await cache.snapshot(for: thirdURL)

        XCTAssertNotNil(firstSnapshot)
        XCTAssertNil(secondSnapshot)
        XCTAssertNotNil(thirdSnapshot)
    }

    func testPreviewCacheIgnoresNonWebURLs() async throws {
        let cache = TranscriptLinkPreviewCache(maximumEntryCount: 4)
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/report.txt"))

        await cache.store(TranscriptLinkPreviewSnapshot(title: "File"), for: fileURL)

        let cachedSnapshot = await cache.snapshot(for: fileURL)

        XCTAssertNil(TranscriptLinkPreviewCache.cacheKey(for: fileURL))
        XCTAssertNil(cachedSnapshot)
    }
}
