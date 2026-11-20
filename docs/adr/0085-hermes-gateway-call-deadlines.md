# 0085. Hermes call deadlines and cancellation

Area: networking-hermes

## Give slow host operations the provisioning deadline

`HermesConnection.Deadline.provisioning` allows 120 s per request and 180 s overall. Installing a plugin clones a repository on the host, and a restart takes the gateway down and back up, so 15 s would read as a failure while the host was still succeeding. A sign-in that provisioning starts gets it too, as do a Task's Run Now, which the host answers once the run has finished (#1041), Listen's speech, whose first request can install the host's TTS engine (#1072), and a session export and import, which carry every message (#1048, #1051).

Lives in: `HermesMobile/Networking/Hermes/HermesConnection.swift`

## Give slow gateway calls longer deadlines

`HermesCall.deadline` stretches the reply deadline per call. `slash.exec` waits twice the usual deadline because the host's slash worker allows a command 45 s. `session.compress` (#1050) and a canonical compaction (#1603) ask the model for a summary, so they wait as long as Desktop does (`SESSION_COMPRESS_TIMEOUT_MS`), past the host's own 630 s cap. A commit message (#1115) waits the two minutes webui's does, because the host gives its model call 60 s on a cold tunnel; an approval summary is optional, so it gives up after 20 s at most; `display.start` waits two minutes because it can start a sandbox's container as well as a desktop. The plugin list reads the host's live catalog and waits twice the usual deadline, a plugin toggle can sync the Profile's Python packages and waits three minutes, and an install, which clones the plugin first and took 55 s for a small one, and an update wait five.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`

## Let optional reads and slash commands time out locally

`HermesCall.timesOutLocally` marks optional reads and slash commands, whose timeout fails only that request: a slow command must never end its chat's connection, nor a Hermes chat's slow `@` lookup (#1113) or commit message (#1115). Any other call that times out ends its screen's connection, while the shared socket stays for the others.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`

## End the screen when a cancelled gateway call may have landed

`HermesGateway.cancel(_:generation:safely:)` discards a cancelled read's late reply. Any other cancelled call may already have reached the agent, so its screen ends as `close()` ends it; the shared socket stays open for the other screens.

Lives in: `HermesMobile/Networking/Hermes/HermesGateway.swift`
