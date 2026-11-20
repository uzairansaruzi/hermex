import SwiftUI
import UIKit

final class ComposerChipAttachment: NSTextAttachment {
    let token: ComposerChipToken

    var source: String { token.source }

    init(token: ComposerChipToken, image: UIImage, baselineOffset: CGFloat) {
        self.token = token
        super.init(data: nil, ofType: nil)
        image.accessibilityLabel = token.label
        self.image = image
        accessibilityLabel = token.label
        bounds = CGRect(origin: CGPoint(x: 0, y: baselineOffset), size: image.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

final class ComposerQuoteAttachment: NSTextAttachment {
    let quote: ComposerQuote

    init(quote: ComposerQuote, image: UIImage, baselineOffset: CGFloat) {
        self.quote = quote
        super.init(data: nil, ofType: nil)
        let label = String(localized: "Quoted passage") + ": " + quote.text
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

extension NSAttributedString.Key {
    static let composerQuoteSpacer = NSAttributedString.Key("com.hermex.composerQuoteSpacer")
}

struct ComposerChipMetrics: Equatable {
    let labelFont: UIFont
    let height: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat
    let iconGap: CGFloat
    let horizontalPadding: CGFloat

    init(editorFont: UIFont) {
        let labelFont = UIFont.app(size: max(12, editorFont.pointSize - 2), weight: .medium)
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

@MainActor enum ComposerChipRenderer {
    private static let cache = NSCache<CacheKey, UIImage>()

    private final class CacheKey: NSObject {
        let values: [NSObject]
        init(_ values: [NSObject]) { self.values = values }
        override var hash: Int {
            var hasher = Hasher()
            for value in values { hasher.combine(value.hash) }
            return hasher.finalize()
        }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? CacheKey else { return false }
            return values == other.values
        }
    }

    static func image(
        label: String,
        icon: ComposerChipIcon,
        metrics: ComposerChipMetrics,
        traits: UITraitCollection,
        isRightToLeft: Bool,
        maximumWidth: CGFloat? = nil,
        usesAccentIcon: Bool = false
    ) -> UIImage {
        let values: [NSObject] = [
            label as NSString,
            icon.cacheKey,
            metrics.labelFont.fontName as NSString,
            String(describing: metrics.labelFont.pointSize) as NSString,
            String(describing: metrics.height) as NSString,
            String(traits.userInterfaceStyle.rawValue) as NSString,
            traits[AppAppearanceTrait.self].cacheKey as NSString,
            String(traits.accessibilityContrast.rawValue) as NSString,
            NSNumber(value: Double(traits.displayScale)),
            (isRightToLeft ? "rtl" : "ltr") as NSString,
            (maximumWidth.map(String.init(describing:)) ?? "unbounded") as NSString,
            (usesAccentIcon ? "accent" : "secondary") as NSString
        ]
        let key = CacheKey(values)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = draw(
            label: label,
            icon: icon,
            metrics: metrics,
            traits: traits,
            isRightToLeft: isRightToLeft,
            maximumWidth: maximumWidth,
            usesAccentIcon: usesAccentIcon
        )
        cache.setObject(image, forKey: key)
        return image
    }

    private static func iconImage(
        _ icon: ComposerChipIcon,
        metrics: ComposerChipMetrics,
        traits: UITraitCollection,
        usesAccentIcon: Bool
    ) -> UIImage? {
        switch icon {
        case let .symbol(name):
            let tint = usesAccentIcon
                ? UIColor.appAccent.resolvedColor(with: traits)
                : UIColor.appTextSecondary.resolvedColor(with: traits)
            return UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: metrics.iconSize - 2,
                    weight: .medium
                )
            )?.withTintColor(tint, renderingMode: .alwaysOriginal)
        case let .asset(name):
            return UIImage(named: name)
        case let .bot(reference):
            let view = BotAvatarView(profile: reference.profile, avatar: reference.avatar, size: metrics.iconSize, motion: .still)
                .environment(\.colorScheme, traits.userInterfaceStyle == .dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = max(traits.displayScale, 1)
            return renderer.uiImage
        }
    }

    private static func draw(
        label: String,
        icon iconStyle: ComposerChipIcon,
        metrics: ComposerChipMetrics,
        traits: UITraitCollection,
        isRightToLeft: Bool,
        maximumWidth: CGFloat?,
        usesAccentIcon: Bool
    ) -> UIImage {
        let background = UIColor.appFillSecondary.resolvedColor(with: traits)
        let border = UIColor.appSeparator.resolvedColor(with: traits)
        let textColor = UIColor.appText.resolvedColor(with: traits)

        let icon = iconImage(
            iconStyle,
            metrics: metrics,
            traits: traits,
            usesAccentIcon: usesAccentIcon
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metrics.labelFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let iconWidth = icon == nil ? 0 : metrics.iconSize + metrics.iconGap
        let naturalWidth = ceil(metrics.horizontalPadding * 2 + iconWidth + textSize.width)
        let width = maximumWidth.map { min(naturalWidth, max(metrics.height * 2, $0)) } ?? naturalWidth
        let textWidth = max(0, width - metrics.horizontalPadding * 2 - iconWidth)

        let format = UIGraphicsImageRendererFormat(for: traits)
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
                    width: textWidth,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
        }
    }
}

struct ComposerChipTextStyle {
    let metrics: ComposerChipMetrics
    let traits: UITraitCollection
    let isRightToLeft: Bool

    init(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast,
        layoutDirection: LayoutDirection,
        dynamicTypeSize: DynamicTypeSize,
        displayScale: CGFloat,
        appearance: AppAppearance
    ) {
        metrics = ComposerChipMetrics(editorFont: .app(forTextStyle: .body, at: dynamicTypeSize))
        traits = UITraitCollection { traits in
            traits[AppAppearanceTrait.self] = appearance
            traits.displayScale = displayScale
            traits.userInterfaceStyle = colorScheme == .dark ? .dark : .light
            traits.accessibilityContrast = contrast == .increased ? .high : .normal
        }
        isRightToLeft = layoutDirection == .rightToLeft
    }
}

enum ComposerChipTextLine {
    static func validTokens(_ tokens: [ComposerChipToken], in text: String) -> [ComposerChipToken] {
        let string = text as NSString
        guard tokens.allSatisfy({
            $0.range.upperBound <= string.length && string.substring(with: $0.range) == $0.source
        }) else {
            return []
        }
        return tokens
    }

    @MainActor static func text(
        _ text: String,
        tokens: [ComposerChipToken],
        style: ComposerChipTextStyle
    ) -> Text {
        guard !tokens.isEmpty else { return Text(verbatim: text) }

        let string = text as NSString
        var line = Text(verbatim: "")
        var cursor = 0

        for token in tokens where token.range.location >= cursor {
            if token.range.location > cursor {
                let plain = string.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                line = line + Text(verbatim: plain)
            }

            let chip = ComposerChipRenderer.image(
                label: token.label,
                icon: token.icon,
                metrics: style.metrics,
                traits: style.traits,
                isRightToLeft: style.isRightToLeft
            )
            line = line + Text(Image(uiImage: chip))
            cursor = token.range.upperBound
        }

        if cursor < string.length {
            line = line + Text(verbatim: string.substring(from: cursor))
        }

        return line
    }
}

extension NSAttributedString {
    var composerSourceText: String {
        composerSourceText(in: NSRange(location: 0, length: length))
    }

    func composerSourceText(in range: NSRange) -> String {
        guard range.length > 0 else { return "" }

        let display = string as NSString
        let source = NSMutableString()

        enumerateAttributes(in: range) { attributes, attributeRange, _ in
            if let chip = attributes[.attachment] as? ComposerChipAttachment {
                source.append(chip.source)
            } else if attributes[.attachment] == nil,
                      attributes[.composerQuoteSpacer] == nil {
                source.append(display.substring(with: attributeRange))
            }
        }

        return source as String
    }

    func composerSourceOffset(forDisplayOffset displayOffset: Int) -> Int {
        let bounded = max(0, min(length, displayOffset))
        guard bounded > 0 else { return 0 }

        var source = 0
        enumerateAttributes(in: NSRange(location: 0, length: bounded)) { attributes, range, _ in
            if let chip = attributes[.attachment] as? ComposerChipAttachment {
                source += (chip.source as NSString).length
            } else if attributes[.attachment] == nil,
                      attributes[.composerQuoteSpacer] == nil {
                source += range.length
            }
        }
        return source
    }

    func composerDisplayOffset(forSourceOffset sourceOffset: Int) -> Int {
        var source = 0
        var display = 0

        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, stop in
            if let chip = attributes[.attachment] as? ComposerChipAttachment {
                let chipLength = (chip.source as NSString).length
                if sourceOffset < source + chipLength {
                    display = sourceOffset <= source ? range.location : NSMaxRange(range)
                    stop.pointee = true
                    return
                }
                source += chipLength
            } else if attributes[.attachment] == nil,
                      attributes[.composerQuoteSpacer] == nil {
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

    func composerDisplayRange(forSourceRange range: NSRange) -> NSRange {
        let start = composerDisplayOffset(forSourceOffset: range.location)
        let end = composerDisplayOffset(forSourceOffset: range.upperBound)
        return NSRange(location: start, length: max(0, end - start))
    }

    func composerSourceRange(forDisplayRange range: NSRange) -> NSRange {
        let start = composerSourceOffset(forDisplayOffset: range.location)
        let end = composerSourceOffset(forDisplayOffset: range.upperBound)
        return NSRange(location: start, length: max(0, end - start))
    }
}
