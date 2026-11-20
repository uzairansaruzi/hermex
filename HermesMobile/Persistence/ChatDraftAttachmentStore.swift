import Foundation
import os

protocol ChatDraftAttachmentStoring: Sendable {
    func save(data: Data, suggestedFilename: String) async throws -> String
    func retainedFileBytes() async throws -> [String: Int]
    func data(named fileName: String) async throws -> Data
    func fileURL(named fileName: String) async throws -> URL
    func delete(named fileName: String) async
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async
}

extension ChatDraftAttachmentStoring {
    func retainedFileBytes() async throws -> [String: Int] {
        throw CocoaError(.fileReadUnknown)
    }
}

enum ChatDraftAttachmentReadFailure: Equatable {
    case unrecoverable
    case transient

    static func classify(_ error: Error) -> Self {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return .transient }
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .unrecoverable
        case NSFileReadInvalidFileNameError:
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

    func retainedFileBytes() async throws -> [String: Int] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [:] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        var bytes: [String: Int] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            bytes[url.lastPathComponent] = values.fileSize ?? 0
        }
        return bytes
    }

    func data(named fileName: String) async throws -> Data {
        try Data(contentsOf: fileURL(for: fileName))
    }

    func fileURL(named fileName: String) async throws -> URL {
        try fileURL(for: fileName)
    }

    func delete(named fileName: String) async {
        guard let url = try? fileURL(for: fileName) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
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
