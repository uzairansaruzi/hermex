# 0104. Chat composer rendering

Area: performance

## Keep the composer draft out of ChatView's body

`ChatView.draftMessage` is never read in `body` or wrapped in a get/set binding for the composer: either re-runs the whole chat screen on every keystroke. `ChatComposerView` takes the owner's plain `$state`, because SwiftUI re-runs the owner of a get/set binding on every keystroke; the owner hears about edits through `onDraftEdit`, which `ChatView` routes to `persistDraftEdit`. Work that needs the draft reads it outside `body`, such as the file-chip scan task, and draft edits trigger their own scan from the composer.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`, `HermesMobile/Features/Chat/ChatComposerView.swift`

## Scan draft file references in the composer, not its owner

`ChatComposerView` reports the draft each time its finished `@…` references change (and once on appear) through `onFileReferenceCandidatesChange`, so the owner can confirm which name workspace files. The scan runs in the composer because that view already re-runs per keystroke; the owner never has to read the draft in its own body.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Keep the transcript file-chip scan token O(1)

`ChatView.transcriptFileChipScanToken` changes whenever the transcript has new text that could name a workspace file, or whenever the answers already given have been thrown away: the transcript grew, was swapped for the server's copy (which can rewrite a message in the middle without changing the count or the last id), or the workspace moved. Leaving the offline cache also changes it, so a draft typed offline is confirmed on reconnect. Everything in it is O(1), because it runs on every transcript update, including each token of a live stream. The scan of the transcript itself is the view model's, and it skips candidates the server has already answered for.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Guard per-keystroke @Observable writes

`ChatViewModel.clearSteerFailure()` and `ChatViewModel.clearComposerErrors()` write only when a value is set, because draft edits call them on every keystroke and an `@Observable` write notifies even when the value is unchanged.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Cache baked composer chip images

`ComposerChipRenderer` caches baked chips, keyed by everything that changes one. The editor redraws only when its chips or its style move, but the collapsed composer draws from `body`, which runs again on every parent update, including each token of a live stream; baking there uncached would burn a render pass per frame for a picture that never changed. Its cache key retains image-valued keys and hashes every component, because NSArray's own hash only reflects its count, which would put every chip in the same bucket.

Lives in: `HermesMobile/Features/Chat/ComposerChipRendering.swift`

## Keep the dictation waveform the only reader of mic levels

`ComposerVoiceInputController` holds its `ComposerVoiceLevelMeter` apart from itself so only the waveform redraws for each level. `ComposerDictationWaveform` shows recent mic levels as bars, newest on the trailing edge, and is the only reader of `levels`, so each sample redraws these bars and nothing else. With Reduce Motion the bars stay flat and it reads nothing at all.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`, `HermesMobile/Features/Chat/ChatComposerVoiceControls.swift`

## Keep a staged paste's text out of SwiftUI state

`StagedPasteBuffer` owns the staged-paste sheet's text view, whose text stays there until Save. Only its flags reach SwiftUI, and only when they flip, so typing in a long paste redraws nothing and copies nothing.

Lives in: `HermesMobile/Features/Chat/ChatAttachmentPreviewView.swift`

## Cap editable staged pastes at 256 KB

Past `StagedPasteText.editableBytes` the staged-paste sheet shows only the start, read-only. It is the largest size whose sheet stayed responsive on a loaded iOS 27 simulator; at 512 KB, Done stopped responding.

Lives in: `HermesMobile/Features/Chat/ChatAttachmentPreviewView.swift`
