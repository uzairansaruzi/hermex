# 0123. hermex-push setup

Area: push

## Keep the Hermes sign-in row outside the Bot Mode gate

The Hermes sign-in row in server Settings is not behind the Bot Mode preview gate (#557), because this login is what push pairing needs. On a Hermes server it is the server's own sign-in, and saving it signs a signed-out server back in (#899); on a webui server push serves that server's webui sessions too.

Lives in: `HermesMobile/Features/Settings/SettingsServerPage.swift`, `HermesMobile/Features/Settings/WebuiServerSettings.swift`

## Check notification permission before touching the host

Setup in `HermexPushProvisioner` checks notification permission first and stops with `notificationsOff` when it is missing. A phone that cannot show a notification must not get as far as reinstalling the plugin and restarting the gateway.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`

## Reinstall hermex-push only when the host says it is missing

The host state read from the pairing route means "not set up yet" only for a plugin that is off or missing, or an unset relay. A timeout, a server error, a 404 the host does not explain, or keys this build cannot read are thrown on instead, because reinstalling and restarting on those would replace a self-hosted relay and interrupt work over a failure unrelated to setup. An unmounted route is read against the plugins hub: with hermex-push on disk it throws `HermexPushRouteMissing.notMounted`, and a hub reply with no plugins list leaves the 404 unexplained.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`

## Tell an off plugin from an unmounted one by its 404 body

`HermexPushPlugin.missingRoute` explains a 404 from the pairing route by its body (hermes-agent ca678285, #1178). The dashboard's auth middleware answers "Plugin not found" for a plugin that is off or not installed; the SPA catch-all answers "No such API endpoint" for a plugin that is on but whose routes the dashboard never mounted, since it mounts them only at startup, and `hermes serve`'s headless catch-all means the same. Any other body yields nil.

Lives in: `HermesMobile/Features/Bots/HermexPushPairing.swift`

## Only a dashboard restart mounts a new plugin

A fresh host's hermex-push may have been installed after the dashboard started, or just now (#1178). A gateway restart does not load it; only restarting `hermes dashboard` on the host mounts its routes. Setup stops at the first read that says the route is not mounted, reports `setupNeedsRestart` asking for a dashboard restart, and "Check again" then finishes pairing.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`, `HermesMobileTests/HermexPushProvisioningTests.swift`

## Gate companion features on hermex-push capabilities

`HermexCompanionRoutes` records which hermex-push routes the dashboard has mounted, from `GET /api/plugins/hermex-push/capabilities` (plugin 0.5.0, #1235), each as a method and the path below the plugin's mount, such as `"GET /pairing"`. A feature that needs a plugin route shows only where `supports` says the route is mounted, since a POST cannot be probed without running it. `closed` supports nothing and stands for an older plugin or one the dashboard has not loaded since install. It is read per screen and never cached, so one server's answer cannot gate another's.

Lives in: `HermesMobile/Features/Bots/HermexPushPairing.swift`

## Strip trailing slashes from the relay URL

`HermexPushPlugin.relayURL` removes every trailing slash from the relay URL the host reports. The relay refuses redirects, so a trailing slash must not turn into a `//installs` path.

Lives in: `HermesMobile/Features/Bots/HermexPushPairing.swift`

## Keep the host plugin on while another entry shares the pairing

Two configured entries can reach one host, such as a LAN and a tunnel address, and share its pairing and plugin (#1178). `sharesHostPairing` reports that case, and turning one entry off then leaves the host and relay alone; only the last paired entry disables the plugin. An unreadable Keychain reads as not shared there, and `disable` asks again and stops on it.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`, `HermesMobileTests/HermexPushProvisioningTests.swift`

## Let teardown win over an in-flight push setup

A setup run outlives its screen, so the connection or its whole server can be removed while it works. Teardown wins: when the run sees its connection is gone it abandons, removing what it just stored and taking this phone back off the relay.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`

## Require Reply Notifications for the test push

`canSendTest` requires Reply Notifications on and iOS notifications allowed, because the test needs a banner this iPhone can show. With Reply Notifications off the relay skips the push yet still answers accepted, and with iOS notifications off nothing shows.

Lives in: `HermesMobile/Features/Bots/HermexPushProvisioner.swift`
