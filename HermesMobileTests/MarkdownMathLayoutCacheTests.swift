import XCTest
@testable import HermesMobile

final class MarkdownMathLayoutCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MarkdownMathLayoutCache.removeAll()
    }

    override func tearDown() {
        MarkdownMathLayoutCache.removeAll()
        super.tearDown()
    }

    func testUnclosedDisplayDelimitersStayLiteralUntilTheStreamClosesThem() {
        let partial = #"\[one \[two "#
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: partial), [.markdown(partial)])
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: partial + "$$x$$"),
                       [.markdown(partial), .displayMath("x")])
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: partial + #"\]"#),
                       [.displayMath(#"one \[two"#)])
        let protected = #"\[one `\]` \\]"#
        XCTAssertEqual(MarkdownMathSegmenter.segments(in: protected), [.markdown(protected)])
    }

    func testUnclosedInlineDelimitersDoNotHideMathOnTheNextLine() {
        let partial = #"\(one \(two "#
        XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: partial), partial)
        XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: partial + "\n" + #"\(x^2\)"#),
                       partial + "\nx²")
        XCTAssertEqual(MarkdownMathFormatter.replacingInlineMath(in: partial + "$x^2$"), partial + "x²")
    }

    func testDisplayMathStillSegments() {
        guard case .segmented(let segments) = MarkdownMathLayoutCache.layout(for: "before $$x = 1$$ after") else {
            return XCTFail("Expected display math to produce a segmented layout.")
        }

        XCTAssertTrue(segments.containsMath)
        XCTAssertEqual(segments, MarkdownMathSegmenter.segments(in: "before $$x = 1$$ after"))
    }

    func testUncachedLayoutDoesNotPopulateTheCache() {
        let content = "streaming answer with no math"

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

    func testPlainLayoutMatchesInlineImagePassAcrossGeneratedContent() {
        let fragments = [
            "prose ", "**bold** ", "`code` ", "$5 ", "$x^2$ ", "\\$escaped ",
            "\n\n", "- item\n", "> quote\n", "café ", "| a | b |\n", "[l](u) ",
            "```\ncode\n```\n", "# heading\n", "1. ordered\n",
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
