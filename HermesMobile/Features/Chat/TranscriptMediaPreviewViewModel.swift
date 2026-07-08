import Foundation
import SwiftUI

@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let sessionID: String?
    private let reference: TranscriptMediaReference
    private let apiClient: APIClient
    private var didLoad = false
    private var loadGeneration = 0
    private var originalData: Data?

    private(set) var previewData: Data?
    private(set) var originalByteCount: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(
        server: URL,
        sessionID: String?,
        reference: TranscriptMediaReference,
        apiClient: APIClient? = nil
    ) {
        self.sessionID = sessionID
        self.reference = reference
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canSaveImageToPhotos: Bool {
        reference.isRasterImageCandidate && previewData != nil
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        loadGeneration += 1
        let generation = loadGeneration
        didLoad = true
        previewData = nil
        originalByteCount = nil
        originalData = nil

        guard reference.isRasterImageCandidate else {
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
            if let downsampled = await ImagePreviewDownsampler.previewDataAsync(
                from: data,
                maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
            ) {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                previewData = downsampled
            } else {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                errorMessage = String(localized: "Could not decode this image.")
            }
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func originalImageData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await transcriptMediaData()
        try Task.checkCancellation()
        originalData = data
        originalByteCount = data.count
        return data
    }

    private func transcriptMediaData() async throws -> Data {
        switch reference.source {
        case .localPath:
            guard let sessionID = resolvedSessionID else {
                throw TranscriptMediaPreviewError.missingSessionID
            }
            return try await apiClient.transcriptMediaData(for: reference, sessionID: sessionID)
        case .remoteURL:
            return try await apiClient.transcriptMediaData(for: reference, sessionID: resolvedSessionID ?? "")
        }
    }

    private var resolvedSessionID: String? {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            return nil
        }
        return sessionID
    }
}

private enum TranscriptMediaPreviewError: LocalizedError {
    case missingSessionID

    var errorDescription: String? {
        String(localized: "Preview is not available for this media without a server session.")
    }
}
