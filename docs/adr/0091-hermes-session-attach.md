# 0091. Hermes session attach and recovery

Area: networking-hermes

## Recover a session by reading only, never resending writes

`HermesConversation` keeps one screen attached to one Hermes session on the connection's shared socket. An attach reads, in order: the session's identity (`session.list` for a Bot Chat, `session.create` once for a new session), an identity `session.resume` with `omit_messages`, `session.events.since` from the last `seq`, then one more `session.resume` for live state; the owner reads settled history itself. Frames that land meanwhile are held (#901) and handed over once the owner has the snapshot, and a drop reconnects on a backoff while the screen is active. Recovery only reads: a prompt, answer, stop or setting goes out through `write`, once, from a deliberate action, and is never resent.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Keep the stored key and the runtime id apart

Each session has two ids. The stored key names it and goes in drafts and caches; the runtime id keys session-scoped calls and `seq`, changes after a reap, and is never kept. A `session.resume` reply belongs to this attach when it names its runtime and stored key: a session that has not started answers in a reduced shape with `stored_session_id` in place of `session_key`, so `HermesConversation.attachedKey` and `isCurrent` take whichever key the host resolved, while a Bot Chat's reply must carry `session_key` and it must be the tip its lookup found. On a canonical socket (#1341) the two ids are one and the resume reply is a canonical snapshot that names the key only as `stored_session_id`, started or not. Each session there replays under its own snapshot's `replay_epoch`, which the replay carries, because the socket's epoch would answer `snapshot_required` with no events; the gateway shapes the calls and detaches the session when the screen leaves.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Retry `session.resume` 4007 and 4009 refusals for the reconnect window

`HermesConversation.resume` reads the session's live state, never its transcript. The host answers 4007 while it swaps in a replacement runtime and 4009 while a client-gone interrupt settles; both clear on their own, so they come back as `ResumeRefusal` and the conversation reconnects on its backoff for `resumeRefusalWindow` before showing advice. They are matched by code alone: a real "session not found" also says 4007, and only the host's wording, which can change, differs.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Reattach when the host reclaims this session's runtime

The host broadcasts `session.reclaimed` to every client when it tears down a runtime the client never closed (idle timeout, LRU eviction, an orphan reap), with both ids in the payload; a close this client asked for is never announced. When it names this conversation's runtime or stored key, `HermesConversation.reclaim` treats the rest of its frames as lost, so the owner rebuilds as after a gap and reattaches to the stored key now. The next write then finds a live runtime instead of failing with 4001.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Treat 4001 as a reaped runtime in either error shape

`HermesChatSideTasks.write` binds one write to the attached runtime, with `stillCurrent` adding the caller's checks at the socket write, and throws `NotSent` when it never went out. A 4001 means the host reaped the runtime whether it arrives plain (`BotFailure.rejected(4001)`) or, from `/goal`'s `command.dispatch`, as a setting refusal (`BotSettingFailure.rejected(4001, _)`); the chat reattaches either way (`isReaped`, `onNeedsReattach`). Dropping the setting-refusal case leaves `/goal` on a dead runtime.

Lives in: `HermesMobile/Features/Chat/HermesChatSideTasks.swift`

## Reattach on a `rollback.*` 4001 only when the runtime is gone

`HermesSlashCommands.isGoneRuntime` picks out the 4001 refusals that mean the host no longer holds the runtime: a dashboard's `session not found` (`tui_gateway/session_registry.py` `_sess_nowait`) and a Webapp's `not_found` or `runtime_retired` (`authorize`). Only those make the chat reattach. Every other 4001 on these calls, such as `session_busy` or `unsupported_terminal_backend`, is the host's answer about this runtime and surfaces as such.

Lives in: `HermesMobile/Features/Chat/HermesSlashCommands.swift`

## Keep the platform note before the session call

`HermesConversation.attach` settles `wire.keepPlatformNote(profile:)` before `identify` makes the session call, so the agent the host builds for the session is told what Hermex shows (#1278). It runs alongside `wire.connect()`, so the socket opening does not wait on it.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Never log session ids or Profile names

`HermesConversation`'s log name for a conversation is only its kind, "Bot Chat" or "Hermes session". It never carries a session id or a Profile name.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`
