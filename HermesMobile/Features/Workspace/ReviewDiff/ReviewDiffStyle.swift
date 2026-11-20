import UIKit

struct ReviewDiffTheme {
    let background = UIColor.appCanvas
    let text = UIColor.appText
    let mutedText = UIColor.appTextSecondary
    let headerBackground = UIColor.appSurface
    let border = UIColor.appSeparator
    let accent = UIColor.appAccent
    let hunkBackground = UIColor.appAccent.withAlphaComponent(0.10)
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

enum ReviewDiffPresentation: Equatable {
    case diff
    case source

    var changeBarWidth: CGFloat {
        switch self {
        case .diff: return 4
        case .source: return 0
        }
    }
}

struct ReviewDiffStyle {
    let codeFont: UIFont
    let lineNumberFont: UIFont
    let hunkFont: UIFont
    let fileHeaderFont: UIFont
    let fileHeaderMetaFont: UIFont
    let noticeFont: UIFont
    let metrics: ReviewDiffMetrics
    let codeCharacterWidth: CGFloat
    let gutterWidth: CGFloat
    let changeBarWidth: CGFloat
    let codePadding: CGFloat = 8
    let maxContentWidth: CGFloat = 2800
    let fileHeaderHorizontalPadding: CGFloat = 12

    var stickyWidth: CGFloat { changeBarWidth + gutterWidth }
    var codeStartX: CGFloat { stickyWidth + codePadding }

    static func resolve(
        for traits: UITraitCollection,
        presentation: ReviewDiffPresentation = .diff,
        customCodeSize: CGFloat? = nil
    ) -> ReviewDiffStyle {
        let metrics = UIFontMetrics(forTextStyle: .body)
        func mono(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            if let customCodeSize {
                return .monospacedSystemFont(ofSize: customCodeSize * size / 12, weight: weight)
            }
            return metrics.scaledFont(
                for: .monospacedSystemFont(ofSize: size, weight: weight),
                maximumPointSize: size * 2.2,
                compatibleWith: traits
            )
        }
        let codeFont = mono(12, .regular)
        let lineNumberFont = mono(11, .regular)
        let fileHeaderFont = UIFont.app(forTextStyle: .subheadline, compatibleWith: traits).withWeight(.semibold)
        let noticeFont = UIFont.app(forTextStyle: .footnote, compatibleWith: traits)

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
                noticeHeight: max(44, ceil(noticeFont.lineHeight) + 24),
                wrappedLineHeight: ceil(codeFont.lineHeight)
            ),
            codeCharacterWidth: characterWidth,
            gutterWidth: ceil(gutterSample) + 14,
            changeBarWidth: presentation.changeBarWidth
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
