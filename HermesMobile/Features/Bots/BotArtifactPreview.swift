import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class BotArtifactPreviewModel {
    struct Export {
        let data: Data
        let filename: String
        let contentType: UTType
    }

    private var loaded: (file: QuickLookTemporaryFile, data: Data)?
    var fileURL: URL? { loaded?.file.url }
    private(set) var html: String?
    private(set) var errorMessage: String?
    private var generation = 0

    var export: Export? {
        guard let loaded else { return nil }
        let url = loaded.file.url
        return Export(
            data: loaded.data,
            filename: url.lastPathComponent,
            contentType: UTType(filenameExtension: url.pathExtension) ?? .data
        )
    }

    func load(name: String, decodesHTML: Bool = false, download: () async throws -> Data) async {
        cleanup()
        let owner = generation
        errorMessage = nil
        do {
            let data = try await download()
            try Task.checkCancellation()
            guard owner == generation else { return }
            let written = try await QuickLookTemporaryFile.write(data: data, name: name)
            guard !Task.isCancelled, owner == generation else { return }
            loaded = (written, data)
            if decodesHTML { html = String(decoding: data, as: UTF8.self) }
        } catch {
            guard !Task.isCancelled, owner == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func cleanup() {
        generation += 1
        loaded = nil
        html = nil
    }

}

struct BotArtifactPreview: View {
    let reference: TranscriptMediaReference
    var title: String? = nil
    let download: () async throws -> Data
    @Environment(\.dismiss) private var dismiss
    @State private var model = BotArtifactPreviewModel()
    @State private var attempt = 0
    @State private var isFileExporterPresented = false
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let html = model.html {
                    HTMLReportSheetPage(html: html)
                } else if let url = model.fileURL {
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
                    Text("Loading file...").foregroundStyle(.appSecondary)
                }
            }
            .themedPageBackground()
            .navigationTitle(name)
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
                        .accessibilityLabel(String(localized: "Save \(name) to Files"))
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(String(localized: "Share \(name)"))
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
        .task(id: attempt) {
            await model.load(name: name, decodesHTML: reference.isHTMLReportCandidate, download: download)
        }
        .onDisappear { model.cleanup() }
    }

    private var name: String { title ?? reference.displayName }
}
