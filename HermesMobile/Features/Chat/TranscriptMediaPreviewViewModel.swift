import Foundation
import SwiftUI

@MainActor
@Observable
final class TranscriptMediaPreviewViewModel {
    private let reference: TranscriptMediaReference
    private let apiClient: APIClient
    private var didLoad = false
    private var originalData: Data?

    private(set) var previewData: Data?
    private(set) var textContent: String?
    private(set) var originalByteCount: Int?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastError: Error?

    init(server: URL, reference: TranscriptMediaReference, apiClient: APIClient? = nil) {
        self.reference = reference
        self.apiClient = apiClient ?? APIClient(baseURL: server)
    }

    var canSaveImageToPhotos: Bool {
        reference.isRasterImageCandidate && previewData != nil
    }

    func load(force: Bool = false) async {
        guard force || !didLoad else { return }
        didLoad = true
        previewData = nil
        textContent = nil
        originalByteCount = nil

        guard reference.isRasterImageCandidate || reference.isTextDocumentCandidate else {
            errorMessage = String(localized: "Preview is not available for this media type.")
            return
        }

        isLoading = true
        errorMessage = nil
        lastError = nil
        defer {
            isLoading = false
        }

        do {
            let data = try await apiClient.transcriptMediaData(for: reference)
            originalData = data
            originalByteCount = data.count
            if reference.isRasterImageCandidate {
                if let downsampled = await ImagePreviewDownsampler.previewDataAsync(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    previewData = downsampled
                } else {
                    errorMessage = String(localized: "Could not decode this image.")
                }
            } else if let decodedText = Self.decodedText(from: data) {
                textContent = decodedText
            } else {
                errorMessage = String(localized: "Could not decode this text file.")
            }
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }
    }

    func originalImageData() async throws -> Data {
        if let originalData {
            return originalData
        }

        let data = try await apiClient.transcriptMediaData(for: reference)
        originalData = data
        originalByteCount = data.count
        return data
    }

    private static func decodedText(from data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .ascii] {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }

        return nil
    }
}
