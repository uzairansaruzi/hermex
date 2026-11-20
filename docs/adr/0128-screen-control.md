# 0128. Screen control and leases

Area: screen

## Clear an orphaned plugin hold on every Profile's lease

A hold left by a hermex-screen plugin that has since been removed sits on every Profile's stock display lease, with nothing left to end it. The force Hand Back, `ScreenSource.releaseAny`, therefore goes through `releaseOnEveryProfile`, which lists the Profiles (`profiles.list`) and calls `display.lease.release` on each, not just the current one, and answers the current Profile's lease. A viewer id releases only itself; nil clears any holder.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Verify a release against the returned lease

The host answers success to a lease release whether or not the named id held it, and leaves another person's takeover in place. `ScreenSource.release` names every id in the `ScreenHold` and throws unless the last lease shows none of them holding, rather than trusting the success reply.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Save the hold before Take Over's reply

`ScreenSession.takeOver` saves the `ScreenHold` before the acquire reply arrives, so a phone that suspends before the reply can still find the hold on return. The bot's tools answer `human_has_control` from the host's reply on.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Wait for a host Take Over before releasing

On a host desktop, Take Over goes by HTTP, so a release sent after it can overtake it, finish first, and leave the acquire to pause every bot with nobody watching. `ScreenSession` keeps the Take Over on its way and, in `leave()`, awaits it before releasing when the hold's source is `.hostDesktop`. A gateway call keeps its order, so bot desktops need no wait.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Take back a hold under a new viewer id without a prompt

A new socket means a new viewer id, so `ScreenSession.settleControl` works out who holds the screen and moves a hold this iPhone still has from the old id to the new one without asking. Stock hosts have no conditional acquire, so this can race another person's takeover in the moment between the read and the call; v1 accepts that race.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Nudge the pointer on Keep Control for plugin hosts

The hermex-screen plugin's idle timer runs on the host and counts only input it receives, so `ScreenSession.keepControl` also sends a pointer move to where the pointer already is on `.hostDesktop`. A stock host has no timer, so only local activity is noted there.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Release holds before removing the screen plugin

Hermes runs no plugin code on removal, so any hold has to go first or it would stay held with nothing left to end it. `ScreenSession.removePlugin` releases a saved hold, then reads the host's status again and refuses (`BotFailure.unsupported`) if someone took over while the confirmation was open, since removing the plugin then would leave their takeover with nothing to end it.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Offer the plugin restart only off a Webapp gateway

hermex-push's restart skips the drain of a gateway that serves the Webapp (#1606). When the plugin is not mounted, `ScreenSession` offers `pluginNeedsRestart(canRestart:)` with a restart only when the companion lists `POST /restart` and the client is not `servesWebapp`.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Poll the host's /status for screen lock

A host screen can lock or unlock while its stream runs, and only the plugin's `/status` says so. `ScreenSession.watchHostLock` reads status again every `Options.lockPoll` (20 s) while a host stream is open.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`
