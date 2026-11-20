# 0024. Composer runtime controls

Area: chat-composer

## Load profiles before profile-scoped composer config

`/api/models` and `/api/workspaces` are profile-scoped upstream, so `ChatComposerConfigLoader.loadConfiguration` loads profiles, and switches to the session's profile, first. After that, models, workspaces, and commands load concurrently; only reasoning waits, for the model it is scoped to. Errors keep the serial order's precedence (profiles, models, reasoning, workspaces), and commands load even when the rest fails.

Lives in: `HermesMobile/Features/Chat/ChatComposerConfigLoader.swift`

## Show a static Profile label on single-profile servers

Single-profile servers reject profile switches (#24). When `isStatic`, the composer Profile control is a plain label: no chevron, no menu, no button trait.

Lives in: `HermesMobile/Features/Chat/ChatComposerSelectorControls.swift`

## Allow turning YOLO off during a run

Stopping an approval bypass cannot wait for the work it is letting through. `ComposerApprovals.canTurnOffYolo` stays available while a response runs, and `ChatComposerControlGate.allowsModelSettings` lets the model label open Model settings mid-run for it, with every other row held.

Lives in: `HermesMobile/Features/Chat/ChatComposerSelectorControls.swift`, `HermesMobile/Features/Chat/ChatComposerSendGate.swift`

## Hold Thinking changes while another setting change is out

The host refuses a reasoning level while another kind of change is out. `ModelSettingsSheet` disables hit testing on the `ThinkingControl` while another setting change is in flight, and its action re-checks `!isUpdating || levelSender.isSending` because VoiceOver's adjustment reaches the action past `.allowsHitTesting`. The sheet's own level sends stay open, since `ThinkingLevelSender` keeps only the newest of them.

Lives in: `HermesMobile/Features/Chat/ChatComposerSelectorSheets.swift`

## Keep a client-derived model displayName equal to its id

When the selected model has no catalog match, `ChatComposerView` builds a `ModelCatalogOption` whose `displayName` is the raw id. `ModelDisplayNames` reads a `displayName` that differs from the id as a server-provided name and renders it verbatim, so a locally shortened title would stop prettifying "claude-haiku-4-5" to "Haiku 4.5". Only the webui transport's `name` or `label` is a server name; anything the client derives keeps `displayName == id`. The value is display only: `matchesSelection` and the group lookup match on id and provider, and a blank id keeps the placeholder title ("Model").

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Refresh effort gating inside the composer-update window

After a webui model switch, `ChatViewModel` awaits `refreshReasoningEffortGating()` while still inside the `isUpdatingComposerConfiguration` window. The effort menu stays disabled until the new model's gating lands, with no interactable flash of the previous model's options (#18).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Reset effort gating to unknown when the reasoning fetch fails

`ChatViewModel.refreshReasoningEffortGating()` re-queries webui `GET /api/reasoning` for the current model and provider (#18). A failure is silent to the user but resets gating to the unknown fallback (static effort list, control shown), because keeping the previous model's gating after a successful model switch could hide the control for a model that supports it or offer efforts the new model rejects. If the selected effort is no longer supported, it snaps to the server's coerced `reasoning_effort`.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Refuse /reasoning display words on Hermes

In a Hermes session `ChatViewModel.switchHermesReasoningFromSlashCommand` sends a `/reasoning` level through the effort chip's pick, for this chat only (#1016). Display words are refused before anything is sent, because on the host they rewrite the display settings every client shares.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
