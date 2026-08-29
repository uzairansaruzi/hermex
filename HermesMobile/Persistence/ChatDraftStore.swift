import Foundation
import os

/// One staged composer attachment as referenced by a persisted draft. `file`
/// names the durable app-owned copy in `ChatDraftAttachmentStore`. It remains
/// optional so older or partially corrupt persisted records decode safely;
/// newly staged attachments are not accepted without a durable copy.
struct ChatDraftAttachment: Equatable, Sendable {
    let id: UUID
    let name: String
    let mime: String
    let size: Int?
    let isImage: Bool
    let file: String?
}

/// Effective composer choices snapshotted for a draft context. Restored for
/// new-chat contexts after revalidation against the live server configuration;
/// existing sessions keep loading their configuration from the server.
struct ChatDraftSettings: Equatable, Sendable {
    var modelID: String?
    var modelProviderID: String?
    var reasoningEffort: String?
    var profileName: String?
    var workspacePath: String?

    var isEmpty: Bool {
        let normalized = normalized()
        return normalized.modelID == nil
            && normalized.modelProviderID == nil
            && normalized.reasoningEffort == nil
            && normalized.profileName == nil
            && normalized.workspacePath == nil
    }

    /// Trims every field and collapses blanks to nil.
    func normalized() -> ChatDraftSettings {
        Self.normalized(
            modelID: modelID,
            modelProviderID: modelProviderID,
            reasoningEffort: reasoningEffort,
            profileName: profileName,
            workspacePath: workspacePath
        )
    }

    private static func normalized(
        modelID: String?,
        modelProviderID: String?,
        reasoningEffort: String?,
        profileName: String?,
        workspacePath: String?
    ) -> ChatDraftSettings {
        func value(_ raw: String?) -> String? {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }

        return ChatDraftSettings(
            modelID: value(modelID),
            modelProviderID: value(modelProviderID),
            reasoningEffort: value(reasoningEffort),
            profileName: value(profileName),
            workspacePath: value(workspacePath)
        )
    }
}

/// Everything a composer context restores after navigation, termination, or an
/// abandoned new chat: typed text, staged attachments, and effective settings.
struct ChatDraft: Equatable, Sendable {
    var text = ""
    var attachments: [ChatDraftAttachment] = []
    var settings: ChatDraftSettings?

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && (settings?.isEmpty ?? true)
    }
}

extension ChatDraftAttachment {
    /// The draft record for a staged composer attachment. The record id is the
    /// pending attachment's id so the two stay reconcilable across send-failure
    /// restores and draft syncs.
    init(pending: PendingAttachment) {
        self.init(
            id: pending.id,
            name: pending.name,
            mime: pending.mime,
            size: pending.size,
            isImage: pending.isImage,
            file: pending.draftFileName
        )
    }
}

/// Decides what an accepted send does to a draft's staged attachments.
///
/// A send carries exactly the attachments staged in the composer at the moment
/// it is submitted. Any other record in the draft — one still waiting on a
/// re-upload retry, or one a restore pass has not reached yet — was never
/// carried, so its durable copy must survive and its record must stay in the
/// draft. Getting this wrong deletes files for attachments the user never sent.
enum ChatDraftSendReconciliation {
    struct Outcome: Equatable {
        /// Records the send carried. Their durable copies are now unreferenced
        /// and can be deleted.
        var consumed: [ChatDraftAttachment] = []
        /// Records the send did not carry. They stay in the draft, keep their
        /// durable copies, and remain eligible for a later re-upload.
        var retained: [ChatDraftAttachment] = []
    }

    /// - Parameters:
    ///   - draftRecords: every attachment record the draft held at send time.
    ///   - stagedAttachmentIDs: ids of the attachments actually staged in the
    ///     composer, i.e. the ones the send submitted.
    static func outcome(
        draftRecords: [ChatDraftAttachment],
        stagedAttachmentIDs: Set<UUID>
    ) -> Outcome {
        var outcome = Outcome()
        for record in draftRecords {
            if stagedAttachmentIDs.contains(record.id) {
                outcome.consumed.append(record)
            } else {
                outcome.retained.append(record)
            }
        }
        return outcome
    }
}

struct ChatDraftKey: Hashable, Sendable {
    enum Context: Hashable, Sendable {
        case session(String)
        case newChat
    }

    let serverID: String
    let context: Context

    static func session(server: URL, sessionID: String) -> Self {
        Self(serverID: server.absoluteString, context: .session(sessionID))
    }

    static func newChat(server: URL) -> Self {
        Self(serverID: server.absoluteString, context: .newChat)
    }
}

protocol ChatDraftPersisting: Sendable {
    func load() async -> [ChatDraftKey: ChatDraft]
    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws
}

actor ChatDraftFilePersistence: ChatDraftPersisting {
    #if os(iOS)
    static let fileProtectionType = FileProtectionType.completeUntilFirstUserAuthentication
    #endif

    private struct Document: Codable {
        let version: Int?
        let drafts: [FailableRecord]?

        init(version: Int, records: [Record]) {
            self.version = version
            drafts = records.map { FailableRecord(value: $0) }
        }
    }

    private struct FailableRecord: Codable {
        let value: Record?

        init(value: Record?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? Record(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            guard let value else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
                return
            }
            try value.encode(to: encoder)
        }
    }

    /// Per-element tolerance: one malformed attachment record must not discard
    /// the rest of the draft.
    private struct FailableAttachment: Codable {
        let value: AttachmentRecord?

        init(value: AttachmentRecord?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? AttachmentRecord(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            guard let value else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
                return
            }
            try value.encode(to: encoder)
        }
    }

    private struct AttachmentRecord: Codable {
        let id: String?
        let name: String?
        let mime: String?
        let size: Int?
        let isImage: Bool?
        let file: String?

        init(_ attachment: ChatDraftAttachment) {
            id = attachment.id.uuidString
            name = attachment.name
            mime = attachment.mime
            size = attachment.size
            isImage = attachment.isImage
            file = attachment.file
        }

        var attachment: ChatDraftAttachment? {
            guard
                let idString = id?.trimmingCharacters(in: .whitespacesAndNewlines),
                let id = UUID(uuidString: idString),
                let name = Self.nonEmpty(name),
                let mime = Self.nonEmpty(mime)
            else {
                return nil
            }

            // Stored file names are plain names generated by
            // ChatDraftAttachmentStore; reject anything with path components so
            // a corrupted document cannot point outside the attachments
            // directory. A rejected file name degrades the record to
            // metadata-only instead of dropping it.
            let sanitizedFile = file.flatMap { rawFile -> String? in
                let trimmed = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed != ".",
                      trimmed != "..",
                      trimmed == URL(fileURLWithPath: trimmed).lastPathComponent
                else {
                    return nil
                }
                return trimmed
            }

            return ChatDraftAttachment(
                id: id,
                name: name,
                mime: mime,
                size: size,
                isImage: isImage ?? false,
                file: sanitizedFile
            )
        }

        private static func nonEmpty(_ raw: String?) -> String? {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    private struct SettingsRecord: Codable {
        let modelID: String?
        let modelProviderID: String?
        let reasoningEffort: String?
        let profileName: String?
        let workspacePath: String?

        init(_ settings: ChatDraftSettings) {
            modelID = settings.modelID
            modelProviderID = settings.modelProviderID
            reasoningEffort = settings.reasoningEffort
            profileName = settings.profileName
            workspacePath = settings.workspacePath
        }

        var settings: ChatDraftSettings? {
            let normalized = ChatDraftSettings(
                modelID: modelID,
                modelProviderID: modelProviderID,
                reasoningEffort: reasoningEffort,
                profileName: profileName,
                workspacePath: workspacePath
            ).normalized()
            return normalized.isEmpty ? nil : normalized
        }
    }

    private struct Record: Codable {
        let serverID: String?
        let context: String?
        let sessionID: String?
        let text: String?
        let attachments: [FailableAttachment]?
        let settings: SettingsRecord?

        private enum CodingKeys: String, CodingKey {
            case serverID
            case context
            case sessionID
            case text
            case attachments
            case settings
        }

        init(key: ChatDraftKey, draft: ChatDraft) {
            serverID = key.serverID
            switch key.context {
            case .session(let sessionID):
                context = "session"
                self.sessionID = sessionID
            case .newChat:
                context = "newChat"
                sessionID = nil
            }
            text = draft.text
            attachments = draft.attachments.map { FailableAttachment(value: AttachmentRecord($0)) }
            settings = draft.settings.map { SettingsRecord($0) }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Field-level tolerance: an unexpected shape in one field must not
            // discard the whole draft.
            serverID = (try? container.decodeIfPresent(String.self, forKey: .serverID)) ?? nil
            context = (try? container.decodeIfPresent(String.self, forKey: .context)) ?? nil
            sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
            attachments = (try? container.decodeIfPresent([FailableAttachment].self, forKey: .attachments)) ?? nil
            settings = (try? container.decodeIfPresent(SettingsRecord.self, forKey: .settings)) ?? nil
        }

        var draft: (key: ChatDraftKey, draft: ChatDraft)? {
            guard
                let serverID = serverID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !serverID.isEmpty,
                let context
            else {
                return nil
            }

            let key: ChatDraftKey
            switch context {
            case "session":
                guard
                    let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !sessionID.isEmpty
                else {
                    return nil
                }
                key = ChatDraftKey(serverID: serverID, context: .session(sessionID))
            case "newChat":
                key = ChatDraftKey(serverID: serverID, context: .newChat)
            default:
                return nil
            }

            let draft = ChatDraft(
                text: text ?? "",
                attachments: (attachments ?? []).compactMap(\.value?.attachment),
                settings: settings?.settings
            )
            guard !draft.isEmpty else { return nil }
            return (key, draft)
        }
    }

    private static let currentVersion = 2
    /// Version 1 documents carry text-only records; they decode through the
    /// same schema (attachments/settings are optional fields) so upgrading
    /// never loses saved drafts.
    private static let readableVersions: Set<Int> = [1, currentVersion]
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "ChatDraftStore"
    )

    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseURL = directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = baseURL
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json", isDirectory: false)
    }

    func load() async -> [ChatDraftKey: ChatDraft] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version.map(Self.readableVersions.contains) == true else { return [:] }

            return (document.drafts ?? []).reduce(into: [:]) { result, record in
                guard let draft = record.value?.draft else { return }
                result[draft.key] = draft.draft
            }
        } catch {
            Self.logger.warning("Ignoring unreadable persisted chat drafts: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {
        let nonEmptyDrafts = drafts.filter { !$0.value.isEmpty }
        let records = nonEmptyDrafts
            .map { Record(key: $0.key, draft: $0.value) }
            .sorted {
                let lhs = ($0.serverID ?? "", $0.context ?? "", $0.sessionID ?? "")
                let rhs = ($1.serverID ?? "", $1.context ?? "", $1.sessionID ?? "")
                return lhs < rhs
            }
        let data = try JSONEncoder().encode(
            Document(version: Self.currentVersion, records: records)
        )
        let directoryURL = fileURL.deletingLastPathComponent()

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try setProtectedFileAttributes(at: directoryURL)
        try data.write(to: fileURL, options: [.atomic])
        try setProtectedFileAttributes(at: fileURL)
    }

    private func setProtectedFileAttributes(at url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtectionType],
            ofItemAtPath: url.path
        )
        #endif
    }
}

@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore(attachmentStore: ChatDraftAttachmentStore.shared)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "ChatDraftStore"
    )

    private let persistence: any ChatDraftPersisting
    private let attachmentStore: (any ChatDraftAttachmentStoring)?
    private let debounceDuration: Duration
    private let attachmentSweepMaxAge: TimeInterval
    private var drafts: [ChatDraftKey: ChatDraft] = [:]
    private var keysChangedBeforeLoad: Set<ChatDraftKey> = []
    private var loadTask: Task<[ChatDraftKey: ChatDraft], Never>?
    private var persistTask: Task<Void, Never>?
    private var isLoaded = false

    init(
        persistence: any ChatDraftPersisting = ChatDraftFilePersistence(),
        attachmentStore: (any ChatDraftAttachmentStoring)? = nil,
        debounceDuration: Duration = .milliseconds(200),
        attachmentSweepMaxAge: TimeInterval = 24 * 60 * 60
    ) {
        self.persistence = persistence
        self.attachmentStore = attachmentStore
        self.debounceDuration = debounceDuration
        self.attachmentSweepMaxAge = attachmentSweepMaxAge
    }

    func draft(for key: ChatDraftKey) async -> ChatDraft? {
        await loadIfNeeded()
        return drafts[key]
    }

    /// Updates the draft's typed text without disturbing its attachments or
    /// settings.
    func setDraft(_ text: String, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.text = text }
    }

    /// Replaces the draft's staged-attachment records without disturbing its
    /// text or settings.
    func setAttachments(_ attachments: [ChatDraftAttachment], for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.attachments = attachments }
    }

    /// Replaces the draft's settings snapshot without disturbing its text or
    /// attachments.
    func setSettings(_ settings: ChatDraftSettings, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        let normalized = settings.normalized()
        updateDraft(for: key) { draft in
            draft.settings = normalized.isEmpty ? nil : normalized
        }
    }

    /// Removes one composer draft and deletes attachment copies that no other
    /// draft still references. Used after the server accepts session deletion.
    func discardDraft(for key: ChatDraftKey) async {
        await loadIfNeeded()
        await discardDrafts(matching: { $0 == key })
    }

    /// Removes every composer draft owned by a server before that server is
    /// removed from the app.
    func discardDrafts(for server: URL) async {
        await loadIfNeeded()
        let serverID = server.absoluteString
        await discardDrafts(matching: { $0.serverID == serverID })
    }

    /// Clears the draft's typed text. Attachments and settings are managed
    /// separately (attachments sync from the composer observationally).
    func clearDraft(for key: ChatDraftKey) {
        setDraft("", for: key)
    }

    func resolveSubmission(
        submittedText: String,
        currentText: String,
        didStart: Bool,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> String {
        if didStart {
            // A started send consumed any staged attachments, even when the
            // user kept typing during the request.
            updateDraft(for: key) { $0.attachments = [] }
        }

        guard !draftWasEdited else { return currentText }

        if didStart {
            if currentText.isEmpty {
                // Content is consumed by the accepted send; applicable settings
                // stay so the context keeps them.
                updateDraft(for: key) { draft in
                    draft.text = ""
                    draft.attachments = []
                }
            }
            return currentText
        }

        if currentText.isEmpty {
            setDraft(submittedText, for: key)
            return submittedText
        }
        return currentText
    }

    func resolveConsumedInput(
        submittedText: String,
        currentText: String,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> String {
        guard !draftWasEdited, currentText == submittedText else { return currentText }
        clearDraft(for: key)
        return ""
    }

    /// Moves the entire draft object (text, attachments, settings) between
    /// contexts, e.g. a new-chat draft into its created session.
    @discardableResult
    func moveDraft(from sourceKey: ChatDraftKey, to targetKey: ChatDraftKey) -> ChatDraft {
        markChangedBeforeLoad(sourceKey)
        markChangedBeforeLoad(targetKey)

        let movedDraft = drafts[sourceKey] ?? drafts[targetKey] ?? ChatDraft()
        drafts.removeValue(forKey: sourceKey)
        if movedDraft.isEmpty {
            drafts.removeValue(forKey: targetKey)
        } else {
            drafts[targetKey] = movedDraft
        }
        schedulePersist()
        return movedDraft
    }

    @discardableResult
    func restoreAbandonedNewChatDraft(
        from sessionKey: ChatDraftKey,
        to newChatKey: ChatDraftKey,
        didStartConversation: Bool
    ) -> ChatDraft? {
        guard !didStartConversation else { return nil }
        return moveDraft(from: sessionKey, to: newChatKey)
    }

    func flush() async throws {
        persistTask?.cancel()
        persistTask = nil
        try await persistNow()
    }

    private func persistNow() async throws {
        await loadIfNeeded()
        try await persistence.write(drafts)
    }

    private func updateDraft(for key: ChatDraftKey, mutate: (inout ChatDraft) -> Void) {
        var draft = drafts[key] ?? ChatDraft()
        mutate(&draft)

        if draft.isEmpty {
            guard drafts[key] != nil else { return }
            drafts.removeValue(forKey: key)
        } else {
            guard drafts[key] != draft else { return }
            drafts[key] = draft
        }
        schedulePersist()
    }

    private func discardDrafts(matching shouldDiscard: (ChatDraftKey) -> Bool) async {
        let discardedKeys = drafts.keys.filter(shouldDiscard)
        guard !discardedKeys.isEmpty else { return }

        let discardedDrafts = discardedKeys.compactMap { drafts.removeValue(forKey: $0) }
        let stillReferencedFiles = Set(drafts.values.flatMap { $0.attachments.compactMap(\.file) })
        let filesToDelete = Set(discardedDrafts.flatMap { $0.attachments.compactMap(\.file) })
            .subtracting(stillReferencedFiles)
        schedulePersist()

        guard let attachmentStore else { return }
        for fileName in filesToDelete.sorted() {
            await attachmentStore.delete(named: fileName)
        }
    }

    private func markChangedBeforeLoad(_ key: ChatDraftKey) {
        if !isLoaded {
            keysChangedBeforeLoad.insert(key)
        }
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }

        if loadTask == nil {
            let persistence = persistence
            loadTask = Task {
                await persistence.load()
            }
        }

        guard let loadTask else { return }
        let persistedDrafts = await loadTask.value
        guard !isLoaded else { return }

        for (key, draft) in persistedDrafts where !keysChangedBeforeLoad.contains(key) {
            drafts[key] = draft
        }
        isLoaded = true
        self.loadTask = nil
        sweepOrphanedAttachmentFiles()
    }

    /// Backstop cleanup for orphaned attachment copies — e.g. an ingest that
    /// crashed between writing the durable copy and persisting its record.
    /// Explicit deletes cover successful sends and discards; this reclaims the
    /// rest, age-gated so copies whose record write is still pending survive.
    private func sweepOrphanedAttachmentFiles() {
        guard let attachmentStore else { return }

        let referencedFiles = Set(drafts.values.flatMap { draft in
            draft.attachments.compactMap(\.file)
        })
        let maxAge = attachmentSweepMaxAge
        Task {
            await attachmentStore.sweep(keepingReferenced: referencedFiles, olderThan: maxAge)
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
                try await persistNow()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("Could not persist chat drafts: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
