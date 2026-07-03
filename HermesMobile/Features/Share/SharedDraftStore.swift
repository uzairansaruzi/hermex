import Foundation

struct SharedDraftPayload: Codable, Equatable {
    let draft: String
    let createdAt: Date
    let attachments: [SharedAttachmentPayload]?

    init(
        draft: String,
        createdAt: Date,
        attachments: [SharedAttachmentPayload] = []
    ) {
        self.draft = draft
        self.createdAt = createdAt
        self.attachments = attachments.isEmpty ? nil : attachments
    }
}

struct SharedAttachmentPayload: Codable, Equatable {
    let filename: String
    let storedFileName: String
    let typeIdentifier: String?
    let size: Int?
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

enum HermesShareDraft {
    static var appGroupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String
            ?? "group.com.sourcebottle.hermex"
    }

    static let pendingDraftFileName = "pending-share-draft.json"
    static let pendingAttachmentsDirectoryName = "pending-share-attachments"
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
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploadableAttachments = attachments
            .filter { !$0.data.isEmpty && $0.data.count <= maximumSharedAttachmentBytes }
            .prefix(maximumSharedAttachmentCount)

        guard !trimmedDraft.isEmpty || !uploadableAttachments.isEmpty else {
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let attachmentsDirectory = pendingAttachmentsDirectoryURL(in: directory)
        try? fileManager.removeItem(at: attachmentsDirectory)

        var attachmentPayloads: [SharedAttachmentPayload] = []
        if !uploadableAttachments.isEmpty {
            try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

            for attachment in uploadableAttachments {
                let filename = sanitizedFilename(attachment.filename)
                let storedFileName = storedFileName(for: filename)
                let destinationURL = attachmentsDirectory.appendingPathComponent(storedFileName, isDirectory: false)
                try attachment.data.write(to: destinationURL, options: [.atomic])
                attachmentPayloads.append(
                    SharedAttachmentPayload(
                        filename: filename,
                        storedFileName: storedFileName,
                        typeIdentifier: attachment.typeIdentifier,
                        size: attachment.data.count
                    )
                )
            }
        }

        let payload = SharedDraftPayload(draft: trimmedDraft, createdAt: now, attachments: attachmentPayloads)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: pendingDraftURL(in: directory), options: [.atomic])
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
        let url = pendingDraftURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        defer {
            if removeAfterLoad {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: pendingAttachmentsDirectoryURL(in: directory))
            }
        }

        let payload = try JSONDecoder().decode(SharedDraftPayload.self, from: Data(contentsOf: url))
        let draft = payload.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = loadAttachments(from: payload, in: directory)
        let sharedImport = SharedImport(draft: draft, attachments: attachments)
        return sharedImport.isEmpty ? nil : sharedImport
    }

    private static func pendingDraftURL(in directory: URL) -> URL {
        directory.appendingPathComponent(pendingDraftFileName, isDirectory: false)
    }

    private static func pendingAttachmentsDirectoryURL(in directory: URL) -> URL {
        directory.appendingPathComponent(pendingAttachmentsDirectoryName, isDirectory: true)
    }

    private static func loadAttachments(
        from payload: SharedDraftPayload,
        in directory: URL
    ) -> [SharedAttachmentImport] {
        let attachmentsDirectory = pendingAttachmentsDirectoryURL(in: directory)

        return (payload.attachments ?? []).compactMap { attachment in
            let fileURL = attachmentsDirectory.appendingPathComponent(attachment.storedFileName, isDirectory: false)
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                return nil
            }

            return SharedAttachmentImport(
                filename: sanitizedFilename(attachment.filename),
                typeIdentifier: attachment.typeIdentifier,
                data: data
            )
        }
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
