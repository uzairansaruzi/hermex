import AVFoundation
import Foundation
import UIKit
import UniformTypeIdentifiers

enum TranscriptMediaResolvedExportKind {
    case image
    case audio
    case video
    case data
}

enum TranscriptMediaExportSupport {
    static func payload(
        for reference: TranscriptMediaReference,
        data: Data,
        resolvedKind: TranscriptMediaResolvedExportKind? = nil
    ) -> FileExportPayload {
        let descriptor = exportDescriptor(for: reference, data: data, resolvedKind: resolvedKind)
        return FileExportPayload(
            data: data,
            filename: exportFilename(for: reference, fileExtension: descriptor.fileExtension),
            contentType: descriptor.contentType,
            isImage: descriptor.kind == .image,
            isVideo: descriptor.kind == .video
        )
    }

    private static func exportDescriptor(
        for reference: TranscriptMediaReference,
        data: Data,
        resolvedKind: TranscriptMediaResolvedExportKind?
    ) -> TranscriptMediaExportDescriptor {
        if let fileExtension = reference.exportFileExtension,
           let contentType = UTType(filenameExtension: fileExtension) {
            return TranscriptMediaExportDescriptor(
                kind: exportKind(for: contentType),
                contentType: contentType,
                fileExtension: fileExtension
            )
        }

        if resolvedKind == .image || UIImage(data: data) != nil {
            return TranscriptMediaExportDescriptor(kind: .image, contentType: .png, fileExtension: "png")
        }

        if resolvedKind == .audio || isAudioData(data) {
            let audioType = audioType(from: data) ?? (UTType(filenameExtension: "m4a") ?? .audio, "m4a")
            return TranscriptMediaExportDescriptor(
                kind: .audio,
                contentType: audioType.contentType,
                fileExtension: audioType.fileExtension
            )
        }

        if resolvedKind == .data {
            return TranscriptMediaExportDescriptor(kind: .data, contentType: .data, fileExtension: "bin")
        }

        return TranscriptMediaExportDescriptor(kind: .video, contentType: .mpeg4Movie, fileExtension: "mp4")
    }

    private static func exportFilename(for reference: TranscriptMediaReference, fileExtension: String) -> String {
        let baseName = reference.exportBaseName
        guard URL(fileURLWithPath: baseName).pathExtension.isEmpty else {
            return baseName
        }

        return "\(baseName).\(fileExtension)"
    }

    private static func exportKind(for contentType: UTType) -> TranscriptMediaResolvedExportKind {
        if contentType.conforms(to: .image) {
            return .image
        }

        if contentType.conforms(to: .audio) {
            return .audio
        }

        if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
            return .video
        }

        return .data
    }

    private static func isAudioData(_ data: Data) -> Bool {
        (try? AVAudioPlayer(data: data)) != nil
    }

    private static func audioType(from data: Data) -> (contentType: UTType, fileExtension: String)? {
        if data.starts(with: Array("RIFF".utf8)), data.dropFirst(8).starts(with: Array("WAVE".utf8)) {
            return (.wav, "wav")
        }

        if data.starts(with: [0x49, 0x44, 0x33]) {
            return (.mp3, "mp3")
        }

        if data.count >= 2 {
            let bytes = Array(data.prefix(2))
            if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
                return (.mp3, "mp3")
            }
        }

        if data.starts(with: Array("caff".utf8)) {
            return (UTType(filenameExtension: "caf") ?? .audio, "caf")
        }

        return nil
    }
}

private struct TranscriptMediaExportDescriptor {
    let kind: TranscriptMediaResolvedExportKind
    let contentType: UTType
    let fileExtension: String
}

extension TranscriptMediaReference {
    var exportBaseName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Hermes Media") : trimmed
    }

    var exportFileExtension: String? {
        let fileExtension: String
        switch source {
        case let .remoteURL(url):
            fileExtension = url.pathExtension
        case let .localPath(path):
            fileExtension = URL(fileURLWithPath: path).pathExtension
        }

        let normalized = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
