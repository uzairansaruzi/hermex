import CryptoKit
import Foundation

struct SharedDraftPayload: Codable, Equatable {
    let version: Int?
    let id: String?
    let draft: String?
    let createdAt: Date?
    let attachments: [SharedAttachmentPayload]?

    init(
        version: Int? = nil,
        id: String? = nil,
        draft: String,
        createdAt: Date,
        attachments: [SharedAttachmentPayload] = []
    ) {
        self.version = version
        self.id = id
        self.draft = draft
        self.createdAt = createdAt
        self.attachments = attachments.isEmpty ? nil : attachments
    }
}

struct SharedAttachmentPayload: Codable, Equatable {
    let filename: String?
    let storedFileName: String?
    let typeIdentifier: String?
    let size: Int?

    init(filename: String, storedFileName: String, typeIdentifier: String?, size: Int?) {
        self.filename = filename
        self.storedFileName = storedFileName
        self.typeIdentifier = typeIdentifier
        self.size = size
    }
}

struct SharedAttachmentImport: Equatable {
    let filename: String
    let typeIdentifier: String?
    let data: Data
}

struct SharedImport: Equatable {
    let draft: String
    let attachments: [SharedAttachmentImport]

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

struct SharedImportReservation: Equatable, Identifiable {
    let itemID: String
    let reservationID: String
    let createdAt: Date
    let sharedImport: SharedImport

    var id: String { reservationID }
}

enum HermesShareDraft {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String
            ?? "group.com.uzairansar.hermesmobile"
    }

    // Legacy single-slot names. Existing installs may still have one of these records.
    static let pendingDraftFileName = "pending-share-draft.json"
    static let pendingAttachmentsDirectoryName = "pending-share-attachments"

    static let inboxDirectoryName = "share-inbox-v1"
    static let pendingItemsDirectoryName = "pending"
    static let reservedItemsDirectoryName = "reserved"
    static let temporaryItemsDirectoryName = "temporary"
    static let reservationLifetime: TimeInterval = 15 * 60
    static let temporaryItemLifetime: TimeInterval = 24 * 60 * 60

    private static let currentPayloadVersion = 1
    private static let payloadFileName = "payload.json"
    private static let reservationFileName = "reservation.json"
    private static let attachmentsDirectoryName = "attachments"

    static var urlScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesURLScheme") as? String
            ?? "hermes-agent"
    }

    static let shareURLHost = "share"
    static let maximumSharedAttachmentBytes = 20 * 1_024 * 1_024
    static let maximumSharedAttachmentCount = 10

    static var openURL: URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = shareURLHost
        guard let url = components.url else {
            preconditionFailure("Invalid share open URL configuration")
        }
        return url
    }

    static func isShareOpenURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == urlScheme else {
            return false
        }

        return url.host?.lowercased() == shareURLHost
    }

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func draftText(textSnippets: [String], urls: [URL]) -> String {
        let text = uniqueNonEmptyStrings(
            textSnippets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        let urlStrings = uniqueNonEmptyStrings(
            urls.map { $0.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        return uniqueNonEmptyStrings(text + urlStrings).joined(separator: "\n\n")
    }

    static func composerDraft(from sharedDraft: String) -> String {
        let trimmedDraft = sharedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else {
            return ""
        }

        return "\(trimmedDraft)\n"
    }

    static func savePendingDraft(
        _ draft: String,
        in directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        try savePendingImport(
            draft: draft,
            attachments: [],
            in: directory,
            fileManager: fileManager,
            now: now
        )
    }

    static func savePendingImport(
        draft: String,
        attachments: [SharedAttachmentImport],
        in directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let normalizedImport = normalizedImport(draft: draft, attachments: attachments)
        guard !normalizedImport.isEmpty else {
            return
        }

        try prepareInbox(in: directory, fileManager: fileManager)
        try cleanTemporaryItems(in: directory, fileManager: fileManager, now: now)
        try enqueue(
            normalizedImport,
            createdAt: now,
            in: directory,
            fileManager: fileManager
        )
    }

    static func reserveNextPendingImport(
        from directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        reservationTimeout: TimeInterval = reservationLifetime
    ) throws -> SharedImportReservation? {
        try prepareInbox(in: directory, fileManager: fileManager)
        try migrateLegacyPendingImportIfNeeded(in: directory, fileManager: fileManager, now: now)
        try recoverExpiredReservations(
            in: directory,
            fileManager: fileManager,
            now: now,
            reservationTimeout: reservationTimeout
        )
        try cleanTemporaryItems(in: directory, fileManager: fileManager, now: now)

        for pendingURL in try sortedPendingItemURLs(in: directory, fileManager: fileManager) {
            let itemID = pendingURL.lastPathComponent
            let reservedURL = reservedItemURL(for: itemID, in: directory)

            do {
                try fileManager.moveItem(at: pendingURL, to: reservedURL)
            } catch {
                // Another process may have reserved or consumed this item after enumeration.
                if !fileManager.fileExists(atPath: pendingURL.path) {
                    continue
                }
                throw error
            }

            let reservationID = UUID().uuidString
            let metadata = SharedReservationMetadata(
                reservationID: reservationID,
                reservedAt: now
            )

            do {
                let metadataURL = reservationURL(in: reservedURL)
                try writeJSON(metadata, to: metadataURL)
                try setProtectedFileAttributes(at: metadataURL, fileManager: fileManager)
            } catch {
                try? fileManager.removeItem(at: reservationURL(in: reservedURL))
                try? fileManager.moveItem(at: reservedURL, to: pendingURL)
                throw error
            }

            guard let loaded = try? loadImport(from: reservedURL), !loaded.sharedImport.isEmpty else {
                // A malformed or incomplete record must not block later valid shares.
                try? fileManager.removeItem(at: reservedURL)
                continue
            }

            return SharedImportReservation(
                itemID: itemID,
                reservationID: reservationID,
                createdAt: loaded.createdAt,
                sharedImport: loaded.sharedImport
            )
        }

        return nil
    }

    static func consume(
        _ reservation: SharedImportReservation,
        from directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let reservedURL = reservedItemURL(for: reservation.itemID, in: directory)
        try validateReservation(reservation, at: reservedURL)
        try fileManager.removeItem(at: reservedURL)
    }

    static func release(
        _ reservation: SharedImportReservation,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let reservedURL = reservedItemURL(for: reservation.itemID, in: directory)
        try validateReservation(reservation, at: reservedURL)

        let pendingURL = pendingItemURL(for: reservation.itemID, in: directory)
        try? fileManager.removeItem(at: reservationURL(in: reservedURL))
        if fileManager.fileExists(atPath: pendingURL.path) {
            try fileManager.removeItem(at: reservedURL)
        } else {
            try fileManager.moveItem(at: reservedURL, to: pendingURL)
        }
    }

    static func loadPendingDraft(
        from directory: URL,
        fileManager: FileManager = .default,
        removeAfterLoad: Bool = true
    ) throws -> String? {
        try loadPendingImport(
            from: directory,
            fileManager: fileManager,
            removeAfterLoad: removeAfterLoad
        )?.draft
    }

    static func loadPendingImport(
        from directory: URL,
        fileManager: FileManager = .default,
        removeAfterLoad: Bool = true
    ) throws -> SharedImport? {
        guard let reservation = try reserveNextPendingImport(
            from: directory,
            fileManager: fileManager
        ) else {
            return nil
        }

        if removeAfterLoad {
            try consume(reservation, from: directory, fileManager: fileManager)
        } else {
            try release(reservation, in: directory, fileManager: fileManager)
        }
        return reservation.sharedImport
    }

    private struct LoadedSharedImport {
        let createdAt: Date
        let sharedImport: SharedImport
    }

    private struct SharedReservationMetadata: Codable {
        let reservationID: String?
        let reservedAt: Date?

        init(reservationID: String, reservedAt: Date) {
            self.reservationID = reservationID
            self.reservedAt = reservedAt
        }
    }

    private enum SharedInboxError: Error {
        case reservationNoLongerOwned
    }

    private static func normalizedImport(
        draft: String,
        attachments: [SharedAttachmentImport]
    ) -> SharedImport {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploadableAttachments = attachments
            .filter { !$0.data.isEmpty && $0.data.count <= maximumSharedAttachmentBytes }
            .prefix(maximumSharedAttachmentCount)
            .map {
                SharedAttachmentImport(
                    filename: sanitizedFilename($0.filename),
                    typeIdentifier: $0.typeIdentifier,
                    data: $0.data
                )
            }

        return SharedImport(draft: trimmedDraft, attachments: uploadableAttachments)
    }

    private static func prepareInbox(in directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for inboxURL in [
            inboxRootURL(in: directory),
            pendingItemsURL(in: directory),
            reservedItemsURL(in: directory),
            temporaryItemsURL(in: directory)
        ] {
            try fileManager.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            try setProtectedFileAttributes(at: inboxURL, fileManager: fileManager)
        }
    }

    private static func enqueue(
        _ sharedImport: SharedImport,
        createdAt: Date,
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let itemID = contentID(for: sharedImport)
        let pendingURL = pendingItemURL(for: itemID, in: directory)
        let reservedURL = reservedItemURL(for: itemID, in: directory)

        guard
            !fileManager.fileExists(atPath: pendingURL.path),
            !fileManager.fileExists(atPath: reservedURL.path)
        else {
            return
        }

        let temporaryURL = temporaryItemsURL(in: directory)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let attachmentsURL = attachmentsURL(in: temporaryURL)
        var attachmentPayloads: [SharedAttachmentPayload] = []
        if !sharedImport.attachments.isEmpty {
            try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: false)

            for attachment in sharedImport.attachments {
                let storedFileName = storedFileName(for: attachment.filename)
                let destinationURL = attachmentsURL.appendingPathComponent(storedFileName, isDirectory: false)
                try attachment.data.write(to: destinationURL, options: [.atomic])
                try setProtectedFileAttributes(at: destinationURL, fileManager: fileManager)
                attachmentPayloads.append(
                    SharedAttachmentPayload(
                        filename: attachment.filename,
                        storedFileName: storedFileName,
                        typeIdentifier: attachment.typeIdentifier,
                        size: attachment.data.count
                    )
                )
            }
        }

        let payload = SharedDraftPayload(
            version: currentPayloadVersion,
            id: itemID,
            draft: sharedImport.draft,
            createdAt: createdAt,
            attachments: attachmentPayloads
        )
        let payloadURL = payloadURL(in: temporaryURL)
        try writeJSON(payload, to: payloadURL)
        try setProtectedFileAttributes(at: payloadURL, fileManager: fileManager)
        try setProtectedFileAttributes(at: temporaryURL, fileManager: fileManager)

        do {
            try fileManager.moveItem(at: temporaryURL, to: pendingURL)
        } catch {
            // A concurrent extension save of the same content is a successful deduplication.
            if fileManager.fileExists(atPath: pendingURL.path)
                || fileManager.fileExists(atPath: reservedURL.path) {
                return
            }
            throw error
        }
    }

    private static func migrateLegacyPendingImportIfNeeded(
        in directory: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        let legacyPayloadURL = pendingDraftURL(in: directory)
        guard fileManager.fileExists(atPath: legacyPayloadURL.path) else {
            return
        }

        let payload = try JSONDecoder().decode(
            SharedDraftPayload.self,
            from: Data(contentsOf: legacyPayloadURL)
        )
        let draft = (payload.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = loadLegacyAttachments(from: payload, in: directory)
        let sharedImport = normalizedImport(draft: draft, attachments: attachments)

        if !sharedImport.isEmpty {
            try enqueue(
                sharedImport,
                createdAt: payload.createdAt ?? now,
                in: directory,
                fileManager: fileManager
            )
        }

        try fileManager.removeItem(at: legacyPayloadURL)
        try? fileManager.removeItem(at: pendingAttachmentsDirectoryURL(in: directory))
    }

    private static func recoverExpiredReservations(
        in directory: URL,
        fileManager: FileManager,
        now: Date,
        reservationTimeout: TimeInterval
    ) throws {
        for reservedURL in try itemDirectoryURLs(at: reservedItemsURL(in: directory), fileManager: fileManager) {
            let metadata = try? JSONDecoder().decode(
                SharedReservationMetadata.self,
                from: Data(contentsOf: reservationURL(in: reservedURL))
            )
            let fallbackDate = try? reservedURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let reservedAt = metadata?.reservedAt ?? fallbackDate ?? .distantPast
            guard now.timeIntervalSince(reservedAt) >= reservationTimeout else {
                continue
            }

            let pendingURL = pendingItemURL(for: reservedURL.lastPathComponent, in: directory)
            try? fileManager.removeItem(at: reservationURL(in: reservedURL))
            if fileManager.fileExists(atPath: pendingURL.path) {
                try fileManager.removeItem(at: reservedURL)
            } else {
                try fileManager.moveItem(at: reservedURL, to: pendingURL)
            }
        }
    }

    private static func cleanTemporaryItems(
        in directory: URL,
        fileManager: FileManager,
        now: Date
    ) throws {
        for temporaryURL in try itemDirectoryURLs(at: temporaryItemsURL(in: directory), fileManager: fileManager) {
            let values = try? temporaryURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modifiedAt) >= temporaryItemLifetime {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
    }

    private static func sortedPendingItemURLs(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try itemDirectoryURLs(at: pendingItemsURL(in: directory), fileManager: fileManager)
            .sorted { lhs, rhs in
                let lhsDate = payloadCreatedAt(in: lhs) ?? .distantPast
                let rhsDate = payloadCreatedAt(in: rhs) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return lhsDate < rhsDate
            }
    }

    private static func itemDirectoryURLs(at directory: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func loadImport(from itemURL: URL) throws -> LoadedSharedImport {
        let payload = try JSONDecoder().decode(
            SharedDraftPayload.self,
            from: Data(contentsOf: payloadURL(in: itemURL))
        )
        let draft = (payload.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = loadAttachments(from: payload, in: itemURL)
        return LoadedSharedImport(
            createdAt: payload.createdAt ?? .distantPast,
            sharedImport: SharedImport(draft: draft, attachments: attachments)
        )
    }

    private static func loadAttachments(
        from payload: SharedDraftPayload,
        in itemURL: URL
    ) -> [SharedAttachmentImport] {
        let directory = attachmentsURL(in: itemURL)

        return (payload.attachments ?? []).compactMap { attachment in
            guard
                let storedFileName = attachment.storedFileName,
                isSafeStoredFileName(storedFileName),
                let data = try? Data(
                    contentsOf: directory.appendingPathComponent(storedFileName, isDirectory: false)
                ),
                !data.isEmpty
            else {
                return nil
            }

            return SharedAttachmentImport(
                filename: sanitizedFilename(attachment.filename ?? "shared-file"),
                typeIdentifier: attachment.typeIdentifier,
                data: data
            )
        }
    }

    private static func loadLegacyAttachments(
        from payload: SharedDraftPayload,
        in directory: URL
    ) -> [SharedAttachmentImport] {
        let attachmentsDirectory = pendingAttachmentsDirectoryURL(in: directory)

        return (payload.attachments ?? []).compactMap { attachment in
            guard
                let storedFileName = attachment.storedFileName,
                isSafeStoredFileName(storedFileName),
                let data = try? Data(
                    contentsOf: attachmentsDirectory.appendingPathComponent(
                        storedFileName,
                        isDirectory: false
                    )
                ),
                !data.isEmpty
            else {
                return nil
            }

            return SharedAttachmentImport(
                filename: sanitizedFilename(attachment.filename ?? "shared-file"),
                typeIdentifier: attachment.typeIdentifier,
                data: data
            )
        }
    }

    private static func validateReservation(
        _ reservation: SharedImportReservation,
        at reservedURL: URL
    ) throws {
        guard
            let metadata = try? JSONDecoder().decode(
                SharedReservationMetadata.self,
                from: Data(contentsOf: reservationURL(in: reservedURL))
            ),
            metadata.reservationID == reservation.reservationID
        else {
            throw SharedInboxError.reservationNoLongerOwned
        }
    }

    private static func contentID(for sharedImport: SharedImport) -> String {
        var hasher = SHA256()
        update(&hasher, with: Data("hermex-share-inbox-v1".utf8))
        update(&hasher, with: Data(sharedImport.draft.utf8))
        for attachment in sharedImport.attachments {
            update(&hasher, with: Data(attachment.filename.utf8))
            update(&hasher, with: Data((attachment.typeIdentifier ?? "").utf8))
            update(&hasher, with: attachment.data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, with data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func payloadCreatedAt(in itemURL: URL) -> Date? {
        guard
            let data = try? Data(contentsOf: payloadURL(in: itemURL)),
            let payload = try? JSONDecoder().decode(SharedDraftPayload.self, from: data)
        else {
            return nil
        }
        return payload.createdAt
    }

    private static func setProtectedFileAttributes(at url: URL, fileManager: FileManager) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "shared-file" : trimmed
    }

    private static func storedFileName(for filename: String) -> String {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        guard !fileExtension.isEmpty else {
            return UUID().uuidString
        }

        return "\(UUID().uuidString).\(fileExtension)"
    }

    private static func isSafeStoredFileName(_ filename: String) -> Bool {
        !filename.isEmpty && URL(fileURLWithPath: filename).lastPathComponent == filename
    }

    private static func inboxRootURL(in directory: URL) -> URL {
        directory.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    private static func pendingItemsURL(in directory: URL) -> URL {
        inboxRootURL(in: directory).appendingPathComponent(pendingItemsDirectoryName, isDirectory: true)
    }

    private static func reservedItemsURL(in directory: URL) -> URL {
        inboxRootURL(in: directory).appendingPathComponent(reservedItemsDirectoryName, isDirectory: true)
    }

    private static func temporaryItemsURL(in directory: URL) -> URL {
        inboxRootURL(in: directory).appendingPathComponent(temporaryItemsDirectoryName, isDirectory: true)
    }

    private static func pendingItemURL(for itemID: String, in directory: URL) -> URL {
        pendingItemsURL(in: directory).appendingPathComponent(itemID, isDirectory: true)
    }

    private static func reservedItemURL(for itemID: String, in directory: URL) -> URL {
        reservedItemsURL(in: directory).appendingPathComponent(itemID, isDirectory: true)
    }

    private static func payloadURL(in itemURL: URL) -> URL {
        itemURL.appendingPathComponent(payloadFileName, isDirectory: false)
    }

    private static func reservationURL(in itemURL: URL) -> URL {
        itemURL.appendingPathComponent(reservationFileName, isDirectory: false)
    }

    private static func attachmentsURL(in itemURL: URL) -> URL {
        itemURL.appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    private static func pendingDraftURL(in directory: URL) -> URL {
        directory.appendingPathComponent(pendingDraftFileName, isDirectory: false)
    }

    private static func pendingAttachmentsDirectoryURL(in directory: URL) -> URL {
        directory.appendingPathComponent(pendingAttachmentsDirectoryName, isDirectory: true)
    }

    private static func uniqueNonEmptyStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }

        return result
    }
}
