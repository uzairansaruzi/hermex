import SwiftUI
import XCTest
@testable import HermesMobile

@MainActor
final class AppFontTests: XCTestCase {
    private var storedFamily: AppFontFamily = .sanFrancisco

    override func setUp() async throws {
        storedFamily = AppFontSettings.shared.family
        AppFontSettings.shared.family = .sanFrancisco
    }

    override func tearDown() async throws {
        AppFontSettings.shared.family = storedFamily
    }

    /// A missing `UIAppFonts` entry or a bad family name falls back to San Francisco silently.
    func testEveryNamedFontLoadsWithItsWeights() {
        let expected: [AppFontFamily: String] = [
            .dmSans: "DM Sans",
            .avenirNext: "Avenir Next",
            .georgia: "Georgia",
            .lora: "Lora"
        ]
        for (family, name) in expected {
            AppFontSettings.shared.family = family
            let regular = UIFont.app(size: 17)
            let bold = UIFont.app(size: 17, weight: .bold)
            XCTAssertEqual(regular.familyName, name)
            XCTAssertEqual(bold.familyName, name)
            XCTAssertNotEqual(regular, bold, "\(name) has no working bold")
        }
    }

    func testSanFranciscoIsTheSystemFontUnchanged() {
        XCTAssertEqual(AppFont.caption(weight: .semibold), .system(.caption, weight: .semibold))
        XCTAssertEqual(AppFont.fixed(size: 11, weight: .bold), .system(size: 11, weight: .bold))
        XCTAssertNil(AppFont.root)
        XCTAssertNil(AppFont.sectionFooter)
        XCTAssertEqual(
            UIFont.app(forTextStyle: .body, at: .xLarge),
            UIFont.preferredFont(forTextStyle: .body, at: .xLarge)
        )
    }

    /// Nothing passes the font down: a body that reads a token re-runs when the font changes,
    /// which is what restyles settled transcript rows and nested hosting. The composer is UIKit
    /// and has to follow in its `updateUIView`.
    func testChangingTheFontRestylesViewsAndTheComposer() async throws {
        let restyled = expectation(description: "A body read the new font")
        let target = AppFont.body()
        var didChange = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(
                session: SessionSummary(title: "Synthetic chat", workspace: "/workspace"),
                server: URL(string: "https://font.invalid")!,
                onAPIError: { _ in },
                loadsInitialMessages: false
            )
            .overlay {
                FontProbe { font in
                    guard font != target, !didChange else { return }
                    didChange = true
                    restyled.fulfill()
                }
            }
        })
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        let composer = try XCTUnwrap(window.firstSubview(of: ComposerChipTextView.self))

        AppFontSettings.shared.family = .lora
        await fulfillment(of: [restyled], timeout: 5)
        window.layoutIfNeeded()

        XCTAssertEqual(composer.font?.familyName, "Lora")
    }
}

private struct FontProbe: View {
    let onBody: (Font) -> Void

    var body: some View {
        let font = AppFont.body()
        let _ = onBody(font)
        Color.clear.font(font)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
