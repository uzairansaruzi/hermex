# 0021. Composer text editor

Area: chat-composer

## Do not treat dictation writes as user edits

Dictation resigns the keyboard (`ComposerChipTextView.resignForDictation`) and its words then reach the resigned editor at the caret. Those writes must never read as a user edit, or dictation would stop after its first word. A real edit by the user still counts as one.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`, `HermesMobileTests/ComposerChipTests.swift`

## Leave dictation's open undo group to its owner when redrawing chips

Dictation holds one undo group open across its insertions. A chip redraw replaces the document and discards undo history, but clearing also drops open groups: dictation's later close then has no match, closing a group that is gone throws, and the run loop's close aborts the app (#1303). `ComposerChipTextView.discardUndoHistory` clears the undo stack only when `undoManager.groupingLevel` is zero and otherwise leaves the group to its owner.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`, `HermesMobileTests/ComposerChipTests.swift`

## Keep a bound composer blur ahead of UIKit first-responder restoration

When the bound `isFocused` turns false, the blur must cancel focus even if the editor has not become first responder yet. UIKit's own `-[UITextView _restoreFirstResponder]` can land after the blur while a navigation pop is still running (#831), and it must not win. `ComposerChipTextView` asks `wantsDeferredFocus`, which `ChatComposerTextInputView` binds to the coordinator's `isFocused`, before taking focus.

Lives in: `HermesMobile/Features/Chat/ComposerChipTextView.swift`, `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`, `HermesMobileTests/ComposerChipTests.swift`

## Count the large-paste limit in UTF-16 units

`ComposerLargePaste.threshold` is Desktop's limit of 3,000, counted in UTF-16 units as JavaScript counts a string. 1,501 emoji are 3,002 units but 1,501 characters, so a character count would have left them inline. A paste past the limit is staged as a file and what was typed stays as it was.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`, `HermesMobileTests/ComposerChipTests.swift`

## Clear the Send hold mark when the choices card closes

Holding Send opens a choices card, and `ChatComposerSendHold` drops the hold's own release. A hold released off Send never reaches the Button, so `choicesClosed(isPressing:)` clears the mark when the card closes; otherwise the next VoiceOver or keyboard activation, which has no touch-down, would do nothing. A finger still down when the card closes (the run ended under it) keeps its release dropped.

Lives in: `HermesMobile/Features/Chat/ChatComposerSendGate.swift`, `HermesMobileTests/ChatComposerSendGateTests.swift`
