# 0058. Transcript rows and placeholders

Area: chat-transcript

## Attach message menus with UIContextMenuInteraction, not .contextMenu

`chatMessageContextMenu` attaches the message action menu to a transcript bubble through UIKit's `UIContextMenuInteraction` instead of SwiftUI's `.contextMenu`. SwiftUI lifts a snapshot of the whole bubble before it can show the menu; on a multi-screen reply that snapshot is slow and taller than the screen, so the menu lands over the undimmed transcript and then jumps as UIKit makes room. The UIKit path lifts nothing: the transcript dims and the menu opens beside the press in one motion, whatever the reply's length (#208).

Lives in: `HermesMobile/Features/Chat/ChatMessageContextMenuView.swift`

## Install the message context-menu interaction on the scroll view

`ChatMessageContextMenuView` is a clear, touch-transparent view behind one bubble that only marks the bubble's frame and menu for the coordinator on the transcript's scroll view. The interaction cannot live on it: SwiftUI's text-selection long-press on the hosting view outranks recognizers on child platform views, so a menu attached there never fires. On the scroll view it wins, as it does in a collection view.

Lives in: `HermesMobile/Features/Chat/ChatMessageContextMenuView.swift`

## Treat transcript row freshness symmetrically

`ChatTranscriptRowFreshness` takes `timestamp` in epoch seconds, as `ChatMessage.timestamp` is, and treats missing or non-finite values as never fresh. `isFresh` is symmetric, `abs(now - timestamp) < window` (3 s), so a server clock running ahead cannot make reconciled history look freshly born; rows the app creates itself use the phone clock and always pass.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Draw the empty-chat prompt as a zero-layout overlay

`ChatTranscriptView` draws its start prompt as an overlay, which takes no layout. Above a keyboard on a short display (iPhone Duo), the prompt's height would stretch the screen and push the composer behind the keyboard.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Show the Forked-from row on an empty fork

A fork can be empty: upstream allows `keep_count: 0`, and an edit of the first message truncates to nothing. `ChatTranscriptView` shows the fork-origin row over the empty-transcript placeholder too, because an empty fork still links to its parent.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptView.swift`

## Show Forked from only for session_source fork

`ForkOrigin` drives the "Forked from" row at the top of a forked chat's transcript. Only chats made by Fork From Here or `/branch` count: upstream stamps those `session_source: "fork"` with a `parent_session_id`. `ForkOrigin.parentSessionID` matches the webui's own test, `session_source` trimmed and lowercased is "fork"; agent child sessions (subagents, cron, CLI `/new`) share `parent_session_id` but are not forks, so they get no row. A Hermes branch is marked in its own row instead, and its chat reads it from the host (`HermesBranchParent`, #1051).

Lives in: `HermesMobile/Features/Chat/ForkOrigin.swift`

## Check audio before Quick Look in attachment previews

`ChatAttachmentPreviewView` loads audio as raw bytes with no downsampling, so `AVAudioPlayer` gets the original encoded audio. The audio check runs before the Quick Look list, which would otherwise take m4a, mp3, wav and flac away from the inline player.

Lives in: `HermesMobile/Features/Chat/ChatAttachmentPreviewView.swift`

## Recover image attributes inside Markdown links

Foundation drops image attributes inside links when parsing Markdown. `InlineMathTextRequest` recovers them from the parser's source spans rather than parsing Markdown delimiters itself.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`

## Render linked inline images as linked alt text

SwiftUI drops links on interpolated image attachments in `Text`. `InlineMathTextRequest` renders an image inside a link as readable linked source or alt text, so the destination stays usable.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`

## Open sign-in and billing links in the system browser

`HermesConnectionTargetRow` opens a connector's sign-in link in the browser, not an in-app sheet: the user's saved sign-ins are there, and the host notices the new account without a callback. It is opened directly with `UIApplication.shared.open`, so the transcript's link router never takes it.

Lives in: `HermesMobile/Features/Chat/HermesRequestCards.swift`
