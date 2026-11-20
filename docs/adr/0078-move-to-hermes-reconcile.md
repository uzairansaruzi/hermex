# 0078. Move to Hermes reconcile

Area: move-to-hermes

## Never write over a Hermes value or resend an unknown change

`MoveToHermesReconcile` (#1214) fills the titles, pins and folders the import (#1213) leaves out, and moves each chat's unsent draft from the webui to Hermes. The runner (#1216) drives it in three steps and journals between them. `plan` reads each chat's Hermes row once as the snapshot, every planned `Operation` records its field's value there as `from`, and the runner saves the plan before anything is sent. `apply` reads the row again before sending: a field still at `from` is written after `willDispatch` records it, one already at `to` counts as applied, and anything else changed in Hermes meanwhile and is left alone. The host keeps no per-field version, so a pin unpinned and pinned again in between reads as unchanged, and an edit between this read and the write still loses to the write. Titles and folders fill only a field Hermes has empty. A pin is filled only on a chat this Move copied, whose unpinned state is the import's own default; a chat Hermes already had keeps its pin and archive state, since its `false` may be the user's choice. Archive state needs no step because the import carries it. Unread state is the host's own and is never moved.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Settle an unknown-result write by reading, never by resending

`settle` handles writes that went out without a known result, such as a timeout, a rate limit or a lost reply, including one the journal still shows in flight after a quit. It reads the row once: `.applied` when Hermes holds `to`, otherwise `.uncertain` and reported, never sent again, even when the field is back at `from`. An operation whose row cannot be read is left out, to settle later.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Never pin a hidden Hermes row

`MoveToHermesReconcile.operations` returns no changes for a hidden row, and `apply` leaves a row that became hidden since planning as Hermes has it. Sending `pinned: true` would unhide it, and nothing lists it.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Move a draft only when its Hermes key is verifiable

`MoveToHermesReconcile.Plan.draftSession` is the chat's id only when the snapshot shows a visible row with no parent, which is how the Hermes Sessions list keys its draft. A row with a parent may continue a compression chain whose root keys the draft, or be a branch keyed by its own id, and the client cannot tell which, so nil leaves the draft on the webui and reports it.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`

## Count the title cap in Unicode scalars

`MoveToHermesReconcile.titleLimit` (100) is measured in Unicode scalars because the host counts title length with Python's `len`, which counts code points rather than grapheme clusters.

Lives in: `HermesMobile/Features/MoveToHermes/MoveToHermesReconcile.swift`
