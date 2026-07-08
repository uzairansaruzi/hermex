import Foundation
import Observation

struct ChatAttachmentSendPreparation {
    let attachments: [PendingAttachment]
    let messageAttachments: [MessageAttachment]

    var apiPayloads: [JSONValue]? {
        attachments.isEmpty ? nil : attachments.map { $0.toJSONValue() }
    }

    func chatMessageText(draft: String) -> String {
        PendingAttachment.chatMessageText(draft: draft, attachments: attachments)
    }
}

@MainActor
protocol ChatAttachmentCoordinatorDelegate: AnyObject {
    var attachmentSessionID: String? { get }
    var attachmentIsViewingCachedData: Bool { get }

    func attachmentCoordinatorWillUpload()
    func attachmentCoordinatorDidFail(_ error: Error)
}

@MainActor
@Observable
final class ChatAttachmentCoordinator {
    private(set) var pendingAttachments: [PendingAttachment] = []
    private(set) var uploadAttachmentErrorMessage: String?
    private(set) var localAttachmentPreviews: [String: [String: Data]] = [:]
    private var activeUploadCount = 0

    var isUploadingAttachment: Bool {
        activeUploadCount > 0
    }

    weak var delegate: ChatAttachmentCoordinatorDelegate?

    private let client: APIClient
    private var reservedUploadFilenames: Set<String> = []

    init(client: APIClient) {
        self.client = client
    }

    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async {
        guard let attachment = await performUpload(data: data, filename: filename, previewData: previewData) else {
            return
        }
        pendingAttachments.append(attachment)
    }

    /// Uploads a single file and returns it as a `PendingAttachment` *without*
    /// adding it to `pendingAttachments`. The voice-note flow uses this: the clip
    /// is sent as the sole attachment of its own message, so it must not sweep up
    /// the user's typed draft or other staged attachments. Failures surface via
    /// `uploadAttachmentErrorMessage` and the method returns nil.
    func uploadStandaloneAttachment(data: Data, filename: String) async -> PendingAttachment? {
        await performUpload(data: data, filename: filename, previewData: nil)
    }

    private func performUpload(data: Data, filename: String, previewData: Data?) async -> PendingAttachment? {
        guard delegate?.attachmentIsViewingCachedData != true else {
            uploadAttachmentErrorMessage = String(localized: "Reconnect to the server to upload attachments.")
            return nil
        }

        guard data.count <= PendingAttachment.maximumUploadBytes else {
            uploadAttachmentErrorMessage = PendingAttachment.uploadTooLargeMessage(filename: filename)
            return nil
        }

        guard let sessionID = delegate?.attachmentSessionID else {
            uploadAttachmentErrorMessage = String(localized: "The server did not provide a session ID.")
            return nil
        }

        let displayFilename = Self.normalizedAttachmentFilename(filename)
        let uploadFilename = reserveUploadFilename(preferredFilename: displayFilename)

        activeUploadCount += 1
        uploadAttachmentErrorMessage = nil
        delegate?.attachmentCoordinatorWillUpload()
        defer {
            releaseReservedUploadFilename(uploadFilename)
            activeUploadCount = max(activeUploadCount - 1, 0)
        }

        do {
            let response = try await client.uploadFile(sessionID: sessionID, data: data, filename: uploadFilename)
            if let errorMessage = response.error {
                uploadAttachmentErrorMessage = errorMessage
                return nil
            }

            guard let path = response.path, !path.isEmpty else {
                uploadAttachmentErrorMessage = String(localized: "The server did not return the uploaded file path.")
                return nil
            }

            return PendingAttachment(
                name: displayFilename,
                path: path,
                mime: response.mime ?? "application/octet-stream",
                size: response.size,
                isImage: response.isImage ?? false,
                thumbnailData: await Self.thumbnailData(for: response, originalData: data, previewData: previewData)
            )
        } catch {
            delegate?.attachmentCoordinatorDidFail(error)
            uploadAttachmentErrorMessage = error.localizedDescription
            return nil
        }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
        uploadAttachmentErrorMessage = nil
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func setUploadAttachmentError(_ message: String?) {
        uploadAttachmentErrorMessage = message
    }

    func attachmentImageData(path: String) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            let data = try await client.rawFileData(sessionID: sessionID, path: path)
            return await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            )
        } catch {
            return nil
        }
    }

    /// Raw attachment bytes with no image downsampling — used by the inline
    /// audio player, which needs the original encoded audio data intact.
    func attachmentRawData(path: String) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            return try await client.rawFileData(sessionID: sessionID, path: path)
        } catch {
            return nil
        }
    }

    func transcriptMediaThumbnailData(for reference: TranscriptMediaReference) async -> Data? {
        guard reference.isRasterImageCandidate else { return nil }
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            let data = try await client.transcriptMediaData(for: reference, sessionID: sessionID)
            return await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
            ) ?? data
        } catch {
            return nil
        }
    }

    /// Raw transcript media bytes for inline audio/video playback. Local paths
    /// still require a real session ID so `/api/media` can authorize session media.
    func transcriptMediaData(for reference: TranscriptMediaReference) async -> Data? {
        guard let sessionID = delegate?.attachmentSessionID else { return nil }

        do {
            return try await client.transcriptMediaData(for: reference, sessionID: sessionID)
        } catch {
            return nil
        }
    }

    func prepareForSend(localMessageID: String) -> ChatAttachmentSendPreparation {
        let attachmentsForSend = pendingAttachments
        let messageAttachments = attachmentsForSend.map { pending in
            MessageAttachment(
                name: pending.name,
                path: pending.path,
                mime: pending.mime,
                size: pending.size,
                isImage: pending.isImage
            )
        }

        var previews: [String: Data] = [:]
        for pending in attachmentsForSend {
            if let data = pending.thumbnailData {
                previews[pending.path] = data
            }
        }
        if !previews.isEmpty {
            localAttachmentPreviews[localMessageID] = previews
        }

        pendingAttachments.removeAll()
        return ChatAttachmentSendPreparation(
            attachments: attachmentsForSend,
            messageAttachments: messageAttachments
        )
    }

    func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        guard !attachments.isEmpty else { return }
        pendingAttachments = attachments + pendingAttachments
    }

    func consumePendingAttachments() -> [PendingAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        return attachments
    }

    func replacePendingAttachments(_ attachments: [PendingAttachment]) {
        pendingAttachments = attachments
    }

    func removeLocalPreviews(messageID: String) {
        localAttachmentPreviews[messageID] = nil
    }

    func removeAllLocalPreviews() {
        localAttachmentPreviews.removeAll()
    }

    func mergeLocalAttachmentPreviews(_ previews: [String: [String: Data]]) {
        localAttachmentPreviews.merge(previews) { current, _ in current }
    }

    private func reserveUploadFilename(preferredFilename: String) -> String {
        var existingKeys = reservedUploadFilenames
        for attachment in pendingAttachments {
            existingKeys.insert(Self.filenameKey(attachment.name))
            let uploadedFilename = URL(fileURLWithPath: attachment.path).lastPathComponent
            if !uploadedFilename.isEmpty {
                existingKeys.insert(Self.filenameKey(uploadedFilename))
            }
        }

        var candidate = preferredFilename
        while existingKeys.contains(Self.filenameKey(candidate)) {
            candidate = Self.uniquedAttachmentFilename(preferredFilename)
        }

        reservedUploadFilenames.insert(Self.filenameKey(candidate))
        return candidate
    }

    private func releaseReservedUploadFilename(_ filename: String) {
        reservedUploadFilenames.remove(Self.filenameKey(filename))
    }

    nonisolated private static func normalizedAttachmentFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }

    nonisolated private static func filenameKey(_ filename: String) -> String {
        normalizedAttachmentFilename(filename).lowercased()
    }

    nonisolated private static func uniquedAttachmentFilename(_ filename: String) -> String {
        let normalized = normalizedAttachmentFilename(filename)
        let url = URL(fileURLWithPath: normalized)
        let fileExtension = url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.isEmpty ? "attachment" : baseName
        let suffix = UUID().uuidString.prefix(8).lowercased()

        guard !fileExtension.isEmpty else {
            return "\(safeBaseName)-\(suffix)"
        }

        return "\(safeBaseName)-\(suffix).\(fileExtension)"
    }

    nonisolated private static func thumbnailData(
        for response: UploadResponse,
        originalData: Data,
        previewData: Data?
    ) async -> Data? {
        guard response.isImage == true else { return nil }

        return await ImagePreviewDownsampler.previewDataAsync(
            from: previewData ?? originalData,
            maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize
        )
    }
}
