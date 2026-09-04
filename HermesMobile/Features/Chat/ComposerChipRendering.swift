import UIKit

/// The chip a skill reference is drawn as: one attachment glyph that stands for
/// the whole `source` string.
///
/// Everything that leaves the editor - what is sent, copied, cut, or saved as a
/// draft - reads `source` back out, so the chip never changes the message.
final class ComposerChipAttachment: NSTextAttachment {
    let source: String

    init(source: String, label: String, image: UIImage, baselineOffset: CGFloat) {
        self.source = source
        super.init(data: nil, ofType: nil)
        image.accessibilityLabel = label
        self.image = image
        accessibilityLabel = label
        bounds = CGRect(origin: CGPoint(x: 0, y: baselineOffset), size: image.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// Chip geometry, derived from the editor's own font so Dynamic Type moves the
/// chip with the text around it.
///
/// t3code draws a 24 pt chip against a 15 pt label; every other measurement is a
/// fraction of that height, so scaling the height by the label's line height
/// keeps the proportions at every content size.
struct ComposerChipMetrics: Equatable {
    let labelFont: UIFont
    let height: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat
    let iconGap: CGFloat
    let horizontalPadding: CGFloat

    init(editorFont: UIFont) {
        let labelFont = UIFont.systemFont(ofSize: max(12, editorFont.pointSize - 2), weight: .medium)
        let height = ceil(labelFont.lineHeight + 6)
        let scale = height / 24

        self.labelFont = labelFont
        self.height = height
        cornerRadius = 7 * scale
        iconSize = round(14 * scale)
        iconGap = 5 * scale
        horizontalPadding = 9 * scale
    }
}

/// Draws the chip. The image is baked against a trait collection, so the editor
/// re-renders it when the appearance or the content size category changes.
enum ComposerChipRenderer {
    /// Matches the Skills screen's own glyph so a chip reads as the same thing
    /// the rest of the app calls a skill.
    private static let iconName = "hammer"

    /// Baked chips, keyed by everything that changes one. The editor redraws
    /// only when its chips or its style move, but the collapsed composer draws
    /// from `body`, which runs again on every parent update — including each
    /// token of a live stream. Baking there uncached would burn a render pass
    /// per frame for a picture that never changed.
    private static let cache = NSCache<NSString, UIImage>()

    static func image(
        label: String,
        metrics: ComposerChipMetrics,
        traits: UITraitCollection,
        isRightToLeft: Bool
    ) -> UIImage {
        let key = [
            label,
            String(describing: metrics.labelFont.pointSize),
            String(describing: metrics.height),
            String(traits.userInterfaceStyle.rawValue),
            isRightToLeft ? "rtl" : "ltr"
        ].joined(separator: "|") as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = draw(label: label, metrics: metrics, traits: traits, isRightToLeft: isRightToLeft)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func draw(
        label: String,
        metrics: ComposerChipMetrics,
        traits: UITraitCollection,
        isRightToLeft: Bool
    ) -> UIImage {
        let background = UIColor.secondarySystemFill.resolvedColor(with: traits)
        let border = UIColor.separator.resolvedColor(with: traits)
        let textColor = UIColor.label.resolvedColor(with: traits)
        let tint = UIColor.secondaryLabel.resolvedColor(with: traits)

        let icon = UIImage(
            systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: metrics.iconSize - 2,
                weight: .medium
            )
        )?.withTintColor(tint, renderingMode: .alwaysOriginal)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.labelFont,
            .foregroundColor: textColor
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let iconWidth = icon == nil ? 0 : metrics.iconSize + metrics.iconGap
        let width = ceil(metrics.horizontalPadding * 2 + iconWidth + textSize.width)

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: metrics.height),
            format: format
        )

        return renderer.image { _ in
            let bounds = CGRect(x: 0, y: 0, width: width, height: metrics.height)
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: metrics.cornerRadius
            )
            background.setFill()
            path.fill()
            border.setStroke()
            path.lineWidth = 1
            path.stroke()

            // The icon leads in both directions: mirroring it by hand is what
            // keeps an RTL chip from reading back to front, since the image is
            // drawn once and reused as a glyph.
            let iconX = isRightToLeft
                ? width - metrics.horizontalPadding - metrics.iconSize
                : metrics.horizontalPadding
            let textX = isRightToLeft
                ? metrics.horizontalPadding
                : metrics.horizontalPadding + iconWidth

            icon?.draw(
                in: CGRect(
                    x: iconX,
                    y: (metrics.height - metrics.iconSize) / 2,
                    width: metrics.iconSize,
                    height: metrics.iconSize
                )
            )

            (label as NSString).draw(
                in: CGRect(
                    x: textX,
                    y: (metrics.height - textSize.height) / 2,
                    width: textSize.width + 1,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
        }
    }
}

/// Crossing between the draft the server sees and the text the editor draws.
///
/// A chip is one character on screen and its whole source string in the draft,
/// so every caret the editor reports and every range the composer asks for has
/// to be translated. The rendered document is the authority: reading the
/// mapping off the attachments themselves means a caret can never be computed
/// from a stale idea of where the chips are.
extension NSAttributedString {
    /// The draft text this document stands for.
    var composerSourceText: String {
        composerSourceText(in: NSRange(location: 0, length: length))
    }

    func composerSourceText(in range: NSRange) -> String {
        guard range.length > 0 else { return "" }

        let display = string as NSString
        let source = NSMutableString()

        enumerateAttribute(.attachment, in: range) { value, attributeRange, _ in
            if let chip = value as? ComposerChipAttachment {
                source.append(chip.source)
            } else {
                source.append(display.substring(with: attributeRange))
            }
        }

        return source as String
    }

    /// The draft offset a display offset points at.
    func composerSourceOffset(forDisplayOffset displayOffset: Int) -> Int {
        let bounded = max(0, min(length, displayOffset))
        guard bounded > 0 else { return 0 }

        var source = 0
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: bounded)) { value, range, _ in
            if let chip = value as? ComposerChipAttachment {
                source += (chip.source as NSString).length
            } else {
                source += range.length
            }
        }
        return source
    }

    /// The display offset a draft offset points at. An offset that lands inside
    /// a chip resolves to just after it, because there is nowhere inside a chip
    /// for a caret to be.
    func composerDisplayOffset(forSourceOffset sourceOffset: Int) -> Int {
        guard sourceOffset > 0 else { return 0 }

        var source = 0
        var display = 0

        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, stop in
            if let chip = value as? ComposerChipAttachment {
                let chipLength = (chip.source as NSString).length
                if sourceOffset < source + chipLength {
                    // The chip's own start still has a caret position; anywhere
                    // else inside it resolves to just after the chip.
                    display = sourceOffset <= source ? range.location : NSMaxRange(range)
                    stop.pointee = true
                    return
                }
                source += chipLength
            } else {
                if sourceOffset < source + range.length {
                    display = range.location + (sourceOffset - source)
                    stop.pointee = true
                    return
                }
                source += range.length
            }
            display = NSMaxRange(range)
        }

        return display
    }

    /// The display range a draft range covers.
    func composerDisplayRange(forSourceRange range: NSRange) -> NSRange {
        let start = composerDisplayOffset(forSourceOffset: range.location)
        let end = composerDisplayOffset(forSourceOffset: range.upperBound)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The draft range a display range covers.
    func composerSourceRange(forDisplayRange range: NSRange) -> NSRange {
        let start = composerSourceOffset(forDisplayOffset: range.location)
        let end = composerSourceOffset(forDisplayOffset: range.upperBound)
        return NSRange(location: start, length: max(0, end - start))
    }
}
