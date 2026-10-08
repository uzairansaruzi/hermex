import Foundation
import SwiftUI

@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let reference: TranscriptMediaReference
    private let download: () async throws -> Data
    private var didLoad = false
    private var loadGeneration = 0
    private var originalData: Data?
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
        sessionID: String?,
        reference: TranscriptMediaReference,
        apiClient: APIClient? = nil,
        download: (() async throws -> Data)? = nil
    ) {
        self.reference = reference
        if let download {
            self.download = download
        } else {
            let client = apiClient ?? APIClient(baseURL: server)
            let trimmedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSessionID = trimmedSessionID.flatMap { $0.isEmpty ? nil : $0 }
            self.download = {
                try await client.transcriptMediaData(for: reference, sessionID: resolvedSessionID)
            }
        }
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
        originalData != nil
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
            let data = try await download()
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
        }
    }

    func originalImageData() async throws -> Data {
        try await originalMediaData()
    }

    func originalMediaData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await download()
        try Task.checkCancellation()
        originalData = data
        originalByteCount = data.count
        return data
    }

    func exportPayload() async throws -> FileExportPayload {
        let data = try await originalMediaData()
        return TranscriptMediaExportSupport.payload(
            for: reference,
            data: data,
            resolvedKind: resolvedExportKind
        )
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
