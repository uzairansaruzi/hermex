import UIKit

/// When a sent user message folds to its first lines behind Show more.
///
/// `MessageBubbleView` asks `mayFold` on every pass. It is cheap and rules out
/// nearly every message, and those are never measured. The rest are measured
/// with `lineCount` once per row width and text size, and fold when `folds`
/// says so.
enum UserBubbleFoldPolicy {
    /// The lines a folded bubble shows.
    static let visibleLines = 6
    /// The most wrapped lines a bubble shows in full.
    static let maximumUnfoldedLines = 8

    /// Whether `text` could wrap past `maximumUnfoldedLines` in any bubble.
    ///
    /// Each hard line counts once, plus one wrapped line per
    /// `bodyBytesPerLine` UTF-8 bytes, scaled down as the font grows. Real
    /// lines hold more than that, and wide scripts spend more bytes per
    /// character, so the estimate runs high and a message this rejects does
    /// not fold. It stops reading once the estimate passes the limit, so a
    /// long paste costs a few hundred bytes.
    static func mayFold(text: String, font: UIFont) -> Bool {
        let bytesPerLine = max(1, Int(bodyBytesPerLine * bodyPointSize / font.pointSize))
        var lines = 1
        var bytes = 0
        for byte in text.utf8 {
            bytes += 1
            if byte == UInt8(ascii: "\n") { lines += 1 }
            if lines + bytes / bytesPerLine > maximumUnfoldedLines { return true }
        }
        return false
    }

    /// The number of lines `text` wraps to in a column `width` points wide,
    /// laid out with TextKit. A `limit` above 0 stops layout at that many
    /// lines, so a long paste lays out only what the fold needs.
    static func lineCount(text: String, width: CGFloat, font: UIFont, limit: Int = 0) -> Int {
        guard width > 0, !text.isEmpty else { return 0 }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = limit
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }

    static func folds(lineCount: Int) -> Bool {
        lineCount > maximumUnfoldedLines
    }

    /// The fewest bytes a 17 pt body line can hold: capitals in the narrowest
    /// text column, 228 pt in a 320 pt window (iPad Slide Over or narrow Split
    /// View, or Display Zoom on a small iPhone).
    private static let bodyBytesPerLine: CGFloat = 18
    private static let bodyPointSize: CGFloat = 17
}
