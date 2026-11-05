import SwiftUI
import UIKit

struct ChatAttachmentPreviewItem: Identifiable, Equatable {
    let id = UUID()
    let name: String?
    let path: String?
    let mime: String?
    let size: Int?
    let isImage: Bool?
    let localImageData: Data?

    init(message attachment: MessageAttachment, localData: Data?) {
        name = attachment.name
        path = attachment.path
        mime = attachment.mime
        size = attachment.size
        isImage = attachment.isImage
        localImageData = localData
    }

    init(pending attachment: PendingAttachment) {
        name = attachment.name
        path = attachment.path
        mime = attachment.mime
        size = attachment.size
        isImage = attachment.isImage
        localImageData = attachment.thumbnailData
    }

    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
            return lastPathComponent.isEmpty ? path : lastPathComponent
        }

        return inferredIsImage ? String(localized: "Image") : String(localized: "File")
    }

    var displayPath: String {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedPath, !trimmedPath.isEmpty else {
            return displayName
        }
        return trimmedPath
    }

    var inferredIsImage: Bool {
        if isImage == true { return true }
        if let mime = mime?.lowercased(), mime.hasPrefix("image/") { return true }
        return Self.imageExtensions.contains(pathExtension)
    }

    var inferredIsAudio: Bool {
        AttachmentAudioDetection.isAudio(isImage: isImage, mime: mime, name: name, path: path)
    }

    var binaryPreview: BinaryFilePreview? {
        BinaryFilePreview(path: name ?? path ?? "")
    }

    private var pathExtension: String {
        URL(fileURLWithPath: name ?? path ?? "").pathExtension.lowercased()
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico"
    ]
}

struct ChatAttachmentPreviewView: View {
    let onAPIError: (Error) -> Void

    private let item: ChatAttachmentPreviewItem
    @State private var viewModel: ChatAttachmentPreviewViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CodeDisplaySettings.wrapsLinesKey) private var wrapsCodeLines = false
    @AppStorage(CodeDisplaySettings.customSizeKey) private var customCodeSize: Double?

    init(
        session: SessionSummary,
        server: URL,
        item: ChatAttachmentPreviewItem,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: ChatAttachmentPreviewViewModel(session: session, server: server, item: item))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.preview == nil {
                    ProgressView("Loading attachment...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage, viewModel.preview == nil {
                    ContentUnavailableView {
                        Label("Could Not Load Attachment", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadAttachment() }
                        }
                    }
                } else if let preview = viewModel.preview {
                    previewContent(preview)
                } else {
                    unavailableContent(String(localized: "Preview is not available for this attachment."))
                }
            }
            .themedPageBackground()
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadAttachment()
            }
            .refreshable {
                await loadAttachment(force: true)
            }
        }
        .adaptivePagePresentation()
    }

    @ViewBuilder
    private func previewContent(_ preview: FilePreviewContent) -> some View {
        switch preview {
        case let .text(file):
            textContent(file)
        case let .image(file):
            imageContent(file)
        case let .audio(data):
            audioContent(data)
        case let .quickLook(file):
            QuickLookFileView(url: file.url)
        case let .unavailable(message):
            unavailableContent(message)
        }
    }

    private func audioContent(_ data: Data) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileHeader

                InlineAudioPlayerView(
                    title: item.displayName,
                    load: { data }
                )
            }
            .padding()
        }
        .background(Color(.appCanvas))
    }

    private func textContent(_ file: FileResponse) -> some View {
        ScrollView(wrapsCodeLines ? .vertical : [.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                fileHeader

                Text(file.content ?? "")
                    .font(AppFont.code(style: .body, customSize: customCodeSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.appCanvas))
    }

    @ViewBuilder
    private func imageContent(_ file: ImageFilePreview) -> some View {
        if let image = UIImage(data: file.data) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileHeader

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(item.displayName)
                }
                .padding()
            }
            .background(Color(.appCanvas))
        } else {
            unavailableContent(String(localized: "Could not preview this image."))
        }
    }

    private func unavailableContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: item.inferredIsImage ? "photo" : "doc.questionmark")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text(item.displayPath)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.appSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayPath)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.appSecondary)
                .textSelection(.enabled)

            if let metadataText {
                Text(metadataText)
                    .font(.footnote)
                    .foregroundStyle(.appSecondary)
            }
        }
    }

    private var metadataText: String? {
        var parts: [String] = []

        if let preview = viewModel.preview {
            switch preview {
            case let .text(file):
                if let size = file.size {
                    parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if let lines = file.lines {
                    parts.append(String(localized: "\(lines) lines"))
                }
            case let .image(file):
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(file.originalByteCount), countStyle: .file))
            case let .audio(data):
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
            case .quickLook, .unavailable:
                break
            }
        } else if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }

        if let mime = item.mime?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mime.isEmpty {
            parts.append(mime)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    private func loadAttachment(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

/// What a staged paste's sheet shows: its text, or the start of a paste too long to edit.
struct StagedPasteText: Equatable, Sendable {
    /// Past this the sheet shows only the start, read-only. The largest size whose sheet
    /// stayed responsive on a loaded iOS 27 simulator; at 512 KB, Done stopped responding.
    static let editableBytes = 256_000
    static let sendingNotice = String(localized: "This text is being sent, so it can't be edited right now.")

    let text: String
    let totalBytes: Int
    /// False when `text` is only the start of the file.
    let isWhole: Bool

    /// Nil for bytes that aren't UTF-8, which would come back damaged if edited and saved.
    init?(data: Data) {
        var end = min(data.count, Self.editableBytes)
        // A cut inside a character backs up to its first byte.
        while end > 0, end < data.count, data[data.startIndex + end] & 0xC0 == 0x80 { end -= 1 }
        guard let text = String(bytes: data.prefix(end), encoding: .utf8) else { return nil }
        self.text = text
        totalBytes = data.count
        isWhole = end == data.count
    }
}

/// Opens one staged paste. `isSending` is read as it opens: the sheet covers Send, and a
/// save checks again.
struct StagedPasteItem: Identifiable {
    let attachment: PendingAttachment
    let isSending: Bool
    var id: UUID { attachment.id }
}

/// Shows a staged paste and, unless a send holds it or it is too long, edits it (#1456).
/// Cancel and Save both close the sheet. The chat's `load` and `save` keep it free of the
/// attachment stores.
struct StagedPasteSheet: View {
    private enum Content {
        case loading, unreadable
        case loaded(StagedPasteText)
    }

    let item: StagedPasteItem
    let load: () async -> StagedPasteText?
    /// Returns why the edit did not save, or nil once it has.
    let save: (String) async -> String?

    @State private var content = Content.loading
    @State private var buffer = StagedPasteBuffer()
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false
    @State private var saveFailure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                switch content {
                case .loading:
                    Color.clear
                case .unreadable:
                    ContentUnavailableView {
                        Label("Could Not Read This Text", systemImage: "doc.questionmark")
                    } description: {
                        Text("It may not be plain text, or its local copy is gone. It can't be edited. You can remove it from the message and paste again.")
                    }
                case let .loaded(paste):
                    VStack(spacing: 0) {
                        if let notice = notice(for: paste) {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.appSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.appSurface), in: .rect(cornerRadius: 10))
                                .padding(.horizontal)
                                .padding(.top, 8)
                        }
                        StagedPasteTextView(text: paste.text, name: item.attachment.name, buffer: buffer)
                    }
                }
            }
            .themedPageBackground()
            .navigationTitle(item.attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert("Couldn't Save", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveFailure ?? "")
            }
        }
        .task {
            content = await load().map(Content.loaded) ?? .unreadable
        }
        .interactiveDismissDisabled(buffer.hasChanges || isSaving)
        .adaptivePagePresentation()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(item.attachment.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !dynamicTypeSize.isAccessibilitySize, let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.appSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        if buffer.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if buffer.hasChanges { isConfirmingDiscard = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .confirmationDialog("Discard Changes", isPresented: $isConfirmingDiscard, titleVisibility: .hidden) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveEdit)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!buffer.hasChanges || buffer.isEmpty || isSaving)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if case let .loaded(paste) = content, paste.isWhole, !item.isSending {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { buffer.beginEditing() }
                }
            }
        }
    }

    private var subtitle: String? {
        if buffer.isEditing { return String(localized: "Editing") }
        return item.attachment.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    private func notice(for paste: StagedPasteText) -> String? {
        if !paste.isWhole {
            let shown = ByteCountFormatter.string(fromByteCount: Int64(StagedPasteText.editableBytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(paste.totalBytes), countStyle: .file)
            return String(localized: "Showing the first \(shown) of \(total). This text is too long to edit here. The whole file is sent.")
        }
        return item.isSending ? StagedPasteText.sendingNotice : nil
    }

    private func saveEdit() {
        guard let text = buffer.text else { return }
        if case let .loaded(paste) = content, paste.text == text { return dismiss() }
        isSaving = true
        buffer.setEditable(false)
        Task {
            let failure = await save(text)
            isSaving = false
            if let failure {
                buffer.setEditable(true)
                saveFailure = failure
            } else {
                dismiss()
            }
        }
    }
}

/// Owns the sheet's text view, whose text stays there until Save. Only the flags below reach
/// SwiftUI, and only when they flip, so typing in a long paste redraws nothing and copies nothing.
@MainActor
@Observable
final class StagedPasteBuffer: NSObject, UITextViewDelegate {
    private(set) var isEditing = false
    private(set) var hasChanges = false
    private(set) var isEmpty = false
    @ObservationIgnored fileprivate weak var textView: UITextView?

    var text: String? { textView?.text }

    /// Starts editing where the user is reading: a selection stays, otherwise the caret goes
    /// to the top of what's on screen, so the keyboard doesn't jump back to the first line.
    func beginEditing() {
        guard let textView else { return }
        isEditing = true
        textView.isEditable = true
        if textView.selectedRange.length == 0 {
            let top = CGPoint(
                x: textView.textContainerInset.left,
                y: textView.contentOffset.y + textView.adjustedContentInset.top + textView.textContainerInset.top
            )
            if let caret = textView.closestPosition(to: top) {
                textView.selectedTextRange = textView.textRange(from: caret, to: caret)
            }
        }
        textView.becomeFirstResponder()
    }

    /// Off while a save runs, so nothing typed after Save is lost when the sheet closes.
    func setEditable(_ isEditable: Bool) {
        textView?.isEditable = isEditable
    }

    func textViewDidChange(_ textView: UITextView) {
        if !hasChanges { hasChanges = true }
        let isEmpty = textView.textStorage.length == 0
        if self.isEmpty != isEmpty { self.isEmpty = isEmpty }
    }
}

/// The paste in a wrapping, selectable text view. Text-changing keyboard helpers stay off so
/// a log isn't altered as it's edited.
private struct StagedPasteTextView: UIViewRepresentable {
    let text: String
    let name: String
    let buffer: StagedPasteBuffer

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = .appText
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(context.environment.dynamicTypeSize))
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.textAlignment = .natural
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityLabel = name
        textView.text = text
        textView.delegate = buffer
        buffer.textView = textView
        return textView
    }

    /// The text view keeps the text from here on (`StagedPasteBuffer`).
    func updateUIView(_ textView: UITextView, context: Context) {}
}

/// An attachment that is already known to be an image opens in the full-bleed lightbox.
/// Text, audio, Quick Look documents, and anything without a preview keep
/// `ChatAttachmentPreviewView`, which only learns what it has once the server answers.
/// `page` ties it to its gallery's pager.
struct ChatAttachmentImageLightbox: View {
    let onAPIError: (Error) -> Void

    private let item: ChatAttachmentPreviewItem
    private let page: ImageLightboxPage
    @State private var viewModel: ChatAttachmentPreviewViewModel

    init(
        session: SessionSummary,
        server: URL,
        item: ChatAttachmentPreviewItem,
        page: ImageLightboxPage,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.page = page
        self.onAPIError = onAPIError
        _viewModel = State(
            initialValue: ChatAttachmentPreviewViewModel(session: session, server: server, item: item)
        )
    }

    var body: some View {
        ImageLightboxView(
            content: content,
            title: item.displayName,
            path: item.displayPath,
            imageAccessibilityLabel: item.displayName,
            page: page,
            onRetry: { Task { await loadAttachment(force: true) } }
        )
        .task {
            await loadAttachment()
        }
    }

    private var content: ImageLightboxContent {
        switch viewModel.preview {
        case let .image(file):
            if let image = viewModel.previewImage {
                return .image(
                    image,
                    detail: ByteCountFormatter.string(
                        fromByteCount: Int64(file.originalByteCount),
                        countStyle: .file
                    )
                )
            }
            return .failure(String(localized: "Could not preview this image."))

        case let .unavailable(message):
            return .failure(message)

        case .text, .audio, .quickLook:
            return .failure(String(localized: "Preview is not available for this attachment."))

        case .none:
            if !viewModel.isLoading, let message = viewModel.errorMessage {
                return .failure(message)
            }
            return .loading(String(localized: "Loading attachment..."))
        }
    }

    private func loadAttachment(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

@MainActor
@Observable
final class ChatAttachmentPreviewViewModel {
    private let session: SessionSummary
    private let item: ChatAttachmentPreviewItem
    private let apiClient: APIClient
    private var didLoad = false

    private(set) var preview: FilePreviewContent? {
        didSet {
            previewImage = if case let .image(file) = preview { UIImage(data: file.data) } else { nil }
        }
    }
    /// An image preview decoded once, so a redraw hands the lightbox the same image and
    /// keeps its zoom.
    private(set) var previewImage: UIImage?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(session: SessionSummary, server: URL, item: ChatAttachmentPreviewItem, apiClient: APIClient? = nil) {
        self.session = session
        self.item = item
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        didLoad = true
        preview = nil

        // A pathless item, such as a Hermes session's chip (#1012), shows its local copy
        // and never needs the session.
        let trimmedPath = item.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = trimmedPath, !path.isEmpty else {
            preview = localFallbackPreview
            return
        }

        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer { isLoading = false }

        do {
            if item.inferredIsImage {
                let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
                if let previewData = ImagePreviewDownsampler.previewData(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    preview = .image(.init(data: previewData, originalByteCount: data.count))
                } else {
                    preview = .unavailable(String(localized: "Could not decode this image."))
                }
            } else if item.inferredIsAudio {
                // Raw bytes (no downsampling) so AVAudioPlayer gets the original
                // encoded audio; checked before the Quick Look list, which would
                // otherwise take m4a/mp3/wav/flac away from the inline player.
                preview = .audio(try await apiClient.rawFileData(sessionID: sessionID, path: path))
            } else if item.binaryPreview == .quickLook {
                let apiClient = apiClient
                preview = try await FilePreviewContent.loadQuickLook(name: item.displayName, knownSize: item.size) {
                    try await apiClient.rawFilePreviewData(sessionID: sessionID, path: path)
                }.content
            } else if item.binaryPreview == .unavailable {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
            } else {
                preview = .text(try await apiClient.file(sessionID: sessionID, path: path))
            }
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    private var localFallbackPreview: FilePreviewContent {
        if item.inferredIsImage, let data = item.localImageData {
            return .image(.init(data: data, originalByteCount: data.count))
        }

        return .unavailable(String(localized: "This attachment does not have a server file path."))
    }
}
