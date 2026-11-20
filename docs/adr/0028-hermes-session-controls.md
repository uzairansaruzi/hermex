# 0028. Hermes chat session controls

Area: chat-composer

## Scope Hermes model, effort and Fast picks to the session

`HermesChatSettings` drives a Hermes session's model, effort, Fast and Profile chips in the main chat's composer (#1015, #1016, #1142) and its `/personality` command; `HermesChatTurnCoordinator` owns it and connects it on each attach. The model rides `BotChatControls` on the session's runtime: the catalog is `model.options` for the chat's Profile, and a pick goes out once as `config.set` with `--session`, so the next chat in the Profile still starts on its default. The host may ask to confirm an expensive model (`confirmation`) or apply the pick after the running response (`pendingModel`); a new chat's session exists from the moment it opens, so a pick there is sent at once. On a canonical host (#1604) the pick is the session's fenced `model` edit, whose confirmation resends the host's own token. Effort is one `config.set` reasoning for this chat, never a display word, and the host may send a lower level when the model's route can't take it, which `session.info` reports as `reasoning_effort_wire` (`sentEffort`). Fast is one `config.set fast` for this chat, shown only from the host's answer (#1142); the host may fall back to the Profile's default if the runtime goes away mid-dispatch, an accepted limitation (#508). A personality is Profile-wide, since the host has no session-only one, so a confirmed `/personality` change writes the Profile's default and switches this session too. The Profile chip lists `profiles.list`; a session's Profile never changes, so picking another starts a new chat in it (`ChatView`).

Lives in: `HermesMobile/Features/Chat/HermesChatSettings.swift`

## Send a canonical Fast toggle without a scope

On a canonical host, Fast is `config.set fast` without the `scope` the host refuses there. The host acknowledges it as recorded, and it changes this chat alone.

Lives in: `HermesMobile/Features/Chat/HermesChatSettings.swift`, `HermesMobileTests/HermesChatSettingsTests.swift`

## Record a ran model pick locally since unbuilt agents send no session.info

When the host runs this chat's pick, at once or once it lands after a response, `HermesChatSettings` brings the reported model up to the one the session now runs. A session whose agent is not built yet reports no `session.info` for the pick, so nothing else would update it.

Lives in: `HermesMobile/Features/Chat/HermesChatSettings.swift`

## Sanitize model values sent through the session model flag string

The host parses the model pick as a flag string, not with shell quoting. `HermesModelCatalog` rejects tokens that could change the pick's scope, and always sends `--session`, even when the host persists picks by default.

Lives in: `HermesMobile/Networking/Hermes/HermesModelCatalog.swift`

## Recheck the confirmed loop or heartbeat at the socket write

The host acts on the session's current loop or heartbeat, not the one the user confirmed. `HermesChatSideTasks.confirmAutomation` rechecks that `automations` still contains the confirmed control in the write's last-moment check and throws `BotFailure.stale` if it is gone, including when the write ends in `NotSent`.

Lives in: `HermesMobile/Features/Chat/HermesChatSideTasks.swift`

## Answer Hermes theme requests in-app without a card

A theme request for this runtime is answered by `HermesChatRequests` instead of joining `open`: `theme.apply` changes the app's appearance first, as Settings does. Each envelope id is answered once, with no card and nothing shown on failure; a refusal or a lost reply leaves the host to time the request out. A `.stale` answer forgets the id so the next attach that lists it answers it. A response frame goes stale only before it is sent, but a `request.answer` is also re-checked after its reply, so that answer may already have gone out; the host has then resolved the request, the second answer changes nothing there, and the same theme applies again.

Lives in: `HermesMobile/Features/Chat/HermesChatRequests.swift`

## Hold the landed Thinking thumb until the picked level arrives

When the finger lifts, `ThinkingControl` holds `position` where the thumb landed. The picked level reaches the ladder through the screen around the track one update after this state changes, and for that update the thumb would otherwise jump back toward the old level.

Lives in: `HermesMobile/Features/Chat/ThinkingControl.swift`

## Use a UIKit sideways pan for the Thinking slider

The Thinking slider uses a UIKit pan that begins only if the finger first moves sideways and otherwise fails at once, so the list or sheet around it scrolls. SwiftUI's `DragGesture` can't decline a touch like that: it holds the touch whichever way the finger goes, which stops a swipe that starts on a slider from scrolling.

Lives in: `HermesMobile/Features/Chat/ThinkingControl.swift`
