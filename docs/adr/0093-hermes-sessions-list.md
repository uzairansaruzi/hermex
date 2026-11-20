# 0093. Hermes sessions list and lifecycle

Area: networking-hermes

## Name each Profile once so the host watches its sessions

`HermesCall.sessionMostRecent` is the Sessions list's one Profile-scoped read after it connects (#1046): the host watches a Profile's store for `sessions.changed` only once some call names that Profile. `SessionListViewModel.watchHermesProfile` makes that read for each listed Profile, and the host keeps watching every one named. A Profile the host no longer has answers 4064, which for the picked Profile means it is gone; any other failure only costs live updates.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`, `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Poll live states while a row is busy

`HermesSessionListSource.statusPollInterval` is the gap between live-state re-reads while a row is busy. `sessions.changed` can miss a turn's end, since post-turn work writes nothing.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Delete sessions over RPC, never REST `DELETE`

`HermesCall.sessionDelete` deletes that exact stored session and its messages under `profile` (#1048). The host refuses with 4023 while a runtime in its process holds the session; REST `DELETE` has no such check, so it is never used.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Ignore `active_id` in the project delete reply

`deleteHermesProject` removes the project only: its sessions stay in the list, now in whichever lane claims their folders. The reply's `active_id` is Desktop's pick and can still name the deleted project, so it is never read.

Lives in: `HermesMobile/Features/SessionList/SessionListViewModel.swift`

## Treat any non-idle `session.active_list` status as running

`LeftoverLiveActivitySettlement.runningKeys` takes each listed `session_key` whose status isn't `idle` as running, including a status this build doesn't know. An unfamiliar state then never ends a run's leftover Live Activity.

Lives in: `HermesMobile/LiveActivities/AgentLiveActivityManager.swift`

## Skip `session.title` after a canonical `session.create`

In `BotCreator.ensureChat`, a canonical host's `session.create` already titled and hid the Bot Chat (#1603), and the host has no `session.title`. The step is marked done without a title write when `client.speaksCanonicalProtocol`.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`

## Persist a lazily created Bot Chat with a title write

On other hosts the row `session.create` makes is lazy. `BotCreator.ensureChat`'s `session.title` write persists it, so the roster and the phone's exact-title lookup find the chat before any prompt.

Lives in: `HermesMobile/Features/Bots/BotCreator.swift`
