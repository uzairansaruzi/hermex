import SwiftUI
import UIKit

/// Where a `HermexSameWindowOverlay` fills to: `.root` spans the whole root view, currently used by
/// Dialog and Popover Menu. `.aboveKeyboard` stops at the keyboard layout guide's top instead, so a
/// composer underneath could stay first responder; it is a reusable foundation capability with no
/// current production caller and is not exercised by the current test suite.
enum HermexSameWindowOverlayBounds {
    case root
    case aboveKeyboard
}

/// Mounts a transparent SwiftUI overlay as a sibling above the app's current root view, inside the
/// existing window, instead of presenting a new controller: sibling attachment, a transparent
/// detached `UIHostingController`, environment forwarding, and deterministic teardown. The
/// attachment picker keeps its own separate, pre-existing local same-window implementation
/// (`HermexKeyboardRetainingOverlay` in `CustomAttachmentPicker.swift`) and does not import this
/// type — do not assume the picker adopts this shared mechanism.
struct HermexSameWindowOverlay<Overlay: View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let isPresented: Bool
    let bounds: HermexSameWindowOverlayBounds
    let accessibilityIdentifier: String
    private let overlay: () -> Overlay

    init(
        isPresented: Bool,
        bounds: HermexSameWindowOverlayBounds,
        accessibilityIdentifier: String,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.isPresented = isPresented
        self.bounds = bounds
        self.accessibilityIdentifier = accessibilityIdentifier
        self.overlay = overlay
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            bounds: bounds,
            accessibilityIdentifier: accessibilityIdentifier,
            anchor: controller,
            // This sibling host does not inherit SwiftUI's scene/appearance/accessibility
            // environment; forward what a detached host needs to render and behave correctly.
            overlay: AnyView(
                overlay()
                    .environment(\.scenePhase, scenePhase)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\._colorSchemeContrast, colorSchemeContrast)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.locale, locale)
                    .environment(\._accessibilityReduceMotion, reduceMotion)
                    .environment(\._accessibilityReduceTransparency, reduceTransparency)
            )
        )
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        private var host: UIHostingController<AnyView>?
        private var wantsPresentation = false
        private var latestOverlay = AnyView(EmptyView())
        private var latestBounds = HermexSameWindowOverlayBounds.root
        private var latestAccessibilityIdentifier = ""

        func update(
            isPresented: Bool,
            bounds: HermexSameWindowOverlayBounds,
            accessibilityIdentifier: String,
            anchor: UIViewController,
            overlay: AnyView
        ) {
            wantsPresentation = isPresented
            latestOverlay = overlay
            latestBounds = bounds
            latestAccessibilityIdentifier = accessibilityIdentifier

            guard isPresented else {
                removeOverlay()
                return
            }

            if let host {
                host.rootView = overlay
                return
            }

            guard let root = anchor.view.window?.rootViewController else {
                DispatchQueue.main.async { [weak self, weak anchor] in
                    guard let self, let anchor, self.wantsPresentation else { return }
                    self.attachIfPossible(to: anchor)
                }
                return
            }
            attach(to: root)
        }

        private func attachIfPossible(to anchor: UIViewController) {
            guard host == nil,
                  wantsPresentation,
                  let root = anchor.view.window?.rootViewController
            else { return }
            attach(to: root)
        }

        private func attach(to root: UIViewController) {
            guard let container = root.view.superview ?? root.view.window else { return }

            let host = UIHostingController(rootView: latestOverlay)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.accessibilityViewIsModal = true
            host.view.accessibilityIdentifier = latestAccessibilityIdentifier

            // UIHostingController's root view does not support UIKit subviews.
            // Install the overlay beside it in their common container instead.
            container.addSubview(host.view)

            switch latestBounds {
            case .root:
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                    host.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                    host.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor)
                ])
            case .aboveKeyboard:
                root.view.keyboardLayoutGuide.followsUndockedKeyboard = true
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                    host.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                    host.view.bottomAnchor.constraint(equalTo: root.view.keyboardLayoutGuide.topAnchor)
                ])
            }
            self.host = host
        }

        func removeOverlay() {
            guard let host else { return }
            host.view.removeFromSuperview()
            self.host = nil
        }

        func stop() {
            wantsPresentation = false
            removeOverlay()
        }
    }
}
