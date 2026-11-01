import XCTest
@testable import HermesMobile

/// Guards the memoized markdown layout used by the transcript renderers.
///
/// The optimization it protects: for content with no display math, the renderer
/// used to segment the whole string and then run `replacingInlineMath` over the
/// whole string a second time, on every SwiftUI body evaluation. These tests
/// pin the two properties that make dropping that second pass safe — the cached
/// layout must be byte-identical to the old two-pass output, and the streaming
/// path must not pollute the cache.
final class MarkdownMathLayoutCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MarkdownMathLayoutCache.removeAll()
    }

    override func tearDown() {
        MarkdownMathLayoutCache.removeAll()
        super.tearDown()
    }

    func testDisplayMathStillSegments() {
        guard case .segmented(let segments) = MarkdownMathLayoutCache.layout(for: "before $$x = 1$$ after") else {
            return XCTFail("Expected display math to produce a segmented layout.")
        }

        XCTAssertTrue(segments.containsMath)
        XCTAssertEqual(segments, MarkdownMathSegmenter.segments(in: "before $$x = 1$$ after"))
    }

    /// Streaming mutates the string on nearly every token. If that path wrote
    /// through the cache it would insert an entry per token and evict the
    /// settled answers the cache exists to protect.
    func testUncachedLayoutDoesNotPopulateTheCache() {
        let content = "streaming answer with no math"

        // Comparing the two layout values proves nothing: they are equal
        // whether or not the cache was written. Observe the cache directly.
        XCTAssertFalse(MarkdownMathLayoutCache.hasCachedLayout(for: content))

        let uncached = MarkdownMathLayoutCache.uncachedLayout(for: content)

        XCTAssertFalse(
            MarkdownMathLayoutCache.hasCachedLayout(for: content),
            "The streaming path must not write to the cache; per-token entries would evict settled answers."
        )

        let cached = MarkdownMathLayoutCache.layout(for: content)

        XCTAssertTrue(
            MarkdownMathLayoutCache.hasCachedLayout(for: content),
            "The settled path is expected to memoize."
        )
        XCTAssertEqual(uncached, cached, "Cached and uncached layouts must agree.")
    }

    /// Differential check over generated content: for every no-math input, the
    /// cached `.plain` payload must equal the inline-image two-pass output exactly.
    ///
    /// This is the test that actually licenses dropping the second
    /// `replacingInlineMath` pass. It is randomized but seeded, so a failure is
    /// reproducible from the printed input.
    func testPlainLayoutMatchesInlineImagePassAcrossGeneratedContent() {
        let fragments = [
            "prose ", "**bold** ", "`code` ", "$5 ", "$x^2$ ", "\\$escaped ",
            "\n\n", "- item\n", "> quote\n", "café ", "| a | b |\n", "[l](u) ",
            "```\ncode\n```\n", "# heading\n", "1. ordered\n",
            // Display delimiters, including the empty spans the segmenter
            // recognises but emits no math for. These are the cases that
            // regressed once; keep them in the generator.
            "$$ $$ ", "$$$$ ", "\\[ \\] ", "$$m$$ ", "\\[d\\] ", "$$", "\\["
        ]

        var generator = SeededGenerator(seed: 0xC0FFEE)
        var checked = 0

        for _ in 0..<3_000 {
            let count = Int.random(in: 1...14, using: &generator)
            var content = ""
            for _ in 0..<count {
                content += fragments.randomElement(using: &generator)!
            }

            MarkdownMathLayoutCache.removeAll()
            guard case .plain(let layout) = MarkdownMathLayoutCache.layout(for: content) else {
                continue
            }
            checked += 1

            XCTAssertEqual(
                layout,
                MarkdownMathFormatter.inlineMathImages(in: content),
                "Layout diverged from the inline-image pass for \(content.debugDescription)"
            )
        }

        XCTAssertGreaterThan(checked, 500, "Generator produced too few no-math cases to be meaningful.")
    }
}

/// Deterministic generator so a differential failure is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
