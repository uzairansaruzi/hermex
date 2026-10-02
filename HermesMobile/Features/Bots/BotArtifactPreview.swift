import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The preview owns its temporary file and the bytes written to it. Quick Look
/// and Share read the file; Save to Files writes the same bytes, so exporting
/// never downloads again. Dismissal invalidates late completions and removes
/// only the directory this presentation created.
@MainActor @Observable final class BotArtifactPreviewModel {
    /// What Save to Files writes: the downloaded bytes under the temporary file's
    /// sanitized name, typed by its extension, or `.data` without one.
    struct Export {
        let data: Data
        let filename: String
        let contentType: UTType
    }

    private var loaded: (file: QuickLookTemporaryFile, data: Data)?
    var fileURL: URL? { loaded?.file.url }
    private(set) var errorMessage: String?
    private var generation = 0

    /// Nil while loading, on error and after cleanup, when there are no bytes to save.
    var export: Export? {
        guard let loaded else { return nil }
        let url = loaded.file.url
        return Export(
            data: loaded.data,
            filename: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension) ?? .data
        )
    }

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
            loaded = (written, data)
        } catch {
            guard !Task.isCancelled, owner == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cleanup() {
        generation += 1
        loaded = nil
    }

}

/// A Bot Chat artifact or staged attachment in Quick Look. Once loaded, Save to
/// Files and Share sit beside Done and act on the bytes already downloaded.
struct BotArtifactPreview: View {
    let reference: TranscriptMediaReference
    let download: () async throws -> Data
    @Environment(\.dismiss) private var dismiss
    @State private var model = BotArtifactPreviewModel()
    @State private var attempt = 0
    @State private var isFileExporterPresented = false
    @State private var exportErrorMessage: String?

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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let url = model.fileURL {
                        Button {
                            isFileExporterPresented = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel(String(localized: "Save \(reference.displayName) to Files"))
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(String(localized: "Share \(reference.displayName)"))
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: model.export.map { ExportedFileDocument(data: $0.data) },
            contentType: model.export?.contentType ?? .data,
            defaultFilename: model.export?.filename
        ) { result in
            if case let .failure(error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .task(id: attempt) { await model.load(name: reference.displayName, download: download) }
        .onDisappear { model.cleanup() }
    }
}
