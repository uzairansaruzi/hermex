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
}

enum PhotoLibrarySaveError: LocalizedError {
    case notAuthorized
    case notImage
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "Allow Photos access to save images from Zora.")
        case .notImage:
            String(localized: "This file is not an image that can be saved to Photos.")
        case .saveFailed:
            String(localized: "Photos could not save this image.")
        }
    }
}
