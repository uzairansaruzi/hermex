@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

enum HermexAttachmentCameraStatus: Equatable {
    case idle
    case requestingPermission
    case configuring
    case ready
    case capturing
    case denied
    case restricted
    case unavailable
    case interrupted
    case failed(String)
}
enum HermexAttachmentCameraPermissionPolicy {
    static func status(for authorization: AVAuthorizationStatus) -> HermexAttachmentCameraStatus {
        switch authorization {
        case .authorized: .configuring
        case .notDetermined: .requestingPermission
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
}

final class HermexAttachmentCameraController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var status: HermexAttachmentCameraStatus = .idle
    @Published private(set) var captureDevice: AVCaptureDevice?
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var captureErrorMessage: String?

    let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.hermex.attachment-camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var activeToken: UUID?
    private var captureRotationAngle: CGFloat = 0
    private var captureCompletion: (@MainActor (Result<Data, Error>) -> Void)?
    private var captureFence = HermexAttachmentLifecycleFence()
    private var captureGenerationsBySettingsID: [Int64: UUID] = [:]
    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeSessionLifecycle()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    @MainActor
    func start() {
        let token = UUID()
        publish(status: HermexAttachmentCameraPermissionPolicy.status(
            for: AVCaptureDevice.authorizationStatus(for: .video)
        ))
        sessionQueue.async { [weak self] in self?.activeToken = token }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(token: token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart(token: token)
                } else {
                    self.publish(status: .denied, ifActive: token)
                }
            }
        case .denied:
            publish(status: .denied, ifActive: token)
        case .restricted:
            publish(status: .restricted, ifActive: token)
        @unknown default:
            publish(status: .unavailable, ifActive: token)
        }
    }

    @MainActor
    func stop() {
        captureFence.invalidate()
        captureCompletion = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.activeToken = nil
            self.captureGenerationsBySettingsID.removeAll()
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        publish(status: .idle)
        publishCaptureError(nil)
    }

    @MainActor
    func setCaptureRotationAngle(_ angle: CGFloat) {
        sessionQueue.async { [weak self] in self?.captureRotationAngle = angle }
    }

    /// Detaching a preview layer makes AVCaptureSession rebuild its graph and
    /// wait for it to finish, which takes seconds on device. Run it on the
    /// session queue so the main thread never blocks on it.
    func detachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            layer.session = nil
        }
    }

    @MainActor
    func capturePhoto(completion: @MainActor @escaping (Result<Data, Error>) -> Void) {
        guard status == .ready else { return }
        status = .capturing
        captureErrorMessage = nil
        let captureGeneration = captureFence.begin()
        captureCompletion = completion

        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else {
                self?.completeCapture(
                    .failure(HermexAttachmentCameraError.sessionUnavailable),
                    generation: captureGeneration
                )
                return
            }

            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [
                    AVVideoCodecKey: AVVideoCodecType.jpeg
                ])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .balanced

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(self.captureRotationAngle) {
                connection.videoRotationAngle = self.captureRotationAngle
            }
            self.captureGenerationsBySettingsID[settings.uniqueID] = captureGeneration
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    @MainActor
    func switchCamera() {
        guard status == .ready else { return }
        status = .configuring
        sessionQueue.async { [weak self] in
            guard let self, let token = self.activeToken else { return }
            let nextPosition: AVCaptureDevice.Position = self.videoInput?.device.position == .front
                ? .back
                : .front
            guard let device = Self.camera(position: nextPosition) else {
                self.publish(status: .ready, ifActive: token)
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                if let current = self.videoInput {
                    self.session.removeInput(current)
                }
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                    self.publishDevice(device, ifActive: token)
                } else if let current = self.videoInput, self.session.canAddInput(current) {
                    self.session.addInput(current)
                }
                self.session.commitConfiguration()
                self.publish(status: .ready, ifActive: token)
            } catch {
                self.publish(status: .failed("Camera switching failed."), ifActive: token)
            }
        }
    }

    private func configureAndStart(token: UUID) {
        publish(status: .configuring, ifActive: token)
        sessionQueue.async { [weak self] in
            guard let self, self.activeToken == token else { return }
            do {
                if !self.isConfigured {
                    try self.configureSession(token: token)
                }
                guard self.activeToken == token else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.publish(status: .ready, ifActive: token)
            } catch HermexAttachmentCameraError.cameraUnavailable {
                self.publish(status: .unavailable, ifActive: token)
            } catch {
                self.publish(status: .failed("Camera could not start."), ifActive: token)
            }
        }
    }

    private func configureSession(token: UUID) throws {
        guard let device = Self.camera(position: .back) else {
            throw HermexAttachmentCameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw HermexAttachmentCameraError.sessionUnavailable
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .balanced
        videoInput = input
        isConfigured = true
        publishDevice(device, ifActive: token)
    }

    private static func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    guard let token = self.activeToken else { return }
                    self.publish(status: .interrupted, ifActive: token)
                }
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    guard let token = self.activeToken else { return }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.publish(status: .ready, ifActive: token)
                }
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                self.sessionQueue.async {
                    guard let token = self.activeToken else { return }
                    if error?.code == .mediaServicesWereReset {
                        if !self.session.isRunning { self.session.startRunning() }
                        self.publish(status: .ready, ifActive: token)
                    } else {
                        self.publish(status: .failed("Camera became unavailable."), ifActive: token)
                    }
                }
            }
        ]
    }

    private func publish(status: HermexAttachmentCameraStatus, ifActive token: UUID? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let token {
                self.sessionQueue.async { [weak self] in
                    guard let self, self.activeToken == token else { return }
                    DispatchQueue.main.async { [weak self] in self?.status = status }
                }
            } else {
                self.status = status
            }
        }
    }

    private func publishDevice(_ device: AVCaptureDevice, ifActive token: UUID) {
        sessionQueue.async { [weak self] in
            guard let self, self.activeToken == token else { return }
            DispatchQueue.main.async { [weak self] in
                self?.captureDevice = device
                self?.cameraPosition = device.position
            }
        }
    }

    private func publishCaptureError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in self?.captureErrorMessage = message }
    }

    private func completeCapture(_ result: Result<Data, Error>, generation: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.captureFence.consume(generation) else { return }
            if self.status == .capturing {
                self.status = .ready
            }
            if case .failure = result {
                self.captureErrorMessage = "Photo capture failed. Try again."
            }
            let completion = self.captureCompletion
            self.captureCompletion = nil
            completion?(result)
        }
    }
}

extension HermexAttachmentCameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<Data, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation(), !data.isEmpty {
            result = .success(data)
        } else {
            result = .failure(HermexAttachmentCameraError.missingPhotoData)
        }
        let settingsID = photo.resolvedSettings.uniqueID
        sessionQueue.async { [weak self] in
            guard let self,
                  let generation = self.captureGenerationsBySettingsID.removeValue(forKey: settingsID)
            else { return }
            self.completeCapture(result, generation: generation)
        }
    }
}

private enum HermexAttachmentCameraError: Error {
    case cameraUnavailable
    case sessionUnavailable
    case missingPhotoData
}

struct HermexAttachmentCameraPanel: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: HermexAttachmentCameraController
    let isBusy: Bool
    let onBack: () -> Void
    let onCaptured: (Data) -> Void

    var body: some View {
        ZStack {
            Color.black
            if let device = controller.captureDevice {
                HermexAttachmentCameraPreview(
                    session: controller.session,
                    device: device,
                    onCaptureAngleChanged: controller.setCaptureRotationAngle,
                    detachPreviewLayer: controller.detachPreviewLayer
                )
                .transition(.opacity)
            }

            statusOverlay

            LinearGradient(
                colors: [.clear, .black.opacity(0.48)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            controls
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.captureDevice != nil)
        .onAppear {
            if scenePhase == .active { controller.start() }
        }
        .onDisappear { controller.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.start()
            } else {
                controller.stop()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera attachment picker")
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch controller.status {
        case .idle, .requestingPermission, .configuring:
            ProgressView()
                .tint(.white)
                .controlSize(.large)
                .accessibilityLabel("Starting camera")
        case .denied, .restricted:
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.title)
                Text("Camera access is off")
                    .font(.headline)
                Text("Allow camera access in Settings to take a photo for this chat.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
            }
            .foregroundStyle(.white)
            .padding(32)
        case .unavailable:
            cameraMessage("Camera unavailable", detail: "This device does not have an available camera.")
        case .interrupted:
            cameraMessage("Camera paused", detail: "The camera will resume when it is available again.")
        case .failed(let message):
            cameraMessage("Camera unavailable", detail: message)
        case .ready, .capturing:
            if let message = controller.captureErrorMessage {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(.bottom, 108)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .center) {
            cameraControl(
                systemImage: "chevron.left",
                label: "Back to attachment choices",
                enabled: !isBusy,
                action: onBack
            )

            Spacer()

            Button {
                controller.capturePhoto { result in
                    if case .success(let data) = result { onCaptured(data) }
                }
            } label: {
                ZStack {
                    Circle().fill(.white.opacity(controller.status == .ready ? 1 : 0.48))
                    Circle().stroke(.white.opacity(0.72), lineWidth: 4).padding(-7)
                    if controller.status == .capturing {
                        ProgressView().tint(.black)
                    }
                }
                .frame(width: 66, height: 66)
            }
            .buttonStyle(.plain)
            .disabled(controller.status != .ready || isBusy)
            .accessibilityLabel("Take photo")

            Spacer()

            cameraControl(
                systemImage: "arrow.triangle.2.circlepath.camera",
                label: "Switch camera",
                enabled: controller.status == .ready && !isBusy,
                action: controller.switchCamera
            )
        }
        .padding(.horizontal, 25)
        .padding(.bottom, 25)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func cameraControl(
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

    private func cameraMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.title)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct HermexAttachmentCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice
    let onCaptureAngleChanged: (CGFloat) -> Void
    let detachPreviewLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> HermexAttachmentCameraPreviewView {
        let view = HermexAttachmentCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: HermexAttachmentCameraPreviewView, context: Context) {
        view.detachPreviewLayer = detachPreviewLayer
        view.update(device: device, onCaptureAngleChanged: onCaptureAngleChanged)
    }

    static func dismantleUIView(_ view: HermexAttachmentCameraPreviewView, coordinator: Void) {
        view.teardown()
        if let detach = view.detachPreviewLayer {
            detach(view.previewLayer)
        } else {
            view.previewLayer.session = nil
        }
    }
}

/// KVO callbacks may arrive off-main, but this view is only touched after hopping to main.
private final class HermexAttachmentCameraPreviewView: UIView, @unchecked Sendable {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("Camera preview must use AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    private var configuredDeviceID: String?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?
    private var captureAngleChanged: ((CGFloat) -> Void)?
    var detachPreviewLayer: ((AVCaptureVideoPreviewLayer) -> Void)?

    func update(device: AVCaptureDevice, onCaptureAngleChanged: @escaping (CGFloat) -> Void) {
        captureAngleChanged = onCaptureAngleChanged
        guard configuredDeviceID != device.uniqueID else { return }
        teardown()
        configuredDeviceID = device.uniqueID

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        previewObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            guard let view = self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { [weak view] in
                guard let view, let connection = view.previewLayer.connection else { return }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
        captureObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            guard let view = self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            DispatchQueue.main.async { [weak view] in view?.captureAngleChanged?(angle) }
        }
    }

    func teardown() {
        previewObservation?.invalidate()
        captureObservation?.invalidate()
        previewObservation = nil
        captureObservation = nil
        rotationCoordinator = nil
        configuredDeviceID = nil
    }
}
