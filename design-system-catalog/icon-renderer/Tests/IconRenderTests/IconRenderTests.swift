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

    // Renders the catalog's five default icon-size steps (HermesIconSize: xs/small/medium/large/
    // extraLarge — 12/16/20/24/32pt) for the shared size-scale demo glyph `star.fill` directly at
    // each point size, through the same `UIImage(systemName:)` API — a real, point-accurate asset
    // per step, rather than one 32pt render resized in CSS. Each PNG is sized to the symbol's own
    // rendered bounds at that point size (no padding box), so the browser catalog shows the glyph at
    // its true relative scale across steps. `iconSizeStepPoints` (GeneratedNames.swift) is the same
    // [12, 16, 20, 24, 32] source generate-icon-previews.mjs derives from hermesIconSize.ts.
    func testRenderSizeScaleSpecimens() throws {
        XCTAssertFalse(iconSizeStepPoints.isEmpty, "expected a non-empty size-step list from GeneratedNames.swift")

        var missing: [Int] = []
        for pointSize in iconSizeStepPoints {
            let configuration = UIImage.SymbolConfiguration(pointSize: CGFloat(pointSize), weight: .regular)
            guard let symbol = UIImage(systemName: iconSizeStepSymbolName, withConfiguration: configuration)?
                .withTintColor(.black, renderingMode: .alwaysOriginal) else {
                missing.append(pointSize)
                continue
            }
            let size = symbol.size
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let png = renderer.pngData { _ in
                symbol.draw(at: .zero)
            }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "icon_size_\(pointSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(missing.isEmpty, "UIImage(systemName:) returned nil for \(iconSizeStepSymbolName) at point size(s): \(missing.map(String.init).joined(separator: ", "))")
    }
}
