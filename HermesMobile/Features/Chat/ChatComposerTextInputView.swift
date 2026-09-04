import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerTextInputView: View {
    @Binding var text: String
    @Binding var selection: ComposerSelection
    @Binding var isFocused: Bool
    @Binding var inputHeight: CGFloat
    @Binding var measuredHeight: CGFloat

    let isDisabled: Bool
    /// Pill mode: a single truncated line stands in for the editor and a tap
    /// focuses it. The text view stays in the hierarchy (invisible) so focus and
    /// the draft survive the pill-to-card morph without recreating it.
    let isCollapsed: Bool
    let isKeyboardSendEnabled: Bool
    let verticalPadding: CGFloat
    let onKeyboardSend: () -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void

    private let placeholder = String(localized: "Ask anything... /commands")
    private let collapsedLineHeight: CGFloat = 22
    private let expandedMinimumHeight: CGFloat = 72

    var body: some View {
        ZStack(alignment: isCollapsed ? .leading : .topLeading) {
            ComposerTextView(
                text: $text,
                selection: $selection,
                isFocused: $isFocused,
                isDisabled: isDisabled,
                isKeyboardSendEnabled: isKeyboardSendEnabled,
                onKeyboardSend: onKeyboardSend,
                onHeightChange: updateMeasuredHeight,
                onPasteFileProviders: onPasteFileProviders,
                onPasteFileURLs: onPasteFileURLs,
                onPasteImageProviders: onPasteImageProviders,
                onPasteImages: onPasteImages
            )
            // The card editor is at least 72 pt of real text view, so a tap
            // anywhere in it lands on the editor rather than dead space.
            .frame(height: isCollapsed ? collapsedLineHeight : max(expandedMinimumHeight, inputHeight))
            .padding(.vertical, isCollapsed ? 0 : verticalPadding)
            .padding(.horizontal, 16)
            .opacity(isCollapsed ? 0 : 1)
            .allowsHitTesting(!isCollapsed)
            .accessibilityHidden(isCollapsed)

            if isCollapsed {
                Text(text.isEmpty ? placeholder : text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(text.isEmpty ? Color(.placeholderText) : Color(.label))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isDisabled { isFocused = true }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("Edit message"))
            } else if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color(.placeholderText))
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

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: ComposerSelection
    @Binding var isFocused: Bool
    let isDisabled: Bool
    let isKeyboardSendEnabled: Bool
    let onKeyboardSend: () -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, isFocused: $isFocused, onHeightChange: onHeightChange)
    }

    func makeUIView(context: Context) -> PastingTextView {
        let textView = PastingTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.isScrollEnabled = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContentType = .none
        textView.isKeyboardSendEnabled = isKeyboardSendEnabled
        textView.onKeyboardSend = onKeyboardSend
        textView.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.fileURL.identifier,
                UTType.image.identifier,
                UTType.text.identifier
            ]
        )
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        context.coordinator.reportHeight(for: textView)
        return textView
    }

    func updateUIView(_ textView: PastingTextView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.applyBoundText(text, generation: selection.publishGeneration, to: textView)
        // Mirror the chat RTL toggle onto the text view itself (#259): SwiftUI's
        // layoutDirection environment does not propagate into a wrapped UITextView,
        // so set the base direction directly so the cursor/empty-field rests on the
        // trailing edge. `.natural` keeps the LTR default untouched, and per-run
        // bidi still resolves mixed Arabic+Latin/URL content within the line.
        let isRTL = context.environment.layoutDirection == .rightToLeft
        textView.semanticContentAttribute = isRTL ? .forceRightToLeft : .unspecified
        textView.textAlignment = isRTL ? .right : .natural
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.textColor = isDisabled ? .secondaryLabel : .label
        textView.isKeyboardSendEnabled = isKeyboardSendEnabled
        textView.onKeyboardSend = onKeyboardSend
        textView.onPasteFileProviders = onPasteFileProviders
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onPasteImageProviders = onPasteImageProviders
        textView.onPasteImages = onPasteImages
        context.coordinator.syncSelection(selection, to: textView, expecting: text)
        context.coordinator.syncFocus(for: textView, shouldFocus: isFocused, isDisabled: isDisabled)
        context.coordinator.reportHeight(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selection: ComposerSelection
        @Binding var isFocused: Bool
        var onHeightChange: (CGFloat) -> Void
        private var pendingFocusTarget: Bool?
        /// Set while we push a bound value into the editor, so the delegate
        /// callbacks it provokes do not write the bindings back mid-update.
        private var isApplyingBoundValue = false
        private var appliedSelectionRevision = 0
        /// Publishes made to the bindings, matched against the generation the
        /// bound value carries to spot one the parent has not caught up with.
        private var publishGeneration = 0

        init(
            text: Binding<String>,
            selection: Binding<ComposerSelection>,
            isFocused: Binding<Bool>,
            onHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            _selection = selection
            _isFocused = isFocused
            self.onHeightChange = onHeightChange
        }

        /// Pushes a parent-side draft change into the editor as an *edit* rather
        /// than a wholesale assignment, so the change lands on the editor's undo
        /// stack and the caret follows the insertion. Accepting a slash
        /// completion is the case that matters: undo puts back what was typed.
        ///
        /// While an IME composition is marked, assigning text commits it
        /// half-formed and splits characters such as 자 into ㅈㅏ (#312). A
        /// binding that simply has not seen the marked text yet is not a real
        /// change, so it is ignored; a deliberate clear or replacement still
        /// applies. `generation` is the publish count the bound value was built
        /// from, which is what tells those two apart when the value is empty.
        func applyBoundText(_ text: String, generation: Int, to textView: UITextView) {
            guard textView.text != text else { return }

            if let marked = textView.markedTextRange {
                guard ComposerMarkedText.isDeliberateReplacement(
                    text,
                    editorText: textView.text,
                    marked: markedRange(of: textView, marked: marked),
                    isCurrent: generation >= publishGeneration
                ) else {
                    return
                }

                applyingBoundValue { textView.text = text }
                return
            }

            applyingBoundValue {
                // An empty editor has no typing attributes to insert with, so
                // filling or emptying one stays a plain assignment; everything
                // in between goes through the input system for its undo stack.
                if textView.isEditable,
                   !textView.text.isEmpty,
                   !text.isEmpty,
                   let edit = ComposerTextEdit.between(current: textView.text, target: text),
                   let range = textView.textRange(from: edit.range) {
                    textView.replace(range, withText: edit.replacement)
                }

                // `replace` goes through the input system, which can normalize
                // what it inserts; fall back rather than leave the editor out
                // of sync.
                if textView.text != text {
                    textView.text = text
                }
            }
        }

        /// Keeps the editor's caret and the composer's idea of it in step.
        ///
        /// A caret the composer asked for is applied once, keyed on its
        /// revision, so a later update replaying the same value cannot yank the
        /// caret away from where the user has since put it. Every other pass
        /// leaves the editor's own caret alone and reports it back.
        func syncSelection(_ selection: ComposerSelection, to textView: UITextView, expecting expectedText: String) {
            guard textView.markedTextRange == nil, textView.text == expectedText else { return }

            guard selection.revision == appliedSelectionRevision else {
                appliedSelectionRevision = selection.revision

                let clamped = Self.clamp(selection.range, toLengthOf: textView.text)
                // Assigning `selectedRange` resets predictive text, so never
                // assign a range the editor already holds.
                if textView.selectedRange != clamped {
                    applyingBoundValue { textView.selectedRange = clamped }
                }
                return
            }

            publishSelection(of: textView)
        }

        /// Reports the caret the editor settled on. Deferred, because a binding
        /// cannot be written during a view update.
        private func publishSelection(of textView: UITextView) {
            let range = textView.selectedRange
            guard selection.range != range else { return }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      textView.selectedRange == range,
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

        private func applyingBoundValue(_ body: () -> Void) {
            isApplyingBoundValue = true
            body()
            isApplyingBoundValue = false
        }

        func syncFocus(for textView: UITextView, shouldFocus: Bool, isDisabled: Bool) {
            if isDisabled, isFocused {
                Task { @MainActor [weak self] in
                    self?.isFocused = false
                }
            }

            let target = shouldFocus && !isDisabled
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
                } else if textView.isFirstResponder {
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
            if isFocused {
                isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingBoundValue else { return }

            // Text and caret travel together: publishing them in one update is
            // what keeps the two consistent when the composer maps the caret
            // back onto the draft to find the slash trigger. The generation
            // rides along so a later update can be dated against this one.
            publishGeneration &+= 1
            text = textView.text
            selection.range = textView.selectedRange
            selection.publishGeneration = publishGeneration
            reportHeight(for: textView)
        }

        /// Publishes pure caret moves — a tap, an arrow key, a selection drag.
        /// Edits are left to `textViewDidChange`, which carries both halves, and
        /// a live IME composition is left alone entirely.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingBoundValue, textView.markedTextRange == nil else { return }
            guard textView.text == text, selection.range != textView.selectedRange else { return }

            selection.range = textView.selectedRange
        }

        func reportHeight(for textView: UITextView) {
            guard textView.bounds.width > 0 else { return }

            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let height = ceil(textView.sizeThatFits(fittingSize).height)
            onHeightChange(min(160, max(22, height)))
        }
    }

    final class PastingTextView: UITextView {
        var isKeyboardSendEnabled = false
        var onKeyboardSend: () -> Void = {}
        var onPasteFileProviders: ([NSItemProvider]) -> Void = { _ in }
        var onPasteFileURLs: ([URL]) -> Void = { _ in }
        var onPasteImageProviders: ([NSItemProvider]) -> Void = { _ in }
        var onPasteImages: ([UIImage]) -> Void = { _ in }

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
}

enum ComposerKeyboardCommand {
    static let title = String(localized: "Send Message")
    static let input = "\r"
    static let modifierFlags: UIKeyModifierFlags = .command
}
