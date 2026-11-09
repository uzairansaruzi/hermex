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
    private var stagingIDs: Set<UUID> = []
    /// Bytes of Hermes files still staging, so overlapping imports share the 50 MB total.
    private var stagingBytes = 0
    private(set) var uploadStartGeneration = 0

    var isUploadingAttachment: Bool {
        activeUploadCount > 0
    }

    var uploadInFlightCount: Int {
        activeUploadCount
    }

    weak var delegate: ChatAttachmentCoordinatorDelegate?

    private let client: APIClient
    private let draftAttachmentStore: any ChatDraftAttachmentStoring
    private let draftStore: ChatDraftStore?
    private let attachmentLease: ChatDraftAttachmentLease?
    private var reservedUploadFilenames: Set<String> = []
    /// Names held by pasted text still staging, so a paste that starts before the
    /// last one lands takes the next name (#1381).
    private var stagingPasteNames: Set<String> = []
    /// Long pastes still staging, so `cancelPastedTextStaging()` can stop them.
    private var pasteTasks: [UUID: Task<PendingAttachment?, Never>] = [:]
    /// A Hermes session (#1012): staging keeps only the local copy, under Bot Chat's
    /// limits and image conversion, and Send or Queue uploads it
    /// (`HermesChatTurnCoordinator`). A webui session uploads each file as it is staged.
    let uploadsOnSend: Bool

    init(
        client: APIClient,
        draftAttachmentStore: any ChatDraftAttachmentStoring = ChatDraftAttachmentStore.shared,
        draftStore: ChatDraftStore? = nil,
        uploadsOnSend: Bool = false
    ) {
        self.client = client
        self.draftAttachmentStore = draftAttachmentStore
        self.uploadsOnSend = uploadsOnSend
        let retention = draftStore ?? ((draftAttachmentStore as? ChatDraftAttachmentStore) === ChatDraftAttachmentStore.shared ? .shared : nil)
        self.draftStore = retention
        self.attachmentLease = retention?.makeAttachmentLease()
    }

    private func refreshAttachmentSlots() {
        attachmentLease?.slotIDs = Set(pendingAttachments.map(\.id)).union(stagingIDs)
    }

    func protectDraft(_ key: ChatDraftKey) {
        attachmentLease?.key = key
    }

    func protectRestoringAttachments(_ records: [ChatDraftAttachment]) {
        for record in records {
            if let file = record.file { attachmentLease?.filesByAttachmentID[record.id] = file }
        }
    }

    /// Saves a durable app-owned copy, uploads it, and appends the result to the
    /// pending strip. Staging stops if the durable copy cannot be established,
    /// so every attachment shown in the composer is restorable from its draft.
    /// A Hermes session only stages the copy (`stageForSend`).
    @discardableResult
    func uploadAttachment(data: Data, filename: String, previewData: Data? = nil) async -> PendingAttachment? {
        if uploadsOnSend { return await stageForSend(data: data, filename: filename) }
        guard data.count <= PendingAttachment.maximumUploadBytes else {
            uploadAttachmentErrorMessage = PendingAttachment.uploadTooLargeMessage(filename: filename)
            return nil
        }

        guard pendingAttachments.count + stagingIDs.count < ChatDraftStore.maximumAttachmentCount else {
            uploadAttachmentErrorMessage = String(localized: "A draft can have up to 10 attachments.")
            return nil
        }
        let stagingID = UUID()
        stagingIDs.insert(stagingID)
        refreshAttachmentSlots()
        defer {
            stagingIDs.remove(stagingID)
            refreshAttachmentSlots()
        }
        guard let draftFileName = await saveDraftCopy(data, filename: filename, attachmentID: stagingID) else {
            return nil
        }
        guard let attachment = await performUpload(
            data: data,
            filename: filename,
            previewData: previewData,
            draftFileName: draftFileName,
            draftAttachmentID: stagingID,
            reportsErrors: true
        ) else {
            attachmentLease?.filesByAttachmentID[stagingID] = nil
            await deleteUnreferencedCopy(draftFileName)
            return nil
        }
        pendingAttachments.append(attachment)
        refreshAttachmentSlots()
        return attachment
    }

    /// Starts staging a long paste as a text file under the next free `pasted-text`
    /// name (#1381). The name is held before the task starts, against the strip and
    /// every paste still staging, and the paste counts as an upload while the text is
    /// encoded, so Send waits for it. The chat stops it with `cancelPastedTextStaging()`
    /// as it goes away.
    @discardableResult
    func stagePastedText(_ text: String) -> Task<PendingAttachment?, Never> {
        let filename = ComposerLargePaste.filename(avoiding: stagingPasteNames.union(pendingAttachments.map(\.name)))
        stagingPasteNames.insert(filename)
        activeUploadCount += 1
        let id = UUID()
        let limit = uploadsOnSend ? BotAttachmentUpload.maximumFileBytes : PendingAttachment.maximumUploadBytes
        let task = Task { () -> PendingAttachment? in
            defer {
                stagingPasteNames.remove(filename)
                pasteTasks[id] = nil
            }
            // Measured before encoding, so a paste over the file limit never copies its text.
            let data = await Task.detached { text.utf8.count <= limit ? Data(text.utf8) : nil }.value
            activeUploadCount = max(activeUploadCount - 1, 0)
            guard !Task.isCancelled else { return nil }
            guard let data else {
                uploadAttachmentErrorMessage = uploadsOnSend
                    ? BotAttachmentFailure.limit.localizedDescription
                    : PendingAttachment.uploadTooLargeMessage(filename: filename)
                return nil
            }
            return await uploadAttachment(data: data, filename: filename)
        }
        pasteTasks[id] = task
        return task
    }

    /// Stops every long paste still staging, so none lands after its chat is gone.
    func cancelPastedTextStaging() {
        pasteTasks.values.forEach { $0.cancel() }
    }

    /// The text of a staged paste, read from its local copy for `StagedPasteSheet` (#1456).
    /// Nil when the copy is gone or isn't UTF-8.
    func stagedPasteText(_ attachment: PendingAttachment) async -> StagedPasteText? {
        guard let file = attachment.draftFileName,
              let data = try? await draftAttachmentStore.data(named: file) else { return nil }
        return await Task.detached { StagedPasteText(data: data) }.value
    }

    /// Puts edited text in place of a staged paste (#1456). The new copy is written first and
    /// the draft saved before the old copy goes, so a failure at any step leaves the original
    /// whole. The save counts as an upload, so Send waits for it. A tile removed or changed
    /// meanwhile stays as it is. Returns why the edit did not save, or nil once it has.
    func replaceStagedPaste(_ attachment: PendingAttachment, with text: String) async -> String? {
        let isCurrent = { (staged: PendingAttachment, file: String?) in staged.id == attachment.id && staged.draftFileName == file }
        let notSaved = String(localized: "Your original text is unchanged. Try again shortly.")
        let gone = String(localized: "This attachment is no longer in the message.")
        guard let old = attachment.draftFileName, pendingAttachments.contains(where: { isCurrent($0, old) }) else { return gone }

        activeUploadCount += 1
        defer {
            activeUploadCount = max(activeUploadCount - 1, 0)
            refreshAttachmentSlots()
        }
        let limit = BotAttachmentUpload.maximumFileBytes
        let data = await Task.detached { text.utf8.count <= limit ? Data(text.utf8) : nil }.value
        let others = pendingAttachments.reduce(stagingBytes) { $1.id == attachment.id ? $0 : $0 + ($1.size ?? limit) }
        guard let data, others + data.count <= BotAttachmentUpload.maximumTotalBytes else {
            return BotAttachmentFailure.limit.localizedDescription
        }
        stagingBytes += data.count
        defer { stagingBytes -= data.count }

        // A failure is reported in the sheet, so the composer's banner stays as it was.
        let banner = uploadAttachmentErrorMessage
        guard let file = await saveDraftCopy(data, filename: attachment.name, attachmentID: attachment.id,
                                             maximumBytes: limit) else {
            uploadAttachmentErrorMessage = banner
            return notSaved
        }
        guard let index = pendingAttachments.firstIndex(where: { isCurrent($0, old) }) else {
            attachmentLease?.filesByAttachmentID[attachment.id] = pendingAttachments.first { $0.id == attachment.id }?.draftFileName
            await deleteUnreferencedCopy(file)
            return gone
        }

        let original = pendingAttachments[index]
        let edited = PendingAttachment(
            id: original.id, name: original.name, path: original.path, mime: original.mime,
            size: data.count, isImage: original.isImage, draftFileName: file
        )
        pendingAttachments[index] = edited
        let key = attachmentLease?.key
        if let key { draftStore?.replaceAttachmentRecord(ChatDraftAttachment(pending: edited), for: key) }
        // Nothing else references the old copy now; an import freeing space must not take it
        // before the save below decides whether the edit stands.
        attachmentLease?.files.insert(old)
        do {
            try await draftStore?.flush()
        } catch {
            if let index = pendingAttachments.firstIndex(where: { isCurrent($0, file) }) { pendingAttachments[index] = original }
            if let key { draftStore?.replaceAttachmentRecord(ChatDraftAttachment(pending: original), for: key) }
            attachmentLease?.filesByAttachmentID[attachment.id] = old
            attachmentLease?.files.remove(old)
            await deleteUnreferencedCopy(file)
            return notSaved
        }
        attachmentLease?.files.remove(old)
        await deleteUnreferencedCopy(old)
        return nil
    }

    /// Re-uploads a restored draft attachment from its durable local copy,
    /// preserving the draft record's identity so the restored pending
    /// attachment reconciles with the persisted draft instead of duplicating
    /// it. Failures stay quiet (no banner, no delegate error): the caller
    /// reports them in aggregate and keeps the record for a later retry.
    @discardableResult
    func reuploadDraftAttachment(data: Data, draftAttachment: ChatDraftAttachment) async -> PendingAttachment? {
        if let file = draftAttachment.file { attachmentLease?.filesByAttachmentID[draftAttachment.id] = file }
        if uploadsOnSend {
            // A Hermes send uploads it later; restoring only shows the local copy again.
            let attachment = PendingAttachment(
                id: draftAttachment.id, name: draftAttachment.name, path: "", mime: draftAttachment.mime,
                size: draftAttachment.size, isImage: draftAttachment.isImage,
                thumbnailData: draftAttachment.isImage ? await Self.thumbnail(of: data) : nil,
                draftFileName: draftAttachment.file
            )
            pendingAttachments.append(attachment)
            refreshAttachmentSlots()
            return attachment
        }
        guard let attachment = await performUpload(
            data: data,
            filename: draftAttachment.name,
            previewData: draftAttachment.isImage ? data : nil,
            draftFileName: draftAttachment.file,
            draftAttachmentID: draftAttachment.id,
            reportsErrors: false
        ) else {
            return nil
        }
        pendingAttachments.append(attachment)
        refreshAttachmentSlots()
        return attachment
    }

    /// Keeps a durable local copy for a Hermes send to upload, under Bot Chat's rules:
    /// eight files, 25 MB each and 50 MB in all; images re-encoded as JPEG, or PNG with
    /// transparency (`BotAttachmentUpload.prepare`). Counts as an upload while it runs, so
    /// the composer waits for it as it waits for a webui upload.
    private func stageForSend(data: Data, filename: String) async -> PendingAttachment? {
        let stagingID = UUID()
        stagingIDs.insert(stagingID)
        activeUploadCount += 1
        uploadStartGeneration += 1
        uploadAttachmentErrorMessage = nil
        refreshAttachmentSlots()
        defer {
            stagingIDs.remove(stagingID)
            activeUploadCount = max(activeUploadCount - 1, 0)
            refreshAttachmentSlots()
        }
        let prepared: (data: Data, name: String, mime: String, image: Bool)
        do {
            guard pendingAttachments.count + stagingIDs.count <= HermexAttachmentPickerPolicy.maximumBotAttachments,
                  !data.isEmpty, data.count <= BotAttachmentUpload.maximumFileBytes
            else { throw BotAttachmentFailure.limit }
            prepared = try await Task.detached { try BotAttachmentUpload.prepare(data: data, filename: filename) }.value
            let staged = pendingAttachments.reduce(stagingBytes) { $0 + ($1.size ?? BotAttachmentUpload.maximumFileBytes) }
            guard staged + prepared.data.count <= BotAttachmentUpload.maximumTotalBytes else { throw BotAttachmentFailure.limit }
        } catch {
            uploadAttachmentErrorMessage = error.localizedDescription
            return nil
        }
        stagingBytes += prepared.data.count
        defer { stagingBytes -= prepared.data.count }
        guard let file = await saveDraftCopy(prepared.data, filename: prepared.name, attachmentID: stagingID,
                                             maximumBytes: BotAttachmentUpload.maximumFileBytes) else { return nil }
        // A cancelled import (a paste whose chat went away) keeps no copy and no tile.
        guard !Task.isCancelled else {
            await deleteDraftCopy(named: file, attachmentID: stagingID)
            return nil
        }
        let attachment = PendingAttachment(
            id: stagingID, name: prepared.name, path: "", mime: prepared.mime, size: prepared.data.count,
            isImage: prepared.image, thumbnailData: prepared.image ? await Self.thumbnail(of: prepared.data) : nil,
            draftFileName: file
        )
        pendingAttachments.append(attachment)
        refreshAttachmentSlots()
        return attachment
    }

    /// Saves the app-owned copy a staged attachment is restored from, or reports why it
    /// could not and returns nil.
    private func saveDraftCopy(_ data: Data, filename: String, attachmentID: UUID,
                               maximumBytes: Int = PendingAttachment.maximumUploadBytes) async -> String? {
        let draftFileName: String
        do {
            if let draftStore, let attachmentLease {
                draftFileName = try await draftStore.stageAttachment(
                    data: data, filename: filename, lease: attachmentLease, attachmentID: attachmentID,
                    maximumFileBytes: maximumBytes
                )
            } else {
                draftFileName = try await draftAttachmentStore.save(data: data, suggestedFilename: filename)
            }
        } catch is CancellationError {
            return nil
        } catch let error as ChatDraftStorageError {
            switch error {
            case .attachmentLimit:
                uploadAttachmentErrorMessage = String(localized: "A draft can have up to 10 attachments.")
            case .unavailable:
                uploadAttachmentErrorMessage = String(localized: "Attachment storage is busy. Try again shortly.")
            }
            return nil
        } catch {
            uploadAttachmentErrorMessage = String(localized: "Could not save the attachment on this device.")
            delegate?.attachmentCoordinatorDidFail(error)
            return nil
        }
        attachmentLease?.filesByAttachmentID[attachmentID] = draftFileName
        attachmentLease?.files.remove(draftFileName)
        return draftFileName
    }

    /// The staged files a Hermes Send or Queue uploads, in strip order, each read from its
    /// local copy only when the send gets to it.
    func outgoingAttachments(_ attachments: [PendingAttachment]) -> [HermesChatTurnCoordinator.OutgoingAttachment] {
        attachments.map { attachment in
            HermesChatTurnCoordinator.OutgoingAttachment(
                name: attachment.name, mime: attachment.mime, isImage: attachment.isImage
            ) { [draftAttachmentStore] in
                guard let file = attachment.draftFileName else { throw BotAttachmentFailure.unreadable }
                let data = try await draftAttachmentStore.data(named: file)
                guard !data.isEmpty, data.count <= BotAttachmentUpload.maximumFileBytes else { throw BotAttachmentFailure.limit }
                return data
            }
        }
    }

    /// Removes files a send carried from the strip and deletes their local copies.
    func consumeSentAttachments(_ sent: [PendingAttachment]) async {
        let ids = Set(sent.map(\.id))
        pendingAttachments.removeAll { ids.contains($0.id) }
        refreshAttachmentSlots()
        for attachment in sent {
            guard let file = attachment.draftFileName else { continue }
            await deleteDraftCopy(named: file, attachmentID: attachment.id)
        }
    }

    nonisolated private static func thumbnail(of data: Data) async -> Data? {
        await ImagePreviewDownsampler.previewDataAsync(from: data, maxPixelSize: ImagePreviewDownsampler.attachmentMaxPixelSize)
    }

    /// Uploads a single file and returns it as a `PendingAttachment` *without*
    /// adding it to `pendingAttachments`. The voice-note flow uses this: the clip
    /// is sent as the sole attachment of its own message, so it must not sweep up
    /// the user's typed draft or other staged attachments — and it is never part
    /// of a persisted draft. Failures surface via `uploadAttachmentErrorMessage`
    /// and the method returns nil.
    func uploadStandaloneAttachment(data: Data, filename: String) async -> PendingAttachment? {
        await performUpload(
            data: data,
            filename: filename,
            previewData: nil,
            draftFileName: nil,
            draftAttachmentID: nil,
            reportsErrors: true
        )
    }

    private func performUpload(
        data: Data,
        filename: String,
        previewData: Data?,
        draftFileName: String?,
        draftAttachmentID: UUID?,
        reportsErrors: Bool
    ) async -> PendingAttachment? {
        guard delegate?.attachmentIsViewingCachedData != true else {
            if reportsErrors {
                uploadAttachmentErrorMessage = String(localized: "Reconnect to the server to upload attachments.")
            }
            return nil
        }

        guard data.count <= PendingAttachment.maximumUploadBytes else {
            if reportsErrors {
                uploadAttachmentErrorMessage = PendingAttachment.uploadTooLargeMessage(filename: filename)
            }
            return nil
        }

        guard let sessionID = delegate?.attachmentSessionID else {
            if reportsErrors {
                uploadAttachmentErrorMessage = String(localized: "The server did not provide a session ID.")
            }
            return nil
        }

        let displayFilename = Self.normalizedAttachmentFilename(filename)
        let uploadFilename = reserveUploadFilename(preferredFilename: displayFilename)

        activeUploadCount += 1
        uploadStartGeneration += 1
        if reportsErrors {
            uploadAttachmentErrorMessage = nil
            delegate?.attachmentCoordinatorWillUpload()
        }
        defer {
            releaseReservedUploadFilename(uploadFilename)
            activeUploadCount = max(activeUploadCount - 1, 0)
        }

        do {
            let response = try await client.uploadFile(sessionID: sessionID, data: data, filename: uploadFilename)
            if let errorMessage = response.error {
                if reportsErrors {
                    uploadAttachmentErrorMessage = errorMessage
                }
                return nil
            }

            guard let path = response.path, !path.isEmpty else {
                if reportsErrors {
                    uploadAttachmentErrorMessage = String(localized: "The server did not return the uploaded file path.")
                }
                return nil
            }

            return PendingAttachment(
                id: draftAttachmentID ?? UUID(),
                name: displayFilename,
                path: path,
                mime: response.mime ?? "application/octet-stream",
                size: response.size,
                isImage: response.isImage ?? false,
                thumbnailData: await Self.thumbnailData(for: response, originalData: data, previewData: previewData),
                draftFileName: draftFileName
            )
        } catch {
            if reportsErrors {
                delegate?.attachmentCoordinatorDidFail(error)
                uploadAttachmentErrorMessage = error.localizedDescription
            }
            return nil
        }
    }

    func clearPendingAttachments() {
        pendingAttachments.removeAll()
        refreshAttachmentSlots()
        uploadAttachmentErrorMessage = nil
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        refreshAttachmentSlots()
    }

    func setUploadAttachmentError(_ message: String?) {
        uploadAttachmentErrorMessage = message
    }

    func deleteDraftCopy(named fileName: String, attachmentID: UUID) async {
        attachmentLease?.filesByAttachmentID[attachmentID] = nil
        if let key = attachmentLease?.key {
            draftStore?.removeAttachmentReference(id: attachmentID, for: key)
        }
        await deleteUnreferencedCopy(fileName)
    }

    /// Deletes a local copy unless a draft or a live owner still holds it.
    private func deleteUnreferencedCopy(_ fileName: String) async {
        if let draftStore {
            await draftStore.deleteAttachmentIfUnreferenced(fileName)
        } else {
            await draftAttachmentStore.delete(named: fileName)
        }
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
        refreshAttachmentSlots()
        return ChatAttachmentSendPreparation(
            attachments: attachmentsForSend,
            messageAttachments: messageAttachments
        )
    }

    func restorePendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        guard !attachments.isEmpty else { return }
        let existingIDs = Set(pendingAttachments.map(\.id))
        pendingAttachments = attachments.filter { !existingIDs.contains($0.id) } + pendingAttachments
        refreshAttachmentSlots()
    }

    func appendPendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        guard !attachments.isEmpty else { return }
        pendingAttachments += attachments
        refreshAttachmentSlots()
    }

    func consumePendingAttachments() -> [PendingAttachment] {
        let attachments = pendingAttachments
        pendingAttachments.removeAll()
        refreshAttachmentSlots()
        return attachments
    }

    func replacePendingAttachments(_ attachments: [PendingAttachment]) {
        protectRestoringAttachments(attachments.map(ChatDraftAttachment.init(pending:)))
        pendingAttachments = attachments
        refreshAttachmentSlots()
    }

    func removeLocalPreviews(messageID: String) {
        localAttachmentPreviews[messageID] = nil
    }

    /// A Hermes prompt row's thumbnails, by file name: its chips carry no path (#1012).
    func keepLocalPreviews(of attachments: [PendingAttachment], forMessageID messageID: String) {
        var previews: [String: Data] = [:]
        for attachment in attachments { previews[attachment.name] = attachment.thumbnailData }
        if !previews.isEmpty { localAttachmentPreviews[messageID] = previews }
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
