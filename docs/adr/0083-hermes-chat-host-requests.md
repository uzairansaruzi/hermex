# 0083. Hermes slash commands and host request answers

Area: networking-hermes

## Admit only a bare name to command.dispatch

`command.dispatch` resolves quick commands ahead of skills, and a quick command can run a shell command on the host. `HermesCall.admit` therefore allows `commandDispatch` only for one bare name, with no leading `/` and no whitespace, so it never widens into the general slash runner (`slash.exec`), a Profile scope or a `shell` flag. The slash panel's two reads stay this narrow shape.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`, `HermesMobileTests/BotClientTests.swift`

## Drop slash skills shadowed by a gateway command

`command.dispatch` resolves quick, plugin and registry commands ahead of skills, and a quick command can run a shell command on the host. `BotSlashCatalog.skills(from:)` never offers a skill key that collides with one, so a tap on a shadowed skill can't run the command instead.

Lives in: `HermesMobile/Features/Bots/BotSlashCommands.swift`, `HermesMobileTests/BotSlashCommandTests.swift`

## Pick connection.respond's session key by host release

0.21.5 names the answered session as an `owner` (`{type: session, session_id}`); 0.21.4 took a bare `session_id`. Each refuses the other's key, so `HermesCall` shapes `connection.respond` by the release the host reported at sign-in, decided by `HermesCall.predatesSessionOwner`. A canary reads as its base release, and a missing, partial or unreadable version reads as the pin (`HermesCompatibility.release`).

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`, `HermesMobileTests/BotClientTests.swift`

## Echo the host's own clarify label in answers

A clarify choice keeps the host's raw label as `wireLabel` (for example "Primary (Recommended)"), and the answer sends it back verbatim. Only the label shown to the user is stripped of its presentation marker.

Lives in: `HermesMobile/Features/Bots/BotPendingRequest.swift`, `HermesMobile/Features/Bots/BotPendingRequestCard.swift`, `HermesMobileTests/BotPendingRequestTests.swift`
