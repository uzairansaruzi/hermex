import AVFoundation
import AVKit
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
    let cacheNamespace: String
    let loadMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?
    let isStreaming: Bool

    init(
        segments: [TranscriptMediaSegment],
        cacheNamespace: String,
        loadMediaImage: ((TranscriptMediaReference) async -> Data?)?,
        loadMediaData: ((TranscriptMediaReference) async -> Data?)?,
        onPreviewMedia: ((TranscriptMediaReference) -> Void)?,
        isStreaming: Bool = false
    ) {
        self.segments = segments
        self.cacheNamespace = cacheNamespace
        self.loadMediaImage = loadMediaImage
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
                    TranscriptMediaThumbnailView(
                        reference: reference,
                        cacheNamespace: cacheNamespace,
                        loadMediaImage: loadMediaImage,
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

private struct TranscriptMediaThumbnailView: View {
    let reference: TranscriptMediaReference
    let cacheNamespace: String
    let loadMediaImage: ((TranscriptMediaReference) async -> Data?)?
    let loadMediaData: ((TranscriptMediaReference) async -> Data?)?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    private let thumbnailWidth: CGFloat = 210
    private let thumbnailHeight: CGFloat = 132

    var body: some View {
        switch reference.mediaKind {
        case .image where reference.isExtensionlessRemoteMediaCandidate && loadMediaData != nil:
            if let loadMediaData {
                TranscriptMediaResolvedRemoteView(
                    reference: reference,
                    loadMediaData: loadMediaData,
                    onPreviewMedia: onPreviewMedia
                )
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }

        case .image where loadMediaImage != nil:
            Button {
                onPreviewMedia?(reference)
            } label: {
                thumbnailContent
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(imageButtonAccessibilityLabel)
            .task(id: imageCacheKey) {
                guard let loadMediaImage else { return }
                image = nil
                didAttemptLoad = false
                let loadedImage = await TranscriptMediaImageCache.shared.image(
                    for: reference,
                    cacheNamespace: cacheNamespace,
                    loadMediaImage: loadMediaImage
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    image = loadedImage
                    didAttemptLoad = true
                }
            }
        case .audio where loadMediaData != nil:
            InlineAudioPlayerView(title: reference.displayName) {
                guard let loadMediaData else { return nil }
                return await loadMediaData(reference)
            }
            .frame(maxWidth: 280)
            .accessibilityElement(children: .contain)

        case .video:
            Button {
                onPreviewMedia?(reference)
            } label: {
                TranscriptMediaVideoTile(reference: reference)
            }
            .buttonStyle(.chatTactile(.thumbnail))
            .accessibilityLabel(String(localized: "Open media video \(reference.displayName)"))

        default:
            TranscriptMediaUnavailableChip(reference: reference)
        }
    }

    private var imageCacheKey: TranscriptMediaImageCacheKey {
        TranscriptMediaImageCacheKey(namespace: cacheNamespace, reference: reference)
    }

    private var imageButtonAccessibilityLabel: String {
        if image == nil, didAttemptLoad, reference.isExtensionlessRemoteMediaCandidate {
            return String(localized: "Open media video \(reference.displayName)")
        }

        return String(localized: "Open media image \(reference.displayName)")
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
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
        } else if didAttemptLoad {
            if reference.isExtensionlessRemoteMediaCandidate {
                TranscriptMediaVideoTile(reference: reference)
            } else {
                TranscriptMediaUnavailableChip(reference: reference)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemFill))
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .overlay {
                    ProgressView()
                        .tint(Color(.tertiaryLabel))
                }
        }
    }
}

private struct TranscriptMediaResolvedRemoteView: View {
    let reference: TranscriptMediaReference
    let loadMediaData: (TranscriptMediaReference) async -> Data?
    let onPreviewMedia: ((TranscriptMediaReference) -> Void)?

    @State private var resolvedMedia: ResolvedMedia?

    var body: some View {
        Group {
            switch resolvedMedia {
            case let .image(image):
                Button {
                    onPreviewMedia?(reference)
                } label: {
                    thumbnailContent(image)
                }
                .buttonStyle(.chatTactile(.thumbnail))
                .accessibilityLabel(String(localized: "Open media image \(reference.displayName)"))

            case let .audio(data):
                InlineAudioPlayerView(title: reference.displayName) {
                    data
                }
                .frame(maxWidth: 280)
                .accessibilityElement(children: .contain)

            case .video:
                Button {
                    onPreviewMedia?(reference)
                } label: {
                    TranscriptMediaVideoTile(reference: reference)
                }
                .buttonStyle(.chatTactile(.thumbnail))
                .accessibilityLabel(String(localized: "Open media video \(reference.displayName)"))

            case .unavailable:
                TranscriptMediaUnavailableChip(reference: reference)

            case nil:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemFill))
                    .frame(width: 210, height: 132)
                    .overlay {
                        ProgressView()
                            .tint(Color(.tertiaryLabel))
                    }
            }
        }
        .task(id: reference.id) {
            resolvedMedia = nil
            guard let data = await loadMediaData(reference) else {
                guard !Task.isCancelled else { return }
                resolvedMedia = .unavailable
                return
            }

            guard !Task.isCancelled else { return }
            resolvedMedia = Self.resolve(data)
        }
    }

    private func thumbnailContent(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 210, height: 132)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
            )
    }

    private static func resolve(_ data: Data) -> ResolvedMedia {
        if let image = UIImage(data: data) {
            return .image(image)
        }

        if (try? AVAudioPlayer(data: data)) != nil {
            return .audio(data)
        }

        return .video
    }

    private enum ResolvedMedia {
        case image(UIImage)
        case audio(Data)
        case video
        case unavailable
    }
}

private struct TranscriptMediaVideoTile: View {
    let reference: TranscriptMediaReference

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 210, height: 132)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )

            VStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 172)

                Text("Video")
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .padding(.horizontal, 14)
        }
    }
}

private struct TranscriptMediaUnavailableChip: View {
    let reference: TranscriptMediaReference

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(.secondaryLabel))

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("Media unavailable")
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Media unavailable \(reference.displayName)"))
    }

    private var iconName: String {
        switch reference.mediaKind {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .unsupported:
            "doc"
        }
    }
}

private actor TranscriptMediaImageCache {
    static let shared = TranscriptMediaImageCache()

    private var cache: [TranscriptMediaImageCacheKey: UIImage] = [:]
    private var inFlight: [TranscriptMediaImageCacheKey: Task<UIImage?, Never>] = [:]

    func image(
        for reference: TranscriptMediaReference,
        cacheNamespace: String,
        loadMediaImage: @escaping (TranscriptMediaReference) async -> Data?
    ) async -> UIImage? {
        let key = TranscriptMediaImageCacheKey(namespace: cacheNamespace, reference: reference)
        if let cached = cache[key] {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            guard let data = await loadMediaImage(reference) else {
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

struct TranscriptMediaImageCacheKey: Hashable {
    let namespace: String
    let referenceID: String

    init(namespace: String, reference: TranscriptMediaReference) {
        self.namespace = namespace
        referenceID = reference.id
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

    init(
        server: URL,
        sessionID: String?,
        item: TranscriptMediaPreviewItem,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(
            initialValue: TranscriptMediaPreviewViewModel(
                server: server,
                sessionID: sessionID,
                reference: item.reference
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.previewData == nil {
                    ProgressView("Loading media...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage, viewModel.previewData == nil {
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
                } else if let audioData = viewModel.audioData {
                    audioContent(audioData)
                } else if let videoURL = viewModel.videoFileURL {
                    videoContent(videoURL)
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
            .onDisappear {
                viewModel.cleanupTemporaryFiles()
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

    private func audioContent(_ data: Data) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            mediaHeader

            InlineAudioPlayerView(title: item.reference.displayName) {
                data
            }
            .frame(maxWidth: 360)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func videoContent(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            mediaHeader

            TranscriptVideoPreviewPlayerView(url: url)
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func unavailableContent(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No Preview", systemImage: unavailableIconName)
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

    private var unavailableIconName: String {
        switch item.reference.mediaKind {
        case .image:
            "photo"
        case .audio:
            "waveform"
        case .video:
            "play.rectangle"
        case .unsupported:
            "doc.questionmark"
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

private struct TranscriptVideoPreviewPlayerView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}
