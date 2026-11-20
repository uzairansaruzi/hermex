# 0146. Move to Hermes commit

Area: settings-onboarding-auth

## Save a moved server's sign-in before its registry entry

`AuthManager.commitMove` saves a new Hermes server's `BotConnection` sign-in before committing its registry entry, so a committed entry always has one. If the entry isn't saved, `restoreSignIn` puts back whatever sign-in was saved at that address before.

Lives in: `HermesMobile/Auth/AuthManager+MoveToHermes.swift`

## Re-check a move under the registry lock

`commitMove` calls `checkMove` a second time inside `serverRegistry.commit`, against the servers the registry holds at that moment, so a change between the first check and the commit can't produce a conflicting move.

Lives in: `HermesMobile/Auth/AuthManager+MoveToHermes.swift`

## Compare webui and Hermes addresses in Hermes-normalized form

In `AuthManager.checkMove`, a webui server id keeps its host's case while a Hermes address is lowercased by `BotConnection.address(_:)`. So ids are compared the way a Hermes address is normalized; a plain string compare would miss the same-address and webui-at-destination conflicts.

Lives in: `HermesMobile/Auth/AuthManager+MoveToHermes.swift`

## Add the Hermes server without suspending after removing the webui one

`AuthManager.replaceWebuiServer` (#1027) awaits `removeServer` for the webui server and then calls `addHermesServer` with no suspension in between, so no screen ever shows the server the removal falls back to.

Lives in: `HermesMobile/Auth/AuthManager.swift`
