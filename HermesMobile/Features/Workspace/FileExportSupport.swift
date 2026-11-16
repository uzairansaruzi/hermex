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

/// The system share sheet for one local file, presented in a `.sheet`. `ShareLink` can't
/// be presented programmatically after an async download finishes. The caller owns the
/// file and deletes it once the sheet is gone, which is after the activity UI finishes
/// in both the completed and cancelled paths.
struct FileShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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

    static func saveVideoFile(at sourceURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibrarySaveError.notAuthorized
        }

        let stagedVideo = try StagedPhotoLibraryVideo(sourceURL: sourceURL)
        defer { stagedVideo.cleanup() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: stagedVideo.fileURL, options: nil)
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

private struct StagedPhotoLibraryVideo {
    let fileURL: URL

    private let directoryURL: URL
    private let fileManager: FileManager

    init(sourceURL: URL, fileManager: FileManager = .default) throws {
        guard sourceURL.isFileURL else {
            throw PhotoLibrarySaveError.videoFileUnavailable
        }

        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        } catch {
            throw PhotoLibrarySaveError.videoFileUnavailable
        }

        guard values.isRegularFile == true, values.isReadable != false else {
            throw PhotoLibrarySaveError.videoFileUnavailable
        }

        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("Hermex-Photo-Import-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)
            let filename = sourceURL.lastPathComponent.isEmpty ? "Hermex Video.mp4" : sourceURL.lastPathComponent
            let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
            try fileManager.copyItem(at: sourceURL, to: fileURL)
            self.fileURL = fileURL
            self.directoryURL = directoryURL
            self.fileManager = fileManager
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw PhotoLibrarySaveError.videoFileUnavailable
        }
    }

    func cleanup() {
        try? fileManager.removeItem(at: directoryURL)
    }
}

enum PhotoLibrarySaveError: LocalizedError, Equatable {
    case notAuthorized
    case notImage
    case notPhotosMedia
    case videoFileUnavailable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "Allow Photos access to save media from Hermex.")
        case .notImage:
            String(localized: "This file is not an image that can be saved to Photos.")
        case .notPhotosMedia:
            String(localized: "Photos can save images and videos. Export audio to Files instead.")
        case .videoFileUnavailable:
            String(localized: "This video is no longer available to save. Try loading it again.")
        case .saveFailed:
            String(localized: "Photos could not save this media.")
        }
    }
}
