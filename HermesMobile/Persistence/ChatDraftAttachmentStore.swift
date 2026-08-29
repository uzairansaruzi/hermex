import Foundation
import os

/// Durable, app-owned copies of staged composer attachments. A draft record
/// references one of these files by name so the attachment can be re-uploaded
/// after the app's process or the server-side per-session upload inbox is gone
/// (the server scopes uploads per session and deletes them with the session).
protocol ChatDraftAttachmentStoring: Sendable {
    /// Writes a copy of the attachment bytes, returning the generated file name
    /// the caller stores in the draft record.
    func save(data: Data, suggestedFilename: String) async throws -> String
    func data(named fileName: String) async throws -> Data
    func delete(named fileName: String) async
    /// Deletes files not referenced by any draft and older than `maxAge`. The
    /// age grace keeps copies whose owning upload/record write is still in
    /// flight from being collected.
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async
}

/// Why a draft attachment's durable copy could not be read, and therefore
/// whether its record is worth keeping.
///
/// Collapsing every read failure to "gone" is what makes this matter: a copy
/// that is merely unreadable *right now* — data protection before first
/// unlock, for instance — would otherwise be reported as permanently lost and
/// dropped from the draft, and its file later reclaimed by the sweep.
enum ChatDraftAttachmentReadFailure: Equatable {
    /// The copy is gone, or its recorded name can never resolve. The record
    /// cannot be restored now or later, so it is dropped.
    case unrecoverable
    /// The copy may still be there; this read just did not succeed. The record
    /// is kept and retried on a later open.
    case transient

    static func classify(_ error: Error) -> Self {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return .transient }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .unrecoverable
        case NSFileReadInvalidFileNameError:
            // A name that cannot be resolved never will be.
            return .unrecoverable
        default:
            return .transient
        }
    }
}

actor ChatDraftAttachmentStore: ChatDraftAttachmentStoring {
    static let shared = ChatDraftAttachmentStore()

    #if os(iOS)
    static let fileProtectionType = FileProtectionType.completeUntilFirstUserAuthentication
    #endif

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "ChatDraftAttachmentStore"
    )

    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let baseURL = directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directoryURL = baseURL
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    func save(data: Data, suggestedFilename: String) async throws -> String {
        try prepareDirectory()
        let fileName = "\(UUID().uuidString.lowercased())-\(Self.normalizedFilename(suggestedFilename))"
        let target = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: target, options: [.atomic])
        try setProtectedFileAttributes(at: target)
        return fileName
    }

    func data(named fileName: String) async throws -> Data {
        try Data(contentsOf: fileURL(for: fileName))
    }

    func delete(named fileName: String) async {
        guard let url = try? fileURL(for: fileName) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone — deletion is idempotent.
        } catch {
            Self.logger.warning("Could not delete draft attachment \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in contents {
            let fileName = url.lastPathComponent
            guard !fileNames.contains(fileName) else { continue }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            guard created < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Self.logger.warning("Could not sweep draft attachment \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try setProtectedFileAttributes(at: directoryURL)
    }

    private func setProtectedFileAttributes(at url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: Self.fileProtectionType],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// Resolves a stored file name back to a URL, rejecting anything that is
    /// not a plain file name so a corrupted draft document cannot escape the
    /// attachments directory.
    private func fileURL(for fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              trimmed == Self.normalizedFilename(trimmed) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directoryURL.appendingPathComponent(trimmed, isDirectory: false)
    }

    private static func normalizedFilename(_ filename: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: filename).lastPathComponent
        let trimmed = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "attachment" : trimmed
    }
}
