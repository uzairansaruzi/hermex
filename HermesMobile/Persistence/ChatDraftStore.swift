import Foundation
import os

struct ChatDraftAttachment: Equatable, Sendable {
    let id: UUID
    let name: String
    let mime: String
    let size: Int?
    let isImage: Bool
    let file: String?
    var isClipboardPaste = false
}

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

struct ChatDraft: Equatable, Sendable {
    var text = ""
    var quotes: [ComposerQuote] = []
    var attachments: [ChatDraftAttachment] = []
    var settings: ChatDraftSettings?
    var botSubmissionUncertain = false
    var lastUsedAt: Date?
    var sharedImportIDs: Set<String> = []
    var textOrigin: ImportedTextOrigin?
    var waitingSend: WaitingSend?

    struct WaitingSend: Equatable, Sendable {
        var text: String
        var createdAt: Date
    }

    var isEmpty: Bool {
        text.isEmpty && quotes.isEmpty && attachments.isEmpty && (settings?.isEmpty ?? true) && !botSubmissionUncertain
            && waitingSend == nil
    }
}

extension ChatDraftAttachment {
    init(pending: PendingAttachment) {
        self.init(
            id: pending.id,
            name: pending.name,
            mime: pending.mime,
            size: pending.size,
            isImage: pending.isImage,
            file: pending.draftFileName,
            isClipboardPaste: pending.isClipboardPaste
        )
    }
}

enum ChatDraftSendReconciliation {
    struct Outcome: Equatable {
        var consumed: [ChatDraftAttachment] = []
        var retained: [ChatDraftAttachment] = []
    }

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

enum ChatDraftQueueParking {
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
        case hermesSession(connectionID: UUID, profile: String, key: String?, cwd: String?)
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

    static func hermesSession(server: URL, connectionID: UUID, profile: String, key: String?, cwd: String? = nil) -> Self {
        hermesSession(serverID: server.absoluteString, connectionID: connectionID, profile: profile, key: key, cwd: cwd)
    }

    fileprivate static func hermesSession(serverID: String, connectionID: UUID, profile: String, key: String?,
                                          cwd: String?) -> Self {
        Self(serverID: serverID, context: .hermesSession(
            connectionID: connectionID, profile: profile, key: key, cwd: key == nil && cwd?.isEmpty == false ? cwd : nil))
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
        let isClipboardPaste: Bool?

        init(_ attachment: ChatDraftAttachment) {
            id = attachment.id.uuidString
            name = attachment.name
            mime = attachment.mime
            size = attachment.size
            isImage = attachment.isImage
            file = attachment.file
            isClipboardPaste = attachment.isClipboardPaste
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
                file: sanitizedFile,
                isClipboardPaste: isClipboardPaste ?? false
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
        var cwd: String?
        var botSubmissionUncertain: Bool?
        var sharedImportIDs: [String]?
        var fromShortcut: Bool?
        var textOrigin: String?
        var waitingSendText: String?
        var waitingSendCreatedAt: Date?

        let lastUsedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case serverID
            case context
            case sessionID
            case text
            case quotes
            case attachments
            case settings, connectionID, profile, cwd, botSubmissionUncertain, lastUsedAt, sharedImportIDs, fromShortcut, textOrigin
            case waitingSendText, waitingSendCreatedAt
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
            case .hermesSession(let connectionID, let profile, let key, let cwd):
                context = "hermesSession"
                sessionID = key
                self.connectionID = connectionID
                self.profile = profile
                self.cwd = cwd
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
            sharedImportIDs = draft.sharedImportIDs.isEmpty ? nil : draft.sharedImportIDs.sorted()
            textOrigin = draft.textOrigin?.rawValue
            waitingSendText = draft.waitingSend?.text
            waitingSendCreatedAt = draft.waitingSend?.createdAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastUsedAt = try? container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            serverID = (try? container.decodeIfPresent(String.self, forKey: .serverID)) ?? nil
            context = (try? container.decodeIfPresent(String.self, forKey: .context)) ?? nil
            sessionID = (try? container.decodeIfPresent(String.self, forKey: .sessionID)) ?? nil
            connectionID = try? container.decodeIfPresent(UUID.self, forKey: .connectionID)
            profile = try? container.decodeIfPresent(String.self, forKey: .profile)
            cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
            botSubmissionUncertain = (try? container.decodeIfPresent(Bool.self, forKey: .botSubmissionUncertain))
                ?? (["bot", "hermesSession"].contains(context) && container.contains(.botSubmissionUncertain))
            text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? nil
            quotes = (try? container.decodeIfPresent([FailableQuote].self, forKey: .quotes)) ?? nil
            attachments = (try? container.decodeIfPresent([FailableAttachment].self, forKey: .attachments)) ?? nil
            settings = (try? container.decodeIfPresent(SettingsRecord.self, forKey: .settings)) ?? nil
            sharedImportIDs = (try? container.decodeIfPresent([String].self, forKey: .sharedImportIDs)) ?? nil
            fromShortcut = (try? container.decodeIfPresent(Bool.self, forKey: .fromShortcut)) ?? nil
            textOrigin = (try? container.decodeIfPresent(String.self, forKey: .textOrigin)) ?? nil
            waitingSendText = (try? container.decodeIfPresent(String.self, forKey: .waitingSendText)) ?? nil
            waitingSendCreatedAt = (try? container.decodeIfPresent(Date.self, forKey: .waitingSendCreatedAt)) ?? nil
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
                key = .hermesSession(serverID: serverID, connectionID: connectionID, profile: profile,
                                     key: session?.isEmpty == false ? session : nil, cwd: cwd)
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
                lastUsedAt: lastUsedAt,
                sharedImportIDs: Set(sharedImportIDs ?? []),
                textOrigin: textOrigin.flatMap(ImportedTextOrigin.init(rawValue:)) ?? (fromShortcut == true ? .shortcut : nil),
                waitingSend: waitingSendText.flatMap { $0.isEmpty ? nil : .init(text: $0, createdAt: waitingSendCreatedAt ?? .distantPast) }
            )
            guard !draft.isEmpty else { return nil }
            return (key, draft)
        }
    }

    private static let currentVersion = 4
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
        await lockStorage()
        defer { unlockStorage() }
        return drafts[key]
    }

    struct DraftRow: Hashable, Sendable {
        let profile: String
        let key: String
    }

    func hermesSessionDraftKeys(server: URL, connectionID: UUID) async -> Set<DraftRow> {
        await loadIfNeeded()
        let serverID = server.absoluteString
        var rows: Set<DraftRow> = []
        for (key, draft) in drafts where key.serverID == serverID && !draft.isEmpty {
            guard case .hermesSession(connectionID, let profile, let stored?, _) = key.context else { continue }
            rows.insert(DraftRow(profile: profile, key: stored))
        }
        return rows
    }

    func setDraft(_ text: String, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.text = text }
    }

    func setBotSubmissionUncertain(_ uncertain: Bool, for key: ChatDraftKey) {
        switch key.context {
        case .bot, .hermesSession: break
        case .session, .newChat: return
        }
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.botSubmissionUncertain = uncertain }
    }

    func holdWaitingSend(_ send: ChatDraft.WaitingSend, replacing submitted: String, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { draft in
            draft.waitingSend = send
            if draft.text == submitted { draft.text = "" }
        }
    }

    func removeWaitingSend(for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { $0.waitingSend = nil }
    }

    @discardableResult
    func returnWaitingSend(for key: ChatDraftKey) -> ChatDraft? {
        guard let waiting = drafts[key]?.waitingSend else { return drafts[key] }
        markChangedBeforeLoad(key)
        updateDraft(for: key) { draft in
            draft.text = [waiting.text, draft.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            draft.waitingSend = nil
        }
        return drafts[key]
    }

    func discardBotDrafts(server: URL, connectionID: UUID? = nil, profile: String? = nil) async {
        await loadIfNeeded()
        await discardDrafts { key in
            guard key.serverID == server.absoluteString else { return false }
            let id: UUID, name: String
            switch key.context {
            case .bot(let keyConnection, let keyProfile), .hermesSession(let keyConnection, let keyProfile, _, _):
                (id, name) = (keyConnection, keyProfile)
            case .session, .newChat: return false
            }
            return (connectionID == nil || id == connectionID) && (profile == nil || name == profile)
        }
    }

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

    func setAttachments(
        _ attachments: [ChatDraftAttachment], replacing previous: [ChatDraftAttachment]? = nil, for key: ChatDraftKey
    ) {
        markChangedBeforeLoad(key)
        updateDraft(for: key) { draft in
            var unseen: [ChatDraftAttachment] = []
            if let previous {
                let seen = Set((previous + attachments).map(\.id))
                unseen = draft.attachments.filter { !seen.contains($0.id) }
            }
            draft.attachments = attachments + unseen
        }
    }

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

    func appendShare(
        _ shareID: String, text: String, files: [(data: Data, name: String, mime: String, image: Bool)],
        to key: ChatDraftKey, maximumFileBytes: Int, origin: ImportedTextOrigin? = nil,
        admitting fits: ([ChatDraftAttachment]) throws -> Void = { _ in }
    ) async throws {
        await loadIfNeeded()
        func isHere() -> Bool { drafts[key]?.sharedImportIDs.contains(shareID) == true }
        let lease = makeAttachmentLease(key: key)
        var records: [ChatDraftAttachment] = []
        func deleteCopies() async {
            for file in records.compactMap(\.file) {
                lease.files.remove(file)
                await deleteAttachmentIfUnreferenced(file)
            }
        }
        do {
            for file in files where !isHere() {
                let id = UUID()
                let copy = try await stageAttachment(
                    data: file.data, filename: file.name, lease: lease, attachmentID: id, maximumFileBytes: maximumFileBytes
                )
                records.append(ChatDraftAttachment(id: id, name: file.name, mime: file.mime, size: file.data.count,
                                                   isImage: file.image, file: copy))
            }
            if !isHere() { try Task.checkCancellation() }
        } catch {
            await deleteCopies()
            throw error
        }
        guard !isHere() else {
            await deleteCopies()
            try await flush()
            guard isHere() else { throw ChatDraftStorageError.unavailable }
            return
        }
        if !records.isEmpty {
            do { try fits((drafts[key]?.attachments ?? []) + records) } catch {
                await deleteCopies()
                throw error
            }
        }
        let unsent = drafts[key]?.text ?? ""
        let earlierOrigin = drafts[key]?.textOrigin
        updateDraft(for: key) { draft in
            let earlier = origin != nil ? draft.text : draft.text.trimmingCharacters(in: .newlines)
            if !text.isEmpty { draft.text = earlier.isEmpty ? text : earlier + "\n\n" + text }
            draft.attachments += records
            draft.sharedImportIDs.insert(shareID)
            if let origin { draft.textOrigin = origin }
        }
        let merged = drafts[key]?.text
        let ids = Set(records.map(\.id))
        do {
            try await flush()
            guard isHere(), ids.isSubset(of: Set(drafts[key]?.attachments.map(\.id) ?? [])),
                  text.isEmpty || drafts[key]?.text.contains(text) == true else {
                throw ChatDraftStorageError.unavailable
            }
        } catch {
            updateDraft(for: key) { draft in
                draft.sharedImportIDs.remove(shareID)
                draft.attachments.removeAll { ids.contains($0.id) }
                if draft.text == merged { draft.text = unsent }
                if origin != nil { draft.textOrigin = earlierOrigin }
            }
            if (try? await flush()) != nil { await deleteCopies() }
            throw error
        }
    }

    func setTextOrigin(_ origin: ImportedTextOrigin?, for key: ChatDraftKey) {
        guard drafts[key]?.textOrigin != origin else { return }
        updateDraft(for: key) { $0.textOrigin = origin }
    }

    func setSettings(_ settings: ChatDraftSettings, for key: ChatDraftKey) {
        markChangedBeforeLoad(key)
        let normalized = settings.normalized()
        updateDraft(for: key) { draft in
            draft.settings = normalized.isEmpty ? nil : normalized
        }
    }

    func discardDraft(for key: ChatDraftKey) async {
        deletedSessionKeys.insert(key)
        await loadIfNeeded()
        await discardDrafts(matching: { $0 == key })
    }

    func discardDrafts(for server: URL) async {
        await loadIfNeeded()
        let serverID = server.absoluteString
        await discardDrafts(matching: { $0.serverID == serverID })
    }

    func clearDraft(for key: ChatDraftKey) {
        setContent(.empty, for: key)
    }

    func retainRejectedAttachments(_ attachments: [ChatDraftAttachment], for key: ChatDraftKey) {
        guard !attachments.isEmpty, !deletedSessionKeys.contains(key) else { return }
        markChangedBeforeLoad(key)
        updateDraft(for: key) { draft in
            let existingIDs = Set(draft.attachments.map(\.id))
            draft.attachments += attachments.filter { !existingIDs.contains($0.id) }
        }
    }

    func resolveSubmission(
        submitted: ComposerDraftContent,
        current: ComposerDraftContent,
        didStart: Bool,
        draftWasEdited: Bool,
        preserveRejectedSubmission: Bool = false,
        for key: ChatDraftKey
    ) -> ComposerDraftContent {
        if !didStart, preserveRejectedSubmission {
            let text = current.text.isEmpty || current.text == submitted.text
                ? submitted.text
                : [submitted.text, current.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let quotes = submitted.quotes + current.quotes.filter { !submitted.quotes.contains($0) }
            let recovered = ComposerDraftContent(text: text, quotes: quotes)
            setContent(recovered, for: key)
            return recovered
        }
        if didStart {
            updateDraft(for: key) { $0.attachments = [] }
        }

        guard !draftWasEdited else { return current }

        if didStart {
            if current.isEmpty {
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
        preserveRejectedSubmission: Bool = false,
        for key: ChatDraftKey
    ) -> ComposerDraftContent {
        if preserveRejectedSubmission {
            return resolveSubmission(
                submitted: submitted, current: current, didStart: false,
                draftWasEdited: draftWasEdited, preserveRejectedSubmission: true, for: key
            )
        }
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

    func transferDraft(from source: ChatDraftKey, to destination: ChatDraftKey) async throws -> ChatDraftTransfer {
        await loadIfNeeded()
        guard var moved = drafts[source] else { return .nothingToMove }
        moved.settings = nil
        moved.botSubmissionUncertain = false
        guard !moved.isEmpty else { return .nothingToMove }
        func holdsMoved(_ key: ChatDraftKey) -> Bool { drafts[key].map { Self.sameContent($0, moved) } ?? false }

        var copied = false
        if let existing = drafts[destination], !existing.isEmpty {
            guard holdsMoved(destination) else { return .conflict }
        } else {
            updateDraft(for: destination) { $0 = moved }
            do {
                try await flush()
            } catch {
                if holdsMoved(destination) { updateDraft(for: destination) { $0 = ChatDraft() } }
                try? await flush()
                throw error
            }
            guard holdsMoved(destination) else { return .conflict }
            copied = true
        }
        guard holdsMoved(source), let original = drafts[source] else { return .conflict }
        updateDraft(for: source) { $0 = ChatDraft() }
        do {
            try await flush()
        } catch {
            if drafts[source] == nil { drafts[source] = original }
            try? await flush()
            throw error
        }
        return copied ? .moved : .alreadyMoved
    }

    private static func sameContent(_ lhs: ChatDraft, _ rhs: ChatDraft) -> Bool {
        lhs.text == rhs.text && lhs.quotes == rhs.quotes && lhs.attachments == rhs.attachments
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
            var recency: [String: Date] = [:]
            var position: [String: Int] = [:]
            for draft in drafts.values {
                for (index, attachment) in draft.attachments.enumerated() {
                    guard let file = attachment.file, !protected.contains(file) else { continue }
                    recency[file] = max(recency[file] ?? .distantPast, draft.lastUsedAt ?? .distantPast)
                    position[file] = min(position[file] ?? index, index)
                }
            }
            let referenced = Set(drafts.values.flatMap { $0.attachments.compactMap(\.file) })
            for file in inventory.keys where !referenced.contains(file) && !protected.contains(file) {
                recency[file] = .distantPast
                position[file] = -1
            }
            let ordered = recency.keys.sorted {
                if recency[$0] != recency[$1] { return recency[$0]! < recency[$1]! }
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
            do {
                try await persistence.write(updated)
            } catch {
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
            for file in selected.sorted() {
                await attachmentStore.delete(named: file)
            }
            let remaining = try await attachmentStore.retainedFileBytes().values.reduce(0, +)
            guard remaining + data.count <= retainedByteLimit else { throw ChatDraftStorageError.unavailable }
        }
        try Task.checkCancellation()
        let file = try await attachmentStore.save(data: data, suggestedFilename: filename)
        lease.files.insert(file)
        didStage = true
        return file
    }

    func replaceAttachmentRecord(_ record: ChatDraftAttachment, for key: ChatDraftKey) {
        updateDraft(for: key) { draft in
            guard let index = draft.attachments.firstIndex(where: { $0.id == record.id }) else { return }
            draft.attachments[index] = record
        }
    }

    func removeAttachmentReference(id: UUID, for key: ChatDraftKey) {
        updateDraft(for: key) { $0.attachments.removeAll { $0.id == id } }
    }

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

enum ChatDraftTransfer: Equatable, Sendable {
    case moved
    case alreadyMoved
    case nothingToMove
    case conflict
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
