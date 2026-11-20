import QuickLookThumbnailing
import UIKit

protocol ComposerThumbnailGenerating: Sendable {
    func thumbnail(ofFileAt url: URL, size: CGSize, scale: CGFloat) async -> UIImage?
}

struct QuickLookComposerThumbnailGenerator: ComposerThumbnailGenerating {
    func thumbnail(ofFileAt url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}

@MainActor
final class ComposerDocumentThumbnails {
    static let shared = ComposerDocumentThumbnails()

    private let store: any ChatDraftAttachmentStoring
    private let generator: any ComposerThumbnailGenerating
    private let limit: Int
    private var results: [String: UIImage?] = [:]
    private var order: [String] = []

    init(
        store: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
        generator: any ComposerThumbnailGenerating = QuickLookComposerThumbnailGenerator(),
        limit: Int = 32
    ) {
        self.store = store
        self.generator = generator
        self.limit = limit
    }

    func cachedThumbnail(for attachment: PendingAttachment) -> UIImage? {
        attachment.draftFileName.flatMap { results[$0] ?? nil }
    }

    func thumbnail(for attachment: PendingAttachment, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard !attachment.isImage, let fileName = attachment.draftFileName else { return nil }
        if let result = results[fileName] { return result }

        let image: UIImage?
        if let url = try? await store.fileURL(named: fileName) {
            image = await generator.thumbnail(ofFileAt: url, size: size, scale: scale)
        } else {
            image = nil
        }
        guard !Task.isCancelled else { return nil }

        remember(image, for: fileName)
        return image
    }

    private func remember(_ image: UIImage?, for fileName: String) {
        if results.updateValue(image, forKey: fileName) == nil {
            order.append(fileName)
        }
        while order.count > limit {
            results.removeValue(forKey: order.removeFirst())
        }
    }
}
