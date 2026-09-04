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
    /// The skills whose references the editor draws as chips. Empty until the
    /// server's skill list has loaded, which leaves the draft as plain text.
    let chipSkills: [SkillSlashSuggestion]
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
                chipSkills: chipSkills,
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
    let chipSkills: [SkillSlashSuggestion]
    let onKeyboardSend: () -> Void
    let onHeightChange: (CGFloat) -> Void
    let onPasteFileProviders: ([NSItemProvider]) -> Void
    let onPasteFileURLs: ([URL]) -> Void
    let onPasteImageProviders: ([NSItemProvider]) -> Void
    let onPasteImages: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, isFocused: $isFocused, onHeightChange: onHeightChange)
    }

    func makeUIView(context: Context) -> ComposerChipTextView {
        let textView = ComposerChipTextView()
        textView.delegate = context.coordinator
        textView.textDropDelegate = context.coordinator
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

    func updateUIView(_ textView: ComposerChipTextView, context: Context) {
        context.coordinator.onHeightChange = onHeightChange
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
        textView.chipSkills = chipSkills
        context.coordinator.onDropFileProviders = onPasteFileProviders
        context.coordinator.onDropImageProviders = onPasteImageProviders
        context.coordinator.applyBoundText(text, generation: selection.publishGeneration, to: textView)
        context.coordinator.syncSelection(selection, to: textView, expecting: text)
        // Chips are redrawn last so they settle around the caret the composer
        // just asked for rather than the one the edit happened to leave behind.
        context.coordinator.applyingBoundValue { textView.refreshChipsIfNeeded() }
        context.coordinator.syncFocus(for: textView, shouldFocus: isFocused, isDisabled: isDisabled)
        context.coordinator.reportHeight(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextDropDelegate {
        @Binding var text: String
        @Binding var selection: ComposerSelection
        @Binding var isFocused: Bool
        var onHeightChange: (CGFloat) -> Void
        var onDropFileProviders: ([NSItemProvider]) -> Void = { _ in }
        var onDropImageProviders: ([NSItemProvider]) -> Void = { _ in }
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
                // An empty editor has no typing attributes to insert with, so
                // filling or emptying one stays a plain assignment; everything
                // in between goes through the input system for its undo stack.
                if textView.isEditable,
                   !current.isEmpty,
                   !text.isEmpty,
                   let edit = ComposerTextEdit.between(current: current, target: text),
                   let range = textView.displayTextRange(forSourceRange: edit.range) {
                    textView.replace(range, withText: edit.replacement)
                }

                // `replace` goes through the input system, which can normalize
                // what it inserts, and a range that straddles a chip cannot be
                // edited in place at all; rebuild rather than leave the editor
                // out of sync.
                if textView.sourceText != text {
                    textView.replaceDocument(with: text)
                }
            }
        }

        /// Keeps the editor's caret and the composer's idea of it in step.
        ///
        /// A caret the composer asked for is applied once, keyed on its
        /// revision, so a later update replaying the same value cannot yank the
        /// caret away from where the user has since put it. Every other pass
        /// leaves the editor's own caret alone and reports it back.
        func syncSelection(
            _ selection: ComposerSelection,
            to textView: ComposerChipTextView,
            expecting expectedText: String
        ) {
            guard textView.markedTextRange == nil, textView.sourceText == expectedText else { return }

            guard selection.revision == appliedSelectionRevision else {
                appliedSelectionRevision = selection.revision

                let clamped = Self.clamp(selection.range, toLengthOf: expectedText)
                // Assigning `selectedRange` resets predictive text, so never
                // assign a range the editor already holds.
                if textView.sourceSelection != clamped {
                    applyingBoundValue { textView.sourceSelection = clamped }
                }
                return
            }

            publishSelection(of: textView)
        }

        /// Reports the caret the editor settled on. Deferred, because a binding
        /// cannot be written during a view update.
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
            guard !isApplyingBoundValue, let textView = textView as? ComposerChipTextView else { return }

            // Text and caret travel together: publishing them in one update is
            // what keeps the two consistent when the composer maps the caret
            // back onto the draft to find the slash trigger. The generation
            // rides along so a later update can be dated against this one.
            publishGeneration &+= 1
            text = textView.sourceText
            selection.range = textView.sourceSelection
            selection.publishGeneration = publishGeneration
            reportHeight(for: textView)
        }

        /// Publishes pure caret moves — a tap, an arrow key, a selection drag.
        /// Edits are left to `textViewDidChange`, which carries both halves, and
        /// a live IME composition is left alone entirely.
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingBoundValue, textView.markedTextRange == nil else { return }
            guard let textView = textView as? ComposerChipTextView else { return }
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
            // Typing right after a chip would otherwise inherit the attachment's
            // attributes and swallow the new characters into the image.
            (textView as? ComposerChipTextView)?.restoreTypingAttributes()
            return true
        }

        // MARK: - Drops

        /// Claims a drop only when the composer can route every item through the
        /// attachment pipeline, so UIKit never inserts an attachment the draft
        /// cannot represent. Anything mixed or unrecognised is left to UIKit.
        func textDroppableView(
            _ textDroppableView: UIView & UITextDroppable,
            proposalForDrop drop: UITextDropRequest
        ) -> UITextDropProposal {
            guard claimedDrop(in: drop) != nil else { return drop.suggestedProposal }

            let proposal = UITextDropProposal(operation: .copy)
            proposal.dropAction = .insert
            proposal.dropPerformer = .delegate
            return proposal
        }

        func textDroppableView(
            _ textDroppableView: UIView & UITextDroppable,
            willPerformDrop drop: UITextDropRequest
        ) {
            switch claimedDrop(in: drop) {
            case let .files(providers):
                onDropFileProviders(providers)
            case let .images(providers):
                onDropImageProviders(providers)
            case nil:
                break
            }
        }

        private enum ClaimedDrop {
            case files([NSItemProvider])
            case images([NSItemProvider])
        }

        /// File URLs win over images, the same order `paste` uses: a dropped
        /// PNG file is a file the user picked, not a screenshot on the clipboard.
        private func claimedDrop(in drop: UITextDropRequest) -> ClaimedDrop? {
            let providers = drop.dropSession.items.map(\.itemProvider)
            guard !providers.isEmpty else { return nil }

            if providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
                return .files(providers)
            }
            if providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
                return .images(providers)
            }
            return nil
        }

        func reportHeight(for textView: UITextView) {
            guard textView.bounds.width > 0 else { return }

            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let height = ceil(textView.sizeThatFits(fittingSize).height)
            onHeightChange(min(160, max(22, height)))
        }
    }
}

enum ComposerKeyboardCommand {
    static let title = String(localized: "Send Message")
    static let input = "\r"
    static let modifierFlags: UIKeyModifierFlags = .command
}
