import SwiftUI
import UIKit

enum ImageLightboxContent {
    case loading(String)
    case image(UIImage, detail: String?)
    case failure(String)
}

enum ImageLightboxGesturePolicy {
    static let dismissDistance: CGFloat = 220
    static let dismissDistanceThreshold: CGFloat = 110
    static let dismissVelocityThreshold: CGFloat = 900

    static func shouldDismiss(translation: CGFloat, velocity: CGFloat) -> Bool {
        guard translation > 0 else { return false }
        return translation > dismissDistanceThreshold || velocity > dismissVelocityThreshold
    }

    static func canBeginDismiss(
        zoomScale: CGFloat,
        minimumZoomScale: CGFloat,
        velocity: CGPoint
    ) -> Bool {
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    static func maximumZoomScale(imagePixelWidth: CGFloat, fittedWidth: CGFloat) -> CGFloat {
        guard fittedWidth > 0, imagePixelWidth > 0 else { return 3 }
        return min(8, max(3, imagePixelWidth / fittedWidth))
    }

    static func doubleTapZoomScale(maximumZoomScale: CGFloat) -> CGFloat {
        min(maximumZoomScale, 2.5)
    }
}

struct ImageLightboxView<Actions: View>: View {
    let content: ImageLightboxContent
    let title: String
    let path: String?
    let imageAccessibilityLabel: String
    let page: ImageLightboxPage?
    let onRetry: () -> Void
    let actions: Actions

    @State private var ownShowsChrome = true
    @State private var isZoomed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    init(
        content: ImageLightboxContent,
        title: String,
        path: String?,
        imageAccessibilityLabel: String,
        page: ImageLightboxPage? = nil,
        onRetry: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.content = content
        self.title = title
        self.path = path
        self.imageAccessibilityLabel = imageAccessibilityLabel
        self.page = page
        self.onRetry = onRetry
        self.actions = actions()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            contentLayer

            chromeLayer
        }
        .preferredColorScheme(.dark)
    }

    private var showsChrome: Binding<Bool> {
        page?.showsChrome ?? $ownShowsChrome
    }

    private var positionText: String? {
        guard let position = page?.position, position.count > 1 else { return nil }
        return String(localized: "\(position.index + 1) of \(position.count)")
    }

    private var isChromeVisible: Bool {
        guard case .image = content, !voiceOverEnabled else { return true }
        return showsChrome.wrappedValue && !isZoomed
    }

    @ViewBuilder
    private var contentLayer: some View {
        switch content {
        case let .loading(message):
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(message)
                    .font(AppFont.footnote())
                    .foregroundStyle(.white.opacity(0.6))
            }

        case let .image(image, _):
            ZoomableImageView(
                image: image,
                reduceMotion: reduceMotion,
                onSingleTap: { showsChrome.wrappedValue.toggle() },
                onZoomChange: { zoomed in
                    guard zoomed != isZoomed else { return }
                    isZoomed = zoomed
                    page?.onZoomChange(zoomed)
                },
                onDismiss: { dismiss() }
            )
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel(imageAccessibilityLabel)
            .accessibilityValue(positionText ?? "")
            .accessibilityAddTraits(.isImage)
            .modifier(ImageLightboxStepAction(onStep: positionText == nil ? nil : page?.onStep))

        case let .failure(message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.6))
                Text(message)
                    .font(AppFont.subheadline())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(32)
        }
    }

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar

            Spacer(minLength: 0)

            if let path, !path.isEmpty {
                caption(path: path)
            }
        }
        .opacity(isChromeVisible ? 1 : 0)
        .allowsHitTesting(isChromeVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isChromeVisible)
    }

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)

                if let positionText {
                    Text(positionText)
                        .font(AppFont.caption())
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 104)

            HStack(spacing: 10) {
                ImageLightboxActionButton(
                    systemImage: "xmark",
                    accessibilityLabel: String(localized: "Done"),
                    action: { dismiss() }
                )

                Spacer(minLength: 0)

                actions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func caption(path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(AppFont.caption2())
                .fontDesign(.monospaced)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .truncationMode(.head)

            if case let .image(_, detail) = content, let detail {
                Text(detail)
                    .font(AppFont.caption2())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

extension ImageLightboxView where Actions == EmptyView {
    init(
        content: ImageLightboxContent,
        title: String,
        path: String?,
        imageAccessibilityLabel: String,
        page: ImageLightboxPage? = nil,
        onRetry: @escaping () -> Void
    ) {
        self.init(
            content: content,
            title: title,
            path: path,
            imageAccessibilityLabel: imageAccessibilityLabel,
            page: page,
            onRetry: onRetry,
            actions: { EmptyView() }
        )
    }
}

private struct ImageLightboxStepAction: ViewModifier {
    let onStep: ((Int) -> Void)?

    func body(content: Content) -> some View {
        if let onStep {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(1)
                case .decrement: onStep(-1)
                @unknown default: break
                }
            }
        } else {
            content
        }
    }
}

struct ImageLightboxActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let isDisabled: Bool
    let action: () -> Void

    init(
        systemImage: String,
        accessibilityLabel: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppFont.body(weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .adaptiveGlass(isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    let onSingleTap: () -> Void
    let onZoomChange: (Bool) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomableScrollView {
        let coordinator = context.coordinator

        let scrollView = ZoomableScrollView()
        scrollView.delegate = coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        coordinator.scrollView = scrollView
        coordinator.imageView = imageView
        scrollView.onLayoutSizeChange = { [weak coordinator] size in
            coordinator?.layoutImage(in: size)
        }

        let doubleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        let dismissPan = UIPanGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = coordinator
        scrollView.addGestureRecognizer(dismissPan)
        coordinator.dismissPan = dismissPan

        return scrollView
    }

    func updateUIView(_ scrollView: ZoomableScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.reduceMotion = reduceMotion
        coordinator.onSingleTap = onSingleTap
        coordinator.onZoomChange = onZoomChange
        coordinator.onDismiss = onDismiss

        if coordinator.imageView?.image !== image {
            coordinator.imageView?.image = image
            coordinator.layoutImage(in: scrollView.bounds.size)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: ZoomableScrollView?
        weak var imageView: UIImageView?
        weak var dismissPan: UIPanGestureRecognizer?

        var reduceMotion = false
        var onSingleTap: () -> Void = {}
        var onZoomChange: (Bool) -> Void = { _ in }
        var onDismiss: () -> Void = {}

        private var isDismissing = false

        func layoutImage(in size: CGSize) {
            guard let scrollView,
                  let imageView,
                  let image = imageView.image,
                  size.width > 0, size.height > 0,
                  image.size.width > 0, image.size.height > 0
            else { return }

            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let fitted = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )

            scrollView.zoomScale = 1
            imageView.transform = .identity
            imageView.alpha = 1
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            scrollView.maximumZoomScale = ImageLightboxGesturePolicy.maximumZoomScale(
                imagePixelWidth: image.size.width * image.scale,
                fittedWidth: fitted.width
            )
            centerContent()
            onZoomChange(false)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            onZoomChange(scale > scrollView.minimumZoomScale + 0.01)
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            let animated = !reduceMotion

            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
                onZoomChange(false)
                return
            }

            let target = ImageLightboxGesturePolicy.doubleTapZoomScale(
                maximumZoomScale: scrollView.maximumZoomScale
            )
            scrollView.zoom(
                to: zoomRect(for: target, around: gesture.location(in: imageView)),
                animated: animated
            )
            onZoomChange(true)
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            let translation = gesture.translation(in: scrollView)
            let velocity = gesture.velocity(in: scrollView)

            switch gesture.state {
            case .changed:
                let progress = min(1, max(0, translation.y / ImageLightboxGesturePolicy.dismissDistance))
                let shrink = 1 - progress * 0.15
                imageView.transform = CGAffineTransform(
                    translationX: translation.x,
                    y: max(0, translation.y)
                ).scaledBy(x: shrink, y: shrink)

            case .ended where ImageLightboxGesturePolicy.shouldDismiss(
                translation: translation.y,
                velocity: velocity.y
            ):
                dismiss(from: translation)

            case .ended, .cancelled, .failed:
                restoreImagePosition()

            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let scrollView
            else { return true }

            return ImageLightboxGesturePolicy.canBeginDismiss(
                zoomScale: scrollView.zoomScale,
                minimumZoomScale: scrollView.minimumZoomScale,
                velocity: pan.velocity(in: scrollView)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === dismissPan else { return true }
            return other === scrollView?.panGestureRecognizer
        }

        private func centerContent() {
            guard let scrollView else { return }
            let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: vertical,
                left: horizontal,
                bottom: vertical,
                right: horizontal
            )
        }

        private func zoomRect(for scale: CGFloat, around point: CGPoint) -> CGRect {
            guard let scrollView, scale > 0 else { return .zero }
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            return CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        private func dismiss(from translation: CGPoint) {
            guard !isDismissing else { return }
            isDismissing = true

            guard !reduceMotion, let imageView, let scrollView else {
                onDismiss()
                return
            }

            let offScreen = max(scrollView.bounds.height, 480)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn]) {
                imageView.transform = CGAffineTransform(translationX: translation.x, y: offScreen)
                    .scaledBy(x: 0.7, y: 0.7)
                imageView.alpha = 0
            } completion: { [weak self] _ in
                self?.onDismiss()
            }
        }

        private func restoreImagePosition() {
            guard let imageView else { return }

            if let scrollView, scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                return
            }

            guard !reduceMotion else {
                imageView.transform = .identity
                imageView.alpha = 1
                return
            }

            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.85,
                initialSpringVelocity: 0
            ) {
                imageView.transform = .identity
                imageView.alpha = 1
            }
        }
    }
}

final class ZoomableScrollView: UIScrollView {
    var onLayoutSizeChange: ((CGSize) -> Void)?

    private var lastLaidOutSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0, bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size
        onLayoutSizeChange?(bounds.size)
    }
}
