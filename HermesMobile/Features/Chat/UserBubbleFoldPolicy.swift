import UIKit

enum UserBubbleFoldPolicy {
    static let visibleLines = 6
    static let maximumUnfoldedLines = 8

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

    private static let bodyBytesPerLine: CGFloat = 18
    private static let bodyPointSize: CGFloat = 17
}
