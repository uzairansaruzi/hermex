import Foundation
import UniformTypeIdentifiers

enum AttachmentAudioDetection {
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "ogg", "oga", "opus", "flac"
    ]

    static func isAudio(isImage: Bool?, mime: String?, name: String?, path: String?) -> Bool {
        if isImage == true { return false }

        if let mime = mime?.lowercased(), mime.hasPrefix("audio/") {
            return true
        }

        for candidate in [name, path] {
            let ext = URL(fileURLWithPath: candidate ?? "").pathExtension.lowercased()
            if audioExtensions.contains(ext) { return true }
        }
        return false
    }

    static func containerType(of data: Data) -> (contentType: UTType, fileExtension: String)? {
        let bytes = Array(data.prefix(12))
        func starts(with tag: String, at offset: Int = 0) -> Bool {
            let tagBytes = Array(tag.utf8)
            return bytes.count >= offset + tagBytes.count && Array(bytes[offset..<offset + tagBytes.count]) == tagBytes
        }
        if starts(with: "RIFF"), starts(with: "WAVE", at: 8) { return (.wav, "wav") }
        if starts(with: "ID3") { return (.mp3, "mp3") }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return (.mp3, "mp3") }
        if starts(with: "caff") { return (UTType(filenameExtension: "caf") ?? .audio, "caf") }
        if starts(with: "ftyp", at: 4), starts(with: "M4A", at: 8) { return (.mpeg4Audio, "m4a") }
        if starts(with: "fLaC") { return (UTType(filenameExtension: "flac") ?? .audio, "flac") }
        if starts(with: "OggS") { return (UTType(filenameExtension: "ogg") ?? .audio, "ogg") }
        return nil
    }
}

enum AudioDurationFormatter {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

extension MessageAttachment {
    var inferredIsAudio: Bool {
        AttachmentAudioDetection.isAudio(isImage: isImage, mime: mime, name: name, path: path)
    }
}
