# 0057. Transcript reload and reconcile

Area: chat-transcript

## Capture the pre-reload window before the cache-first paint

In `ChatViewModel.loadMessages`, the cache-first render (#289) captures the pre-reload window (`messages` and `messagesOffset`) before painting any cached transcript, so the network reconcile replaces it cleanly, with no merge and no duplication. Only then, on a cold open with a populated cache, does it render the cached messages, so the loading skeleton never shows.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Revert the cache-first placeholder only while it is untouched

`ChatViewModel.revertCacheFirstPlaceholder` undoes the cache-first paint only if nothing mutated the transcript since the prime. Otherwise, for example after an optimistic send during the load window, it would wipe in-flight local content while its send or stream is still running.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Bump transcriptRevision on every transcript replacement

`ChatViewModel.transcriptRevision` is bumped whenever the transcript is replaced rather than extended: a cache-first paint, the server's reconcile, a page of older messages. A reconcile can rewrite a message in the middle of the list without changing the count or the last id, so nothing cheaper than "the transcript was swapped" can be trusted to notice a reference arriving.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Keep the current offset when a reload returns a smaller window

Mid-session reloads (turn-end `.done`, the completion refresh, or a pull-to-refresh while reading) can come back with a smaller `_messages_offset` than the window on screen: the server widened the page, or `.done` omitted the offset and it resolved to 0. Adopting that offset renumbers every positional `transcript:<absoluteIndex>` renderID, SwiftUI remounts the whole list, and a reader who scrolled up is dumped at the top of the session. `ChatViewModel.trimmingReloadedMessages` checks whether the reloaded window still contains the first shown message at the absolute index both offsets imply; if so it drops the reloaded rows before that overlap and keeps the current offset, so rows on screen keep their renderIDs and the tail takes the server-authoritative content. It returns nil when the windows don't align, falling back to plain replacement.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Keep the post-retry reload capped at msg_limit

After a retry, `ChatViewModel` reloads with the raw `msg_limit` cap (`messagePageLimit`) and leaves `expandRenderable` at its default false. The post-retry reload is deliberately not treated as a cold load (a non-goal of #168), because the user already has the transcript in view.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Treat steer echoes as part of the active turn

Steer echoes ride along inside the active turn and never open a new one, so `ChatViewModel` bounds its turn searches with `TranscriptTurnClassifier.isTurnBoundary`, which skips them. When merging a reloaded transcript with the live stream, a trailing echo must not move the assistant search range past the streaming assistant, which would skip content reconciliation and append a duplicate assistant row. When finding the in-flight assistant response for the stream coordinator, a trailing echo must not hide it.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Match steer echoes only to persisted steer rows

When `ChatViewModel` dedupes an optimistic user row against a reloaded one, steer echoes only match persisted steer rows, and vice versa. The steer wrapper is stripped for content comparison, so without this gate an ordinary repeated prompt could swallow a persisted steer row, or a steer echo could swallow an ordinary user message with identical text.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Strip the steer wrapper before dedup comparison

The server persists an accepted steer wrapped in the out-of-band marker, while the local echo carries the bare text. `ChatViewModel`'s user-content comparison strips the wrapper (`ChatMessage.strippedSteerText(from:)`), so the persisted row is recognized as the echo's server copy instead of a duplicate.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Dedupe optimistic attachments by basename identityKey

`ChatViewModel.attachmentKeys(for:)` matches attachments on `MessageAttachment.identityKey`, the lowercased basename. The server returns attachment paths inconsistently on reload, so basename matching is the only reliable way to dedupe an optimistic bubble against its reloaded copy; `identityKey` holds the full rationale.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
