import UIKit

/// Semantic colours for the surface. Every colour is dynamic, so a draw pass resolves
/// light or dark from the current trait collection with no theme plumbing.
struct ReviewDiffTheme {
    let background = UIColor.systemBackground
    let text = UIColor.label
    let mutedText = UIColor.secondaryLabel
    let headerBackground = UIColor.secondarySystemBackground
    let border = UIColor.separator
    let accent = UIColor.systemBlue
    let hunkBackground = UIColor.systemBlue.withAlphaComponent(0.10)
    let addBackground = UIColor.systemGreen.withAlphaComponent(0.14)
    let deleteBackground = UIColor.systemRed.withAlphaComponent(0.14)
    let addTint = UIColor.systemGreen
    let deleteTint = UIColor.systemRed
    let conflictTint = UIColor.systemOrange

    func tint(for changeKind: GitFile.ChangeKind) -> UIColor {
        switch changeKind {
        case .added, .untracked: return addTint
        case .deleted: return deleteTint
        case .conflict: return conflictTint
        case .renamed, .modified, .ignored, .unknown: return accent
        }
    }
}

/// Fonts and fixed geometry, resolved once per trait collection. Row heights follow
/// the scaled code font so Dynamic Type grows rows instead of clipping them.
struct ReviewDiffStyle {
    let codeFont: UIFont
    let lineNumberFont: UIFont
    let hunkFont: UIFont
    let fileHeaderFont: UIFont
    let fileHeaderMetaFont: UIFont
    let noticeFont: UIFont
    let metrics: ReviewDiffMetrics
    /// Advance of one character in `codeFont`; the word highlights sit on this grid.
    let codeCharacterWidth: CGFloat
    let gutterWidth: CGFloat
    let changeBarWidth: CGFloat = 4
    let codePadding: CGFloat = 8
    let maxContentWidth: CGFloat = 2800
    let fileHeaderHorizontalPadding: CGFloat = 12

    /// Change bar plus gutter: the part of a row that never scrolls horizontally.
    var stickyWidth: CGFloat { changeBarWidth + gutterWidth }
    var codeStartX: CGFloat { stickyWidth + codePadding }

    static func resolve(for traits: UITraitCollection) -> ReviewDiffStyle {
        let metrics = UIFontMetrics(forTextStyle: .body)
        func mono(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            metrics.scaledFont(
                for: .monospacedSystemFont(ofSize: size, weight: weight),
                maximumPointSize: size * 2.2,
                compatibleWith: traits
            )
        }
        let codeFont = mono(12, .regular)
        let lineNumberFont = mono(11, .regular)
        let fileHeaderFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).withWeight(.semibold)
        let noticeFont = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)

        let sample = String(repeating: "M", count: 64)
        let characterWidth = (sample as NSString).size(withAttributes: [.font: codeFont, .ligature: 0]).width / 64
        let gutterSample = ("00000" as NSString).size(withAttributes: [.font: lineNumberFont]).width

        return ReviewDiffStyle(
            codeFont: codeFont,
            lineNumberFont: lineNumberFont,
            hunkFont: mono(12, .semibold),
            fileHeaderFont: fileHeaderFont,
            fileHeaderMetaFont: mono(12, .semibold),
            noticeFont: noticeFont,
            metrics: ReviewDiffMetrics(
                rowHeight: ceil(codeFont.lineHeight) + 6,
                fileHeaderHeight: ceil(fileHeaderFont.lineHeight) + 30,
                noticeHeight: max(44, ceil(noticeFont.lineHeight) + 24)
            ),
            codeCharacterWidth: characterWidth,
            gutterWidth: ceil(gutterSample) + 14
        )
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
