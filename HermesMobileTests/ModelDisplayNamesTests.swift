import XCTest
@testable import HermesMobile

final class ModelDisplayNamesTests: XCTestCase {
    func testGatewayLocalGLMIdSplitsNameAndFlashTag() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "zai/glm-5.3-flash:local"),
            ModelDisplayNames.Parts(name: "GLM 5.3", tag: "Flash")
        )
        XCTAssertEqual(ModelDisplayNames.displayLabel(for: "zai/glm-5.3-flash:local"), "GLM 5.3 · Flash")
    }

    func testLocalQwenIdPrettifiesParameterCountsAndKeepsNoTag() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "qwen/qwen3.6-35b-a3b:local"),
            ModelDisplayNames.Parts(name: "Qwen3.6 35B A3B", tag: "")
        )
    }

    func testBareDeepSeekVariantIdSplitsNameAndFlashTag() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "deepseek-v4.1-flash"),
            ModelDisplayNames.Parts(name: "DeepSeek V4.1", tag: "Flash")
        )
    }

    func testClaudeIdDotsTheVersion() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "anthropic/claude-haiku-4-5"),
            ModelDisplayNames.Parts(name: "Haiku 4.5", tag: "")
        )
    }

    func testGPTIdKeepsTheGPTPrefixForm() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "openai/gpt-5.5"),
            ModelDisplayNames.Parts(name: "GPT-5.5", tag: "")
        )
    }

    func testGeminiIdPrettifiesWithAndWithoutVendorPrefix() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "google/gemini-2.5-flash"),
            ModelDisplayNames.Parts(name: "Gemini 2.5", tag: "Flash")
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "gemini-2.5-flash"),
            ModelDisplayNames.Parts(name: "Gemini 2.5", tag: "Flash")
        )
    }

    func testGGUFQuantBecomesTheTagInEitherOrderWithTheVariant() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "mistral/mistral-large-3-Q4_K_XL:local"),
            ModelDisplayNames.Parts(name: "Mistral Large 3", tag: "Q4")
        )

        let variantFirst = ModelDisplayNames.parts(for: "mistral-large-3-flash-Q4_K_XL:local")
        let quantFirst = ModelDisplayNames.parts(for: "mistral-large-3-Q4_K_XL-flash:local")
        XCTAssertEqual(variantFirst, quantFirst)
        XCTAssertEqual(variantFirst.tag, "Flash Q4")
    }

    func testContextWindowSuffixAndDatePinLeaveTheName() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "anthropic/claude-sonnet-5[1m]"),
            ModelDisplayNames.Parts(name: "Sonnet 5", tag: "1M")
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "openai/gpt-5.5-20251101"),
            ModelDisplayNames.Parts(name: "GPT-5.5", tag: "")
        )
    }

    func testUnrecognizableIdFallsBackToTheRawTrimmedId() {
        // An id that is only the local-build marker prettifies to nothing, so
        // the raw id comes back unchanged instead of an empty label.
        XCTAssertEqual(ModelDisplayNames.parts(for: ":local"), ModelDisplayNames.Parts(name: ":local", tag: ""))
        // A well-formed unknown family still gets the base prettifying.
        XCTAssertEqual(ModelDisplayNames.parts(for: "weird-id"), ModelDisplayNames.Parts(name: "Weird Id", tag: ""))
        // Whitespace-only input never renders as "".
        XCTAssertEqual(ModelDisplayNames.parts(for: "   ").name, "No model")
    }

    func testVariantTagsKeepLookAlikeIdsDistinct() {
        let flash = ModelDisplayNames.parts(for: "zai/glm-5.3-flash:local")
        let thinking = ModelDisplayNames.parts(for: "zai/glm-5.3-thinking:local")

        XCTAssertNotEqual(flash, thinking)
        XCTAssertNotEqual(
            ModelDisplayNames.displayLabel(for: "zai/glm-5.3-flash:local"),
            ModelDisplayNames.displayLabel(for: "zai/glm-5.3-thinking:local")
        )
    }
}
