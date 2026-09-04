import UIKit
import UniformTypeIdentifiers

/// The composer's editor: a text view that draws known skill references as
/// atomic chips while every value that leaves it stays the draft's own text.
final class ComposerChipTextView: UITextView {
    var isKeyboardSendEnabled = false
    var onKeyboardSend: () -> Void = {}
    var onPasteFileProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteFileURLs: ([URL]) -> Void = { _ in }
    var onPasteImageProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteImages: ([UIImage]) -> Void = { _ in }

    /// The skills whose references are drawn as chips.
    var chipSkills: [SkillSlashSuggestion] = [] {
        didSet {
            guard chipSkills != oldValue else { return }
            chipCatalog = ComposerChipCatalog(skills: chipSkills)
        }
    }

    private var chipCatalog = ComposerChipCatalog.empty
    private var renderedTokens: [ComposerChipToken] = []
    private var renderedStyle: ChipRenderStyle?

    /// What the chips were drawn against. A chip is a baked image, so a change
    /// of appearance or text size has to redraw it even when the draft has not
    /// moved at all.
    private struct ChipRenderStyle: Equatable {
        let fontPointSize: CGFloat
        let userInterfaceStyle: UIUserInterfaceStyle
        let isRightToLeft: Bool
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)

        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]
        ) { (view: ComposerChipTextView, _) in
            // Deferred: `adjustsFontForContentSizeCategory` updates `font` from
            // the same trait change, and the chips have to be sized against the
            // font that wins.
            DispatchQueue.main.async { view.refreshChipsIfNeeded() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: - Draft text

    /// The draft this editor stands for: every chip contributes the reference it
    /// was made from. This, never the on-screen text, is what is sent, saved,
    /// copied, and matched against a slash trigger.
    var sourceText: String {
        attributedText.composerSourceText
    }

    /// The caret or selection in draft coordinates.
    var sourceSelection: NSRange {
        get { attributedText.composerSourceRange(forDisplayRange: selectedRange) }
        set {
            let displayRange = attributedText.composerDisplayRange(forSourceRange: newValue)
            guard selectedRange != displayRange else { return }
            selectedRange = displayRange
        }
    }

    /// The on-screen range a draft range covers, or `nil` when it does not land
    /// on positions this editor recognises.
    func displayTextRange(forSourceRange range: NSRange) -> UITextRange? {
        textRange(from: attributedText.composerDisplayRange(forSourceRange: range))
    }

    // MARK: - Chips

    /// Redraws the document when the chips the draft calls for, or the way they
    /// have to be drawn, no longer match what is on screen. Ordinary typing
    /// changes neither, so it never rebuilds — which is what keeps predictive
    /// text and the undo stack alive.
    func refreshChipsIfNeeded() {
        guard markedTextRange == nil else { return }

        let source = sourceText
        let tokens = ComposerChipTokenizer.tokens(
            in: source,
            catalog: chipCatalog,
            preservingTrailing: renderedTokens
        )
        guard tokens != renderedTokens || currentStyle != renderedStyle else { return }

        render(source: source, tokens: tokens, sourceSelection: sourceSelection)
    }

    /// Replaces the whole draft, chips and all. The fallback for an edit the
    /// input system could not apply in place, and for a deliberate clear.
    func replaceDocument(with source: String) {
        let tokens = ComposerChipTokenizer.tokens(
            in: source,
            catalog: chipCatalog,
            preservingTrailing: renderedTokens
        )
        render(
            source: source,
            tokens: tokens,
            sourceSelection: NSRange(location: (source as NSString).length, length: 0)
        )
    }

    /// Restores the plain typing attributes a chip attachment would otherwise
    /// leave behind. Never while an IME composition is marked: touching typing
    /// attributes mid-composition breaks it.
    func restoreTypingAttributes() {
        guard markedTextRange == nil else { return }

        let attributes = baseAttributes
        guard (typingAttributes[.attachment] != nil)
            || (typingAttributes[.font] as? UIFont) != (attributes[.font] as? UIFont)
        else {
            return
        }
        typingAttributes = attributes
    }

    private var currentStyle: ChipRenderStyle {
        ChipRenderStyle(
            fontPointSize: (font ?? .preferredFont(forTextStyle: .body)).pointSize,
            userInterfaceStyle: traitCollection.userInterfaceStyle,
            isRightToLeft: isRightToLeft
        )
    }

    private var isRightToLeft: Bool {
        UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? .preferredFont(forTextStyle: .body),
            .foregroundColor: textColor ?? .label
        ]
    }

    private func render(source: String, tokens: [ComposerChipToken], sourceSelection: NSRange) {
        let font = self.font ?? .preferredFont(forTextStyle: .body)
        let textColor = self.textColor ?? .label
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let metrics = ComposerChipMetrics(editorFont: font)
        let text = source as NSString

        let document = NSMutableAttributedString()
        var cursor = 0
        for token in tokens {
            if token.range.location > cursor {
                document.append(
                    NSAttributedString(
                        string: text.substring(with: NSRange(location: cursor, length: token.range.location - cursor)),
                        attributes: attributes
                    )
                )
            }
            document.append(chipString(for: token, metrics: metrics, attributes: attributes))
            cursor = token.range.upperBound
        }
        if cursor < text.length {
            document.append(
                NSAttributedString(
                    string: text.substring(from: cursor),
                    attributes: attributes
                )
            )
        }

        attributedText = document
        // Assigning a non-uniform document clears these, and every later render
        // reads them back for its base attributes.
        self.font = font
        self.textColor = textColor
        renderedTokens = tokens
        renderedStyle = currentStyle
        self.sourceSelection = Self.clamp(sourceSelection, toLengthOf: source)
        restoreTypingAttributes()
        // The document was replaced wholesale, so an undo recorded against the
        // old one would put back text the chips no longer describe.
        undoManager?.removeAllActions()
    }

    private func chipString(
        for token: ComposerChipToken,
        metrics: ComposerChipMetrics,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let image = ComposerChipRenderer.image(
            label: token.label,
            metrics: metrics,
            traits: traitCollection,
            isRightToLeft: isRightToLeft
        )
        let font = (attributes[.font] as? UIFont) ?? .preferredFont(forTextStyle: .body)
        let attachment = ComposerChipAttachment(
            source: token.source,
            label: token.label,
            image: image,
            baselineOffset: floor((font.capHeight - image.size.height) / 2)
        )

        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    private static func clamp(_ range: NSRange, toLengthOf text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    // MARK: - Editing

    /// A chip deletes as one thing: backspacing next to it removes the whole
    /// reference rather than the last character of a name the user cannot see.
    override func deleteBackward() {
        guard selectedRange.length == 0, selectedRange.location > 0 else {
            super.deleteBackward()
            return
        }

        let previous = selectedRange.location - 1
        guard textStorage.attribute(.attachment, at: previous, effectiveRange: nil) is ComposerChipAttachment,
              let range = textRange(from: NSRange(location: previous, length: 1))
        else {
            super.deleteBackward()
            return
        }

        replace(range, withText: "")
    }

    /// Copy and cut hand over the draft text, so a chip pasted anywhere - back
    /// into this composer, or into any other app - is the reference itself.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = attributedText.composerSourceText(in: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0, let range = textRange(from: selectedRange) else {
            super.cut(sender)
            return
        }
        UIPasteboard.general.string = attributedText.composerSourceText(in: selectedRange)
        replace(range, withText: "")
    }

    func canPasteItemProviders(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        }
    }

    func pasteItemProviders(_ itemProviders: [NSItemProvider]) {
        let fileProviders = itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        if fileProviders.isEmpty {
            let imageProviders = itemProviders.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            }

            if imageProviders.isEmpty {
                paste(nil)
            } else {
                onPasteImageProviders(imageProviders)
            }
            return
        }

        onPasteFileProviders(fileProviders)
    }

    override var keyCommands: [UIKeyCommand]? {
        let sendCommand = UIKeyCommand(
            title: ComposerKeyboardCommand.title,
            action: #selector(sendMessageFromKeyboard),
            input: ComposerKeyboardCommand.input,
            modifierFlags: ComposerKeyboardCommand.modifierFlags
        )
        return (super.keyCommands ?? []) + [sendCommand]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(sendMessageFromKeyboard) {
            return isKeyboardSendEnabled
        }

        if action == #selector(paste(_:)), hasPasteboardContent {
            return true
        }

        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func sendMessageFromKeyboard() {
        guard isKeyboardSendEnabled else { return }
        onKeyboardSend()
    }

    override func paste(_ sender: Any?) {
        let fileProviders = pasteboardFileProviders

        if !fileProviders.isEmpty {
            onPasteFileProviders(fileProviders)
            return
        }

        let fileURLs = pasteboardFileURLs
        if !fileURLs.isEmpty {
            onPasteFileURLs(fileURLs)
            return
        }

        let imageProviders = pasteboardImageProviders
        if !imageProviders.isEmpty {
            onPasteImageProviders(imageProviders)
            return
        }

        let images = UIPasteboard.general.images ?? []
        if !images.isEmpty {
            onPasteImages(images)
            return
        }

        super.paste(sender)
    }

    private var hasPasteboardContent: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasStrings
            || !pasteboardFileProviders.isEmpty
            || !pasteboardFileURLs.isEmpty
            || !pasteboardImageProviders.isEmpty
            || !(pasteboard.images?.isEmpty ?? true)
    }

    private var pasteboardFileProviders: [NSItemProvider] {
        UIPasteboard.general.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    private var pasteboardFileURLs: [URL] {
        UIPasteboard.general.urls?.filter(\.isFileURL) ?? []
    }

    private var pasteboardImageProviders: [NSItemProvider] {
        UIPasteboard.general.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }
}
