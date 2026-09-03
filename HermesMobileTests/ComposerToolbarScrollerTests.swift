import SwiftUI
import XCTest
@testable import HermesMobile

final class ComposerToolbarScrollerTests: XCTestCase {
    func testNoFadesWhenContentFits() {
        let fades = ComposerToolbarEdgeFades(offset: 0, contentWidth: 300, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testOnlyTrailingFadeAtStartOfOverflowingContent() {
        let fades = ComposerToolbarEdgeFades(offset: 0, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testBothFadesMidScroll() {
        let fades = ComposerToolbarEdgeFades(offset: 90, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertTrue(fades.trailing)
    }

    func testOnlyLeadingFadeAtEnd() {
        let fades = ComposerToolbarEdgeFades(offset: 180, contentWidth: 500, viewportWidth: 320)

        XCTAssertTrue(fades.leading)
        XCTAssertFalse(fades.trailing)
    }

    func testEdgesWithinEpsilonCountAsReached() {
        let nearStart = ComposerToolbarEdgeFades(offset: 3, contentWidth: 500, viewportWidth: 320)
        let nearEnd = ComposerToolbarEdgeFades(offset: 177, contentWidth: 500, viewportWidth: 320)

        XCTAssertFalse(nearStart.leading)
        XCTAssertFalse(nearEnd.trailing)
    }

    func testRightToLeftFlipsRawOffset() {
        // Raw offset 0 in RTL shows the visual start of the content (its right end),
        // so only the trailing (left) edge hides anything.
        let atStart = ComposerToolbarEdgeFades(
            offset: 180, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )
        let atEnd = ComposerToolbarEdgeFades(
            offset: 0, contentWidth: 500, viewportWidth: 320, layoutDirection: .rightToLeft
        )

        XCTAssertFalse(atStart.leading)
        XCTAssertTrue(atStart.trailing)
        XCTAssertTrue(atEnd.leading)
        XCTAssertFalse(atEnd.trailing)
    }

    func testReasoningRendersStaticOnlyForOneSupportedEffort() {
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: ["high"])?.id, "high")
        XCTAssertEqual(ReasoningEffortOption.singleOption(forSupportedEfforts: [" High ", "high"])?.id, "high")
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: ["low", "high"]))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: nil))
        XCTAssertNil(ReasoningEffortOption.singleOption(forSupportedEfforts: []))
    }

    func testProviderGlyphResolvesCatalogAliasesAndLeavesUnknownProvidersBare() {
        let aliases: [String: ProviderGlyphKind] = [
            "the-actual-computer-company": .actual,
            "dashscope": .alibaba,
            "claude-code": .anthropic,
            "arcee-ai": .arcee,
            "ai-gateway": .cloudflare,
            "command-code": .commandCode,
            "deepinfra": .deepInfra,
            "deep-seek": .deepSeek,
            "fireworks-ai": .fireworks,
            "gmi-cloud": .gmi,
            "vertex-ai": .google,
            "kilocode": .kiloCode,
            "element-labs": .lmStudio,
            "meta-llama": .meta,
            "github-copilot": .microsoft,
            "minimax-cn": .miniMax,
            "mistralai": .mistral,
            "kimi-coding": .moonshot,
            "nebius": .nebius,
            "nous-research": .nous,
            "novita-ai": .novita,
            "nvidia-nim": .nvidia,
            "ollama-cloud": .ollama,
            "openai-codex": .openAI,
            "opencode-go": .openCode,
            "opencode-free": .openCode,
            "open-router": .openRouter,
            "ramp-router": .ramp,
            "step-fun": .stepFun,
            "upstage": .upstage,
            "x-ai": .xAI,
            "xiaomi-mimo": .xiaomi,
            "z.ai": .zhipu
        ]

        for (alias, expected) in aliases {
            XCTAssertEqual(ProviderGlyphKind.resolve(providerID: alias), expected, alias)
        }
        XCTAssertEqual(Set(aliases.values), Set(ProviderGlyphKind.allCases))
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: "custom-provider"))
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: "custom"))

        // Suffixed upstream variants inherit their family glyph by prefix.
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "alibaba-coding-plan"), .alibaba)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "kimi-coding-cn"), .moonshot)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "copilot-acp"), .microsoft)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "nebius-token-factory"), .nebius)
        XCTAssertEqual(ProviderGlyphKind.resolve(providerID: "router"), .ramp)
        XCTAssertNil(ProviderGlyphKind.resolve(providerID: nil))
    }

    func testEverySupportedProviderGlyphIsBundled() throws {
        let bundleURL = try XCTUnwrap(
            Bundle.main.url(forResource: "ProviderLogos", withExtension: "bundle")
        )
        let logoBundle = try XCTUnwrap(Bundle(url: bundleURL))

        for kind in ProviderGlyphKind.allCases {
            _ = try XCTUnwrap(
                logoBundle.url(forResource: kind.rawValue, withExtension: "png"),
                kind.rawValue
            )
            XCTAssertNotNil(ProviderGlyphImageStore.image(for: kind), kind.rawValue)
        }
    }

    func testCombinedTitleIncludesEffortOnlyWhenModelSupportsIt() {
        let model = ModelCatalogOption(id: "gpt-5.5", displayName: "GPT-5.5", providerID: "openai")
        let visible = ComposerModelEffortSelection(
            model: model,
            effort: "high",
            supportedEfforts: ["low", "high"],
            supportsEffort: true
        )
        let hidden = ComposerModelEffortSelection(
            model: model,
            effort: "high",
            supportedEfforts: [],
            supportsEffort: false
        )

        XCTAssertEqual(visible.title, "GPT-5.5 · High")
        XCTAssertEqual(hidden.title, "GPT-5.5")
    }

    func testSingleEffortBecomesStaticAndIsCommitted() {
        let selection = ComposerModelEffortSelection(
            model: ModelCatalogOption(id: "o4-mini", displayName: "o4-mini", providerID: "openai"),
            effort: "xhigh",
            supportedEfforts: ["high"],
            supportsEffort: true
        )

        XCTAssertEqual(selection.staticEffort?.id, "high")
        XCTAssertEqual(selection.committedEffort, "high")
        XCTAssertEqual(selection.title, "o4-mini · High")
    }
}
