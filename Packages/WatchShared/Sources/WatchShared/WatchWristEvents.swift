import Foundation

/// Complication tap opens the watch app straight into a voice note.
/// The recording panel still has Cancel before anything is sent.
public enum WatchComplicationLink {
    public static let record = URL(string: "hermex-watch://record")!

    public static func isRecord(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "hermex-watch" && url.host?.lowercased() == "record"
    }
}

/// A finished watch-started reply, small enough for one watch notification.
/// The full turn stays on the Now card.
public enum WatchReplyNotice {
    public static let userInfoKind = "hermex.watch.reply"
    public static let maximumBodyCharacters = 180

    public static func userInfo(body: String, sessionID: String) -> [String: String] {
        [
            "kind": userInfoKind,
            "body": clip(body),
            "session": sessionID
        ]
    }

    public static func body(in userInfo: [String: Any]) -> String? {
        guard (userInfo["kind"] as? String) == userInfoKind else { return nil }
        let text = (userInfo["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The latest assistant words in a wrist transcript, clipped for a notification.
    public static func assistantText(in blocks: [WatchPhoneTranscriptPage.Block]) -> String? {
        for block in blocks.reversed() {
            guard case .text(let role, let text) = block.kind, role == .assistant else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return clip(trimmed) }
        }
        return nil
    }

    public static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumBodyCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maximumBodyCharacters - 1)
        return String(trimmed[..<end]) + "…"
    }
}
