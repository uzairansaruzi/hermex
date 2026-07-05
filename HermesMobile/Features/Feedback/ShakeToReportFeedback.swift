import SwiftUI
import UIKit

struct FeedbackDraft: Identifiable, Equatable {
    let id = UUID()
    let screenName: String
    let screenshot: UIImage?
    let capturedAt: Date
}

struct FeedbackResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let feedback: FeedbackItem?

    struct FeedbackItem: Decodable, Equatable, Sendable {
        let id: String
        let status: String
        let createdAt: String
    }
}

struct FeedbackSubmission: Sendable {
    let text: String
    let app: FeedbackAppMetadata
    let device: FeedbackDeviceMetadata
    let screen: FeedbackScreenMetadata
    let screenshot: FeedbackScreenshotPayload?
    let annotation: FeedbackAnnotationPayload?
}

struct FeedbackAppMetadata: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let build: String
    let bundleId: String
    let platform: String

    static var current: FeedbackAppMetadata {
        let bundle = Bundle.main
        return FeedbackAppMetadata(
            id: "zora-ios",
            name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Zora",
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleId: bundle.bundleIdentifier ?? "unknown",
            platform: "ios"
        )
    }
}

struct FeedbackDeviceMetadata: Codable, Equatable, Sendable {
    let model: String
    let systemName: String
    let systemVersion: String
    let idiom: String

    @MainActor
    static var current: FeedbackDeviceMetadata {
        let device = UIDevice.current
        return FeedbackDeviceMetadata(
            model: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            idiom: device.userInterfaceIdiom.feedbackDescription
        )
    }
}

struct FeedbackScreenMetadata: Codable, Equatable, Sendable {
    let name: String
}

struct FeedbackScreenshotPayload: Codable, Equatable, Sendable {
    let mimeType: String
    let data: String
    let width: Int
    let height: Int

    static func make(from image: UIImage?, compressionQuality: CGFloat = 0.58) -> FeedbackScreenshotPayload? {
        guard let image,
              let jpegData = image.jpegData(compressionQuality: compressionQuality) else { return nil }

        return FeedbackScreenshotPayload(
            mimeType: "image/jpeg",
            data: jpegData.base64EncodedString(),
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )
    }
}

struct FeedbackAnnotationPayload: Codable, Equatable, Sendable {
    let type = "rectangle-markup"
    let rectangles: [FeedbackAnnotationRectangle]
}

struct FeedbackAnnotationRectangle: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(id: UUID = UUID(), x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.id = id
        self.x = x.clamped(to: 0 ... 1)
        self.y = y.clamped(to: 0 ... 1)
        self.width = width.clamped(to: 0 ... 1)
        self.height = height.clamped(to: 0 ... 1)
    }

    init(start: CGPoint, end: CGPoint, canvasSize: CGSize) {
        let canvasWidth = max(canvasSize.width, 1)
        let canvasHeight = max(canvasSize.height, 1)
        let clampedStart = start.clamped(to: canvasSize)
        let clampedEnd = end.clamped(to: canvasSize)
        let minX = min(clampedStart.x, clampedEnd.x)
        let minY = min(clampedStart.y, clampedEnd.y)

        self.init(
            x: minX / canvasWidth,
            y: minY / canvasHeight,
            width: abs(clampedEnd.x - clampedStart.x) / canvasWidth,
            height: abs(clampedEnd.y - clampedStart.y) / canvasHeight
        )
    }

    var isVisibleMark: Bool {
        max(width, height) > 0.024 && min(width, height) > 0.008
    }

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

struct FeedbackRequestPayload: Encodable, Equatable, Sendable {
    let text: String
    let app: FeedbackAppMetadata
    let device: FeedbackDeviceMetadata
    let screen: FeedbackScreenMetadata
    let screenshot: FeedbackScreenshotPayload?
    let annotation: FeedbackAnnotationPayload?

    init(submission: FeedbackSubmission) {
        text = submission.text
        app = submission.app
        device = submission.device
        screen = submission.screen
        screenshot = submission.screenshot
        annotation = submission.annotation
    }
}

struct FeedbackClient: Sendable {
    typealias Submit = @Sendable (FeedbackSubmission) async throws -> FeedbackResponse

    static let defaultBaseURL = URL(string: "https://zora-feedback-inbox.sourcebottle.workers.dev")!

    let submit: Submit

    init(submit: @escaping Submit) {
        self.submit = submit
    }

    static func live(baseURL: URL = defaultBaseURL, session: URLSession = .shared) -> FeedbackClient {
        FeedbackClient { submission in
            var request = URLRequest(url: baseURL.appendingPathComponent("api/feedback"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Zora iOS feedback", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(FeedbackRequestPayload(submission: submission))

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FeedbackClientError.invalidResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw FeedbackClientError.requestFailed(statusCode: httpResponse.statusCode)
            }

            return try JSONDecoder().decode(FeedbackResponse.self, from: data)
        }
    }

    static let mockSuccess = FeedbackClient { _ in
        FeedbackResponse(
            ok: true,
            feedback: FeedbackResponse.FeedbackItem(id: "mock-feedback", status: "new", createdAt: "2026-07-03T00:00:00.000Z")
        )
    }

    static func configuredFromProcess() -> FeedbackClient {
        if ProcessInfo.processInfo.arguments.contains("-ZoraMockFeedbackClient") {
            return .mockSuccess
        }
        return .live()
    }
}

enum FeedbackClientError: LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "The feedback service returned an invalid response.")
        case .requestFailed:
            return String(localized: "The feedback service did not accept the report.")
        }
    }
}

private struct ShakeToReportFeedbackModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    let screenName: String
    let client: FeedbackClient
    let screenshotProvider: @MainActor () -> UIImage?

    @State private var presentation = FeedbackShakePresentationState()
    @State private var didPresentLaunchFeedbackPrompt = false

    func body(content: Content) -> some View {
        content
            .background {
                ShakeDetectorView(
                    responderRefreshID: presentation.responderRefreshID,
                    isSuspended: presentation.draft != nil
                ) {
                    presentFeedbackDraft()
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .sheet(item: $presentation.draft, onDismiss: {
                presentation.feedbackSheetDismissed()
            }) { draft in
                FeedbackReportSheet(draft: draft, feedbackClient: client)
            }
            .task {
                presentLaunchFeedbackPromptIfNeeded()
                presentation.refreshResponderIfIdle()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                presentation.refreshResponderIfIdle()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                presentation.refreshResponderIfIdle()
            }
    }

    private func presentFeedbackDraft() {
        presentation.present(FeedbackDraft(screenName: screenName, screenshot: screenshotProvider(), capturedAt: Date()))
    }

    private func presentLaunchFeedbackPromptIfNeeded() {
        guard !didPresentLaunchFeedbackPrompt,
              ProcessInfo.processInfo.arguments.contains("-ZoraShowFeedbackPrompt") else { return }
        didPresentLaunchFeedbackPrompt = true
        presentFeedbackDraft()
    }
}

struct FeedbackShakePresentationState: Equatable {
    var draft: FeedbackDraft?
    private(set) var responderRefreshID = UUID()

    mutating func present(_ draft: FeedbackDraft) {
        self.draft = draft
    }

    mutating func feedbackSheetDismissed() {
        draft = nil
        refreshResponder()
    }

    mutating func refreshResponderIfIdle() {
        guard draft == nil else { return }
        refreshResponder()
    }

    private mutating func refreshResponder() {
        responderRefreshID = UUID()
    }
}

extension View {
    func shakeToReportFeedback(
        screenName: String,
        client: FeedbackClient = .configuredFromProcess(),
        screenshotProvider: @escaping @MainActor () -> UIImage? = FeedbackScreenshotCapture.captureKeyWindow
    ) -> some View {
        modifier(ShakeToReportFeedbackModifier(screenName: screenName, client: client, screenshotProvider: screenshotProvider))
    }
}

private struct ShakeDetectorView: UIViewControllerRepresentable {
    let responderRefreshID: UUID
    let isSuspended: Bool
    let onShake: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(responderRefreshID: responderRefreshID)
    }

    func makeUIViewController(context: Context) -> ShakeDetectorViewController {
        let viewController = ShakeDetectorViewController()
        viewController.onShake = onShake
        viewController.isSuspended = isSuspended
        return viewController
    }

    func updateUIViewController(_ uiViewController: ShakeDetectorViewController, context: Context) {
        uiViewController.onShake = onShake
        uiViewController.isSuspended = isSuspended
        guard !isSuspended else { return }
        if context.coordinator.responderRefreshID != responderRefreshID {
            context.coordinator.responderRefreshID = responderRefreshID
            uiViewController.refreshFirstResponder()
        }
    }

    final class Coordinator {
        var responderRefreshID: UUID

        init(responderRefreshID: UUID) {
            self.responderRefreshID = responderRefreshID
        }
    }
}

private final class ShakeDetectorViewController: UIViewController {
    var onShake: (@MainActor () -> Void)?
    var isSuspended = false {
        didSet {
            if oldValue, !isSuspended {
                refreshFirstResponder()
            }
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshFirstResponder()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        refreshFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        Task { @MainActor in
            onShake?()
            refreshFirstResponder()
        }
    }

    func refreshFirstResponder() {
        guard !isSuspended else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isSuspended, self.view.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
}

@MainActor
enum FeedbackScreenshotCapture {
    static func captureKeyWindow() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) else { return nil }

        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

private struct FeedbackReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draft: FeedbackDraft
    let feedbackClient: FeedbackClient

    @State private var message = ""
    @State private var annotations: [FeedbackAnnotationRectangle] = []
    @State private var status: SubmissionStatus = .editing
    @FocusState private var isMessageFocused: Bool

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        switch status {
        case .editing, .failed:
            return !trimmedMessage.isEmpty
        case .submitting, .submitted:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ZoraBrandBackground()
                    .ignoresSafeArea()

                content
            }
            .navigationTitle("Report an issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(ZoraBrand.secondaryForeground)
                        .accessibilityIdentifier("feedback.report.closeButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { submit() }
                        .disabled(!canSubmit)
                        .foregroundStyle(canSubmit ? ZoraBrand.foreground : ZoraBrand.tertiaryForeground)
                        .accessibilityIdentifier("feedback.report.navigationSubmitButton")
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(ZoraBrand.foreground)
        .accessibilityIdentifier("feedback.report.sheet")
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .submitted:
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(ZoraBrand.success)
                Text("Report sent")
                    .font(AppFont.title(weight: .semibold))
                    .foregroundStyle(ZoraBrand.foreground)
                    .accessibilityIdentifier("feedback.report.successMessage")
                Text("Thanks — the screenshot and notes were sent to the private Zora feedback queue.")
                    .font(AppFont.callout())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZoraBrand.secondaryForeground)
                    .frame(maxWidth: 320)
                Button("Done") { dismiss() }
                    .buttonStyle(ZoraPrimaryButtonStyle())
                    .accessibilityIdentifier("feedback.report.doneButton")
            }
            .padding(ZoraSpacing.section)
            .zoraSurface(.card, cornerRadius: ZoraRadius.sheet, showsShadow: true)
            .padding(.horizontal, ZoraSpacing.screenInset)
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Shake Report", systemImage: "iphone.radiowaves.left.and.right")
                                .font(AppFont.caption(weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(ZoraBrand.secondaryForeground)
                            Text("Mark the problem area and describe what happened.")
                                .font(AppFont.title2(weight: .semibold))
                                .foregroundStyle(ZoraBrand.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Screen: \(draft.screenName)")
                                .font(AppFont.caption())
                                .foregroundStyle(ZoraBrand.secondaryForeground)
                                .accessibilityIdentifier("feedback.report.screenName")
                        }

                        FeedbackScreenshotMarkupView(screenshot: draft.screenshot, annotations: $annotations)

                        HStack(spacing: 12) {
                            Button {
                                annotations.removeAll()
                            } label: {
                                Label("Clear marks", systemImage: "eraser")
                            }
                            .buttonStyle(ZoraSecondaryButtonStyle())
                            .disabled(annotations.isEmpty)
                            .accessibilityIdentifier("feedback.report.clearMarksButton")

                            Spacer(minLength: 0)

                            Text("\(annotations.count) \(annotations.count == 1 ? "mark" : "marks")")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(ZoraBrand.secondaryForeground)
                                .accessibilityIdentifier("feedback.report.markCount")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Notes")
                                .font(AppFont.headline())
                                .foregroundStyle(ZoraBrand.foreground)

                            TextEditor(text: $message)
                                .font(AppFont.body())
                                .foregroundStyle(ZoraBrand.foreground)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 138)
                                .padding(ZoraSpacing.sm)
                                .background(ZoraSurfaceLevel.strong.fill(reduceTransparency: false), in: RoundedRectangle(cornerRadius: ZoraRadius.card, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: ZoraRadius.card, style: .continuous)
                                        .stroke(ZoraBrand.surfaceHairlineStrong, lineWidth: 1)
                                }
                                .focused($isMessageFocused)
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        isMessageFocused = true
                                        scrollMessageIntoView(proxy)
                                    }
                                )
                                .accessibilityLabel("Feedback notes")
                                .accessibilityIdentifier("feedback.report.textEditor")
                        }
                        .id(ReportScrollTarget.message)

                        if case let .failed(message) = status {
                            Text(message)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(ZoraBrand.ink)
                                .padding(ZoraSpacing.sm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ZoraBrand.danger, in: RoundedRectangle(cornerRadius: ZoraRadius.small, style: .continuous))
                                .accessibilityIdentifier("feedback.report.errorMessage")
                        }

                        Button { submit() } label: {
                            HStack(spacing: 10) {
                                if status.isSubmitting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text(status.isSubmitting ? "Sending" : "Send report")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(ZoraPrimaryButtonStyle())
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("feedback.report.submitButton")
                    }
                    .padding(.horizontal, ZoraSpacing.screenInset)
                    .padding(.top, ZoraSpacing.section)
                    .padding(.bottom, ZoraSpacing.large)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isMessageFocused) { _, focused in
                    if focused { scrollMessageIntoView(proxy) }
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        status = .submitting

        Task {
            do {
                let submission = await FeedbackSubmission(
                    text: trimmedMessage,
                    app: .current,
                    device: .current,
                    screen: FeedbackScreenMetadata(name: draft.screenName),
                    screenshot: FeedbackScreenshotPayload.make(from: draft.screenshot),
                    annotation: annotations.isEmpty ? nil : FeedbackAnnotationPayload(rectangles: annotations)
                )
                _ = try await feedbackClient.submit(submission)
                await MainActor.run { status = .submitted }
            } catch {
                await MainActor.run { status = .failed(error.localizedDescription) }
            }
        }
    }

    private func scrollMessageIntoView(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.24)) {
            proxy.scrollTo(ReportScrollTarget.message, anchor: .center)
        }
    }

    private enum SubmissionStatus: Equatable {
        case editing
        case submitting
        case submitted
        case failed(String)

        var isSubmitting: Bool {
            if case .submitting = self { return true }
            return false
        }
    }

    private enum ReportScrollTarget: Hashable {
        case message
    }
}

private struct FeedbackScreenshotMarkupView: View {
    let screenshot: UIImage?
    @Binding var annotations: [FeedbackAnnotationRectangle]

    @State private var activeAnnotation: FeedbackAnnotationRectangle?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                if let screenshot {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.18))
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: "iphone")
                                    .font(.system(size: 38, weight: .light))
                                Text("Screenshot unavailable")
                                    .font(.callout.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                }

                ForEach(annotations) { annotation in
                    rectangle(for: annotation, in: size)
                }

                if let activeAnnotation {
                    rectangle(for: activeAnnotation, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        activeAnnotation = FeedbackAnnotationRectangle(start: value.startLocation, end: value.location, canvasSize: size)
                    }
                    .onEnded { value in
                        let annotation = FeedbackAnnotationRectangle(start: value.startLocation, end: value.location, canvasSize: size)
                        if annotation.isVisibleMark { annotations.append(annotation) }
                        activeAnnotation = nil
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Screenshot markup area")
            .accessibilityIdentifier("feedback.report.screenshotCanvas")
        }
        .aspectRatio(screenshotAspectRatio, contentMode: .fit)
        .frame(maxWidth: 240, maxHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.tint.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var screenshotAspectRatio: CGFloat {
        guard let screenshot, screenshot.size.height > 0 else { return 9 / 16 }
        return screenshot.size.width / screenshot.size.height
    }

    private func rectangle(for annotation: FeedbackAnnotationRectangle, in size: CGSize) -> some View {
        let rect = annotation.rect(in: size)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
    }
}

#if DEBUG
struct FeedbackReportSheetAuditView: View {
    var body: some View {
        FeedbackReportSheet(
            draft: FeedbackDraft(screenName: "Zora design audit", screenshot: nil, capturedAt: Date()),
            feedbackClient: .mockSuccess
        )
    }
}
#endif

private extension UIUserInterfaceIdiom {
    var feedbackDescription: String {
        switch self {
        case .phone: return "phone"
        case .pad: return "pad"
        case .mac: return "mac"
        case .tv: return "tv"
        case .carPlay: return "carPlay"
        case .vision: return "vision"
        case .unspecified: fallthrough
        @unknown default: return "unspecified"
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension CGPoint {
    func clamped(to size: CGSize) -> CGPoint {
        CGPoint(
            x: x.clamped(to: 0 ... max(size.width, 0)),
            y: y.clamped(to: 0 ... max(size.height, 0))
        )
    }
}
