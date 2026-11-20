import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerTextInputHeight {
    static let expandedMinimum: CGFloat = 72

    static let shortViewportHeight: CGFloat = 360
    static let shortViewportMinimum: CGFloat = 48

    static func expanded(measured: CGFloat, verticalSizeClass: UserInterfaceSizeClass?, isViewportShort: Bool) -> CGFloat {
        if isViewportShort { return shortViewportMinimum }
        return verticalSizeClass == .compact ? expandedMinimum : max(expandedMinimum, measured)
    }
}

extension EnvironmentValues {
    @Entry var composerViewportIsShort = false
}

struct ComposerTextInputView: View {
    @Binding var text: String
    @Binding var selection: ComposerSelection
    @Binding var isFocused: Bool
    @Binding var inputHeight: CGFloat
    @Binding var measuredHeight: CGFloat

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.composerViewportIsShort) private var viewportIsShort
    @AppStorage(SessionChatPreferences.returnSendsKey) private var returnSends = false

    @State private var renderedChips: [ComposerChipToken] = []

    let isDisabled: Bool
    let isCollapsed: Bool
    let keyboardCommands: ComposerKeyboardCommands
    let verticalPadding: CGFloat
    let chipSkills: [SkillSlashSuggestion]
    let chipFilePaths: Set<String>
    var chipBots: [String: ComposerBotReference] = [:]
    let quotes: [ComposerQuote]
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onTapChip: (ComposerChipToken) -> Void
    let onTapQuote: (ComposerQuote) -> Void
    let onRemoveQuote: (UUID) -> Void
    var recallLastSentText: (() -> String?)? = nil
    var onPasteLargeText: ((String) -> Void)? = nil

    var placeholder = String(localized: "Ask anything...")
    var acceptsAttachments = true
    var collapsedHorizontalPadding: CGFloat = 16
    private let collapsedLineHeight: CGFloat = 22

    var body: some View {
        ZStack(alignment: isCollapsed ? .leading : .topLeading) {
            ComposerTextView(
                text: $text,
                selection: $selection,
                isFocused: $isFocused,
                isDisabled: isDisabled,
                keyboardCommands: keyboardCommands,
                returnSends: returnSends,
                chipSkills: chipSkills,
                chipFilePaths: chipFilePaths,
                chipBots: chipBots,
                quotes: quotes,
                renderedChips: $renderedChips,
                onTapChip: onTapChip,
                onTapQuote: onTapQuote,
                onRemoveQuote: onRemoveQuote,
                recallLastSentText: recallLastSentText,
                onHeightChange: updateMeasuredHeight,
                onPasteFileProviders: onPasteFileProviders,
                onPasteFileURLs: onPasteFileURLs,
                onPasteImageProviders: onPasteImageProviders,
                onPasteImages: onPasteImages,
                onPasteLargeText: onPasteLargeText,
                acceptsAttachments: acceptsAttachments,
                accessibilityLabel: placeholder
            )
            .frame(height: isCollapsed
                ? collapsedLineHeight
                : ComposerTextInputHeight.expanded(measured: inputHeight, verticalSizeClass: verticalSizeClass,
                                                   isViewportShort: viewportIsShort))
            .padding(.vertical, isCollapsed ? 0 : verticalPadding)
            .padding(.horizontal, 16)
            .opacity(isCollapsed ? 0 : 1)
            .allowsHitTesting(!isCollapsed)
            .accessibilityHidden(isCollapsed)

            if isCollapsed {
                ComposerCollapsedDraft(
                    draft: text,
                    chips: renderedChips,
                    placeholder: placeholder
                )
                    .padding(.horizontal, collapsedHorizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isDisabled { isFocused = true }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Edit message"))
            } else if text.isEmpty && quotes.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color(.appPlaceholder))
                    .padding(.horizontal, 16)
                    .padding(.vertical, verticalPadding)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: isCollapsed ? 44 : nil, alignment: isCollapsed ? .leading : .topLeading)
    }

    private func updateMeasuredHeight(_ newHeight: CGFloat) {
        guard inputHeight != newHeight || measuredHeight != newHeight else { return }

        DispatchQueue.main.async {
            guard inputHeight != newHeight || measuredHeight != newHeight else { return }
            inputHeight = newHeight
            measuredHeight = newHeight
        }
    }
}

private struct ComposerCollapsedDraft: View {
    let draft: String
    let chips: [ComposerChipToken]
    let placeholder: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        line
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(draft.isEmpty ? Color(.appPlaceholder) : Color(.appText))
            .accessibilityLabel(Text(spokenDraft))
    }

    private var tokens: [ComposerChipToken] {
        ComposerChipTextLine.validTokens(chips, in: draft)
    }

    private var line: Text {
        guard !draft.isEmpty else { return Text(placeholder) }
        return ComposerChipTextLine.text(draft, tokens: tokens, style: chipStyle)
    }

    private var spokenDraft: String {
        draft.isEmpty ? placeholder : ComposerChipTokenizer.spokenText(in: draft, tokens: tokens)
    }

    private var chipStyle: ComposerChipTextStyle {
        ComposerChipTextStyle(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast,
            layoutDirection: layoutDirection,
            dynamicTypeSize: dynamicTypeSize,
            displayScale: displayScale,
            appearance: appearance
        )
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: ComposerSelection
    @Binding var isFocused: Bool
    let isDisabled: Bool
    let keyboardCommands: ComposerKeyboardCommands
    let returnSends: Bool
    let chipSkills: [SkillSlashSuggestion]
    let chipFilePaths: Set<String>
    let chipBots: [String: ComposerBotReference]
    let quotes: [ComposerQuote]
    @Binding var renderedChips: [ComposerChipToken]
    let onTapChip: (ComposerChipToken) -> Void
    let onTapQuote: (ComposerQuote) -> Void
    let onRemoveQuote: (UUID) -> Void
    let recallLastSentText: (() -> String?)?
    let onHeightChange: (CGFloat) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void
    let onPasteLargeText: ((String) -> Void)?

    let acceptsAttachments: Bool
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            selection: $selection,
            isFocused: $isFocused,
            renderedChips: $renderedChips,
            onHeightChange: onHeightChange
        )
    }

    func makeUIView(context: Context) -> ComposerChipTextView {
        let textView = ComposerChipTextView()
        textView.delegate = context.coordinator
        textView.textDropDelegate = context.coordinator
        textView.wantsDeferredFocus = { [weak coordinator = context.coordinator] in coordinator?.isFocused == true }
        textView.backgroundColor = .clear
        textView.font = .app(forTextStyle: .body, at: context.environment.dynamicTypeSize)
        context.coordinator.fontFamily = AppFontSettings.shared.family
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContentType = .none
        textView.allowsEditingTextAttributes = false
        textView.keyboardCommands = keyboardCommands
        textView.returnSends = returnSends
        textView.recallLastSentText = recallLastSentText
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        textView.onPasteLargeText = onPasteLargeText
        textView.onTapChip = onTapChip
        textView.onTapQuote = onTapQuote
        textView.onRemoveQuote = onRemoveQuote
        context.coordinator.reportHeight(for: textView)
        return textView
    }

    func updateUIView(_ textView: ComposerChipTextView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        if context.coordinator.fontFamily != AppFontSettings.shared.family {
            context.coordinator.fontFamily = AppFontSettings.shared.family
            textView.font = .app(forTextStyle: .body, at: context.environment.dynamicTypeSize)
            textView.refreshChipsIfNeeded()
            context.coordinator.reportHeight(for: textView)
        }
        let isRTL = context.environment.layoutDirection == .rightToLeft
        textView.applyPresentationStyle(isRightToLeft: isRTL, isDisabled: isDisabled)
        textView.acceptsAttachments = acceptsAttachments
        textView.accessibilityLabel = accessibilityLabel
        let pasteTypes = acceptsAttachments
            ? [UTType.fileURL.identifier, UTType.image.identifier, UTType.text.identifier]
            : [UTType.plainText.identifier]
        if textView.pasteConfiguration?.acceptableTypeIdentifiers != pasteTypes {
            textView.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: pasteTypes)
        }
        context.coordinator.acceptsAttachments = acceptsAttachments
        context.coordinator.syncEditing(for: textView, isDisabled: isDisabled)
        textView.keyboardCommands = keyboardCommands
        textView.returnSends = returnSends
        textView.recallLastSentText = recallLastSentText
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        textView.onPasteLargeText = onPasteLargeText
        textView.onTapChip = onTapChip
        textView.onTapQuote = onTapQuote
        textView.onRemoveQuote = onRemoveQuote
        textView.quotes = quotes
        textView.chipSkills = chipSkills
        textView.chipFilePaths = chipFilePaths
        textView.chipBots = chipBots
        context.coordinator.onDropFileProviders = onPasteFileProviders
        context.coordinator.onDropImageProviders = onPasteImageProviders
        context.coordinator.applyBoundText(text, generation: selection.publishGeneration, to: textView)
        context.coordinator.syncSelection(selection, to: textView, expecting: text)
        context.coordinator.applyingBoundValue { textView.refreshChipsIfNeeded() }
        context.coordinator.publishRenderedChips(of: textView)
        context.coordinator.syncFocus(for: textView, shouldFocus: isFocused, isDisabled: isDisabled)
        context.coordinator.reportHeight(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextDropDelegate {
        @Binding var text: String
        @Binding var selection: ComposerSelection
        @Binding var isFocused: Bool
        @Binding var renderedChips: [ComposerChipToken]
        var onHeightChange: (CGFloat) -> Void
        var acceptsAttachments = true
        var fontFamily = AppFontFamily.sanFrancisco
        var onDropFileProviders: ([NSItemProvider]) -> Void = { _ in }
        var onDropImageProviders: ([NSItemProvider]) -> Void = { _ in }
        private var pendingFocusTarget: Bool?
        private var pendingEditingTarget: Bool?
        private var isApplyingBoundValue = false
        private var appliedSelectionRevision = 0
        private var publishGeneration = 0

        init(
            text: Binding<String>,
            selection: Binding<ComposerSelection>,
            isFocused: Binding<Bool>,
            renderedChips: Binding<[ComposerChipToken]>,
            onHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            _selection = selection
            _isFocused = isFocused
            _renderedChips = renderedChips
            self.onHeightChange = onHeightChange
        }

        func publishRenderedChips(of textView: ComposerChipTextView) {
            let chips = textView.renderedTokens
            guard renderedChips != chips else { return }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      textView.renderedTokens == chips,
                      self.renderedChips != chips
                else {
                    return
                }
                self.renderedChips = chips
            }
        }

        func applyBoundText(_ text: String, generation: Int, to textView: ComposerChipTextView) {
            let current = textView.sourceText
            guard current != text else { return }

            if let marked = textView.markedTextRange {
                guard ComposerMarkedText.isDeliberateReplacement(
                    text,
                    editorText: current,
                    marked: markedRange(of: textView, marked: marked),
                    isCurrent: generation >= publishGeneration
                ) else {
                    return
                }

                applyingBoundValue { textView.replaceDocument(with: text) }
                return
            }

            applyingBoundValue {
                if textView.isEditable,
                   !current.isEmpty,
                   !text.isEmpty,
                   let edit = ComposerTextEdit.between(current: current, target: text),
                   let range = textView.displayTextRange(forSourceRange: edit.range) {
                    textView.replace(range, withText: edit.replacement)
                }

                if textView.sourceText != text {
                    textView.replaceDocument(with: text)
                }
            }
        }

        func syncSelection(
            _ selection: ComposerSelection,
            to textView: ComposerChipTextView,
            expecting expectedText: String
        ) {
            guard textView.markedTextRange == nil, textView.sourceText == expectedText else { return }

            guard selection.revision == appliedSelectionRevision else {
                appliedSelectionRevision = selection.revision

                let clamped = Self.clamp(selection.range, toLengthOf: expectedText)
                if textView.sourceSelection != clamped {
                    applyingBoundValue { textView.sourceSelection = clamped }
                }
                textView.scrollRangeToVisible(textView.selectedRange)
                return
            }

            publishSelection(of: textView)
        }

        private func publishSelection(of textView: ComposerChipTextView) {
            let range = textView.sourceSelection
            guard selection.range != range else { return }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      textView.sourceSelection == range,
                      self.selection.range != range
                else {
                    return
                }
                self.selection.range = range
            }
        }

        static func clamp(_ selection: NSRange, toLengthOf text: String) -> NSRange {
            let length = (text as NSString).length
            let location = min(max(0, selection.location), length)
            return NSRange(location: location, length: min(max(0, selection.length), length - location))
        }

        private func markedRange(of textView: UITextView, marked: UITextRange) -> NSRange {
            NSRange(
                location: textView.offset(from: textView.beginningOfDocument, to: marked.start),
                length: textView.offset(from: marked.start, to: marked.end)
            )
        }

        func applyingBoundValue(_ body: () -> Void) {
            let wasApplying = isApplyingBoundValue
            isApplyingBoundValue = true
            body()
            isApplyingBoundValue = wasApplying
        }

        func syncEditing(for textView: UITextView, isDisabled: Bool) {
            let editable = !isDisabled
            guard textView.isEditable != editable || textView.isSelectable != editable else {
                pendingEditingTarget = nil
                return
            }
            guard pendingEditingTarget != editable else { return }
            pendingEditingTarget = editable
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.pendingEditingTarget == editable else { return }
                self.pendingEditingTarget = nil
                if !editable, textView.isFirstResponder { textView.resignFirstResponder() }
                textView.isEditable = editable
                textView.isSelectable = editable
            }
        }

        func syncFocus(for textView: ComposerChipTextView, shouldFocus: Bool, isDisabled: Bool) {
            if isDisabled, isFocused {
                Task { @MainActor [weak self] in
                    self?.isFocused = false
                }
            }

            let target = shouldFocus && !isDisabled
            if !target { textView.cancelDeferredFocus() }
            guard textView.isFirstResponder != target else {
                pendingFocusTarget = nil
                return
            }
            guard pendingFocusTarget != target else { return }

            pendingFocusTarget = target
            Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView else { return }

                if target, textView.window == nil {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }

                self.pendingFocusTarget = nil

                if target {
                    guard self.isFocused, textView.isEditable, textView.window != nil else { return }
                    textView.becomeFirstResponder()
                } else if !self.isFocused, textView.isFirstResponder {
                    textView.resignFirstResponder()
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !isFocused {
                isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if let editor = textView as? ComposerChipTextView, editor.isInNavigationTransition {
                return
            }
            if isFocused {
                isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingBoundValue, let textView = textView as? ComposerChipTextView else { return }

            publishGeneration &+= 1
            text = textView.sourceText
            selection.range = textView.sourceSelection
            selection.publishGeneration = publishGeneration
            reportHeight(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingBoundValue, textView.markedTextRange == nil else { return }
            guard let textView = textView as? ComposerChipTextView else { return }
            textView.normalizeSelectionAroundQuoteMetadata()
            textView.restoreTypingAttributes()

            let range = textView.sourceSelection
            guard textView.sourceText == text, selection.range != range else { return }

            selection.range = range
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            (textView as? ComposerChipTextView)?.restoreTypingAttributes()
            return true
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let editor = textView as? ComposerChipTextView, editor.canPasteAsText else { return nil }

            let pasteAsText = UIAction(title: ComposerLargePaste.bypassTitle) { [weak editor] _ in
                editor?.pasteAsText()
            }
            var actions = suggestedActions
            if let index = actions.firstIndex(where: { ($0 as? UIMenu)?.identifier == .standardEdit }),
               let standardEdit = actions[index] as? UIMenu {
                actions[index] = standardEdit.replacingChildren(standardEdit.children + [pasteAsText])
            } else {
                actions.append(pasteAsText)
            }
            return UIMenu(children: actions)
        }

        func textDroppableView(
            _ textDroppableView: UIView & UITextDroppable,
            proposalForDrop drop: UITextDropRequest
        ) -> UITextDropProposal {
            if !acceptsAttachments {
                let hasOnlyText = drop.dropSession.items.allSatisfy {
                    $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                }
                return UITextDropProposal(operation: hasOnlyText ? .copy : .cancel)
            }
            guard ComposerDropRoute(providers: drop.dropSession.items.map(\.itemProvider)) != nil else {
                return drop.suggestedProposal
            }

            let proposal = UITextDropProposal(operation: .copy)
            proposal.dropAction = .insert
            proposal.dropPerformer = .delegate
            return proposal
        }

        func textDroppableView(
            _ textDroppableView: UIView & UITextDroppable,
            willPerformDrop drop: UITextDropRequest
        ) {
            guard acceptsAttachments,
                  let route = ComposerDropRoute(providers: drop.dropSession.items.map(\.itemProvider)) else {
                return
            }

            if !route.files.isEmpty {
                onDropFileProviders(route.files)
            }
            if !route.images.isEmpty {
                onDropImageProviders(route.images)
            }
        }

        func reportHeight(for textView: UITextView) {
            guard textView.bounds.width > 0 else { return }

            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let height = ceil(textView.sizeThatFits(fittingSize).height)
            onHeightChange(min(160, max(22, height)))
        }
    }
}

struct ComposerDropRoute {
    let files: [NSItemProvider]
    let images: [NSItemProvider]

    init?(providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return nil }

        var files: [NSItemProvider] = []
        var images: [NSItemProvider] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                files.append(provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                images.append(provider)
            } else {
                return nil
            }
        }

        self.files = files
        self.images = images
    }
}

enum ComposerLargePaste {
    static let threshold = 3_000
    static let bypassTitle = String(localized: "Paste as Text")

    static func converts(_ text: String) -> Bool {
        !text.utf16.dropFirst(threshold).isEmpty
    }

    static func filename(avoiding taken: Set<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        var candidate = "pasted-text.txt"
        var index = 1
        while taken.contains(candidate) {
            index += 1
            candidate = "pasted-text-\(index).txt"
        }
        return candidate
    }

    static func isStagedPaste(_ attachment: PendingAttachment) -> Bool {
        attachment.path.isEmpty && attachment.draftFileName != nil && !attachment.isImage
            && attachment.name.wholeMatch(of: /pasted-text(-\d+)?\.txt/) != nil
    }
}

struct ComposerKeyboardCommands {
    struct Command {
        let title: String
        let perform: () -> Void
    }

    var send: Command?
    var alternateSend: Command?
    var escape: Command?
}
