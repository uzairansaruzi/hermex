import Foundation

/// Pure, testable audio-attachment detection shared by the chat bubble and the
/// full-screen attachment preview. Mirrors the image-detection rules used by
/// `GridAttachmentCell.inferredIsImage` / `ChatAttachmentPreviewItem.inferredIsImage`.
enum AttachmentAudioDetection {
    /// File extensions we treat as audio. `AVAudioPlayer` natively decodes the
    /// first group (m4a/mp3/wav/aac/caf); ogg/oga/opus/flac/webm/weba are still detected
    /// as audio so they surface an audio player with a graceful "can't play"
    /// state instead of a dead file chip.
    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "ogg", "oga", "opus", "flac", "webm", "weba"
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
