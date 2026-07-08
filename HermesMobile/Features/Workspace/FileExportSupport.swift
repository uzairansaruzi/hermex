import Foundation
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ExportedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum PhotoLibrarySaver {
    static func saveImageData(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { didSave, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if didSave {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
                }
            }
        }
    }

    static func saveVideoData(_ data: Data, contentType: UTType) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.notAuthorized
        }

        guard contentType.conforms(to: .movie) || contentType.conforms(to: .video) else {
            throw PhotoLibrarySaveError.notVideo
        }

        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = contentType.identifier

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, data: data, options: options)
            } completionHandler: { didSave, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if didSave {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
                }
            }
        }
    }
}

enum PhotoLibrarySaveError: LocalizedError {
    case notAuthorized
    case notImage
    case notVideo
    case notPhotosMedia
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "Allow Photos access to save media from Hermex.")
        case .notImage:
            String(localized: "This file is not an image that can be saved to Photos.")
        case .notVideo:
            String(localized: "This file is not a video that can be saved to Photos.")
        case .notPhotosMedia:
            String(localized: "Photos can save images and videos. Export audio to Files instead.")
        case .saveFailed:
            String(localized: "Photos could not save this media.")
        }
    }
}
