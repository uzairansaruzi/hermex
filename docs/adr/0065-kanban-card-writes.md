# 0065. Kanban Card writes

Area: kanban

## Reread the Board after Hermes Card writes

A Hermes host's write reports no `changed` and can move other Cards too: a promoted dependent, a gated one. A new prerequisite can send a Ready dependent back to To Do, and a removed one can promote it. So once a Card write settles, `KanbanFeatureState.reloadBoardAfterHermesWrite` reads the Board again to show where the host put each Card (#1044).

Lives in: `HermesMobile/Features/Kanban/KanbanFeatureState.swift`

## Send a Card's assignee to a Hermes host only when it changed

`changesAssignee` on the Card update request says whether `assignee` differs from the server's Card the save replaces: the one the editor opened, or the newer one a Review and Overwrite overwrites. A Hermes host reassigns on any `assignee` it gets, and refuses a running Card's with a 409, so it gets one only when it changed (#1044). webui always gets it.

Lives in: `HermesMobile/Models/Kanban.swift`

## Offer no To Do when creating a Card on a Hermes host

`KanbanBackend.createStatuses` says where a Card can go on each server (#1044). A Hermes host promotes a To Do Card whose prerequisites are all done to Ready on its next dispatcher tick, so To Do never sticks: a Card goes to Triage or Ready, and the host itself puts it in To Do while a prerequisite is open. Only a Bulk Action moves Cards into Scheduled or Review, as on webui (#1677). webui keeps Triage, To Do and Ready.

Lives in: `HermesMobile/Models/Kanban.swift`

## Require a result to complete a Card outside Review on a Hermes host

`KanbanBackend.completionNeedsResult(from:)` says whether completing a Card needs a note of what was done. A Hermes host completes a Card outside Review only with a result, and refuses it without one with a 400 (#1677).

Lives in: `HermesMobile/Models/Kanban.swift`

## Accept the landings a Hermes host makes for a Status write

`KanbanBackend.accepts(_:requested:from:)` decides whether the Status the server now reports shows that a write took effect. webui lands a Card where it was asked. A Hermes host can land a blocked Card in Triage (a repeat block), and a Card asked into Ready (an unblock or a reopened review) in To Do while a prerequisite is open, or back in Review; those count as success.

Lives in: `HermesMobile/Models/Kanban.swift`

## Undo Archive to Ready, never to Done, on a Hermes host

`KanbanBackend.restoreStatus(after:)` gives the Status Undo Archive returns a Card to, or nil when Undo can't. A Hermes host restores only to an ordinary destination, so everything but Triage goes to Ready, except Done: the host refuses Done from Archived, and Ready would hand finished work back to the dispatcher. Such a Card is restored from the Archived filter.

Lives in: `HermesMobile/Models/Kanban.swift`
