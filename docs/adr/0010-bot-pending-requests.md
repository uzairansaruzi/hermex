# 0010. Bot pending requests

Area: bots

## Never answer unknown server requests from the phone

`BotServerRequest` is a server request received live or restored from `open_requests`. An unknown method keeps `pending` nil: the bot is still blocked, and the phone never answers it, not even with -32601, because a reply from here would pre-empt the Hermes Desktop window that can. `theme.apply` and `theme.pick` keep it nil too, since a Hermes chat answers them itself before they join its requests (`HermesThemeRequest`). The envelope id stays separate from an approval's underlying queue request id.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Drop approvals without a request id

`BotApprovalRequest` is nil when the payload carries no usable request id. Without one the phone cannot address `approval.respond` and must not guess FIFO order.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Never add approval choices the host did not offer

A present `choices` in `BotApprovalRequest` is the host speaking, and nothing may be added to what it offered. If a newer host renames the lot so none of it parses, or `choices` is present but not a list (null, a string, an object), Deny is the only thing safe to offer: rebuilding would invent an Always allow the host never sanctioned. Only an absent `choices` means an older host, and then the choices it would send are rebuilt from `smart_denied`, `allow_session` and `allow_permanent`.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Send clarify choice labels back verbatim

`BotQuestionRequest.Choice.wireLabel` goes back to the host verbatim. The host strips its own "(Recommended)" suffix, so presentation never leaks into the answer and the phone never has to reconstruct a label.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Encode multi-select clarify answers as a JSON string

`BotQuestionAnswer` sends multi-select answers as a JSON array serialized to a string, which the host parses. A bare array is not part of the contract.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Send batch clarify answers only when all are filled

`BotQuestionRequestBody.hasAnswer` requires every outstanding question, not just one, before Send enables. A partial send would lock the untouched questions as skipped, so Skip stays the deliberate way to decline all of it.

Lives in: `HermesMobile/Features/Bots/BotPendingRequestCard.swift`

## Never answer password-vault prompts from the phone

`BotCredentialRequest` covers a value only the person can supply: the Mac's administrator password, or a secret the bot asked for by name. Password-vault prompts (`vault.*`) are not read: they stay open requests with no card and are never answered from the phone (#1148). Answers carry `{value}` through `request.answer`, and an empty value skips without retaining a secret.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Key request card bodies by request id

`BotPendingRequestCard` keys the credential body by `credential.requestID`, so a new request gets a fresh, empty field: a password typed for a timed-out sudo prompt must never ride along into a secret. It keys the connection body by `operation.opID`, because typed setup values belong to one operation's rows.

Lives in: `HermesMobile/Features/Bots/BotPendingRequestCard.swift`

## Prefill connection env fields with catalog defaults

`BotConnectionOperation.EnvField` starts a non-secret field with the catalog's value, as Desktop does, because the host never fills a default in by itself.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Treat absent env field flags as required and secret

When `required` or `secret` is absent, `BotConnectionOperation.EnvField` takes the host's own defaults: required, and masked to be safe.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Never open MCP sign-in links on the phone

`BotConnectionOperation.Target.finishesOnTheMac` marks an MCP sign-in, which redirects to a listener on the host's own loopback. A phone browser dead-ends there, so the phone never gets the link.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`

## Offer only Deny for unparseable approval choices

`BotApprovalRequest` never invents a permission for a host that renamed its choices: when none of a present `choices` list parses, or the list is empty, Deny is the only thing offered. Only an absent `choices` key means an older host, whose choices are rebuilt from the gateway's flags. A present `choices` value that is not a list is malformed and also gets only Deny, even with `allow_permanent` set.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`, `HermesMobileTests/BotPendingRequestTests.swift`

## Name Tirith findings session-only under Always on Hermes

Hermes downgrades an Always approval to the session for a Tirith finding (`_persist_choice`), so on a Hermes server the approval scope line says Always covers only the shell pattern and keeps the finding to this chat. webui makes every key permanent, Tirith findings included, so its line names no downgrade (#883).

Lives in: `HermesMobile/Models/Approval.swift`, `HermesMobileTests/BotPendingRequestTests.swift`

## Never open MCP sign-in links on the phone

In a `manage_connections` operation, an MCP authorize row's sign-in returns to the Mac's loopback, so `BotConnectionOperation.Target.linkToOpen` is nil for it and it is marked `finishesOnTheMac`, even when the host sends an https `connect_url`. Only a managed connector's https sign-in opens on the phone, while pending or started.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`, `HermesMobile/Features/Chat/HermesRequestCards.swift`, `HermesMobileTests/BotPendingRequestTests.swift`

## Send connection field defaults untouched

A plain (non-secret) `required_env` field in a connection row starts at its declared default and Connect sends it, because the host never fills a default in itself. A required field is ready untouched; only emptying it holds Connect back. Secret fields never have a default.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`, `HermesMobileTests/BotPendingRequestTests.swift`
