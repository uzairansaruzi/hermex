import Foundation
import UniformTypeIdentifiers

struct ShareInput {
    var textSnippets: [String] = []
    var urls: [URL] = []
    var attachments: [SharedAttachmentImport] = []
    /// Items that look like attachments but weren't taken, in share order (#1401).
    var skipped: [SharedSkippedItem] = []
}

enum ShareInputReader {
    static func input(from context: NSExtensionContext?) async -> ShareInput {
        let providers = context?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        return await input(from: providers)
    }

    // Provider-array entry point so unit tests can exercise parsing without an
    // NSExtensionContext (which can't be constructed outside an extension host).
    static func input(from providers: [NSItemProvider]) async -> ShareInput {
        var input = ShareInput()
        for provider in providers {
            if let url = await loadURL(from: provider) {
                input.urls.append(url)
            }

            if let text = await loadText(from: provider) {
                input.textSnippets.append(text)
            }

            guard isAttachmentCandidate(provider) else { continue }
            guard input.attachments.count < HermesShareDraft.maximumSharedAttachmentCount else {
                // Counted from its advertised types alone; nothing past the limit is loaded.
                input.skipped.append(SharedSkippedItem(filename: nil, reason: .overLimit))
                continue
            }

            switch await loadAttachment(from: provider) {
            case .loaded(let attachment):
                input.attachments.append(attachment)
            case .skipped(let item):
                input.skipped.append(item)
            }
        }

        return input
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            return nil
        }

        let item = await loadItem(from: provider, typeIdentifier: UTType.url.identifier)
        if let url = item as? URL {
            return webURL(url)
        }

        if let url = item as? NSURL {
            return webURL(url as URL)
        }

        if let string = item as? String {
            return webURL(URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        if let string = item as? NSString {
            return webURL(URL(string: (string as String).trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return webURL(URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return nil
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        let typeIdentifier = [UTType.plainText.identifier, UTType.text.identifier]
            .first { provider.hasItemConformingToTypeIdentifier($0) }

        guard let typeIdentifier else {
            return nil
        }

        let item = await loadItem(from: provider, typeIdentifier: typeIdentifier)
        if let string = item as? String {
            return string
        }

        if let string = item as? NSString {
            return string as String
        }

        if let attributedString = item as? NSAttributedString {
            return attributedString.string
        }

        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    private static func webURL(_ url: URL?) -> URL? {
        guard let url, !url.isFileURL else {
            return nil
        }

        return url
    }

    private enum AttachmentLoad {
        case loaded(SharedAttachmentImport)
        case skipped(SharedSkippedItem)
    }

    /// Whether `provider` offers a file rather than only text or a link, so leaving it out
    /// is worth saying.
    private static func isAttachmentCandidate(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.registeredTypeIdentifiers.contains { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
            }
    }

    /// Tries the provider's file, then its image or PDF data, and reports one reason when
    /// neither gives an attachment. An oversized file is never read (#734).
    private static func loadAttachment(from provider: NSItemProvider) async -> AttachmentLoad {
        var fileFailure: SharedSkippedItem?
        switch await loadFileAttachment(from: provider) {
        case .loaded(let attachment)?:
            return .loaded(attachment)
        case .skipped(let item)? where item.reason == .tooLarge:
            return .skipped(item)
        case .skipped(let item)?:
            fileFailure = item
        case nil:
            break
        }

        if let dataLoad = await loadDataAttachment(from: provider) {
            return dataLoad
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first
        return .skipped(fileFailure ?? SharedSkippedItem(
            filename: fallbackFilename(for: provider, typeIdentifier: typeIdentifier),
            reason: .unsupported
        ))
    }

    /// Nil when the provider offers no file URL.
    private static func loadFileAttachment(from provider: NSItemProvider) async -> AttachmentLoad? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        let item = await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier)
        guard let url = fileURL(from: item), url.isFileURL else {
            return .skipped(SharedSkippedItem(filename: fallbackFilename(for: provider, typeIdentifier: nil), reason: .unreadable))
        }

        return attachment(from: url, provider: provider)
    }

    /// Nil when the provider offers no image or PDF data.
    private static func loadDataAttachment(from provider: NSItemProvider) async -> AttachmentLoad? {
        guard let typeIdentifier = attachmentDataTypeIdentifier(from: provider) else {
            return nil
        }

        let filename = fallbackFilename(for: provider, typeIdentifier: typeIdentifier)
        let data: Data?
        switch await loadMappedFile(from: provider, typeIdentifier: typeIdentifier) {
        case .loaded(let fileData):
            data = fileData
        case .oversized:
            return .skipped(SharedSkippedItem(filename: filename, reason: .tooLarge))
        case .unavailable:
            // Providers that only vend in-memory data; these are usually small.
            data = await loadData(from: provider, typeIdentifier: typeIdentifier)
        }

        guard let data, !data.isEmpty else {
            return .skipped(SharedSkippedItem(filename: filename, reason: .unreadable))
        }
        guard data.count <= HermesShareDraft.maximumSharedAttachmentBytes else {
            return .skipped(SharedSkippedItem(filename: filename, reason: .tooLarge))
        }

        return .loaded(SharedAttachmentImport(filename: filename, typeIdentifier: typeIdentifier, data: data))
    }

    private static func attachment(from url: URL, provider: NSItemProvider) -> AttachmentLoad {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let typeIdentifier = attachmentTypeIdentifier(from: provider, fallbackURL: url)
        let filename = url.lastPathComponent.isEmpty
            ? fallbackFilename(for: provider, typeIdentifier: typeIdentifier)
            : url.lastPathComponent

        let data: Data?
        do {
            data = try mappedAttachmentData(at: url)
        } catch {
            return .skipped(SharedSkippedItem(filename: filename, reason: .unreadable))
        }
        guard let data else {
            return .skipped(SharedSkippedItem(filename: filename, reason: .tooLarge))
        }

        return .loaded(SharedAttachmentImport(filename: filename, typeIdentifier: typeIdentifier, data: data))
    }

    /// Maps a shared file's bytes instead of copying them into the extension's
    /// memory, or returns nil when the file exceeds the share limit. Mapped pages
    /// are clean and file-backed, so they are not charged to the extension's
    /// footprint, and the mapping stays valid after security-scoped access ends
    /// or a provider deletes its temporary copy.
    private static func mappedAttachmentData(at url: URL) throws -> Data? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > HermesShareDraft.maximumSharedAttachmentBytes {
            return nil
        }

        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count <= HermesShareDraft.maximumSharedAttachmentBytes else {
            return nil
        }

        return data
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let url = item as? NSURL {
            return url as URL
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }

        if let string = item as? NSString {
            let value = string as String
            return URL(string: value) ?? URL(fileURLWithPath: value)
        }

        return nil
    }

    private static func attachmentDataTypeIdentifier(from provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf)
        }
    }

    private static func attachmentTypeIdentifier(from provider: NSItemProvider, fallbackURL: URL) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type != .fileURL && (type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .data))
        } ?? UTType(filenameExtension: fallbackURL.pathExtension)?.identifier
    }

    private static func fallbackFilename(for provider: NSItemProvider, typeIdentifier: String?) -> String {
        let type = typeIdentifier.flatMap(UTType.init)

        if let suggestedName = provider.suggestedName,
           !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !URL(fileURLWithPath: suggestedName).pathExtension.isEmpty {
                return suggestedName
            }

            if let fileExtension = type?.preferredFilenameExtension, !fileExtension.isEmpty {
                return "\(suggestedName).\(fileExtension)"
            }

            return suggestedName
        }

        let baseName: String
        if type?.conforms(to: .image) == true {
            baseName = "shared-image"
        } else if type?.conforms(to: .pdf) == true {
            baseName = "shared-document"
        } else {
            baseName = "shared-file"
        }

        guard let fileExtension = type?.preferredFilenameExtension, !fileExtension.isEmpty else {
            return baseName
        }

        return "\(baseName).\(fileExtension)"
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    private enum MappedFileLoad {
        case loaded(Data)
        case oversized
        case unavailable
    }

    /// Loads an image or PDF through its file representation so an oversized
    /// item is rejected by size before any of its bytes are read.
    private static func loadMappedFile(from provider: NSItemProvider, typeIdentifier: String) async -> MappedFileLoad {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                // The provider deletes this file when the handler returns, so map it here.
                guard let url else {
                    continuation.resume(returning: .unavailable)
                    return
                }

                do {
                    let data = try mappedAttachmentData(at: url)
                    continuation.resume(returning: data.map(MappedFileLoad.loaded) ?? .oversized)
                } catch {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
