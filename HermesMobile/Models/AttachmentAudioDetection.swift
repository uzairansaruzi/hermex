import Foundation
import UniformTypeIdentifiers

/// Pure, testable audio-attachment detection shared by the chat bubble and the
/// full-screen attachment preview. Mirrors the image-detection rules used by
/// `GridAttachmentCell.inferredIsImage` / `ChatAttachmentPreviewItem.inferredIsImage`.
enum AttachmentAudioDetection {
    /// File extensions we treat as audio. `AVAudioPlayer` natively decodes the
    /// first group (m4a/mp3/wav/aac/caf); ogg/oga/opus/flac are still detected
    /// as audio so they surface an audio player with a graceful "can't play"
    /// state instead of a dead file chip.
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "ogg", "oga", "opus", "flac"
    ]

    /// Audio when the attachment is *not* an image and either its MIME type
    /// starts with `audio/` or its filename carries a known audio extension.
    /// The explicit `isImage == true` server flag always wins, so an image is
    /// never misclassified as audio.
    static func isAudio(isImage: Bool?, mime: String?, name: String?, path: String?) -> Bool {
        if isImage == true { return false }

        if let mime = mime?.lowercased(), mime.hasPrefix("audio/") {
            return true
        }

        // Check the display name first, then fall back to the path: a human
        // display name like "Voice note" carries no extension even when the
        // path ends in `.m4a`, so a single `name ?? path` candidate would miss it.
        for candidate in [name, path] {
            let ext = URL(fileURLWithPath: candidate ?? "").pathExtension.lowercased()
            if audioExtensions.contains(ext) { return true }
        }
        return false
    }

    /// The audio container `data` starts with, judged from its magic bytes:
    /// WAV, MP3 (ID3 tag or bare frame sync), CAF, M4A, FLAC, and Ogg. Used
    /// for extensionless media and exports, where nothing else names the type.
    /// A byte check is deliberate: asking AVFoundation or AudioToolbox to open
    /// the data starts the audio subsystem, which takes seconds on a cold
    /// simulator and is wasted work for a preview nobody has pressed play on.
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

/// Formats a playback offset/duration as `m:ss` (or `h:mm:ss` past an hour).
/// Non-finite or negative inputs clamp to `0:00` so the label stays monotonic
/// and never shows `NaN`.
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
    /// Whether this attachment should render as a playable audio clip.
    var inferredIsAudio: Bool {
        AttachmentAudioDetection.isAudio(isImage: isImage, mime: mime, name: name, path: path)
    }
}
