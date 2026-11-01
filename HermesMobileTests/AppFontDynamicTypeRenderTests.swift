import XCTest
import SwiftUI
import UIKit
@testable import HermesMobile

final class AppFontDynamicTypeRenderTests: XCTestCase {
    private struct ProbeRow: View {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        let text: String

        var body: some View {
            Text(text).appFont(.body, dynamicTypeSize: dynamicTypeSize)
        }
    }

    private func measuredWidth(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let probe = ProbeRow(text: String(repeating: "M", count: 40))
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let hosting = UIHostingController(rootView: probe)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 3000, height: 200)
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        return hosting.sizeThatFits(in: CGSize(width: 3000, height: 200)).width
    }

    func testTextAppFontRendersLargerUnderAccessibilityDynamicTypeSize() {
        let largeWidth = measuredWidth(dynamicTypeSize: .large)
        let accessibilityWidth = measuredWidth(dynamicTypeSize: .accessibility3)
        XCTAssertGreaterThan(accessibilityWidth, largeWidth * 1.3)
    }
}
