# 0020. Composer chips and suggestions

Area: chat-composer

## Draw the collapsed pill from the editor's rendered chips

`ComposerChipTokenizer`'s `preservingTrailing` makes the chip set depend on what was drawn before: a trailing chip whose following space was deleted stays a chip, and only the editor knows that. `ComposerChipTextView` exposes `renderedTokens`, the coordinator publishes them through `publishRenderedChips` into `ComposerTextInputView.renderedChips` (deferred, since a binding cannot be written during a view update), and `ComposerCollapsedDraft` draws that same set rather than re-tokenizing the draft.

Lives in: `HermesMobile/Features/Chat/ChatComposerTextInputView.swift`, `HermesMobile/Features/Chat/ComposerChipTextView.swift`

## Translate carets through chip attachments and drop foreign ones

A chip is one character on screen and its whole source string in the draft, so every caret the editor reports and every range the composer asks for is translated. The `NSAttributedString` extensions `composerSourceText`, `composerSourceOffset`, and `composerDisplayOffset` read the mapping off the attachments themselves, so the rendered document is the authority and a caret is never computed from a stale idea of where the chips are. An attachment Hermex did not create contributes nothing, not even its U+FFFC placeholder, because the draft is what is sent, saved, and copied: a stray glyph would travel to the server, come back in the transcript, and be rendered by whatever reads it next.

Lives in: `HermesMobile/Features/Chat/ComposerChipRendering.swift`

## Offer every @ run as a file candidate and let the server decide

`ComposerChipTokenizer.fileReferenceCandidates` uses the same scan as the tokenizer (an `@` that starts the text or follows whitespace, running to the next whitespace) and returns candidates in order without repeats. It applies no "looks like a filename" heuristic, because whether a candidate is a file is the server's answer, and guessing locally would make a real reference silently fail to draw. `isComplete` carries the tokenizer's meaning: without it a reference that ends the text is still being typed, so `@sr` on the way to `@src/x.swift` is not looked up.

Lives in: `HermesMobile/Features/Chat/ComposerChipToken.swift`

## Confirm @path chips against the server on a view-model-owned task

What the composer picked lives in `ChatViewModel`, which dies when the chat is left, so on re-entry or on another device only the server knows a `@word` is a file. `ChatViewModel.loadFileChipReferences` confirms the `@path` candidates in the draft and in the transcript's user messages by listing each candidate's parent folder once, through the cache the `@` panel fills (a Hermes chat asks `complete.path` instead); every candidate a listing contains becomes a chip in both composer and transcript. The pass runs on `fileChipReferenceLoad`, a task the view model owns like the skill loader, so a caller cancelled by an unrelated view update cannot take the listings down and a caller arriving mid-pass awaits it instead of starting a second one. It is held while the chat shows its offline cache, and the chat asks for a fresh pass on reconnect.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Treat the draft's trailing @reference as complete when confirming chips

`ChatViewModel.fileChipReferenceCandidates` calls `ComposerChipTokenizer.fileReferenceCandidates(in:isComplete: true)` even for the draft, so a trailing reference with no following space still counts. A chip whose trailing space was backspaced is still a reference, and by the time a pass runs the user has moved on to whatever changed the token.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Settle file-chip candidates only when a folder answers

`ChatViewModel.confirmFileChipReferences` marks candidates settled in `checkedFileChipCandidates` only when their parent folder's listing succeeded. A `listedFileReferences` call that throws is skipped with `continue` rather than recorded as "not a file", so the next pass retries those candidates. Settling answered candidates is what keeps a `@word` that is not a file from costing a request on every transcript update. Results are dropped once `fileChipScopeRevision` moves past the scope the pass started under.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Pick the outermost slash trigger on the caret's line

`ComposerSlashTrigger.detect` collects every `/` on the caret's line that could open a trigger and takes the outermost one that holds up. A path argument such as `/workspace /Users/me/app` belongs to the command in front of it, so the inner slash must never win.

Lives in: `HermesMobile/Features/Chat/ComposerSlashTrigger.swift`

## Share skill and personality loads on a view-model-owned task

The composer asks for skills from two `.task` modifiers, the chip warm-up for a restored draft and the autocomplete panel, and an unrelated view update can cancel either. `ChatViewModel.loadSkillSlashSuggestions()` and `loadPersonalitySuggestions()` run their request on tasks the view model owns (`skillSlashSuggestionsLoad`, `personalitySuggestionsLoad`) that every caller awaits, so a cancelled caller cannot take the fetch down and a caller arriving mid-flight gets the same result instead of racing past an "already loading" flag to an empty list. A failed load clears the handle so the next caller retries. Loads are held while the chat shows its offline cache; the composer and transcript ask again on reconnect.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
