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
/// abandoned new chat: typed text, quoted passages, staged attachments, and
/// effective settings.
struct ChatDraft: Equatable, Sendable {
    var text = ""
    var quotes: [ComposerQuote] = []
    var attachments: [ChatDraftAttachment] = []
    var settings: ChatDraftSettings?
    // Written durably before a Bot Chat or Hermes session submission; acknowledgement
    // loss must survive relaunch (#508).
    var botSubmissionUncertain = false
    var lastUsedAt: Date?

    var isEmpty: Bool {
        text.isEmpty && quotes.isEmpty && attachments.isEmpty && (settings?.isEmpty ?? true) && !botSubmissionUncertain
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

/// Folds messages that were queued behind a run into their chat's draft when
/// the user leaves mid-run, so they come back for review instead of sending
/// on their own (#857).
enum ChatDraftQueueParking {
    /// Queued texts first, in queue order, then the draft's own text, joined
    /// by blank lines: the order they were typed in. The draft's quotes stay
    /// quotes; a queued text already carries its quotes as Markdown. Queued
    /// attachments go after the draft's own, without duplicate ids.
    static func merged(
        _ draft: ChatDraft,
        queuedTexts: [String],
        queuedAttachments: [ChatDraftAttachment]
    ) -> ChatDraft {
        var merged = draft
        merged.text = (queuedTexts + [draft.text])
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var attachmentIDs = Set(draft.attachments.map(\.id))
        merged.attachments += queuedAttachments.filter { attachmentIDs.insert($0.id).inserted }
        return merged
    }
}

struct ChatDraftKey: Hashable, Sendable {
    enum Context: Hashable, Sendable {
        case session(String)
        case bot(connectionID: UUID, profile: String)
        /// A Hermes session on a Hermes connection, by its stored key; nil for a new
        /// session not created yet (`ConversationTarget`).
        case hermesSession(connectionID: UUID, profile: String, key: String?)
        case newChat
    }

    let serverID: String
    let context: Context

    static func session(server: URL, sessionID: String) -> Self {
        Self(serverID: server.absoluteString, context: .session(sessionID))
    }

    static func bot(server: URL, connectionID: UUID, profile: String) -> Self {
        Self(serverID: server.absoluteString, context: .bot(connectionID: connectionID, profile: profile))
    }

    static func hermesSession(server: URL, connectionID: UUID, profile: String, key: String?) -> Self {
        Self(serverID: server.absoluteString, context: .hermesSession(connectionID: connectionID, profile: profile, key: key))
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

    /// Per-element tolerance keeps one damaged quote from discarding the rest
    /// of the draft.
    private struct FailableQuote: Codable {
        let value: QuoteRecord?

        init(value: QuoteRecord?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? QuoteRecord(from: decoder)
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

    private struct QuoteRecord: Codable {
        let id: String?
        let text: String?

        init(_ quote: ComposerQuote) {
            id = quote.id.uuidString
            text = quote.text
        }

        var quote: ComposerQuote? {
            guard
                let idString = id?.trimmingCharacters(in: .whitespacesAndNewlines),
                let id = UUID(uuidString: idString),
                let text,
                !text.isEmpty
            else {
                return nil
            }
            return ComposerQuote(id: id, text: text)
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
        let quotes: [FailableQuote]?
        let attachments: [FailableAttachment]?
        let settings: SettingsRecord?
        var connectionID: UUID?
        var profile: String?
        var botSubmissionUncertain: Bool?

        let lastUsedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case serverID
            case context
            case sessionID
            case text
            case quotes
            case attachments
            case settings, connectionID, profile, botSubmissionUncertain, lastUsedAt
        }

        init(key: ChatDraftKey, draft: ChatDraft) {
            serverID = key.serverID
            switch key.context {
            case .session(let sessionID):
                context = "session"
                self.sessionID = sessionID
            case .bot(let connectionID, let profile):
                context = "bot"
                sessionID = nil
                self.connectionID = connectionID
                self.profile = profile
            case .hermesSession(let connectionID, let profile, let key):
                context = "hermesSession"
                sessionID = key
                self.connectionID = connectionID
                self.profile = profile
            case .newChat:
                context = "newChat"
                sessionID = nil
            }
            lastUsedAt = draft.lastUsedAt
            botSubmissionUncertain = draft.botSubmissionUncertain
            text = draft.text
            quotes = draft.quotes.map { FailableQuote(value: QuoteRecord($0)) }
            attachments = draft.attachments.map { FailableAttachment(value: AttachmentRecord($0)) }
            settings = draft.settings.map { SettingsRecord($0) }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastUsedAt = try? container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            // Field-level tolerance: an unexpected shape in one field must not
            // discard the whole draft.
            serverID = (try? container.decodeIfPresent(String.self, forKey: .serverID)) ?? nil
            context = (try? container.decodeIfPresent(String.self, forKey: .context)) ?? nil
            sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
            connectionID = try? container.decodeIfPresent(UUID.self, forKey: .connectionID)
            profile = try? container.decodeIfPresent(String.self, forKey: .profile)
            // A malformed uncertainty field fails closed for Bot and Hermes session records.
            botSubmissionUncertain = (try? container.decodeIfPresent(Bool.self, forKey: .botSubmissionUncertain))
                ?? (["bot", "hermesSession"].contains(context) && container.contains(.botSubmissionUncertain))
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
            quotes = (try? container.decodeIfPresent([FailableQuote].self, forKey: .quotes)) ?? nil
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
            case "bot":
                guard let connectionID, let profile, !profile.isEmpty else { return nil }
                key = ChatDraftKey(serverID: serverID, context: .bot(connectionID: connectionID, profile: profile))
            case "hermesSession":
                guard let connectionID, let profile, !profile.isEmpty else { return nil }
                let session = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                key = ChatDraftKey(serverID: serverID, context: .hermesSession(
                    connectionID: connectionID, profile: profile, key: session?.isEmpty == false ? session : nil))
            case "newChat":
                key = ChatDraftKey(serverID: serverID, context: .newChat)
            default:
                return nil
            }

            let draft = ChatDraft(
                text: text ?? "",
                quotes: (quotes ?? []).compactMap(\.value?.quote),
                attachments: (attachments ?? []).compactMap(\.value?.attachment),
                settings: settings?.settings,
                botSubmissionUncertain: ["bot", "hermesSession"].contains(context) && (botSubmissionUncertain ?? false),
                lastUsedAt: lastUsedAt
            )
            guard !draft.isEmpty else { return nil }
            return (key, draft)
        }
    }

    private static let currentVersion = 4
    /// Older documents decode through the same schema because every field added
    /// after typed text is optional.
    private static let readableVersions: Set<Int> = [1, 2, 3, currentVersion]
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
    static let maximumAttachmentCount = 10

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
    /// Sessions deleted in this launch. On iPad a chat stays on screen while
    /// its session is deleted from the sidebar, so it parks its queue after
    /// the discard; that must not bring back a draft nobody can open.
    private var deletedSessionKeys: Set<ChatDraftKey> = []
    private var loadTask: Task<[ChatDraftKey: ChatDraft], Never>?
    private var persistTask: Task<Void, Never>?
    private var isLoaded = false
    private let retainedByteLimit: Int
    private var retentionLeases: [WeakDraftAttachmentLease] = []
    private var retiringAttachmentFiles: Set<String> = []
    private var storageBusy = false
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []


    init(
        persistence: any ChatDraftPersisting = ChatDraftFilePersistence(),
        attachmentStore: (any ChatDraftAttachmentStoring)? = nil,
        debounceDuration: Duration = .milliseconds(200),
        attachmentSweepMaxAge: TimeInterval = 24 * 60 * 60,
        retainedByteLimit: Int = 200 * 1024 * 1024
    ) {
        self.retainedByteLimit = retainedByteLimit
        self.persistence = persistence
        self.attachmentStore = attachmentStore
        self.debounceDuration = debounceDuration
        self.attachmentSweepMaxAge = attachmentSweepMaxAge
    }

    func draft(for key: ChatDraftKey) async -> ChatDraft? {
        await loadIfNeeded()
        // Hydration must not capture a reference from a tentative cleanup write.
        await lockStorage()
        defer { unlockStorage() }
        return drafts[key]
    }

    /// Updates the draft's typed text without disturbing its attachments or
    /// settings.
    func setDraft(_ text: String, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.text = text }
    }

    /// Marks a Bot Chat or Hermes session prompt sent with its outcome unknown (#508).
    func setBotSubmissionUncertain(_ uncertain: Bool, for key: ChatDraftKey) {
        switch key.context {
        case .bot, .hermesSession: break
        case .session, .newChat: return
        }
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.botSubmissionUncertain = uncertain }
    }

    /// Drops Bot Chat and Hermes session drafts for a server, one connection, or one
    /// deleted bot on it.
    func discardBotDrafts(server: URL, connectionID: UUID? = nil, profile: String? = nil) async {
        await loadIfNeeded()
        await discardDrafts { key in
            guard key.serverID == server.absoluteString else { return false }
            let id: UUID, name: String
            switch key.context {
            case .bot(let keyConnection, let keyProfile), .hermesSession(let keyConnection, let keyProfile, _):
                (id, name) = (keyConnection, keyProfile)
            case .session, .newChat: return false
            }
            return (connectionID == nil || id == connectionID) && (profile == nil || name == profile)
        }
    }

    /// Replaces explicit quoted passages without disturbing typed text,
    /// attachments, or settings.
    func setQuotes(_ quotes: [ComposerQuote], for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.quotes = quotes }
    }

    func setContent(_ content: ComposerDraftContent, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { draft in
            draft.text = content.text
            draft.quotes = content.quotes
        }
    }

    /// Replaces the draft's staged-attachment records without disturbing its
    /// text or settings.
    func setAttachments(_ attachments: [ChatDraftAttachment], for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.attachments = attachments }
    }

    /// Parks the messages queued behind a run in the chat's draft, in one
    /// write (merge rule: `ChatDraftQueueParking`). ChatView calls it when the
    /// chat is left mid-run (#857). Only files with a durable copy are
    /// recorded, as in `ChatView.syncDraftAttachments`: nothing else can be
    /// restored on reopen. Synchronous, so it lands even while the chat's view
    /// is going away. Returns the merged draft, or nil when the chat's session
    /// was deleted.
    func parkQueuedMessages(_ queued: [QueuedSlashMessage], for key: ChatDraftKey) -> ChatDraft? {
        guard !deletedSessionKeys.contains(key) else { return nil }
        markChangedBeforeLoad(key)
        let merged = ChatDraftQueueParking.merged(
            drafts[key] ?? ChatDraft(),
            queuedTexts: queued.map(\.text),
            queuedAttachments: queued.flatMap(\.attachments)
                .map(ChatDraftAttachment.init(pending:))
                .filter { $0.file != nil }
        )
        updateDraft(for: key) { $0 = merged }
        return drafts[key]
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
    /// draft still references. Used after the server accepts session deletion;
    /// a later queue park for the key is skipped.
    func discardDraft(for key: ChatDraftKey) async {
        deletedSessionKeys.insert(key)
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

    /// Clears the draft's user-authored content. Attachments and settings are
    /// managed separately (attachments sync from the composer observationally).
    func clearDraft(for key: ChatDraftKey) {
        setContent(.empty, for: key)
    }

    func resolveSubmission(
        submitted: ComposerDraftContent,
        current: ComposerDraftContent,
        didStart: Bool,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> ComposerDraftContent {
        if didStart {
            // A started send consumed any staged attachments, even when the
            // user kept editing the composer during the request.
            updateDraft(for: key) { $0.attachments = [] }
        }

        guard !draftWasEdited else { return current }

        if didStart {
            if current.isEmpty {
                // Content is consumed by the accepted send; applicable settings
                // stay so the context keeps them.
                updateDraft(for: key) { draft in
                    draft.text = ""
                    draft.quotes = []
                    draft.attachments = []
                }
            }
            return current
        }

        if current.isEmpty {
            setContent(submitted, for: key)
            return submitted
        }
        return current
    }

    func resolveSubmission(
        submittedText: String,
        currentText: String,
        didStart: Bool,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> String {
        resolveSubmission(
            submitted: ComposerDraftContent(text: submittedText, quotes: []),
            current: ComposerDraftContent(text: currentText, quotes: []),
            didStart: didStart,
            draftWasEdited: draftWasEdited,
            for: key
        ).text
    }

    func resolveConsumedInput(
        submitted: ComposerDraftContent,
        current: ComposerDraftContent,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> ComposerDraftContent {
        guard !draftWasEdited, current == submitted else { return current }
        clearDraft(for: key)
        return .empty
    }

    func resolveConsumedInput(
        submittedText: String,
        currentText: String,
        draftWasEdited: Bool,
        for key: ChatDraftKey
    ) -> String {
        resolveConsumedInput(
            submitted: ComposerDraftContent(text: submittedText, quotes: []),
            current: ComposerDraftContent(text: currentText, quotes: []),
            draftWasEdited: draftWasEdited,
            for: key
        ).text
    }

    /// Moves the entire draft object (text, quotes, attachments, settings)
    /// between contexts, e.g. a new-chat draft into its created session.
    @discardableResult
    func moveDraft(from sourceKey: ChatDraftKey, to targetKey: ChatDraftKey) -> ChatDraft {
        markChangedBeforeLoad(sourceKey)
        markChangedBeforeLoad(targetKey)

        var movedDraft = drafts[sourceKey] ?? drafts[targetKey] ?? ChatDraft()
        movedDraft.lastUsedAt = Date()
        for lease in retentionLeases.compactMap(\.value) where lease.key == sourceKey {
            lease.key = targetKey
        }
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

    /// A lease lives with its composer/coordinator, not with a view redraw. Weak
    /// registration releases abandoned owners without a delayed deinit task.
    func makeAttachmentLease(key: ChatDraftKey? = nil) -> ChatDraftAttachmentLease {
        retentionLeases.removeAll { $0.value == nil }
        let lease = ChatDraftAttachmentLease(key: key)
        retentionLeases.append(WeakDraftAttachmentLease(value: lease))
        return lease
    }

    func markUsed(_ key: ChatDraftKey) async {
        await loadIfNeeded()
        guard drafts[key] != nil else { return }
        drafts[key]?.lastUsedAt = Date()
        schedulePersist()
    }

    private var protectedAttachmentFiles: Set<String> {
        retentionLeases.removeAll { $0.value == nil }
        return retentionLeases.compactMap(\.value).reduce(into: Set<String>()) { files, lease in
            files.formUnion(lease.files)
            files.formUnion(lease.filesByAttachmentID.values)
            if let key = lease.key {
                files.formUnion(drafts[key]?.attachments.compactMap(\.file) ?? [])
            }
        }
    }

    /// Serializes admission, record commits and deletion. New copies are counted
    /// on disk before the next admission can begin, including uploads in flight.
    func stageAttachment(
        data: Data, filename: String, lease: ChatDraftAttachmentLease,
        attachmentID: UUID = UUID(), maximumFileBytes: Int = PendingAttachment.maximumUploadBytes,
        in fileStore: (any ChatDraftAttachmentStoring)? = nil
    ) async throws -> String {
        guard data.count <= maximumFileBytes,
              data.count <= retainedByteLimit,
              let attachmentStore = fileStore ?? attachmentStore else { throw ChatDraftStorageError.unavailable }
        lease.slotIDs.insert(attachmentID)
        var didStage = false
        defer { if !didStage { lease.slotIDs.remove(attachmentID) } }
        await loadIfNeeded()
        await lockStorage()
        defer { unlockStorage() }
        try Task.checkCancellation()
        if let key = lease.key {
            var ids = Set(drafts[key]?.attachments.map(\.id) ?? [])
            for owner in retentionLeases.compactMap(\.value) where owner.key == key {
                ids.formUnion(owner.slotIDs)
            }
            ids.remove(attachmentID)
            guard ids.count < Self.maximumAttachmentCount else { throw ChatDraftStorageError.attachmentLimit }
        }
        let inventory = try await attachmentStore.retainedFileBytes()
        let required = inventory.values.reduce(0, +) + data.count - retainedByteLimit
        if required > 0 {
            let original = drafts
            let protected = protectedAttachmentFiles
            // A shared copy is as recent as its most recently used reference.
            var recency: [String: Date] = [:]
            var position: [String: Int] = [:]
            for draft in drafts.values {
                for (index, attachment) in draft.attachments.enumerated() {
                    guard let file = attachment.file, !protected.contains(file) else { continue }
                    recency[file] = max(recency[file] ?? .distantPast, draft.lastUsedAt ?? .distantPast)
                    position[file] = min(position[file] ?? index, index)
                }
            }
            // Interrupted saves/deletions can leave unreferenced copies behind.
            // Reclaim those before draft content, but keep every live reservation.
            let referenced = Set(drafts.values.flatMap { $0.attachments.compactMap(\.file) })
            for file in inventory.keys where !referenced.contains(file) && !protected.contains(file) {
                recency[file] = .distantPast
                position[file] = -1
            }
            let ordered = recency.keys.sorted {
                if recency[$0] != recency[$1] { return recency[$0]! < recency[$1]! }
                // The strip's persisted order breaks ties within a draft; file
                // name makes equally old records across drafts deterministic.
                if position[$0] != position[$1] { return position[$0]! < position[$1]! }
                return $0 < $1
            }
            var selected: Set<String> = []
            var reclaimed = 0
            for file in ordered where reclaimed < required {
                guard let bytes = inventory[file], bytes > 0 else { continue }
                selected.insert(file)
                reclaimed += bytes
            }
            guard reclaimed >= required else { throw ChatDraftStorageError.unavailable }
            var updated = drafts
            for key in updated.keys {
                updated[key]?.attachments.removeAll { $0.file.map(selected.contains) == true }
            }
            // Do not expose the tentative removal. If a composer opens, edits or
            // moves a draft while the write suspends, repair the disk and refuse
            // this admission; none of its selected files have been deleted.
            do {
                try await persistence.write(updated)
            } catch {
                // An atomic write may have succeeded before a protection-attribute
                // failure. Restore the authoritative records before propagating.
                try? await persistence.write(drafts)
                throw error
            }
            guard !Task.isCancelled, drafts == original,
                  protectedAttachmentFiles.isDisjoint(with: selected) else {
                try await persistence.write(drafts)
                try Task.checkCancellation()
                throw ChatDraftStorageError.unavailable
            }
            drafts = updated.filter { !$0.value.isEmpty }
            retiringAttachmentFiles = selected
            defer { retiringAttachmentFiles = [] }
            // From this point readers see only the committed records. No new
            // owner can restore one of the removed references during deletion.
            for file in selected.sorted() {
                await attachmentStore.delete(named: file)
            }
            // Deletion can fail (e.g. data protection); never assume it freed bytes.
            let remaining = try await attachmentStore.retainedFileBytes().values.reduce(0, +)
            guard remaining + data.count <= retainedByteLimit else { throw ChatDraftStorageError.unavailable }
        }
        try Task.checkCancellation()
        let file = try await attachmentStore.save(data: data, suggestedFilename: filename)
        lease.files.insert(file)
        didStage = true
        return file
    }

    func removeAttachmentReference(id: UUID, for key: ChatDraftKey) {
        updateDraft(for: key) { $0.attachments.removeAll { $0.id == id } }
    }

    /// Used after explicit removal or a successful send. Persist the record
    /// removal first and retain copies still owned by another draft or window.
    func deleteAttachmentIfUnreferenced(_ file: String, from fileStore: (any ChatDraftAttachmentStoring)? = nil) async {
        await loadIfNeeded()
        await lockStorage()
        defer { unlockStorage() }
        guard let attachmentStore = fileStore ?? attachmentStore else { return }
        do { try await persistence.write(drafts) } catch { return }
        guard !drafts.values.contains(where: { $0.attachments.contains { $0.file == file } }),
              !protectedAttachmentFiles.contains(file) else { return }
        await attachmentStore.delete(named: file)
    }

    private func lockStorage() async {
        if !storageBusy { storageBusy = true; return }
        await withCheckedContinuation { storageWaiters.append($0) }
    }

    private func unlockStorage() {
        if storageWaiters.isEmpty { storageBusy = false }
        else { storageWaiters.removeFirst().resume() }
    }

    func flush() async throws {
        persistTask?.cancel()
        persistTask = nil
        try await persistNow()
    }

    private func persistNow() async throws {
        await loadIfNeeded()
        await lockStorage()
        defer { unlockStorage() }
        try await persistence.write(drafts)
    }

    private func updateDraft(for key: ChatDraftKey, mutate: (inout ChatDraft) -> Void) {
        var draft = drafts[key] ?? ChatDraft()
        mutate(&draft)
        draft.attachments.removeAll { $0.file.map(retiringAttachmentFiles.contains) == true }

        if draft.isEmpty {
            guard drafts[key] != nil else { return }
            drafts.removeValue(forKey: key)
        } else {
            guard drafts[key] != draft else { return }
            draft.lastUsedAt = Date()
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

        for fileName in filesToDelete.sorted() {
            await deleteAttachmentIfUnreferenced(fileName)
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

        Task {
            await lockStorage()
            defer { unlockStorage() }
            let referencedFiles = Set(drafts.values.flatMap { $0.attachments.compactMap(\.file) })
                .union(protectedAttachmentFiles)
            await attachmentStore.sweep(keepingReferenced: referencedFiles, olderThan: attachmentSweepMaxAge)
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

/// Held across restore, upload, queueing and send; a live owner protects its files
/// even when they temporarily leave the pending strip.
@MainActor
final class ChatDraftAttachmentLease {
    var key: ChatDraftKey?
    var files: Set<String> = []
    var slotIDs: Set<UUID> = []
    var filesByAttachmentID: [UUID: String] = [:]
    init(key: ChatDraftKey? = nil) { self.key = key }
}

private struct WeakDraftAttachmentLease {
    weak var value: ChatDraftAttachmentLease?
}

enum ChatDraftStorageError: Error, LocalizedError {
    case unavailable
    case attachmentLimit

    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "Attachment storage is busy. Try again shortly.")
        case .attachmentLimit: return String(localized: "A draft can have up to 10 attachments.")
        }
    }
}
