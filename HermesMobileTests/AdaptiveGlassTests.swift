import SwiftUI
import XCTest
@testable import HermesMobile

final class AdaptiveGlassTests: XCTestCase {
    func testSurfaceResolutionPrefersOpaqueWhenReduceTransparencyIsEnabled() {
        let surface = AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: true,
            isGlassEnabled: true,
            reduceTransparency: true
        )

        XCTAssertEqual(surface, .opaque)
    }

    func testSurfaceResolutionFallsBackToMaterialWhenGlassIsDisabled() {
        let surface = AdaptiveGlassSurface.resolve(
            liquidGlassAvailable: true,
            isGlassEnabled: false,
            reduceTransparency: false
        )

        XCTAssertEqual(surface, .material)
    }

    func testScrollEdgeTreatmentDisablesWhenReduceTransparencyIsEnabled() {
        let treatment = AdaptiveScrollEdgeTreatment.resolve(
            softScrollEdgesAvailable: true,
            reduceTransparency: true
        )

        XCTAssertEqual(treatment, .disabled)
    }
}

@MainActor
final class ChatNavigationBackgroundTests: XCTestCase {
    func testChatNavigationHasOpaqueBackgroundWhenTransparencyIsReduced() async throws {
        try await checkBackground(reduceTransparency: true)
    }

    private func checkBackground(reduceTransparency: Bool) async throws {
        let appeared = expectation(description: "Chat navigation appeared")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            ChatView(
                session: SessionSummary(title: "Synthetic chat", workspace: "/workspace"),
                server: URL(string: "https://chat-header.invalid")!,
                onAPIError: { _ in },
                loadsInitialMessages: false
            )
            // SwiftUI's public accessibility value is read-only; the test-only
            // backing setter exercises ChatView without changing simulator settings.
            .environment(\._accessibilityReduceTransparency, reduceTransparency)
            .background(NavigationAppearanceCompletionObserver { appeared.fulfill() })
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        let navigation = try XCTUnwrap(findNavigation(in: host))
        let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
        let appearance = item.scrollEdgeAppearance ?? navigation.navigationBar.scrollEdgeAppearance
            ?? navigation.navigationBar.standardAppearance
        if #available(iOS 26, *), !reduceTransparency {
            XCTAssertTrue(appearance.backgroundEffect is UIBlurEffect,
                          "Chat must request a native material behind the title even at the scroll edge")
        } else {
            XCTAssertEqual(appearance.backgroundColor?.resolvedColor(with: host.traitCollection),
                           UIColor.systemBackground.resolvedColor(with: host.traitCollection),
                           "Reduce Transparency and older systems must cover the navigation and status-bar region with an opaque background")
        }
    }

    private func findNavigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.findNavigation(in: $0) }.first
    }
}
