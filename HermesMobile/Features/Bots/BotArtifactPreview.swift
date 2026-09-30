import Foundation
import Observation
import SwiftUI

/// The preview owns its temporary file. Dismissal invalidates late completions
/// and removes only the directory this presentation created.
@MainActor @Observable final class BotArtifactPreviewModel {
    private var file: QuickLookTemporaryFile?
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
            let written = try await QuickLookTemporaryFile.write(data: data, name: name)
            // Returning drops a late write, which deletes its directory.
            guard !Task.isCancelled, owner == generation else { return }
            file = written
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
                    QuickLookFileView(url: url)
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
