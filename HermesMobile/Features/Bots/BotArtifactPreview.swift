import Foundation
import Observation
import QuickLook
import SwiftUI

/// The preview owns its temporary file. Dismissal invalidates late completions
/// and removes only the directory this presentation created.
@MainActor @Observable final class BotArtifactPreviewModel {
    private var file: BotArtifactTemporaryFile?
    var fileURL: URL? { file?.url }
    private(set) var errorMessage: String?
    private var generation = 0

    func load(name: String, download: () async throws -> Data) async {
        cleanup()
        let owner = generation
        errorMessage = nil
        do {
            let data = try await download()
            try Task.checkCancellation()
            guard owner == generation else { return }
            let url = try await Task.detached {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bot-artifact-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = URL(fileURLWithPath: name).lastPathComponent
                let url = directory.appendingPathComponent(filename.isEmpty || filename == "." || filename == ".." ? "File" : filename)
                do {
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                    return url
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }.value
            guard !Task.isCancelled, owner == generation else {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                return
            }
            file = BotArtifactTemporaryFile(url: url)
        } catch {
            guard !Task.isCancelled, owner == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cleanup() {
        generation += 1
        file = nil
    }

}

private final class BotArtifactTemporaryFile {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

struct BotArtifactPreview: View {
    let reference: TranscriptMediaReference
    let download: () async throws -> Data
    @Environment(\.dismiss) private var dismiss
    @State private var model = BotArtifactPreviewModel()
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let url = model.fileURL {
                    BotNativeFilePreview(url: url)
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Could Not Load File", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { attempt += 1 }
                    }
                } else {
                    Text("Loading file...").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: attempt) { await model.load(name: reference.displayName, download: download) }
        .onDisappear { model.cleanup() }
    }
}

/// Quick Look provides native PDF, image, audio and document viewers and export.
private struct BotNativeFilePreview: UIViewControllerRepresentable {
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
