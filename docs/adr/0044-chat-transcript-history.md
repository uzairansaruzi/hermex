# 0044. Chat transcript history

Area: chat-transcript

## Count Fork From Here rows as the host's visible history

Fork From Here sends `session.branch` a `count` (#1051), and the host keeps the first `count` rows of its visible history: the user and assistant rows of its display projection whose content has text (`_visible_branch_history`, `tui_gateway/methods_session.py`). A transcript page is that projection, so `HermesBranchCount` counts the rows from the session's first one through the chosen one that pass the same test. Compacted rows and the hidden compaction summary count, and tool rows never do. On `scripts/local-hermes` at the pin, a branch counted this way ended at the chosen row after tool turns and on both sides of an in-place compaction.

Lives in: `HermesMobile/Features/Chat/HermesTranscriptHistory.swift`, `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`

## Refuse Fork From Here in a session that continues another

The host counts `session.branch`'s rows from the first row of every session this one continues, which this chat's pages never hold. So a fork in a session whose own row has a parent other than the one it branched from is refused (`HermesBranchParent.standsAlone`, `BranchContinuesEarlierSession`) before anything is read or sent. `/branch` still copies all of it, and a branch of a branch stands alone, so it forks.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`, `HermesMobileTests/HermesBranchDuplicateTests.swift`

## Page Hermes transcripts with `order=latest` and `include_compacted`

`HermesREST.sessionMessages` with an offset sends both `order=latest` and `limit`, because a limit alone pages from the oldest row. It also sends `include_compacted`, because without it the transcript would end at the last compaction (#1047).

Lives in: `HermesMobile/Networking/Hermes/HermesREST.swift`

## Keep the on-screen offset when a done reload widens the window

`.done` reloads the session with a window that can reach all the way back to the session start (offset 0), and a `.done` without `_messages_offset` used to resolve to offset 0 and renumber every on-screen row. The rows already on screen must keep their positional renderIDs (`transcript:<index>`), so the current offset wins and the widened head is trimmed to the overlap.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Recognize steer messages only by the exact out-of-band wrapper

`ChatMessage.steerMarkerOpen` and `steerMarkerClose` hold the exact out-of-band wrapper hermes-agent ≥ 2026.9.11 persists around each mid-turn steer. Recognition (`isSteerWrappedContent`, `strippedSteerText`) requires this exact text; a bare prefix match would misfire on user text that merely mentions it.

Lives in: `HermesMobile/Models/ChatMessage.swift`

## Unwrap a steer before stripping the mention note

A steer is stored inside the out-of-band marker, so `HermesTranscriptProjection` unwraps it with `ChatMessage.strippedSteerText` first. Only once unwrapped is the trailing mention note still a suffix, which `BotMentions.displayText` then hides as on any other user row.

Lives in: `HermesMobile/Features/Chat/HermesTranscriptHistory.swift`

## Take the last instruction marker in a single-skill row

In `HermesTranscriptProjection.skillInvocation`, a bundle's instruction comes before its skills. A single skill's instruction follows the skill's body, which may quote the marker, so the cut takes the last occurrence as the user's instruction.

Lives in: `HermesMobile/Features/Chat/HermesTranscriptHistory.swift`

## Stop the chat only when its last view leaves

A split view can build a `ChatView` that appears and leaves while another `ChatView` for the same model stays on screen. `ChatContinuity` stops the model's stream only when the last one leaves, in either order of a swap.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`, `HermesMobile/Features/Chat/ChatView.swift`, `HermesMobileTests/ChatTranscriptRenderBudgetTests.swift`
