import ImageIO
import Observation
import Photos
import SwiftUI
import UIKit

struct HermexPickedMedia: Sendable {
    let data: Data
    let filename: String
}

private enum HermexAttachmentPickerMode: Equatable {
    case menu
    case camera
    case photos
}

enum HermexAttachmentPickerPolicy {
    static let maximumBotAttachments = 8
    static let maximumSessionImages = 10
    static let maximumVisiblePhotos = 180

    static func availableCapacity(existingCount: Int, maximum: Int = maximumBotAttachments) -> Int {
        max(0, maximum - existingCount)
    }

    static func toggledSelection(_ selected: [String], id: String, capacity: Int) -> [String] {
        if selected.contains(id) {
            return selected.filter { $0 != id }
        }
        guard selected.count < max(0, capacity) else { return selected }
        return selected + [id]
    }

    static func visibleSelection(_ selected: [String], visibleIDs: Set<String>) -> [String] {
        selected.filter(visibleIDs.contains)
    }

    static func confirmationLabel(count: Int) -> String {
        count == 1 ? String(localized: "Add 1 Photo") : String(localized: "Add \(count) Photos")
    }
}

struct HermexAttachmentLifecycleFence {
    private(set) var activeID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeID = id
        return id
    }

    mutating func invalidate() {
        activeID = nil
    }

    mutating func consume(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

private enum HermexPhotoLibraryStatus: Equatable {
    case idle
    case loading
    case denied
    case empty
    case ready(limited: Bool)
}

@MainActor
@Observable
private final class HermexAttachmentPickerModel {
    private(set) var libraryStatus: HermexPhotoLibraryStatus = .idle
    private(set) var assets: [PHAsset] = []
    private(set) var selectedAssetIDs: [String] = []
    private(set) var isPreparing = false
    private(set) var hasLimitedAccess = false
    var errorMessage: String?

    var selectionCount: Int { selectedAssetIDs.count }

    func loadLibrary() async {
        libraryStatus = .loading
        var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else {
            assets = []
            selectedAssetIDs = []
            hasLimitedAccess = false
            libraryStatus = .denied
            return
        }
        hasLimitedAccess = authorization == .limited

        let options = PHFetchOptions()
        options.fetchLimit = HermexAttachmentPickerPolicy.maximumVisiblePhotos
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [PHAsset] = []
        loaded.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in loaded.append(asset) }
        selectedAssetIDs = HermexAttachmentPickerPolicy.visibleSelection(
            selectedAssetIDs,
            visibleIDs: Set(loaded.map(\.localIdentifier))
        )
        assets = loaded
        libraryStatus = loaded.isEmpty ? .empty : .ready(limited: authorization == .limited)
    }

    func toggle(_ asset: PHAsset, capacity: Int) {
        let nextIDs = HermexAttachmentPickerPolicy.toggledSelection(
            selectedAssetIDs,
            id: asset.localIdentifier,
            capacity: capacity
        )
        guard nextIDs != selectedAssetIDs else { return }
        selectedAssetIDs = nextIDs
    }

    func order(for asset: PHAsset) -> Int? {
        selectedAssetIDs.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    func clearSelection() {
        selectedAssetIDs = []
    }

    func prepareSelection() async throws -> [HermexPickedMedia] {
        guard !isPreparing else { return [] }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        let selectedAssets = selectedAssetIDs.compactMap { assetsByID[$0] }
        guard selectedAssets.count == selectedAssetIDs.count else {
            throw HermexAttachmentPickerError.unreadablePhoto
        }
        guard !selectedAssets.isEmpty else { return [] }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        var prepared: [HermexPickedMedia] = []
        prepared.reserveCapacity(selectedAssets.count)
        for asset in selectedAssets {
            try Task.checkCancellation()
            let picked = try await HermexPhotoLibraryImageLoader.pickedImage(for: asset)
            prepared.append(try await HermexAttachmentImageProcessor.prepare(
                data: picked.data,
                filename: picked.filename
            ))
        }
        selectedAssetIDs = []
        return prepared
    }
}

enum HermexPhotoLibraryImageLoader {
    static func pickedImage(for asset: PHAsset) async throws -> HermexPickedMedia {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo.jpg"
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        let request = HermexPhotoLibraryImageRequest()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(asset: asset, name: name, options: options, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
        }
    }
}

private final class HermexPhotoLibraryImageRequest: @unchecked Sendable {
    private let manager = PHImageManager.default()
    private let lock = NSLock()
    private var requestID = PHInvalidImageRequestID
    private var continuation: CheckedContinuation<HermexPickedMedia, Error>?
    private var isFinished = false

    func start(
        asset: PHAsset,
        name: String,
        options: PHImageRequestOptions,
        continuation: CheckedContinuation<HermexPickedMedia, Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let id = manager.requestImageDataAndOrientation(for: asset, options: options) { [weak self] data, _, _, info in
            let result: Result<HermexPickedMedia, Error>
            if let error = info?[PHImageErrorKey] as? Error {
                result = .failure(error)
            } else if (info?[PHImageCancelledKey] as? Bool) == true {
                result = .failure(CancellationError())
            } else if let data, !data.isEmpty {
                result = .success(.init(data: data, filename: name))
            } else {
                result = .failure(HermexAttachmentPickerError.unreadablePhoto)
            }
            self?.finish(result)
        }

        lock.lock()
        if isFinished {
            lock.unlock()
            manager.cancelImageRequest(id)
        } else {
            requestID = id
            lock.unlock()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()), cancellingRequest: true)
    }

    private func finish(_ result: Result<HermexPickedMedia, Error>, cancellingRequest: Bool = false) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let id = requestID
        requestID = PHInvalidImageRequestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if cancellingRequest, id != PHInvalidImageRequestID {
            manager.cancelImageRequest(id)
        }
        continuation?.resume(with: result)
    }
}

private enum HermexAttachmentPickerError: LocalizedError {
    case unreadablePhoto
    case photoTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            String(localized: "Could not read one of the selected photos.")
        case .photoTooLarge:
            String(localized: "One of the selected photos is too large to attach.")
        }
    }
}

enum HermexAttachmentImageProcessor {
    private static let maximumSourceBytes = 32 * 1_024 * 1_024
    private static let maximumOutputBytes = 8 * 1_024 * 1_024

    static func prepare(data: Data, filename: String) async throws -> HermexPickedMedia {
        let worker = Task.detached(priority: .userInitiated) {
            try prepareSynchronously(data: data, filename: filename)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func prepareSynchronously(data: Data, filename: String) throws -> HermexPickedMedia {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumSourceBytes else {
            throw HermexAttachmentPickerError.photoTooLarge
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw HermexAttachmentPickerError.unreadablePhoto
        }

        for edge in [3_072, 2_048, 1_536, 1_024] {
            try Task.checkCancellation()
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                throw HermexAttachmentPickerError.unreadablePhoto
            }
            let alpha = image.alphaInfo
            let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst
                || alpha == .premultipliedLast || alpha == .alphaOnly
            for quality in hasAlpha ? [1.0] : [0.86, 0.72, 0.58] {
                try Task.checkCancellation()
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    (hasAlpha ? "public.png" : "public.jpeg") as CFString,
                    1,
                    nil
                ) else {
                    throw HermexAttachmentPickerError.unreadablePhoto
                }
                let options: [CFString: Any] = hasAlpha
                    ? [:]
                    : [kCGImageDestinationLossyCompressionQuality: quality]
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw HermexAttachmentPickerError.unreadablePhoto
                }
                if output.length <= maximumOutputBytes {
                    let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    let safeBase = base.isEmpty ? "Photo" : base
                    let ext = hasAlpha ? "png" : "jpg"
                    return HermexPickedMedia(data: output as Data, filename: "\(safeBase).\(ext)")
                }
            }
        }
        throw HermexAttachmentPickerError.photoTooLarge
    }
}

enum HermexAttachmentPickerLayoutMetrics {
    static let menuMaximumWidth: CGFloat = 280
    static let menuLeadingPadding: CGFloat = 12

    static func menuWidth(containerWidth: CGFloat) -> CGFloat {
        min(menuMaximumWidth, max(1, containerWidth - (menuLeadingPadding * 2)))
    }
}

private struct HermexAttachmentPickerLayout {
    static let photoColumnCount = 3
    static let photoGridSpacing: CGFloat = 1.5
    static let expandedMaximumWidth: CGFloat = 620
    static let expandedMaximumHeight: CGFloat = 700

    let panelSize: CGSize
    let leadingPadding: CGFloat
    let bottomPadding: CGFloat

    static func resolve(containerSize: CGSize, mode: HermexAttachmentPickerMode) -> Self {
        let width = max(1, containerSize.width)
        let height = max(1, containerSize.height)
        let expanded = mode == .photos || mode == .camera
        let edgePadding: CGFloat = expanded && width >= 700 ? 28 : 12
        let panelWidth = expanded
            ? min(expandedMaximumWidth, max(1, width - (edgePadding * 2)))
            : HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: width)
        let leadingPadding = expanded
            ? (width - panelWidth) / 2
            : HermexAttachmentPickerLayoutMetrics.menuLeadingPadding
        let bottomPadding: CGFloat = expanded ? (width >= 700 ? 18 : 8) : 74
        let availableHeight = max(1, height - bottomPadding - 12)
        let preferredExpandedHeight = max(460, height * 0.66)
        let panelHeight = expanded
            ? min(expandedMaximumHeight, min(preferredExpandedHeight, availableHeight))
            : min(222, availableHeight)
        return Self(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            leadingPadding: leadingPadding,
            bottomPadding: bottomPadding
        )
    }

    static func photoCellSide(panelWidth: CGFloat) -> CGFloat {
        let spacing = photoGridSpacing * CGFloat(photoColumnCount - 1)
        return max(1, floor((panelWidth - spacing) / CGFloat(photoColumnCount)))
    }
}

/// Hosts the picker inside the app's existing window instead of presenting a
/// new controller. Its bottom follows the keyboard, so the composer remains
/// first responder and the picker always occupies the space above it.
enum HermexAttachmentPickerPresentation {
    static let overlayHostAccessibilityIdentifier = "HermexAttachmentPickerOverlay"
}

struct HermexKeyboardRetainingOverlay<Overlay: View>: UIViewControllerRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let isPresented: Bool
    private let overlay: () -> Overlay

    init(isPresented: Bool, @ViewBuilder overlay: @escaping () -> Overlay) {
        self.isPresented = isPresented
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
            anchor: controller,
            // This sibling host does not inherit SwiftUI's scene environment.
            // Forward it so camera/media work starts and stops with its owner.
            overlay: AnyView(overlay().environment(\.scenePhase, scenePhase))
        )
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        private var host: UIHostingController<AnyView>?
        private var wantsPresentation = false
        private var latestOverlay = AnyView(EmptyView())

        func update(isPresented: Bool, anchor: UIViewController, overlay: AnyView) {
            wantsPresentation = isPresented
            latestOverlay = overlay

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
            host.view.accessibilityIdentifier = HermexAttachmentPickerPresentation.overlayHostAccessibilityIdentifier

            // UIHostingController's root view does not support UIKit subviews.
            // Install the overlay beside it in their common container instead.
            container.addSubview(host.view)
            root.view.keyboardLayoutGuide.followsUndockedKeyboard = true
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                host.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: root.view.keyboardLayoutGuide.topAnchor)
            ])
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

/// The floating card's material and shadow, shared by the attachment picker
/// and the Bot send-choice card so the two read as one control.
struct HermexAttachmentPanelSurface: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    Color(.secondarySystemBackground)
                } else {
                    Rectangle().fill(.regularMaterial)
                }
            }
            .shadow(color: .black.opacity(0.24), radius: 27, y: 12)
            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
    }
}

struct HermexAttachmentPickerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = HermexAttachmentPickerModel()
    @StateObject private var cameraController = HermexAttachmentCameraController()
    @State private var mode = HermexAttachmentPickerMode.menu
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationFence = HermexAttachmentLifecycleFence()
    @State private var activePreparationID: UUID?
    @State private var transitionTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var isDismissing = false

    let imageCapacity: Int
    let onChooseFiles: () -> Void
    let onAdd: ([HermexPickedMedia]) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = HermexAttachmentPickerLayout.resolve(containerSize: proxy.size, mode: mode)
            ZStack(alignment: .bottomLeading) {
                Button(action: dismissPicker) {
                    Color.black.opacity(isVisible ? (mode == .menu ? 0.08 : 0.2) : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDismissing)
                .accessibilityLabel("Close attachment picker")

                panel(size: layout.panelSize)
                    .padding(.leading, layout.leadingPadding)
                    .padding(.bottom, layout.bottomPadding)
                    .opacity(isVisible ? 1 : 0)
                    .scaleEffect(isVisible ? 1 : 0.96, anchor: .bottomLeading)
                    .offset(y: isVisible ? 0 : 8)
                    .allowsHitTesting(!isDismissing)
            }
        }
        .presentationBackground(.clear)
        .interactiveDismissDisabled(isBusy || isDismissing)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismissPicker)
        .onAppear(perform: presentPicker)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                cancelPreparation()
            } else if mode == .photos, !isBusy {
                Task { await model.loadLibrary() }
            }
        }
        .onDisappear(perform: cancelLifecycle)
        .alert("Couldn’t add media", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func panel(size: CGSize) -> some View {
        ZStack {
            if mode == .menu { menuPanel.transition(.opacity) }
            if mode == .photos { photoPanel.transition(.opacity) }
            if mode == .camera {
                HermexAttachmentCameraPanel(
                    controller: cameraController,
                    isBusy: isBusy,
                    onBack: backToMenu,
                    onCaptured: addCameraCapture
                )
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .modifier(HermexAttachmentPanelSurface(reduceTransparency: reduceTransparency))
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 46, style: .continuous))
    }

    private var menuPanel: some View {
        VStack(spacing: 0) {
            menuRow(title: "Files", systemImage: "paperclip", enabled: !isBusy, action: chooseFiles)
            menuRow(title: "Camera", systemImage: "camera", enabled: imageChoicesAreEnabled) {
                animate { mode = .camera }
            }
            menuRow(title: "Photos", systemImage: "photo.on.rectangle.angled", enabled: imageChoicesAreEnabled) {
                animate { mode = .photos }
                Task { await model.loadLibrary() }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachment choices")
    }

    private func menuRow(
        title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HermexAttachmentMenuRow(title: Text(title), systemImage: systemImage, action: action)
            .disabled(!enabled)
    }

    private var photoPanel: some View {
        ZStack(alignment: .bottom) {
            photoGrid
            LinearGradient(
                colors: [.clear, .black.opacity(0.42)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            HStack(spacing: 12) {
                roundControl(
                    systemImage: "chevron.left",
                    label: "Back to attachment choices",
                    enabled: !isBusy,
                    action: backToMenu
                )
                Spacer()
                Button(action: addSelection) {
                    Group {
                        if model.isPreparing {
                            ProgressView().tint(.white)
                        } else {
                            Text(confirmLabel)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.selectionCount == 0 ? .white.opacity(0.58) : .white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 46)
                    .background(
                        model.selectionCount == 0 ? Color.black.opacity(0.54) : Color.accentColor,
                        in: Capsule()
                    )
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: confirmLabel)
                }
                .buttonStyle(.plain)
                .disabled(model.selectionCount == 0 || model.isPreparing || model.libraryStatus == .loading)
            }
            .padding(.horizontal, 25)
            .padding(.bottom, 25)

            if model.hasLimitedAccess {
                Button("Manage Access", action: openSettings)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.black.opacity(0.54), in: Capsule())
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder
    private var photoGrid: some View {
        switch model.libraryStatus {
        case .ready:
            GeometryReader { proxy in
                let spacing = HermexAttachmentPickerLayout.photoGridSpacing
                let side = HermexAttachmentPickerLayout.photoCellSide(panelWidth: proxy.size.width)
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(side), spacing: spacing),
                            count: HermexAttachmentPickerLayout.photoColumnCount
                        ),
                        spacing: spacing
                    ) {
                        ForEach(model.assets, id: \.localIdentifier) { asset in
                            photoCell(asset, side: side)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 104)
                }
                .scrollIndicators(.hidden)
                .accessibilityLabel("Recent photos")
            }
        case .loading, .idle:
            GeometryReader { proxy in
                let spacing = HermexAttachmentPickerLayout.photoGridSpacing
                let side = HermexAttachmentPickerLayout.photoCellSide(panelWidth: proxy.size.width)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(side), spacing: spacing),
                        count: HermexAttachmentPickerLayout.photoColumnCount
                    ),
                    spacing: spacing
                ) {
                    ForEach(0..<15, id: \.self) { _ in
                        Color(.secondarySystemBackground)
                            .frame(width: side, height: side)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading recent photos")
            }
        case .empty:
            placeholder {
                Image(systemName: "photo.on.rectangle").font(.title2)
                Text("No photos are available.")
            }
        case .denied:
            placeholder {
                Image(systemName: "photo.badge.exclamationmark").font(.title2)
                Text("Photo access is off").font(.headline)
                Text("Allow access in Settings to browse recent photos here.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func photoCell(_ asset: PHAsset, side: CGFloat) -> some View {
        let order = model.order(for: asset)
        return Button {
            animate { model.toggle(asset, capacity: imageCapacity) }
        } label: {
            HermexPhotoAssetThumbnail(asset: asset, targetDimension: side)
                .frame(width: side, height: side)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let order {
                        Text("\(order)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor, in: Circle())
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                            .padding(5)
                            .transition(.scale(scale: 0.45).combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: side, height: side)
        .accessibilityLabel(photoAccessibilityLabel(for: asset))
        .accessibilityValue(order.map { "Selected, number \($0)" } ?? "Not selected")
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
    }

    private func roundControl(
        systemImage: String,
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.45))
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.54), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
    }

    private var confirmLabel: String {
        model.selectionCount == 0
            ? String(localized: "Select Photos")
            : HermexAttachmentPickerPolicy.confirmationLabel(count: model.selectionCount)
    }

    private var isBusy: Bool {
        preparationTask != nil || model.isPreparing
    }

    private var imageChoicesAreEnabled: Bool {
        !isBusy && !isDismissing && imageCapacity > 0
    }

    private func chooseFiles() {
        guard !isBusy, !isDismissing else { return }
        onChooseFiles()
        animateDismissal()
    }

    private func backToMenu() {
        guard !isBusy else { return }
        model.clearSelection()
        animate { mode = .menu }
    }

    private func addCameraCapture(_ data: Data) {
        guard imageCapacity > 0, !data.isEmpty else { return }
        let filename = "camera_\(Int(Date().timeIntervalSince1970)).jpg"
        startPreparation {
            [try await HermexAttachmentImageProcessor.prepare(data: data, filename: filename)]
        }
    }

    private func addSelection() {
        guard case .ready = model.libraryStatus else { return }
        startPreparation {
            try await model.prepareSelection()
        }
    }

    private func startPreparation(
        _ operation: @escaping @MainActor () async throws -> [HermexPickedMedia]
    ) {
        guard preparationTask == nil, !model.isPreparing else { return }
        let operationID = preparationFence.begin()
        activePreparationID = operationID
        preparationTask = Task { @MainActor in
            defer {
                if activePreparationID == operationID {
                    preparationFence.invalidate()
                    activePreparationID = nil
                    preparationTask = nil
                }
            }
            do {
                let media = try await operation()
                try Task.checkCancellation()
                guard preparationFence.consume(operationID) else { return }
                guard !media.isEmpty else { return }
                onAdd(media)
                animateDismissal()
            } catch is CancellationError {
                return
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelPreparation() {
        preparationFence.invalidate()
        activePreparationID = nil
        preparationTask?.cancel()
        preparationTask = nil
    }

    private func cancelLifecycle() {
        cancelPreparation()
        transitionTask?.cancel()
        transitionTask = nil
    }

    private func presentPicker() {
        guard !isVisible else { return }
        guard !reduceMotion else {
            isVisible = true
            return
        }
        transitionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) {
                isVisible = true
            }
            transitionTask = nil
        }
    }

    private func animateDismissal() {
        guard !isDismissing else { return }
        isDismissing = true
        transitionTask?.cancel()

        guard !reduceMotion else {
            onDismiss()
            return
        }
        withAnimation(.easeInOut(duration: 0.16)) {
            isVisible = false
        }
        transitionTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    private func dismissPicker() {
        cancelPreparation()
        animateDismissal()
    }

    private func photoAccessibilityLabel(for asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return String(localized: "Photo") }
        return String(localized: "Photo from \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private func animate(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28), changes)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct HermexPhotoAssetThumbnail: View {
    @Environment(\.displayScale) private var displayScale
    private static let imageManager = PHCachingImageManager()

    let asset: PHAsset
    let targetDimension: CGFloat
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var requestToken: UUID?

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .onAppear(perform: requestImage)
        .onDisappear(perform: cancelRequest)
        .onChange(of: asset.localIdentifier) {
            cancelRequest()
            image = nil
            requestImage()
        }
    }

    private func requestImage() {
        guard requestID == PHInvalidImageRequestID else { return }
        let token = UUID()
        requestToken = token
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        let pixelDimension = max(1, ceil(targetDimension * displayScale))
        requestID = Self.imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: pixelDimension, height: pixelDimension),
            contentMode: .aspectFill,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            guard !cancelled, info?[PHImageErrorKey] == nil, let result else { return }
            Task { @MainActor in
                guard requestToken == token else { return }
                image = result
            }
        }
    }

    private func cancelRequest() {
        guard requestID != PHInvalidImageRequestID else { return }
        Self.imageManager.cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
        requestToken = nil
    }
}

/// One choice in a floating card: a circled icon and a title. Shared by the
/// attachment picker and the Bot send-choice card.
struct HermexAttachmentMenuRow: View {
    let title: Text
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.primary.opacity(0.08), in: Circle())
                title
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
