import XCTest
import UIKit

// Renders every name in `iconRenderNames` (GeneratedNames.swift, written fresh by
// scripts/generate-icon-previews.mjs — gitignored, never committed) through
// `UIImage(systemName:)`, the same iOS SF Symbols API the production app uses, and attaches each
// PNG so the orchestrator script can pull it back out via `xcresulttool export attachments`.
// A name `UIImage(systemName:)` cannot resolve fails the whole run instead of producing a
// placeholder image, so a bad/renamed symbol can never pass silently.
final class IconRenderTests: XCTestCase {
    func testRenderAllCatalogSymbols() throws {
        XCTAssertFalse(iconRenderNames.isEmpty, "expected a non-empty symbol name list from GeneratedNames.swift")

        var missing: [String] = []
        let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)

        for (index, name) in iconRenderNames.enumerated() {
            guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(.black, renderingMode: .alwaysOriginal) else {
                missing.append(name)
                continue
            }
            let png = renderer.pngData { _ in
                let size = symbol.size
                let origin = CGPoint(x: (64 - size.width) / 2, y: (64 - size.height) / 2)
                symbol.draw(at: origin)
            }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "icon_\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(missing.isEmpty, "UIImage(systemName:) returned nil for: \(missing.joined(separator: ", "))")
    }
}
