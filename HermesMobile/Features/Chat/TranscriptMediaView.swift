import SwiftUI
import UIKit

struct TranscriptMediaPreviewItem: Identifiable, Equatable {
    let reference: TranscriptMediaReference

    var id: String {
        reference.id
    }
}

struct TranscriptMediaContentView: View {
    let segments: [TranscriptMediaSegment]
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?
    let isStreaming: Bool

    init(
        segments: [TranscriptMediaSegment],
        loadMediaData: ((TranscriptMediaReference) async -> Data?)?,
        onPreviewMedia: ((TranscriptMediaReference) -> Void)?,
        isStreaming: Bool = false
    ) {
        self.segments = segments
        self.loadMediaData = loadMediaData
        self.onPreviewMedia = onPreviewMedia
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownRenderer(content: text, isStreaming: isStreaming)
                    }
                case let .media(reference):
                    if reference.isAudioCandidate {
                        TranscriptMediaAudioView(
                            reference: reference,
                            loadMediaData: loadMediaData
                        )
                        .forcedLeftToRight()
                    } else {
                        TranscriptMediaThumbnailView(
                            reference: reference,
                            loadMediaData: loadMediaData,
                            onPreviewMedia: onPreviewMedia
                        )
                        // Pin the image container LTR so media keeps its leading-edge
                        // anchor inside an RTL message (#259); the text segments above
                        // still follow the chat direction.
                        .forcedLeftToRight()
                    }
                }
            }
        }
    }
}

private struct TranscriptMediaThumbnailView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    private let thumbnailWidth: CGFloat = 210
    private let thumbnailHeight: CGFloat = 132

    var body: some View {
        if reference.isRasterImageCandidate, let loadMediaData {
            Button {
                onPreviewMedia?(reference)
            } label: {
                thumbnailContent
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(String(localized: "Open media image \(reference.displayName)"))
            .task(id: reference.id) {
                let loadedImage = await TranscriptMediaImageCache.shared.image(
                    for: reference,
                    loadMediaData: loadMediaData
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    image = loadedImage
                    didAttemptLoad = true
                }
            }
        } else if reference.isTextDocumentCandidate, loadMediaData != nil {
            Button {
                onPreviewMedia?(reference)
            } label: {
                TranscriptMediaDocumentChip(reference: reference)
            }
            .buttonStyle(.chatTactile(.card))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(String(localized: "Open file \(reference.displayName)"))
        } else {
            TranscriptMediaUnavailableChip(reference: reference)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ZoraBrand.surfaceHairline, lineWidth: 0.5)
                )
        } else if didAttemptLoad {
            TranscriptMediaUnavailableChip(reference: reference)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ZoraBrand.subtleFill)
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .overlay {
                    ProgressView()
                        .tint(Color(.tertiaryLabel))
                }
        }
    }
}

private struct TranscriptMediaDocumentChip: View {
    let reference: TranscriptMediaReference

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZoraBrand.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Open file")
                    .font(.caption2)
                    .foregroundStyle(ZoraBrand.secondaryForeground)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(ZoraBrand.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ZoraBrand.surfaceHairline, lineWidth: 0.5)
        )
    }
}

private struct TranscriptMediaAudioView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?

    var body: some View {
        if let loadMediaData {
            InlineAudioPlayerView(
                title: reference.displayName,
                load: {
                    await loadMediaData(reference)
                }
            )
            .id(reference.id)
            .frame(maxWidth: 300, alignment: .leading)
        } else {
            TranscriptMediaUnavailableChip(reference: reference)
        }
    }
}

private struct TranscriptMediaUnavailableChip: View {
    let reference: TranscriptMediaReference

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ZoraBrand.secondaryForeground)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZoraBrand.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Media unavailable")
                    .font(.caption2)
                    .foregroundStyle(ZoraBrand.secondaryForeground)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(ZoraBrand.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(ZoraBrand.surfaceHairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Media unavailable \(reference.displayName)"))
    }

    private var iconName: String {
        if reference.isRasterImageCandidate { return "photo" }
        if reference.isAudioCandidate { return "waveform" }
        if reference.isTextDocumentCandidate { return "doc.text" }
        return "doc"
    }
}

private actor TranscriptMediaImageCache {
    static let shared = TranscriptMediaImageCache()

    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(
        for reference: TranscriptMediaReference,
        loadMediaData: @escaping (TranscriptMediaReference) async -> Data?
    ) async -> UIImage? {
        let key = reference.id
        if let cached = cache[key] {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await loadMediaData(reference) else {
                return nil
            }
            return UIImage(data: data)
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            cache[key] = image
        }
        return image
    }
}

struct TranscriptMediaPreviewView: View {
    let onAPIError: (Error) -> Void

    private let item: TranscriptMediaPreviewItem
    @State private var viewModel: TranscriptMediaPreviewViewModel
    @State private var isSavingToPhotos = false
    @State private var saveConfirmationMessage: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(server: URL, item: TranscriptMediaPreviewItem, onAPIError: @escaping (Error) -> Void) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: TranscriptMediaPreviewViewModel(server: server, reference: item.reference))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.previewData == nil && viewModel.textContent == nil {
                    ProgressView("Loading media...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage,
                          viewModel.previewData == nil,
                          viewModel.textContent == nil {
                    ContentUnavailableView {
                        Label("Could Not Load Media", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadMedia(force: true) }
                        }
                    }
                } else if let data = viewModel.previewData, let image = UIImage(data: data) {
                    imageContent(image)
                } else if let textContent = viewModel.textContent {
                    textDocumentContent(textContent)
                } else {
                    unavailableContent(String(localized: "Preview is not available for this media."))
                }
            }
            .navigationTitle(item.reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.canSaveImageToPhotos {
                        Button {
                            Task { await saveImageToPhotos() }
                        } label: {
                            Image(systemName: "photo")
                        }
                        .disabled(isSavingToPhotos || viewModel.isLoading)
                        .accessibilityLabel("Save image to Photos")
                    }
                }
            }
            .task {
                await loadMedia()
            }
            .refreshable {
                await loadMedia(force: true)
            }
            .alert(
                "Saved",
                isPresented: Binding(
                    get: { saveConfirmationMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            saveConfirmationMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") {
                    saveConfirmationMessage = nil
                }
            } message: {
                Text(saveConfirmationMessage ?? "")
            }
            .alert(
                "Media Action Failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func imageContent(_ image: UIImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                mediaHeader

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(item.reference.displayName)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private func textDocumentContent(_ content: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                mediaHeader

                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private func unavailableContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: item.reference.isRasterImageCandidate ? "photo" : "doc.questionmark")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text(item.reference.rawReference)
                    .font(.footnote)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var mediaHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.reference.rawReference)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let originalByteCount = viewModel.originalByteCount {
                Text(ByteCountFormatter.string(fromByteCount: Int64(originalByteCount), countStyle: .file))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadMedia(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func saveImageToPhotos() async {
        isSavingToPhotos = true
        defer {
            isSavingToPhotos = false
        }

        do {
            let data = try await viewModel.originalImageData()
            guard UIImage(data: data) != nil else {
                throw PhotoLibrarySaveError.notImage
            }
            try await PhotoLibrarySaver.saveImageData(data)
            saveConfirmationMessage = String(localized: "Image saved to Photos.")
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }
}
