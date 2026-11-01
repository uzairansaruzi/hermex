import Observation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

@MainActor final class HermexSameWindowOverlayTests: XCTestCase {
    func testRootOverlayMountsAsSiblingAboveRootView() async throws {
        let model = HermexSameWindowOverlayHarnessModel()
        let window = try show(HermexSameWindowOverlayHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        await settle(window)

        let overlay = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.identifier
        })
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(overlay.superview === rootView.superview)
        XCTAssertFalse(overlay.isDescendant(of: rootView))
    }

    func testRootOverlayFillsRootContainer() async throws {
        let model = HermexSameWindowOverlayHarnessModel()
        let window = try show(HermexSameWindowOverlayHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        await settle(window)

        let overlay = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.identifier
        })
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertEqual(overlay.frame, rootView.frame)
    }

    func testDetachedHostForwardsSceneAndAccessibilityEnvironment() async throws {
        let model = HermexSameWindowOverlayHarnessModel()
        let window = try show(HermexSameWindowOverlayHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        await settle(window)
        XCTAssertEqual(model.observedPhase, .active, "The detached host must forward the owning scene's phase")

        let overlay = try XCTUnwrap(descendants(window).first {
            $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.identifier
        })
        XCTAssertTrue(overlay.accessibilityViewIsModal, "The mounted host must isolate the underlying screen for accessibility")

        model.phase = .background
        await settle(window)
        XCTAssertEqual(model.observedPhase, .background, "A backgrounded owner must reach the hosted overlay")
    }

    func testDismantleRemovesOnlyItsOwnHostedView() async throws {
        let model = HermexSameWindowOverlayHarnessModel()
        let window = try show(HermexSameWindowOverlayHarnessView(model: model))
        defer { close(window) }
        await settle(window)

        model.isPresented = true
        model.isSecondPresented = true
        await settle(window)
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.identifier })
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.secondIdentifier })

        model.isPresented = false
        await settle(window)
        XCTAssertFalse(descendants(window).contains { $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.identifier },
                        "Dismantling one host must remove its own hosted view")
        XCTAssertTrue(descendants(window).contains { $0.accessibilityIdentifier == HermexSameWindowOverlayHarnessModel.secondIdentifier },
                       "Dismantling one host must not remove a sibling host")
    }

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.transaction { $0.disablesAnimations = true })
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor @Observable
private final class HermexSameWindowOverlayHarnessModel {
    static let identifier = "hermex-same-window-overlay-harness"
    static let secondIdentifier = "hermex-same-window-overlay-harness-second"

    var isPresented = false
    var isSecondPresented = false
    var phase = ScenePhase.active
    var observedPhase: ScenePhase?
}

private struct HermexSameWindowOverlayHarnessView: View {
    @Bindable var model: HermexSameWindowOverlayHarnessModel

    var body: some View {
        Color.clear
            .background {
                HermexSameWindowOverlay(
                    isPresented: model.isPresented,
                    bounds: .root,
                    accessibilityIdentifier: HermexSameWindowOverlayHarnessModel.identifier
                ) {
                    HermexSameWindowOverlayEnvironmentProbe { model.observedPhase = $0 }
                }
            }
            .background {
                HermexSameWindowOverlay(
                    isPresented: model.isSecondPresented,
                    bounds: .root,
                    accessibilityIdentifier: HermexSameWindowOverlayHarnessModel.secondIdentifier
                ) {
                    Color.clear
                }
            }
            .environment(\.scenePhase, model.phase)
    }
}

private struct HermexSameWindowOverlayEnvironmentProbe: View {
    @Environment(\.scenePhase) private var phase
    let report: (ScenePhase) -> Void

    var body: some View {
        Color.clear.onChange(of: phase, initial: true) { _, value in report(value) }
    }
}
