import XCTest
@testable import HermesMobile

final class ModelDisplayNamesTests: XCTestCase {
    func testAGatewayIdReadsAsANameWithItsTags() {
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "zai/glm-5.3-flash:local"),
            ModelDisplayNames.Parts(name: "GLM 5.3", tag: "Flash Local")
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "anthropic/claude-haiku-4-5-20251001"),
            ModelDisplayNames.Parts(name: "Haiku 4.5", tag: "")
        )
        XCTAssertEqual(
            ModelDisplayNames.parts(for: "qwen/qwen3.6-35b-a3b-UD-Q4_K_XL"),
            ModelDisplayNames.Parts(name: "Qwen3.6 35B A3B", tag: "UD-Q4_K_XL")
        )
    }

    func testVariantsOfOneModelKeepDistinctLabels() {
        let labels = [
            "zai/glm-5.3", "zai/glm-5.3-flash", "zai/glm-5.3-thinking", "zai/glm-5.3-flash:local",
            "mistral-large-3-Q4_K_M", "mistral-large-3-Q4_K_S", "llama3.2:latest", "llama3.2:3b"
        ].map { ModelDisplayNames.displayLabel(for: $0, displayName: $0) }

        XCTAssertEqual(Set(labels).count, labels.count)
    }

    func testAServerProvidedNameIsShownAsSent() {
        XCTAssertEqual(
            ModelDisplayNames.displayLabel(for: "team/production", displayName: "Team / Production"),
            "Team / Production"
        )
        // Differing from the id in case alone is still the server's name.
        XCTAssertEqual(ModelDisplayNames.displayLabel(for: "qwen-max", displayName: "Qwen-Max"), "Qwen-Max")
    }
}
