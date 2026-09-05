import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The transcript's viewer for an image. Audio, video, and unsupported media keep
/// `TranscriptMediaPreviewView`, which can only tell them apart after the bytes arrive;
/// an image is known to be an image before anything is fetched, so it can open straight
/// into the full-bleed lightbox.
struct TranscriptMediaImageLightbox: View {
    let onAPIError: (Error) -> Void

    private let item: TranscriptMediaPreviewItem
    @State private var viewModel: TranscriptMediaPreviewViewModel
    @State private var exportDocument = ExportedFileDocument(data: Data())
    @State private var exportContentType = UTType.data
    @State private var exportFilename = String(localized: "Hermes Media")
    @State private var isFileExporterPresented = false
    @State private var isExportingMedia = false
    @State private var isSavingToPhotos = false
    @State private var saveConfirmationMessage: String?
    @State private var errorMessage: String?

    init(
        server: URL,
        sessionID: String?,
        item: TranscriptMediaPreviewItem,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.item = item
        self.onAPIError = onAPIError
        _viewModel = State(
            initialValue: TranscriptMediaPreviewViewModel(
                server: server,
                sessionID: sessionID,
                reference: item.reference
            )
        )
    }

    var body: some View {
        ImageLightboxView(
            content: content,
            title: item.reference.displayName,
            path: item.reference.rawReference,
            imageAccessibilityLabel: item.reference.accessibilityName,
            onRetry: { Task { await loadMedia(force: true) } }
        ) {
            if viewModel.canSaveMediaToPhotos {
                ImageLightboxActionButton(
                    systemImage: "photo",
                    accessibilityLabel: String(localized: "Save media to Photos"),
                    isDisabled: exportActionsAreDisabled,
                    action: { Task { await saveMediaToPhotos() } }
                )
            }

            if viewModel.canExportMedia {
                ImageLightboxActionButton(
                    systemImage: "square.and.arrow.up",
                    accessibilityLabel: String(localized: "Export media"),
                    isDisabled: exportActionsAreDisabled,
                    action: { Task { await exportMedia() } }
                )
            }
        }
        .task {
            await loadMedia()
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Saved",
            isPresented: Binding(
                get: { saveConfirmationMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        saveConfirmationMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                saveConfirmationMessage = nil
            }
        } message: {
            Text(saveConfirmationMessage ?? "")
        }
        .alert(
            "Media Action Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            viewModel.cleanupTemporaryFiles()
        }
    }

    private var content: ImageLightboxContent {
        if let data = viewModel.previewData {
            guard let image = UIImage(data: data) else {
                return .failure(String(localized: "Could not decode this image."))
            }
            return .image(image, detail: detailText)
        }

        if !viewModel.isLoading, let message = viewModel.errorMessage {
            return .failure(message)
        }

        return .loading(String(localized: "Loading media..."))
    }

    private var detailText: String? {
        guard let originalByteCount = viewModel.originalByteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(originalByteCount), countStyle: .file)
    }

    private var exportActionsAreDisabled: Bool {
        viewModel.isLoading || isSavingToPhotos || isExportingMedia
    }

    private func loadMedia(force: Bool = false) async {
        await viewModel.load(force: force)
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func exportMedia() async {
        isExportingMedia = true
        defer { isExportingMedia = false }

        do {
            let payload = try await viewModel.exportPayload()
            exportDocument = ExportedFileDocument(data: payload.data)
            exportContentType = payload.contentType
            exportFilename = payload.filename
            isFileExporterPresented = true
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }

    private func saveMediaToPhotos() async {
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }

        do {
            let payload = try await viewModel.exportPayload()
            guard payload.isImage, UIImage(data: payload.data) != nil else {
                throw PhotoLibrarySaveError.notImage
            }
            try await PhotoLibrarySaver.saveImageData(payload.data)
            saveConfirmationMessage = String(localized: "Media saved to Photos.")
        } catch {
            errorMessage = error.localizedDescription
            onAPIError(error)
        }
    }
}
