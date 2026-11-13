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
            ModelDisplayNames.Parts(name: "Mistral Large 3", tag: "Q4_K_XL")
        )

        let variantFirst = ModelDisplayNames.parts(for: "mistral-large-3-flash-Q4_K_XL:local")
        let quantFirst = ModelDisplayNames.parts(for: "mistral-large-3-Q4_K_XL-flash:local")
        XCTAssertEqual(variantFirst, quantFirst)
        XCTAssertEqual(variantFirst.tag, "Flash Q4_K_XL")
    }

    func testQuantTagsKeepTheFullComponentSoLookAlikeBuildsStayDistinct() {
        // The picker renders no raw id beside the label, so `…-Q4_K_M` and
        // `…-Q4_K_S` must not both read `Q4` — the sub-variant is the only
        // thing telling the two files apart.
        let kM = ModelDisplayNames.parts(for: "mistral/mistral-large-3-Q4_K_M:local")
        let kS = ModelDisplayNames.parts(for: "mistral/mistral-large-3-Q4_K_S:local")
        XCTAssertEqual(kM.name, "Mistral Large 3")
        XCTAssertEqual(kM.tag, "Q4_K_M")
        XCTAssertEqual(kS.tag, "Q4_K_S")
        XCTAssertNotEqual(kM, kS)
        XCTAssertNotEqual(
            ModelDisplayNames.displayLabel(for: "mistral/mistral-large-3-Q4_K_M:local"),
            ModelDisplayNames.displayLabel(for: "mistral/mistral-large-3-Q4_K_S:local")
        )

        XCTAssertEqual(
            ModelDisplayNames.parts(for: "qwen/qwen3.6-35b-UD-Q4_K_XL:local").tag,
            "UD-Q4_K_XL"
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "llama/llama-3.1-8b-IQ3_XS:local").tag,
            "IQ3_XS"
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "mistral/mistral-large-3-F16:local").tag,
            "F16"
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "mistral/mistral-large-3-BF16:local").tag,
            "BF16"
        )
    }

    func testServerProvidedNameRendersVerbatim() {
        // The webui transport's `name`/`label` is the server's own string;
        // prettifying it would rename the model behind the server's back.
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "team/production", displayName: "Team / Production"),
            ModelDisplayNames.Parts(name: "Team / Production", tag: "")
        )
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "team/production", displayName: "Team / Production"),
            "Team / Production"
        )
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "qwen/qwen-max", displayName: "Qwen-Max"),
            "Qwen-Max"
        )
        // Differing from the id in case alone is still a server name.
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "qwen-max", displayName: "Qwen-Max"),
            "Qwen-Max"
        )
    }

    func testRawIDFallbackDisplayNameStillPrettifies() {
        // The catalog fills `displayName` with the raw id when the server
        // provided no name; that fallback is what the prettifier exists for.
        XCTAssertEqual(
            ModelDisplayNames.parts(
                for: "zai/glm-5.3-flash:local",
                displayName: "zai/glm-5.3-flash:local"
            ),
            ModelDisplayNames.Parts(name: "GLM 5.3", tag: "Flash")
        )
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(
                for: "zai/glm-5.3-flash:local",
                displayName: "zai/glm-5.3-flash:local"
            ),
            "GLM 5.3 · Flash"
        )
        // A blank `displayName` is no name either; fall back to the id.
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "deepseek-v4.1-flash", displayName: "   "),
            "DeepSeek V4.1 · Flash"
        )
        // A displayName differing from the id only by case is a server name,
        // not an id fallback — it renders verbatim, unprettified.
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "zai/glm-5.3-flash:local", displayName: "ZAI/GLM-5.3-FLASH:LOCAL"),
            "ZAI/GLM-5.3-FLASH:LOCAL"
        )
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
