@preconcurrency import LinkPresentation
import SwiftUI
import UIKit


struct TranscriptLinkPreviewPlaceholderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.clear)
            .frame(minHeight: 84)
    }
}

struct TranscriptLinkPreviewView: View {
    let url: URL

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var snapshot: TranscriptLinkPreviewSnapshot?
    @State private var previewImage: UIImage?
    @State private var didFail = false
    @State private var isLoading = false

    var body: some View {
        Button {
            openURL(url)
        } label: {
            compactCard
        }
        .buttonStyle(.chatTactile(.card))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens in the external browser")
        .task(id: url.absoluteString) {
            await loadMetadataIfNeeded()
        }
    }

    @MainActor
    private func loadMetadataIfNeeded() async {
        guard snapshot == nil, !didFail, !isLoading else { return }

        if let cachedSnapshot = await TranscriptLinkPreviewCache.shared.snapshot(for: url) {
            apply(cachedSnapshot)
            return
        }

        isLoading = true
        let provider = LPMetadataProvider()
        defer {
            isLoading = false
        }

        do {
            let loadedMetadata = try await fetchMetadata(for: url, provider: provider)
            loadedMetadata.originalURL = loadedMetadata.originalURL ?? url
            try Task.checkCancellation()

            let imageData = await loadPreviewImageData(from: loadedMetadata)
            try Task.checkCancellation()

            let loadedSnapshot = TranscriptLinkPreviewSnapshot(
                title: loadedMetadata.title,
                displayURL: loadedMetadata.originalURL ?? loadedMetadata.url ?? url,
                imageData: imageData
            )

            apply(loadedSnapshot)
            await TranscriptLinkPreviewCache.shared.store(loadedSnapshot, for: url)
        } catch {
            if !isCancellation(error) {
                didFail = true
            }
        }
    }

    @MainActor
    private func apply(_ snapshot: TranscriptLinkPreviewSnapshot) {
        self.snapshot = snapshot
        previewImage = snapshot.imageData.flatMap(UIImage.init(data:))
    }

    @MainActor
    private func fetchMetadata(
        for url: URL,
        provider: LPMetadataProvider
    ) async throws -> LPLinkMetadata {
        try Task.checkCancellation()
        let cancellableProvider = TranscriptLinkPreviewMetadataProviderCancellation(provider: provider)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                provider.startFetchingMetadata(for: url) { metadata, error in
                    if let metadata {
                        continuation.resume(returning: metadata)
                    } else {
                        continuation.resume(throwing: error ?? URLError(.cannotParseResponse))
                    }
                }
            }
        } onCancel: {
            cancellableProvider.cancel()
        }
    }

    private func loadPreviewImageData(from metadata: LPLinkMetadata) async -> Data? {
        guard !Task.isCancelled else { return nil }
        guard let itemProvider = metadata.imageProvider ?? metadata.iconProvider else {
            return nil
        }

        if itemProvider.hasItemConformingToTypeIdentifier("public.image") {
            let imageData = await withCheckedContinuation { continuation in
                itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    continuation.resume(returning: data)
                }
            }

            if let image = imageData.flatMap(UIImage.init(data:)) {
                return await thumbnailData(from: image)
            }
        }

        guard !Task.isCancelled else { return nil }

        if itemProvider.canLoadObject(ofClass: UIImage.self) {
            let image = await withCheckedContinuation { continuation in
                itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }

            if let image {
                return await thumbnailData(from: image)
            }
        }

        return nil
    }

    private func thumbnailData(from image: UIImage) async -> Data? {
        guard !Task.isCancelled else { return nil }

        return await withTaskGroup(of: Data?.self) { group in
            group.addTask(priority: .utility) {
                guard !Task.isCancelled else { return nil }
                return TranscriptLinkPreviewThumbnailRenderer.thumbnailData(from: image)
            }

            guard let thumbnailData = await group.next() else {
                return nil
            }
            group.cancelAll()
            guard !Task.isCancelled else { return nil }
            return thumbnailData
        }
    }
}

@MainActor
private final class TranscriptLinkPreviewMetadataProviderCancellation: @unchecked Sendable {
    private let provider: LPMetadataProvider

    init(provider: LPMetadataProvider) {
        self.provider = provider
    }

    nonisolated func cancel() {
        Task { @MainActor [weak self] in
            // LPMetadataProvider is non-Sendable. The provider is created and
            // started on MainActor, so cancellation re-enters MainActor before
            // touching the provider from Swift's synchronous cancellation hook.
            self?.provider.cancel()
        }
    }
}

private enum TranscriptLinkPreviewThumbnailRenderer {
    static func thumbnailData(from image: UIImage) -> Data? {
        guard !Task.isCancelled else { return nil }
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let targetSize = CGSize(width: 164, height: 164)
        let sourceSize = image.size
        let scale = max(
            targetSize.width / sourceSize.width,
            targetSize.height / sourceSize.height
        )
        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let origin = CGPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }

        return thumbnail.jpegData(compressionQuality: 0.8) ?? thumbnail.pngData()
    }
}

private extension TranscriptLinkPreviewView {
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled {
            return true
        }

        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private var accessibilityLabel: String {
        if let host = url.host, !host.isEmpty {
            return String(localized: "Link preview for \(host)")
        }

        return String(localized: "Link preview")
    }

    private var compactCard: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 10)
        }
        .frame(minHeight: 84, alignment: .center)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let previewImage {
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipped()
        } else {
            Image(systemName: "link")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 84, height: 84)
                .background(Color.accentColor.opacity(0.12))
        }
    }

    private var displayTitle: String {
        if let title = snapshot?.title {
            return title
        }

        if let host = url.host, !host.isEmpty {
            return host
        }

        return String(localized: "Link")
    }

    private var displaySubtitle: String {
        if let host = displayURL?.host, !host.isEmpty {
            return host
        }

        return url.absoluteString
    }

    private var displayURL: URL? {
        snapshot?.displayURL ?? url
    }
}
