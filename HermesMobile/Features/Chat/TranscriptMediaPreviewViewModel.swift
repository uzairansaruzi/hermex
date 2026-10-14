import Foundation
import SwiftUI

/// One transcript media reference's preview and export. A MEDIA path downloads through the
/// chat's `WorkspaceFileClient`, from webui's `/api/media` or a Hermes host (#1112); nil is a
/// chat without a session to read from. A remote URL downloads through `apiClient`.
@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let files: (any WorkspaceFileClient)?
    private let reference: TranscriptMediaReference
    private let apiClient: APIClient
    private var didLoad = false
    private var loadGeneration = 0
    private var originalData: Data?
    /// The preview stopped at its 25 MB cap (a Hermes host), so export reads the whole file.
    private var isPastPreviewCap = false
    private var temporaryVideoURL: URL?

    private(set) var previewData: Data?
    private(set) var audioData: Data?
    private(set) var videoFileURL: URL?
    private(set) var originalByteCount: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(
        server: URL,
        files: (any WorkspaceFileClient)?,
        reference: TranscriptMediaReference,
        apiClient: APIClient? = nil
    ) {
        self.files = files
        self.reference = reference
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canSaveImageToPhotos: Bool {
        reference.isRasterImageCandidate && previewData != nil
    }

    var canSaveVideoToPhotos: Bool {
        videoFileURL != nil && originalData != nil
    }

    var canSaveMediaToPhotos: Bool {
        canSaveImageToPhotos || canSaveVideoToPhotos
    }

    var canExportMedia: Bool {
        originalData != nil || isPastPreviewCap
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        loadGeneration += 1
        let generation = loadGeneration
        didLoad = true
        previewData = nil
        audioData = nil
        videoFileURL = nil
        originalByteCount = nil
        originalData = nil
        isPastPreviewCap = false
        removeTemporaryVideoFile()

        guard reference.isRasterImageCandidate || reference.isVideoCandidate else {
            errorMessage = String(localized: "Preview is not available for this media type.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }

        do {
            let data = try await transcriptMediaData()
            guard !Task.isCancelled, loadGeneration == generation else { return }
            originalData = data
            originalByteCount = data.count

            if reference.isVideoCandidate {
                let fileURL = try writeTemporaryVideoFile(data)
                guard !Task.isCancelled, loadGeneration == generation else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                temporaryVideoURL = fileURL
                videoFileURL = fileURL
            } else if reference.isExtensionlessRemoteMediaCandidate, Self.isAudioData(data) {
                // Sniffed before the image decode: a WAV header is a RIFF
                // container, which sends ImageIO looking for a WebP codec.
                audioData = data
            } else {
                if let downsampled = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    previewData = downsampled
                } else {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    if reference.isExtensionlessRemoteMediaCandidate {
                        let fileURL = try writeTemporaryVideoFile(data)
                        temporaryVideoURL = fileURL
                        videoFileURL = fileURL
                    } else {
                        errorMessage = String(localized: "Could not decode this image.")
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            lastError = error
            errorMessage = error.localizedDescription
            isPastPreviewCap = error as? BotArtifactFailure == .tooLarge
        }
    }

    func originalImageData() async throws -> Data {
        try await originalMediaData()
    }

    func originalMediaData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await transcriptMediaData()
        try Task.checkCancellation()
        originalData = data
        originalByteCount = data.count
        return data
    }

    func exportPayload() async throws -> FileExportPayload {
        let data = if isPastPreviewCap, case let .localPath(path) = reference.source, let files {
            try await files.mediaExportData(path: path)
        } else {
            try await originalMediaData()
        }
        return TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: resolvedExportKind
        )
    }

    private func transcriptMediaData() async throws -> Data {
        switch reference.source {
        case let .localPath(path):
            guard let files else { throw TranscriptMediaPreviewError.missingSessionID }
            return try await files.mediaData(path: path)
        case let .remoteURL(url):
            return try await apiClient.remoteTranscriptMediaData(from: url)
        }
    }

    func cleanupTemporaryFiles() {
        loadGeneration += 1
        isLoading = false
        audioData = nil
        removeTemporaryVideoFile()
        videoFileURL = nil
    }

    private func writeTemporaryVideoFile(_ data: Data) throws -> URL {
        let ext = reference.videoFileExtension
        let filename = "transcript-media-\(UUID().uuidString).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func removeTemporaryVideoFile() {
        if let temporaryVideoURL {
            try? FileManager.default.removeItem(at: temporaryVideoURL)
        }
        temporaryVideoURL = nil
    }

    private static func isAudioData(_ data: Data) -> Bool {
        AttachmentAudioDetection.containerType(of: data) != nil
    }

    private var resolvedExportKind: TranscriptMediaResolvedExportKind? {
        if previewData != nil {
            return .image
        }

        if audioData != nil {
            return .audio
        }

        if videoFileURL != nil {
            return .video
        }

        return nil
    }
}

enum TranscriptMediaPreviewError: LocalizedError {
    case missingSessionID

    var errorDescription: String? {
        String(localized: "Preview is not available for this media without a server session.")
    }
}

private extension TranscriptMediaReference {
    var videoFileExtension: String {
        switch source {
        case let .remoteURL(url):
            let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        case let .localPath(path):
            let ext = URL(fileURLWithPath: path).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? "mp4" : ext
        }
    }
}
