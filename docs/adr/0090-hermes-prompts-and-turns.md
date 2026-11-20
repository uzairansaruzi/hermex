# 0090. Hermes prompts and turns

Area: networking-hermes

## Run Hermex sessions as the `gui` source

`HermesCall.source` is the surface every session Hermex creates or resumes runs as (#1278). The host picks the agent's note about the screen it is talking to by this name, and without one assumes its terminal UI, whose note tells the agent it cannot send files. It is `gui` for two reasons (#1335): the host has no note of its own for `gui`, so `HermesREST.platformNote`, which Hermex keeps in each Profile's config, is the only one the agent gets; and a gateway beside the dashboard takes an edit to a session it hasn't loaded only from a local source, which `hermex` was not. Desktop's in-process chats run as `desktop` and never read this note, but one a gateway runs in a managed worker (safe mode, or a custom provider) does; no other name the gateway accepts lacks a note of its own, and on the canonical protocol `gui` means Desktop.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Always submit prompts as `queued`

`HermesCall.promptSubmit` always sends `queued`: even an idle Send can race Desktop, so a fresh send never inherits a host setting that converts it into a redirect or steer. `fence` goes only to a canonical host (#1602), which also gets a `submission_id` minted for this one send. `images` go only to a canonical host too (#1644), as the prompt's own `attachments`, so the host stores them with it and every client shows them; a dashboard listener has no such field, and its prompt names its images in the text (`BotAttachmentUpload.imageReference`). `titlePreview` is the start of a pasted-text attachment, for the session titler only (#1701); it goes out bounded, and only to a host that takes it.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Send prompt attachments with exactly `path` and `mime`

In `HermesCall.params` for `promptSubmit`, each image in `attachments` carries exactly `path` and `mime`. The host refuses any other key with 4001.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Rewind in one call, never `queued`, and confirm deep cuts only when asked

`HermesCall.promptRewind` cuts the transcript at one durable prompt row and starts the turn again with `text`, in one call under the host's history lock. It is never `queued`: the host refuses a cut while busy (4009) instead of queueing or steering it. A Hermes chat's retry of a failed turn (#878), Edit, Regenerate and `/retry` (#1049) use it. `deep` sends `confirm_deep_truncate`, which a host that guards deep cuts asks for (4033) before one that drops later prompts (#1300); older hosts refuse the unknown key (4000), so it goes only to a host that asked (`HermesChatTurnCoordinator.rewind`).

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Always send `confirm_empty_truncate` on rewind

`HermesCall.promptRewind`'s params always carry `confirm_truncate` and `confirm_empty_truncate`, as Desktop sends whenever it names a row. Cutting at the first prompt legitimately empties the transcript.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Delete the btw draft session afterwards

`HermesCall.sessionDraft` makes a hidden draft for one `promptBtw`, on the Profile's model. No prompt ever runs in it, but the host still writes an empty row for it, so the caller closes and deletes it afterwards.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Answer a canonical host's request with a response frame, not the proxy

On a legacy host `HermesConversation.answer` uses the `request.answer` proxy, which gives a definitive ok/expired receipt for live and restored requests alike, unlike a bare JSON-RPC response frame. A canonical host (`wire.speaksCanonicalProtocol`) takes only the response frame (`wire.respond(toRequest:)`), whose write is the answer: its proxy reports "expired" for a request that still waits.

Lives in: `HermesMobile/Features/Hermes/HermesConversation.swift`

## Echo a room attempt's `memberID` as the host named it

`HermesCall.RoomAttempt` is the member and execution generation a canonical host fences one room task by (#1605). `memberID` is echoed back exactly as the host named it, which isn't always one member id: a stalled preparation's Retry names every member it couldn't wake (`"chief, coder"`).

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`
