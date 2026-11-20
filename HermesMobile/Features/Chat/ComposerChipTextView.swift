import UIKit
import UniformTypeIdentifiers

final class ComposerChipTextView: UITextView, UIGestureRecognizerDelegate {
    private var pendingTransitionFocus: UUID?

    var wantsDeferredFocus: () -> Bool = { true }

    override func becomeFirstResponder() -> Bool {
        guard let coordinator = owningViewController?.transitionCoordinator else {
            cancelDeferredFocus()
            return super.becomeFirstResponder()
        }
        if pendingTransitionFocus == nil {
            let request = UUID()
            pendingTransitionFocus = request
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard let self, pendingTransitionFocus == request else { return }
                pendingTransitionFocus = nil
                guard !context.isCancelled, window != nil, wantsDeferredFocus() else { return }
                _ = becomeFirstResponder()
            }
        }
        return false
    }

    func cancelDeferredFocus() {
        pendingTransitionFocus = nil
    }

    @objc func resignForDictation() {
        if markedTextRange != nil { unmarkText() }
        _ = resignFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        cancelDeferredFocus()
        return super.resignFirstResponder()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelDeferredFocus() }
    }

    var isInNavigationTransition: Bool {
        owningViewController?.navigationController?.transitionCoordinator != nil
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    var acceptsAttachments = true
    var keyboardCommands = ComposerKeyboardCommands()
    var returnSends = false
    var recallLastSentText: (() -> String?)?
    var onPasteFileProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteFileURLs: ([URL]) -> Void = { _ in }
    var onPasteImageProviders: ([NSItemProvider]) -> Void = { _ in }
    var onPasteImages: ([UIImage]) -> Void = { _ in }
    var onPasteLargeText: ((String) -> Void)?
    var pasteboard = UIPasteboard.general
    var onTapChip: (ComposerChipToken) -> Void = { _ in }
    var onTapQuote: (ComposerQuote) -> Void = { _ in }
    var onRemoveQuote: (UUID) -> Void = { _ in }

    var quotes: [ComposerQuote] = []

    var chipSkills: [SkillSlashSuggestion] = [] {
        didSet {
            guard chipSkills != oldValue else { return }
            rebuildChipCatalog()
        }
    }

    var chipFilePaths: Set<String> = [] {
        didSet {
            guard chipFilePaths != oldValue else { return }
            rebuildChipCatalog()
        }
    }

    var chipBots: [String: ComposerBotReference] = [:] {
        didSet {
            guard chipBots != oldValue else { return }
            rebuildChipCatalog()
        }
    }

    private var chipCatalog = ComposerChipCatalog.empty
    private(set) var renderedTokens: [ComposerChipToken] = []
    private(set) var renderedQuotes: [ComposerQuote] = []
    private var renderedStyle: ChipRenderStyle?
    private var isUndoClearPending = false
    private lazy var chipTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleChipTap))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    private struct ChipRenderStyle: Equatable {
        let fontName: String
        let fontPointSize: CGFloat
        let userInterfaceStyle: UIUserInterfaceStyle
        let appearance: AppAppearance
        let accessibilityContrast: UIAccessibilityContrast
        let displayScale: CGFloat
        let isRightToLeft: Bool
        let quoteMaximumWidth: CGFloat
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)

        addGestureRecognizer(chipTapRecognizer)

        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, AppAppearanceTrait.self, UITraitAccessibilityContrast.self, UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]
        ) { (view: ComposerChipTextView, _) in
            DispatchQueue.main.async { view.refreshChipsIfNeeded() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var sourceText: String {
        attributedText.composerSourceText
    }

    var sourceSelection: NSRange {
        get { attributedText.composerSourceRange(forDisplayRange: selectedRange) }
        set {
            let displayRange = attributedText.composerDisplayRange(forSourceRange: newValue)
            guard selectedRange != displayRange else { return }
            selectedRange = displayRange
        }
    }

    func applyPresentationStyle(isRightToLeft: Bool, isDisabled: Bool) {
        let semanticAttribute: UISemanticContentAttribute = isRightToLeft ? .forceRightToLeft : .unspecified
        if semanticContentAttribute != semanticAttribute {
            semanticContentAttribute = semanticAttribute
        }

        let alignment: NSTextAlignment = isRightToLeft ? .right : .natural
        if textAlignment != alignment {
            textAlignment = alignment
        }

        let color: UIColor = isDisabled ? .appTextSecondary : .appText
        if textColor != color {
            textColor = color
        }
    }

    func normalizeSelectionAroundQuoteMetadata() {
        let draftSelection = sourceSelection
        sourceSelection = draftSelection
    }

    func displayTextRange(forSourceRange range: NSRange) -> UITextRange? {
        textRange(from: attributedText.composerDisplayRange(forSourceRange: range))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === chipTapRecognizer else { return true }
        guard !renderedTokens.isEmpty || !renderedQuotes.isEmpty else { return false }
        return tappableChip(at: touch.location(in: self)) != nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === chipTapRecognizer || otherGestureRecognizer === chipTapRecognizer
    }

    private func rebuildChipCatalog() {
        chipCatalog = ComposerChipCatalog(skills: chipSkills, filePaths: chipFilePaths, bots: chipBots)
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

    func replaceDocument(with source: String, isComplete: Bool = false) {
        let tokens = ComposerChipTokenizer.tokens(
            in: source,
            catalog: chipCatalog,
            preservingTrailing: renderedTokens,
            isComplete: isComplete
        )
        render(
            source: source,
            tokens: tokens,
            quotes: quotes,
            sourceSelection: NSRange(location: (source as NSString).length, length: 0)
        )
    }

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
            fontName: (font ?? fallbackFont).fontName,
            fontPointSize: (font ?? fallbackFont).pointSize,
            userInterfaceStyle: traitCollection.userInterfaceStyle,
            appearance: traitCollection[AppAppearanceTrait.self],
            accessibilityContrast: traitCollection.accessibilityContrast,
            displayScale: traitCollection.displayScale,
            isRightToLeft: isRightToLeft,
            quoteMaximumWidth: max(120, min(260, bounds.width * 0.72))
        )
    }

    private var fallbackFont: UIFont {
        .app(forTextStyle: .body, compatibleWith: traitCollection)
    }

    private var isRightToLeft: Bool {
        UIView.userInterfaceLayoutDirection(for: semanticContentAttribute) == .rightToLeft
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? fallbackFont,
            .foregroundColor: textColor ?? .label
        ]
    }

    private func render(
        source: String,
        tokens: [ComposerChipToken],
        quotes: [ComposerQuote],
        sourceSelection: NSRange
    ) {
        let font = self.font ?? fallbackFont
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
        self.font = font
        self.textColor = textColor
        renderedTokens = tokens
        renderedQuotes = quotes
        renderedStyle = currentStyle
        self.sourceSelection = Self.clamp(sourceSelection, toLengthOf: source)
        restoreTypingAttributes()
        discardUndoHistory()
    }

    private func discardUndoHistory() {
        guard let undoManager else { return }
        guard undoManager.groupingLevel > 0 else {
            undoManager.removeAllActions()
            return
        }
        guard !isUndoClearPending else { return }
        isUndoClearPending = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoGroupDidClose),
            name: .NSUndoManagerDidCloseUndoGroup,
            object: undoManager
        )
    }

    @objc private func undoGroupDidClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .NSUndoManagerDidCloseUndoGroup, object: nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isUndoClearPending = false
            discardUndoHistory()
        }
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
        let font = (attributes[.font] as? UIFont) ?? fallbackFont
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
        let font = (attributes[.font] as? UIFont) ?? fallbackFont
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

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else {
            super.copy(sender)
            return
        }
        pasteboard.string = attributedText.composerSourceText(in: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0, let range = textRange(from: selectedRange) else {
            super.cut(sender)
            return
        }
        pasteboard.string = attributedText.composerSourceText(in: selectedRange)
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
        var commands = super.keyCommands ?? []
        if let send = keyboardCommands.send {
            commands.append(UIKeyCommand(
                title: send.title, action: #selector(sendFromKeyboard), input: "\r", modifierFlags: .command
            ))
        }
        if returnSends, acceptsKeyboardCommands {
            let send = UIKeyCommand(
                title: keyboardCommands.send?.title ?? String(localized: "Send Message"),
                action: #selector(returnFromKeyboard), input: "\r", modifierFlags: []
            )
            send.wantsPriorityOverSystemBehavior = true
            commands.append(send)
            let newlines = [
                UIKeyCommand(
                    title: String(localized: "New Line"), action: #selector(newlineFromKeyboard),
                    input: "\r", modifierFlags: .shift
                ),
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(newlineFromKeyboard)),
            ]
            for newline in newlines {
                newline.wantsPriorityOverSystemBehavior = true
                commands.append(newline)
            }
        }
        if let alternateSend = keyboardCommands.alternateSend {
            commands.append(UIKeyCommand(
                title: alternateSend.title, action: #selector(alternateSendFromKeyboard), input: "\r",
                modifierFlags: [.command, .shift]
            ))
        }
        if let escape = keyboardCommands.escape {
            let command = UIKeyCommand(
                title: escape.title, action: #selector(escapeFromKeyboard), input: UIKeyCommand.inputEscape,
                modifierFlags: []
            )
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        if onPasteLargeText != nil {
            commands.append(UIKeyCommand(
                title: ComposerLargePaste.bypassTitle, action: #selector(pasteAsText), input: "v",
                modifierFlags: [.command, .shift]
            ))
        }
        guard recallLastSentText != nil else { return commands }
        let recallCommand = UIKeyCommand(
            title: ComposerRecall.commandTitle,
            action: #selector(recallLastSentTextFromKeyboard),
            input: UIKeyCommand.inputUpArrow,
            modifierFlags: []
        )
        recallCommand.wantsPriorityOverSystemBehavior = true
        return commands + [recallCommand]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(sendFromKeyboard) {
            return acceptsKeyboardCommands && keyboardCommands.send != nil
        }

        if action == #selector(returnFromKeyboard) || action == #selector(newlineFromKeyboard) {
            return acceptsKeyboardCommands && returnSends
        }

        if action == #selector(alternateSendFromKeyboard) {
            return acceptsKeyboardCommands && keyboardCommands.alternateSend != nil
        }

        if action == #selector(escapeFromKeyboard) {
            return acceptsKeyboardCommands && keyboardCommands.escape != nil
        }

        if action == #selector(recallLastSentTextFromKeyboard) {
            return recallableText != nil
        }

        if action == #selector(pasteAsText) {
            return canPasteAsText
        }

        if action == #selector(paste(_:)), !acceptsAttachments {
            return isEditable && pasteboard.hasStrings
        }

        if action == #selector(paste(_:)), hasPasteboardContent {
            return true
        }

        return super.canPerformAction(action, withSender: sender)
    }

    private var acceptsKeyboardCommands: Bool {
        isEditable && markedTextRange == nil
    }

    @objc private func sendFromKeyboard() {
        guard acceptsKeyboardCommands else { return }
        keyboardCommands.send?.perform()
    }

    @objc private func returnFromKeyboard() {
        guard acceptsKeyboardCommands, returnSends else { return }
        keyboardCommands.send?.perform()
    }

    @objc private func newlineFromKeyboard() {
        guard acceptsKeyboardCommands, returnSends else { return }
        insertText("\n")
    }

    @objc private func alternateSendFromKeyboard() {
        guard acceptsKeyboardCommands else { return }
        keyboardCommands.alternateSend?.perform()
    }

    @objc private func escapeFromKeyboard() {
        guard acceptsKeyboardCommands else { return }
        keyboardCommands.escape?.perform()
    }

    private var recallableText: String? {
        guard acceptsKeyboardCommands, quotes.isEmpty, textStorage.length == 0,
              let text = recallLastSentText?(), !text.isEmpty
        else {
            return nil
        }
        return text
    }

    @objc private func recallLastSentTextFromKeyboard() {
        guard let text = recallableText else { return }

        replaceDocument(with: text, isComplete: true)
        delegate?.textViewDidChange?(self)

        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { textView in
            let draft = NSRange(location: 0, length: (textView.sourceText as NSString).length)
            guard let range = textView.displayTextRange(forSourceRange: draft) else { return }
            textView.replace(range, withText: "")
        }
        undoManager.endUndoGrouping()
    }

    override func paste(_ sender: Any?) {
        guard acceptsAttachments else {
            guard isEditable, let text = pasteboard.string else { return }
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

        let images = pasteboard.images ?? []
        if !images.isEmpty {
            onPasteImages(images)
            return
        }

        if let onPasteLargeText, isEditable, markedTextRange == nil,
           let text = pasteboard.string, ComposerLargePaste.converts(text) {
            onPasteLargeText(text)
            return
        }

        super.paste(sender)
    }

    var canPasteAsText: Bool {
        onPasteLargeText != nil && acceptsKeyboardCommands && pasteboard.hasStrings
    }

    @objc func pasteAsText() {
        guard canPasteAsText, let text = pasteboard.string else { return }
        insertText(text)
    }

    private var hasPasteboardContent: Bool {
        return pasteboard.hasStrings
            || !pasteboardFileProviders.isEmpty
            || !pasteboardFileURLs.isEmpty
            || !pasteboardImageProviders.isEmpty
            || !(pasteboard.images?.isEmpty ?? true)
    }

    private var pasteboardFileProviders: [NSItemProvider] {
        pasteboard.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
    }

    private var pasteboardFileURLs: [URL] {
        pasteboard.urls?.filter(\.isFileURL) ?? []
    }

    private var pasteboardImageProviders: [NSItemProvider] {
        pasteboard.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
    }
}
