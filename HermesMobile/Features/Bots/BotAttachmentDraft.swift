import Foundation
import Observation
import UniformTypeIdentifiers
import ImageIO

enum BotAttachmentFailure: Error, LocalizedError {
    case limit, type, unreadable
    var errorDescription: String? {
        switch self {
        case .limit: return String(localized: "Use up to 8 attachments, 25 MB each and 50 MB total.")
        case .type: return String(localized: "This attachment type is not supported. Choose an image, PDF, text, audio or document file.")
        case .unreadable: return String(localized: "Could not read this attachment. Remove it and select it again.")
        }
    }
}

/// Only local copies and presentation. Uploads belong to the deliberate submit operation.
@MainActor @Observable final class BotAttachmentDraft {
    nonisolated static let maximumFileBytes = 25 * 1024 * 1024
    nonisolated static let maximumTotalBytes = 50 * 1024 * 1024
    private(set) var items: [PendingAttachment] = []
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private let copies: any ChatDraftAttachmentStoring
    private let drafts: ChatDraftStore
    private let key: ChatDraftKey
    private var generation = 0

    init(key: ChatDraftKey, drafts: ChatDraftStore, copies: any ChatDraftAttachmentStoring) {
        self.key = key; self.drafts = drafts; self.copies = copies
    }

    func cancelImport() { generation += 1 }
    func report(_ error: Error) { errorMessage = error.localizedDescription }

    func restore(_ records: [ChatDraftAttachment]) async {
        let owner = generation
        items = records.map { PendingAttachment(id: $0.id, name: $0.name, path: "", mime: $0.mime,
                                               size: $0.size, isImage: $0.isImage, draftFileName: $0.file) }
        for record in records where record.isImage {
            guard let file = record.file, let data = try? await copies.data(named: file) else { continue }
            let thumbnail = await ImagePreviewDownsampler.previewDataAsync(from: data, maxPixelSize: 512)
            guard owner == generation else { return }
            if let index = items.firstIndex(where: { $0.id == record.id }) {
                items[index] = PendingAttachment(id: record.id, name: record.name, path: "", mime: record.mime,
                                                size: record.size, isImage: true, thumbnailData: thumbnail, draftFileName: file)
            }
        }
    }

    func stage(data: Data, filename: String) async {
        guard !isImporting else { return }
        isImporting = true; errorMessage = nil
        let owner = generation
        defer { isImporting = false }
        var saved: String?
        do {
            guard items.count < 8, !data.isEmpty, data.count <= Self.maximumFileBytes,
                  data.count <= Self.maximumTotalBytes - items.reduce(0, { $0 + ($1.size ?? Self.maximumFileBytes) })
            else { throw BotAttachmentFailure.limit }
            let prepared = try await Task.detached { try Self.prepare(data: data, filename: filename) }.value
            guard owner == generation, !Task.isCancelled else { return }
            guard prepared.data.count <= Self.maximumTotalBytes - items.reduce(0, { $0 + ($1.size ?? Self.maximumFileBytes) })
            else { throw BotAttachmentFailure.limit }
            let file = try await copies.save(data: prepared.data, suggestedFilename: prepared.name)
            saved = file
            guard owner == generation, !Task.isCancelled else { await copies.delete(named: file); return }
            let thumbnail = prepared.image ? await ImagePreviewDownsampler.previewDataAsync(from: prepared.data, maxPixelSize: 512) : nil
            guard owner == generation, !Task.isCancelled else { await copies.delete(named: file); return }
            let item = PendingAttachment(name: prepared.name, path: "", mime: prepared.mime, size: prepared.data.count,
                                         isImage: prepared.image, thumbnailData: thumbnail, draftFileName: file)
            let next = items + [item]
            drafts.setAttachments(next.map(ChatDraftAttachment.init(pending:)), for: key)
            try await drafts.flush()
            // The durable record owns the file even if navigation happened during flush.
            items = next
        } catch {
            drafts.setAttachments(items.map(ChatDraftAttachment.init(pending:)), for: key)
            if let saved { await copies.delete(named: saved) }
            if owner == generation { errorMessage = error.localizedDescription }
        }
    }

    func remove(_ id: UUID) async {
        guard !isImporting else { return }
        let previous = items
        let next = items.filter { $0.id != id }
        isImporting = true
        defer { isImporting = false }
        drafts.setAttachments(next.map(ChatDraftAttachment.init(pending:)), for: key)
        do {
            try await drafts.flush()
            items = next
            for item in previous where item.id == id {
                if let file = item.draftFileName { await copies.delete(named: file) }
            }
        } catch {
            drafts.setAttachments(previous.map(ChatDraftAttachment.init(pending:)), for: key)
            report(error)
        }
    }

    func data(for item: PendingAttachment) async throws -> Data {
        guard let file = item.draftFileName else { throw BotAttachmentFailure.unreadable }
        let data = try await copies.data(named: file)
        guard !data.isEmpty, data.count <= Self.maximumFileBytes else { throw BotAttachmentFailure.limit }
        return data
    }

    /// Called only after the cleared draft has reached disk.
    func consumed() async {
        let old = items; items = []; errorMessage = nil
        for item in old { if let file = item.draftFileName { await copies.delete(named: file) } }
    }

    nonisolated private static func prepare(data: Data, filename: String) throws -> (data: Data, name: String, mime: String, image: Bool) {
        let name = URL(fileURLWithPath: filename).lastPathComponent
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) else { throw BotAttachmentFailure.type }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw BotAttachmentFailure.unreadable }
            let alpha = image.alphaInfo
            let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst
                || alpha == .premultipliedLast || alpha == .alphaOnly
            let format = hasAlpha ? UTType.png : UTType.jpeg
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { throw BotAttachmentFailure.unreadable }
            let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= maximumFileBytes else { throw BotAttachmentFailure.limit }
            let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return (output as Data, base + (hasAlpha ? ".png" : ".jpg"), hasAlpha ? "image/png" : "image/jpeg", true)
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .audio)
                || ["json", "yaml", "yml", "csv", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip"].contains(ext)
        else { throw BotAttachmentFailure.type }
        return (data, name, type.preferredMIMEType ?? "application/octet-stream", false)
    }
}

extension BotAttachmentDraft {
    /// Loading a picker/provider is part of import ownership too: a late provider
    /// callback must not resurrect a selection after navigation or backgrounding.
    func importValue(_ load: () async throws -> (Data, String)) async {
        guard !isImporting else { return }
        let owner = generation
        isImporting = true
        do {
            let (data, name) = try await load()
            isImporting = false
            guard owner == generation, !Task.isCancelled else { return }
            await stage(data: data, filename: name)
        } catch {
            isImporting = false
            if owner == generation { report(error) }
        }
    }

    nonisolated static func readFile(_ url: URL) throws -> (Data, String) {
        guard url.isFileURL else { throw BotAttachmentFailure.unreadable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw BotAttachmentFailure.type }
        guard let size = values.fileSize, size <= maximumFileBytes else { throw BotAttachmentFailure.limit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw BotAttachmentFailure.limit }
        return (data, url.lastPathComponent)
    }
}
