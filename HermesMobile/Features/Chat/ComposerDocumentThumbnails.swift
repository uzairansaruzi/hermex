import QuickLookThumbnailing
import UIKit

/// Draws a file's thumbnail. Quick Look in the app; a double in tests.
protocol ComposerThumbnailGenerating: Sendable {
    /// The thumbnail, or nil when there is none to draw.
    func thumbnail(ofFileAt url: URL, size: CGSize, scale: CGFloat) async -> UIImage?
}

/// Quick Look's `.thumbnail` representation: a PDF's first page, or a
/// rendered excerpt of a text or Office document. Formats with no thumbnail
/// (an archive, say) answer nil rather than a generic icon.
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

/// Previews of the documents staged in a composer, drawn from each one's
/// app-owned draft copy. One cache serves the attachment strip and the
/// collapsed pill in Sessions and Bot Chat, keyed by `PendingAttachment.id`,
/// which a draft restore keeps, so a reopened chat shows its previews at once.
@MainActor
final class ComposerDocumentThumbnails {
    static let shared = ComposerDocumentThumbnails()

    private let store: any ChatDraftAttachmentStoring
    private let generator: any ComposerThumbnailGenerating
    private let limit: Int
    /// A nil value is a document Quick Look couldn't draw, kept so it isn't
    /// retried on every render.
    private var results: [UUID: UIImage?] = [:]
    /// Oldest first, for evicting past `limit`.
    private var order: [UUID] = []

    init(
        store: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
        generator: any ComposerThumbnailGenerating = QuickLookComposerThumbnailGenerator(),
        limit: Int = 32
    ) {
        self.store = store
        self.generator = generator
        self.limit = limit
    }

    /// A preview already made, without starting any work, so a tile that
    /// reappears draws it in its first frame.
    func cachedThumbnail(for id: UUID) -> UIImage? {
        results[id] ?? nil
    }

    /// The document's preview, made once per attachment. Images (which carry
    /// their own thumbnail) and attachments without a draft copy get nil
    /// without any work. A result is kept per attachment, not per size, so
    /// every caller asks at one size. A cancelled request keeps nothing, so
    /// the next caller makes it afresh.
    func thumbnail(for attachment: PendingAttachment, size: CGSize, scale: CGFloat) async -> UIImage? {
        guard !attachment.isImage, let fileName = attachment.draftFileName else { return nil }
        if let result = results[attachment.id] { return result }

        let image: UIImage?
        if let url = try? await store.fileURL(named: fileName) {
            image = await generator.thumbnail(ofFileAt: url, size: size, scale: scale)
        } else {
            image = nil
        }
        guard !Task.isCancelled else { return nil }

        remember(image, for: attachment.id)
        return image
    }

    private func remember(_ image: UIImage?, for id: UUID) {
        if results.updateValue(image, forKey: id) == nil {
            order.append(id)
        }
        while order.count > limit {
            results.removeValue(forKey: order.removeFirst())
        }
    }
}
