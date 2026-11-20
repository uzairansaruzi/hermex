# 0026. Composer text editor

Area: chat-composer

## Disable rich-text editing in the composer

The editor draws its own chip attachments and reads them back as draft text. `ComposerTextInputView` sets `allowsEditingTextAttributes = false`, because rich-text editing would let UIKit insert an attachment the editor cannot read, and that attachment would reach the server as an object-replacement character.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Set the composer text view's base writing direction directly

SwiftUI's `layoutDirection` environment does not propagate into a wrapped `UITextView`. `ComposerTextInputView` mirrors the chat RTL toggle onto the text view itself through `applyPresentationStyle(isRightToLeft:)` (#259), so the caret and the empty field rest on the trailing edge. `.natural` keeps the LTR default untouched, and per-run bidi still resolves mixed Arabic, Latin, and URL content within a line.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Never reassign the composer's current selection

Assigning `UITextView.selectedRange` resets predictive text. `Coordinator.syncSelection` assigns the source selection only when it differs from the range the editor already holds.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Defer editability changes past updateUIView

Disabling a focused `UITextView` can synchronously ask its SwiftUI hosting view for the next responder. `Coordinator.syncEditing` applies `isEditable` and `isSelectable` changes after `updateUIView` has returned; doing it inside the update makes the responder lookup re-enter the active view graph.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Reset typing attributes after composer chips

Typing right after a chip would inherit the `NSTextAttachment`'s attributes and swallow the new characters into the chip image. The composer's `shouldChangeTextIn` delegate calls `restoreTypingAttributes` before every edit.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Defer the chip refresh after a trait change

`adjustsFontForContentSizeCategory` updates `font` from the same trait change that `ComposerChipTextView`'s trait-change registration observes. The registration calls `refreshChipsIfNeeded` through `DispatchQueue.main.async`, so the chips are sized against the font that wins.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Assign presentation attributes only when they change

`ComposerChipTextView.applyPresentationStyle` applies the SwiftUI-owned direction and enabled appearance on every representable update, but compares `semanticContentAttribute`, alignment, and colour before assigning them and never rewrites text attributes. A redundant alignment or colour assignment invalidates `UITextView` layout and can reveal the caret after the user has manually scrolled elsewhere.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Rebuild the composer document only when chips or style change

`ComposerChipTextView.refreshChipsIfNeeded` redraws the attributed document only when the chips the draft calls for, or the `ChipRenderStyle` they are drawn with, no longer match what is on screen, and never while marked text exists. Ordinary typing changes neither, so it never rebuilds, which is what keeps predictive text and the undo stack alive.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Reassign font and textColor after replacing the document

Assigning a non-uniform `attributedText` clears `font` and `textColor`, and every later render reads them back as its base attributes. `ComposerChipTextView` sets both again right after it assigns a new document.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`
