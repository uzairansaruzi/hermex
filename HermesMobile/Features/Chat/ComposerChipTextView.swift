import UIKit
import UniformTypeIdentifiers

/// The composer's editor: a text view that draws known skill references as
/// atomic chips while every value that leaves it stays the draft's own text.
final class ComposerChipTextView: UITextView, UIGestureRecognizerDelegate {
    var acceptsAttachments = true
    var isKeyboardSendEnabled = false
    var onKeyboardSend: () -> Void = {}
    var onPasteFileProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteFileURLs: ([URL]) -> Void = { _ in }
    var onPasteImageProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteImages: ([UIImage]) -> Void = { _ in }
    /// Reports a tap that landed on a chip's glyph. Every chip reports; what a
    /// tap means belongs to the composer.
    var onTapChip: (ComposerChipToken) -> Void = { _ in }
    var onTapQuote: (ComposerQuote) -> Void = { _ in }
    var onRemoveQuote: (UUID) -> Void = { _ in }

    /// Explicit quoted passages are zero-source chips placed before the typed
    /// draft. Their ids and full text live outside the editor document.
    var quotes: [ComposerQuote] = []

    /// The skills whose references are drawn as chips.
    var chipSkills: [SkillSlashSuggestion] = [] {
        didSet {
            guard chipSkills != oldValue else { return }
            rebuildChipCatalog()
        }
    }

    /// The workspace files this composer has inserted, whose `@path` references
    /// are drawn as chips.
    var chipFilePaths: Set<String> = [] {
        didSet {
            guard chipFilePaths != oldValue else { return }
            rebuildChipCatalog()
        }
    }

    private var chipCatalog = ComposerChipCatalog.empty
    /// The chips currently on screen. The collapsed pill reads this rather than
    /// re-deriving it, because `preservingTrailing` makes the set depend on what
    /// was drawn before — a trailing chip whose space was deleted stays a chip,
    /// and nothing but this editor knows that.
    private(set) var renderedTokens: [ComposerChipToken] = []
    private(set) var renderedQuotes: [ComposerQuote] = []
    private var renderedStyle: ChipRenderStyle?
    private lazy var chipTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleChipTap))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    /// What the chips were drawn against. A chip is a baked image, so a change
    /// of appearance or text size has to redraw it even when the draft has not
    /// moved at all.
    private struct ChipRenderStyle: Equatable {
        let fontPointSize: CGFloat
        let userInterfaceStyle: UIUserInterfaceStyle
        let accessibilityContrast: UIAccessibilityContrast
        let isRightToLeft: Bool
        let quoteMaximumWidth: CGFloat
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)

        addGestureRecognizer(chipTapRecognizer)

        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self]
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

    /// The typed portion of the draft: every skill or file chip contributes the
    /// reference it was made from, while quote chips contribute nothing. Quote
    /// metadata is combined with this text by the owning composer when it saves
    /// or sends; copy and slash-trigger matching use this source text directly.
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

    /// UIKit may place a caret on the zero-source quote prefix after a chip tap.
    /// Map it back through draft coordinates so typing always starts after the
    /// quote metadata.
    func normalizeSelectionAroundQuoteMetadata() {
        let draftSelection = sourceSelection
        sourceSelection = draftSelection
    }

    /// The on-screen range a draft range covers, or `nil` when it does not land
    /// on positions this editor recognises.
    func displayTextRange(forSourceRange range: NSRange) -> UITextRange? {
        textRange(from: attributedText.composerDisplayRange(forSourceRange: range))
    }

    // MARK: - Chips

    /// Keeps the chip recognizer out of UIKit's gesture arbitration unless the
    /// touch begins on a rendered chip. Ordinary text touches remain entirely
    /// owned by the text view's native editing recognizers.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === chipTapRecognizer else { return true }
        guard !renderedTokens.isEmpty || !renderedQuotes.isEmpty else { return false }
        return tappableChip(at: touch.location(in: self)) != nil
    }

    /// A chip tap reports its action while UIKit continues handling the same
    /// touch for caret placement and selection.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === chipTapRecognizer || otherGestureRecognizer === chipTapRecognizer
    }

    private func rebuildChipCatalog() {
        chipCatalog = ComposerChipCatalog(skills: chipSkills, filePaths: chipFilePaths)
    }

    @objc private func handleChipTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              let chip = tappableChip(at: recognizer.location(in: self))
        else {
            return
        }
        switch chip {
        case let .reference(token):
            onTapChip(token)
        case let .quote(quote):
            onTapQuote(quote)
        }
    }

    private enum TappableChip {
        case reference(ComposerChipToken)
        case quote(ComposerQuote)
    }

    /// The chip whose glyph covers `point`, or `nil`.
    ///
    /// `closestPosition` answers with a caret boundary, so the characters on
    /// both sides of it are candidates; the glyph's own rectangle is what
    /// decides, which is what keeps a tap in the space beside a chip from
    /// counting as a tap on it.
    private func tappableChip(at point: CGPoint) -> TappableChip? {
        guard let position = closestPosition(to: point) else { return nil }
        let caret = offset(from: beginningOfDocument, to: position)

        for index in [caret - 1, caret] where index >= 0 && index < textStorage.length {
            guard let attachment = textStorage.attribute(
                .attachment,
                at: index,
                effectiveRange: nil
            ) as? NSTextAttachment,
                let range = textRange(from: NSRange(location: index, length: 1)),
                firstRect(for: range).contains(point)
            else {
                continue
            }
            if let chip = attachment as? ComposerChipAttachment {
                return .reference(chip.token)
            }
            if let quote = attachment as? ComposerQuoteAttachment {
                return .quote(quote.quote)
            }
        }

        return nil
    }

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
        guard tokens != renderedTokens || quotes != renderedQuotes || currentStyle != renderedStyle else { return }

        render(source: source, tokens: tokens, quotes: quotes, sourceSelection: sourceSelection)
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
            quotes: quotes,
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
            accessibilityContrast: traitCollection.accessibilityContrast,
            isRightToLeft: isRightToLeft,
            quoteMaximumWidth: max(120, min(260, bounds.width * 0.72))
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

    private func render(
        source: String,
        tokens: [ComposerChipToken],
        quotes: [ComposerQuote],
        sourceSelection: NSRange
    ) {
        let font = self.font ?? .preferredFont(forTextStyle: .body)
        let textColor = self.textColor ?? .label
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let metrics = ComposerChipMetrics(editorFont: font)
        let text = source as NSString

        let document = NSMutableAttributedString()
        for quote in quotes {
            document.append(quoteString(for: quote, metrics: metrics, attributes: attributes))
            document.append(NSAttributedString(
                string: " ",
                attributes: attributes.merging([.composerQuoteSpacer: true]) { _, new in new }
            ))
        }
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
        renderedQuotes = quotes
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
            icon: token.icon,
            metrics: metrics,
            traits: traitCollection,
            isRightToLeft: isRightToLeft
        )
        let font = (attributes[.font] as? UIFont) ?? .preferredFont(forTextStyle: .body)
        let attachment = ComposerChipAttachment(
            token: token,
            image: image,
            baselineOffset: floor((font.capHeight - image.size.height) / 2)
        )

        let chip = NSMutableAttributedString(attachment: attachment)
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    private func quoteString(
        for quote: ComposerQuote,
        metrics: ComposerChipMetrics,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let image = ComposerChipRenderer.image(
            label: quote.preview,
            icon: .symbol("quote.opening"),
            metrics: metrics,
            traits: traitCollection,
            isRightToLeft: isRightToLeft,
            maximumWidth: currentStyle.quoteMaximumWidth,
            usesAccentIcon: true
        )
        let font = (attributes[.font] as? UIFont) ?? .preferredFont(forTextStyle: .body)
        let attachment = ComposerQuoteAttachment(
            quote: quote,
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
        if selectedRange.length == 0,
           sourceSelection.location == 0,
           let quote = renderedQuotes.last {
            onRemoveQuote(quote.id)
            return
        }

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
        if !acceptsAttachments {
            return itemProviders.contains { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        }
        return itemProviders.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        }
    }

    func pasteItemProviders(_ itemProviders: [NSItemProvider]) {
        guard acceptsAttachments else { paste(nil); return }
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

        if action == #selector(paste(_:)), !acceptsAttachments {
            return isEditable && UIPasteboard.general.hasStrings
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
        guard acceptsAttachments else {
            guard isEditable, let text = UIPasteboard.general.string else { return }
            insertText(text)
            return
        }
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
