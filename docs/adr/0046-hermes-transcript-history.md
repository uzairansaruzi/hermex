# 0046. Hermes transcript history and rewind

Area: chat-transcript

## Join transcript pages by position, not id

`HermesTranscriptHistory` holds a Hermes session's settled history as its REST transcript pages bring it (#1047): display rows in the host's order, newest rows first, older pages put in front. A row's `id` is the host's `messages.id` and names the row on every page, but ids do not follow display order (a compaction re-inserts the session's first rows under new ids), so pages join by position and repeat rows drop by id. `offset` counts display rows back from the newest, so rows the host saved since the newest rows were taken shift every older page: the chat takes the newest rows again, or counts them while a turn runs, before it pages back. `HermesNewestCoverage`, the part of the transcript a newest read covered (#1054), is every row once the read reached the first, else its rows oldest first plus every row the host shows after them; it too is placed by position, never by an id range, and a row the offline cache holds there that the read lacks was cut on the host by a rewind or an undo.

Lives in: `HermesMobile/Features/Chat/HermesTranscriptHistory.swift`

## Restart history from the newest page after a compaction

`/compress` and `/compact` (#1050) send `session.compress` on the runtime once, with the Profile and any `focus`; a busy host refuses it (4009), and a rotated stored key in the reply's `info` is adopted first. Once the host removed rows, `HermesChatTurnCoordinator` starts the history again from the newest page, since the compaction archived or re-numbered every row held, and that page replaces the transcript, compaction card included; Load earlier reaches the rest. After a lost or unreadable answer, merging the newest page into the rows held could show turns twice, so `forgetHistoryUntilRebuild` resets the history and sets `needsRebuild`: the next attach, whether the recovery reattaches now or the chat already left, reads the newest page and rebuilds the transcript from it.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Re-read newest rows after a rebuilt running turn ends

`HermesChatTurnCoordinator` sets `rebuiltRunningTurn` when a rebuild lays out a running turn's saved rows with its cards anchored to its live reply (#1531). Until a turn's end re-reads the newest rows, each turn end does so even without a full receipt (`message.complete`'s `persisted_turn`), because a steered turn never gets one.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Resend a lost canonical undo unchanged

A canonical host has no `session.undo`, so `HermesChatTurnCoordinator.undo` rewinds the last saved prompt the history holds (#1603). An undo whose answer was lost (`engine.unansweredOperation`) is sent again as it was: the history read since may already lack its exchange, and a target derived from it would undo another.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Cancel the turn-end history refresh before re-reading after a rollback

`HermesChatTurnCoordinator.restoreCheckpoint` cancels `historyRefresh` before re-reading the newest rows after a whole-tree `/rollback` restore that removed history (#1728). A turn-end refresh still reading would bring back the rows the host just rewound.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Strip the host context footer before the mention note

The host appends its context footer after the trailing mention note in a prompt. `HermesChatTurnCoordinator.displayed(_:)` therefore strips the footer first (`MessageAttachment.hermesReferences`), then the note (`BotMentions.displayText`).

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Rewind only Hermes prompts the host can cut and resend whole

`ChatViewModel.isHermesRewindable` allows a cut and resend only at a prompt that has the host's `rowID`, that compaction has not archived (the host cuts only in its live history), and that has no attachments, which a text-only resend would drop.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Keep an unsent Hermes edit when the cut lands but the send fails

`ChatViewModel.rewindHermesTranscript` cuts a Hermes session's transcript before the saved prompt `rowID` and sends the text in its place, once. Once the host takes it, the prompt shows where the cut was, the rows and cards it replaced go, and the turn streams after it; the turn's end re-reads the newest rows. With `retrying` (Retry on a failed last turn), a prompt the chat showed that is still unsaved as the last one is cut as its row, and a 4018 hides Retry. It returns why it failed, with nothing cut, or nil; on a canonical host the cut can go through while the send doesn't (#1341, decision 5), so the rows go, the text waits in `unsentHermesEdit` for the composer, and the reason says so.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
