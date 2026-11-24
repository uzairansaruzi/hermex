# 0022. Composer edits, IME, and undo

Area: chat-composer

## Apply parent-side draft changes as edits through UITextView.replace

`Coordinator.applyBoundText` pushes a parent-side draft change into the editor as an edit, not a wholesale assignment, so it lands on the editor's undo stack and the caret follows the insertion. Accepting a slash completion is the case that matters: undo puts back what was typed. `ComposerTextEdit` computes the smallest replacement between the editor's text and the composer's target and applies it with `UITextView.replace(_:withText:)`, which keeps the change on the undo stack and leaves the rest of the draft untouched; assigning `text` wholesale does neither.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`, `HermesMobile/Features/Chat/ComposerTextEditing.swift`

## Ignore an echoed draft while an IME composition is marked

Assigning text while an IME composition is marked commits it half-formed and splits characters such as 자 into ㅈㅏ (#312). `ComposerMarkedText.isDeliberateReplacement` treats a bound value equal to the draft with the marked range removed as the parent echoing the committed text back, and `applyBoundText` ignores it; a deliberate clear or replacement still applies. The two checks agree everywhere but on an empty value, where a send that cleared a whole-draft composition and a binding that predates the composition are the same strings, so the publish generation (`ComposerSelection.publishGeneration`, read as `isCurrent`) breaks the tie.

Lives in: `HermesMobile/Features/Chat/ComposerTextEditing.swift`, `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`

## Never split a surrogate pair when diffing composer text

A UTF-16 range that cuts a surrogate pair in half has no `UITextRange`, so the edit could not be applied. `ComposerTextEdit.between` backs the common-prefix or common-suffix boundary off onto the character it belongs to when it lands on a trailing surrogate.

Lives in: `HermesMobile/Features/Chat/ComposerTextEditing.swift`

## Commit the composition and resign immediately when dictation starts

A live IME composition or a pending autocorrection commits as the editor lets go, and dictation's baseline text has to include that edit. `ChatComposerView.toggleVoiceInput` resigns the text view now, through `ComposerChipTextView.resignForDictation` sent down the responder chain, not on the next update. `resignForDictation` calls `unmarkText()` first when `markedTextRange` is set, or dictation's first write would replace the document under the live composition and split its characters (#312).

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`, `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Clear the composer undo stack only once no undo group is open

Clearing the undo stack also drops open groups, and dictation keeps one open across its insertions; its later close then has no match and UIKit aborts the app (#1303). `ComposerChipTextView.discardUndoHistory` removes all actions only when `undoManager.groupingLevel` is 0, and otherwise waits for `NSUndoManagerDidCloseUndoGroup`. `undoGroupDidClose` defers the clear with `DispatchQueue.main.async`, because the group is still closing while the notification posts.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Refuse composer key commands during an IME composition

`ComposerChipTextView.acceptsKeyboardCommands` is false when the editor is locked or `markedTextRange` is set, so an unfinished composition keeps Return and Esc for itself and ⌘↩ never submits half-composed text. It is checked again when a key fires, since UIKit can dispatch a command it listed earlier. With Send with Return on, the plain Return command is left out entirely during composition so Return confirms the candidate. The on-screen keyboard's Return arrives as `insertText("\n")`, so the editor's `insertText` override sends instead when no composition is open, and `newlineFromKeyboard` calls `super.insertText` so Shift-Return and Option-Return still type a newline.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`
