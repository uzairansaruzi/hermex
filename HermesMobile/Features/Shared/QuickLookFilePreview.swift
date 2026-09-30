import Foundation
import QuickLook
import SwiftUI

/// What a preview does with a file it can't draw as text or an image, by extension.
/// The workspace preview, chat file links and chat attachments share one list, and
/// the Files tree never prefetches either kind as text.
enum BinaryFilePreview: Equatable {
    /// Downloaded (at most 25 MB) and shown by Quick Look, which can still decline.
    case quickLook
    /// Never downloaded to preview: archives, executables, object code and databases
    /// would only reach a Quick Look file icon.
    case unavailable

    /// Nil for every other path, which previews as text or as an image.
    init?(path: String) {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        if Self.quickLookExtensions.contains(pathExtension) {
            self = .quickLook
        } else if Self.unavailableExtensions.contains(pathExtension) {
            self = .unavailable
        } else {
            return nil
        }
    }

    private static let quickLookExtensions: Set<String> = [
        "aiff", "avi", "doc", "docx", "flac", "key", "m4a", "mov", "mp3", "mp4", "numbers",
        "pages", "pdf", "ppt", "pptx", "rtf", "svg", "usdz", "wav", "xls", "xlsx"
    ]

    private static let unavailableExtensions: Set<String> = [
        "7z", "a", "bin", "bz2", "class", "db", "dmg", "dylib", "exe", "gz",
        "jar", "o", "pkg", "pyc", "rar", "sqlite", "tar", "tgz", "xz", "zip"
    ]
}

/// A downloaded file in a temporary directory of its own, deleted when the last
/// reference is released. Whatever preview state holds it owns the file, so a
/// refresh, a dismissal or a server switch removes it.
final class QuickLookTemporaryFile: Sendable {
    let url: URL

    private init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Writes `data` as the last path component of `name`, off the main actor.
    static func write(data: Data, name: String) async throws -> QuickLookTemporaryFile {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-look-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = URL(fileURLWithPath: name).lastPathComponent
            // Owned before the write, so a failed write still removes the directory.
            let file = QuickLookTemporaryFile(url: directory.appendingPathComponent(
                filename.isEmpty || filename == "." || filename == ".." ? "File" : filename
            ))
            try data.write(to: file.url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return file
        }.value
    }
}

extension FilePreviewContent {
    /// Loads a `BinaryFilePreview.quickLook` file. A `knownSize` over the 25 MB cap
    /// returns the too-large state without calling `download`, as does a download
    /// stopped at the cap. Quick Look declining the written file falls back to No
    /// Preview. `data` is the downloaded bytes, so Export can reuse them.
    @MainActor
    static func loadQuickLook(
        name: String,
        knownSize: Int?,
        download: () async throws -> Data
    ) async throws -> (content: FilePreviewContent, data: Data?) {
        let tooLarge = FilePreviewContent.unavailable(BotArtifactFailure.tooLarge.localizedDescription)
        if let knownSize, knownSize > BotArtifactBuffer.maximumBytes {
            return (tooLarge, nil)
        }

        let data: Data
        do {
            data = try await download()
        } catch BotArtifactFailure.tooLarge {
            return (tooLarge, nil)
        }

        let file = try await QuickLookTemporaryFile.write(data: data, name: name)
        // A dismissed preview drops the file here, which deletes it.
        try Task.checkCancellation()
        guard QLPreviewController.canPreview(file.url as NSURL) else {
            return (.unavailable(String(localized: "Preview is not available for this file type.")), data)
        }
        return (.quickLook(file), data)
    }
}

/// Quick Look provides native PDF, image, audio and document viewers and export.
struct QuickLookFileView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
