import XCTest
import SwiftUI
@testable import HermesMobile

final class AppFontModifierBuildProofTests: XCTestCase {
    func testAppFontModifierCompilesAndProducesAView() {
        let view: some View = Text("proof").appFont(.body)
        XCTAssertNotNil(view)
    }

    func testAppFontModifierAcceptsTheNamedMonospacedRole() {
        let view: some View = Text("proof").appFont(.mono12)
        XCTAssertNotNil(view)
    }

    func testTextAppFontOverloadConcatenatesAsText() {
        let fragment: Text = Text("summary").appFont(.captionSemibold, dynamicTypeSize: .large)
            + Text(" ")
            + Text("detail").appFont(.caption, dynamicTypeSize: .large)
        XCTAssertNotNil(fragment)
    }
}
