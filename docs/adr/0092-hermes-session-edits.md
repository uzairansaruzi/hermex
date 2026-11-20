# 0092. Hermes session edits and settings

Area: networking-hermes

## Resend a lost session edit identically

`HermesCall.SessionMutation` is one `session.mutate` on a canonical host (#1603): the edit, under the fences it was prepared at, sent once as `write` sends it. `HermesConversation` keeps `unansweredMutation`, the last edit whose answer never came, so the same edit tapped again re-sends this exact value, `requestID` included, and the host answers from its receipt instead of applying it twice. The host's answer, a receipt or a refusal, retires it and its fences are adopted. `mutate` throws `.stale` before any snapshot named a revision.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`, `HermesMobile/Networking/Hermes/HermesCall.swift`

## Treat a status-less model edit receipt as applied

In `BotChatControls.apply`, the receipt of an applied model edit carries no `status`, while `deferred` means the pick waits for the turn. So the picked model is announced (`announce`) only when `result["status"]` is null.

Lives in: `HermesMobile/Features/Bots/BotChatControls.swift`

## Scope `config.set` model writes with `--session`

`HermesCall.SessionSetting.model`'s `value` must end in `--session`, so the host never writes the Profile's default when a session's model changes.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Write personality to the Profile on purpose

`HermesCall.SessionSetting.personality` is the one write that reaches the Profile, deliberately (#1016): the host has no session-only personality, so it always writes the Profile's default and switches this session too. `none` clears it. It is sent without a scope, which the host ignores here.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`
