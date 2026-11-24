# 0122. hermex-push host plugin changes

Area: push

## Mutate the Hermes host's plugins only from confirmed actions

`BotDashboardClient` is the Hermes host's dashboard REST surface, kept apart from `BotClient` because push provisioning needs no gateway socket: it mutates the host's plugins and environment and reads the pairing keys over the sign-in and cookie jar the server's Bot screens share. Its writes change the user's server, so only confirmed actions (Enable, Disable, the plugin update, the restart) make them; only the plugin version and status reads run on their own. `restartGateway` interrupts the user's running work, so only a confirmed Enable or plugin update reaches it.

Lives in: `HermesMobile/Networking/Bots/BotDashboardClient.swift`

## Force-reinstall agent plugins

`installPlugin` reinstalls over an existing copy (`force` is true). An install that refused to overwrite would make the second run, re-enabling after a disable or repairing a plugin too old for this build, fail with nothing the user can do from the phone. Reinstalling cannot unpair a device, because hermex-push keeps its key pair in `plugin-data`, outside the install directory.

Lives in: `HermesMobile/Networking/Bots/BotDashboardClient.swift`

## Disable hermex-push rather than delete it

`setPlugin` enables or disables an installed plugin, and disabling is never a `DELETE`: the plugin directory is also where the host's key pair used to live. Its `validateDispatch` runs after any sign-in, just before each send, and throwing there sends nothing.

Lives in: `HermesMobile/Networking/Bots/BotDashboardClient.swift`

## Disable hermex-push before reinstalling it

Settings' plugin update (#851), from a confirmed tap only, turns hermex-push off, reinstalls it over itself (cloned again from `main`, which turns it back on), restarts the gateway, then reads what the host has loaded. Current Hermes asks at a terminal before replacing an enabled plugin that declares Python packages and refuses the dashboard's reinstall; a disabled one skips that question, and enabling it runs Hermes's own dependency admission. The keys stay in `plugin-data`, so a paired phone stays paired, and an update started from a pairing failure ends here too, since pairing waits for its own tap. The dashboard that serves the pairing route and runs Bot turns loads plugins only when it starts, so "restart needed" is the usual end, and only a plugin already at 0.4.0 or newer can then be restarted from the phone (`restartHermes`).

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`, `HermesMobileTests/HermexPushProvisioningTests.swift`

## Re-enable hermex-push when its reinstall fails

When the reinstall fails, `updatePlugin` turns the plugin back on. Turning a plugin off only edits the host's config, so the running gateway keeps it, and turning it back on keeps the next restart from dropping push. A disable that failed may still have landed, so it is undone too, since enabling an enabled plugin is a no-op; only a confirmed disable is reported as left off.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`

## Wait for the new plugin after a phone restart

"Restart Hermes…" (#934) runs from a confirmed tap on a host whose loaded plugin has the restart route: hermex-push answers 202 and re-execs the dashboard about a second later, and a connection dropped on that request counts as the restart. The public `/api/status` is then probed on `restartDelays` (`HermesRestartWait`), and whenever it answers the pairing route is read, until the newest plugin is loaded; the old process can still answer just after the 202, so an answer with the old plugin keeps waiting. When the schedule runs out the last answer stands: the old plugin is offered the restart again, a new plugin that did not load leaves its routes unmounted and asks for a restart on the host, a host whose read fails reports a failed read, and silence reports "Hermes didn't come back".

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`

## Never restart Hermes through a gateway's Webapp

hermex-push's restart route (0.4.0 or newer, #934) re-execs the dashboard process it runs in, but on a gateway's own Webapp it skips the gateway's drain (uzairansaruzi/hermex-push#33, #1606). `HermexPushProvisioner.servesWebapp` records whether the last plugin read reached one, and only a plugin with the restart route that is not on a Webapp is offered the restart. `BotDashboardClient.restartHermes` checks at each dispatch, after any sign-in, and throws `.stale`, so a sign-in on the way (including a 401 retry) that finds a Webapp sends nothing and the card asks for the restart on the host instead.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`, `HermesMobile/Networking/Bots/BotDashboardClient.swift`, `HermesMobileTests/HermexPushProvisioningTests.swift`

## Offer hermex-push updates outside Settings

Two signals say a paired host's plugin should be updated (#1803). `HermexPushPlugin.minimumVersion` is the oldest plugin this build works properly with, and a loaded plugin below it is recommended the update. At or above it, the host's own update check is the other signal: `plugins.manage` `list`, sent without a Profile so it lists the dashboard's own plugins, reports `update_available` with an `update_target` (a commit or a feed version) for a git install its last scheduled check found behind; the listing makes no network call, so an update shows only after that check has run. The same row's `version` is `plugin.yaml` on disk, so a newer one than the loaded version means an update is waiting for a restart. Features still gate on `/capabilities`, never on a version.

`HermexPushUpdateOffers` keeps each server's last accepted standing in memory, keyed by server URL, so one server's answer never shows under another. The Hermes Sessions list checks once its connection is live, at most hourly per server, through the same `checkPlugin()` Settings runs, which refreshes it too. The check runs outside the view so leaving the list does not drop the answer.

The session list card ranks ahead of every other card, ignores the one-card-per-launch rule and the rating cooldown, because it fixes something. Its button opens Notifications in a sheet and raises the existing update confirmation there, so progress, failures and the restart stay on the one page that renders them and the gateway restart stays behind a confirmation. Dismissing it stores the offer it showed (the minimum, the host's target, or the restart) per server, and a different offer brings it back. Notifications in Settings shows a dot while any offer stands, dismissed or not.

Lives in: `HermesMobile/Features/Bots/HermexPushPairing.swift`, `HermesMobile/Features/Bots/HermexPushProvisioner.swift`, `HermesMobile/Features/SessionList/SessionListCards.swift`, `HermesMobileTests/HermexPushProvisioningTests.swift`, `HermesMobileTests/SessionListCardTests.swift`

## Let push host runs outlive Settings

Setup, the plugin update, and the restart change the host, so the existing provisioner owns each run to the end even if Settings closes before it returns. Once the host has been asked to change or restart, cancelling with the screen would abandon that transaction halfway.

Lives in: `HermesMobile/Features/Bots/HermexPushSettingsPage.swift`
