import Foundation
import QuickLook
import SwiftUI

final class QuickLookTemporaryFile: Sendable {
    let url: URL

    private init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func write(data: Data, name: String) async throws -> QuickLookTemporaryFile {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("quick-look-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let filename = name.split(separator: "/").last.map(String.init) ?? ""
            let file = QuickLookTemporaryFile(url: directory.appendingPathComponent(
                filename.isEmpty || filename == "." || filename == ".." ? "File" : filename
            ))
            try data.write(to: file.url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return file
        }.value
    }
}

extension QuickLookTemporaryFile: Identifiable {}

extension FilePreviewContent {
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
        try Task.checkCancellation()
        guard QLPreviewController.canPreview(file.url as NSURL) else {
            return (.unavailable(String(localized: "Preview is not available for this file type.")), data)
        }
        return (.quickLook(file), data)
    }
}

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
