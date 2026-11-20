# 0089. Hermes plugins

Area: networking-hermes

## Toggle plugins by canonical key

`HermesCall.pluginsToggle` answers `{ok, unchanged, restart_required, gateway_reloaded, activation, name, plugin}`. It always names the canonical key, because bare names collide across category folders. Either direction can sync the Profile's Python packages first, which took 30 s on a fresh host, and a refusal is 5026.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Send the reviewed `ref` on catalog plugin installs

`HermesCall.pluginsInstall` with a catalog source names the entry, so the host resolves its repo and enforces its removal list, and sends `ref`: without one the host reuses a disabled copy at whatever commit it has rather than the one the review showed. `replace` is the host's `force`, which also lets a caution scan through on a repo source; a dangerous one stays blocked. Every refusal is 5026 with the host's message.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Detect an existing plugin from the host's refusal text

`PluginsModel.install` maps a `BotSettingFailure.rejected` whose message contains "already exists" to `.alreadyExists`, the only case that offers Replace. At the pinned Hermes commit the host's sentence is its only signal for this refusal.

Lives in: `HermesMobile/Features/Settings/PluginsModel.swift`

## Send empty plugin settings after a secret write

`HermesCall.pluginsSettings` (`{ok, name, written, plugin}`) carries the manifest's non-secret keys in `values`; a wrong type or a secret is 4021, secrets go to `/api/env`, and a plugin the host lacks is 4020. Empty `values` follow a secret's write, as Desktop's do: this call is what tells the host to reconnect the plugin's MCP servers on the new value and tell its other clients. `PluginsModel.saveKey` sends it so a server that couldn't connect without the key tries again; the key is written by then, so a failed follow-up isn't a failed save.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`, `HermesMobile/Features/Settings/PluginsModel.swift`

## Derive catalog installed state from the shown Profile's list

`PluginsModel.installedCatalogNames` is the catalog entries on the shown Profile, built from that Profile's plugin list. The catalog's own `installed` field isn't used, because its route reads only the dashboard's Profile. It is nil until the list is read, which is no time to offer an install.

Lives in: `HermesMobile/Features/Settings/PluginsModel.swift`

## Load catalog images on an ephemeral, credential-free session

`PluginImageLoader` fetches and downsamples catalog images on a session that sends no cookies or sign-ins, because these requests go to GitHub, not the user's host. The session refuses Low Data Mode, so an image then just stays a tile. The memory cache is bounded and clears itself under pressure, and nothing stays on disk.

Lives in: `HermesMobile/Features/Settings/PluginDiscoverView.swift`

## Tell plugin 404 bodies apart for hermex-screen

`HermexScreenPlugin.State` reads the body of a 404, not just the status. The dashboard's own "Plugin not found" means off or not installed. A catch-all 404 means it's enabled but this dashboard never mounted it, so a restart may help. FastAPI's bare "Not Found" means a newer host tried to mount it and failed, so a restart won't help.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Read the lease after a display Hand Back

`HermesCall.displayLeaseRelease` answers `{lease}` and reports success whether or not the release happened, so the caller reads the lease. `force` skips the refusal, and with a `viewerID` the host still lets only that holder release, so another person's takeover survives. With no `viewerID` it clears any holder, which only the force Hand Back uses.

Lives in: `HermesMobile/Networking/Hermes/HermesCall.swift`

## Manage plugins over plugins.manage, not REST

`HermesPluginsClient` (#1582) sends plugin management over the gateway's `plugins.manage`, because only it can name a Profile; the host's REST mutations act on the Profile the dashboard runs as. Every request names the Profile and nothing is cached, so a row never shows under another server or Profile.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginsClient.swift`

## Never resolve a catalog plugin name to a repository

A `HermesPluginSource.catalog` install sends the catalog name and the commit the review showed, and the host resolves it itself; a repository install fetches its latest commit. The app never turns a catalog name into a repository URL, so the host's catalog removal list always applies (#1582).

Lives in: `HermesMobile/Networking/Hermes/HermesPluginsClient.swift`

## Let the plugin review decide what an install link asks for

`PluginInstallInput` accepts anything a person might paste: a repository or URL, a catalog name, `hermes plugins install <name>`, or a `hermes://plugin/install` link. A link's `force` and `enable` are ignored and command-line flags such as `--force` are dropped, so the in-app install review always decides. `PluginInstallInput.isCatalogName` accepts only upstream's bare `^[a-z0-9_-]{1,64}$` token, so a link cannot pass a repository off as a catalog name.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginCatalog.swift`

## Fetch only HTTPS GitHub plugin catalog images

`PluginCatalogImageRule.url` allows catalog banner and screenshot URLs only over HTTPS on a GitHub host (github.com, githubusercontent.com or its subdomains), matching upstream's allowlist. SVGs are skipped and a GIF shows only its first frame.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginCatalog.swift`

## Hide Update for app-pinned companion plugins

`HermesPlugin` never offers Update for hermex-push or hermex-screen, even when the host reports `update_available`, because this app build pins those plugins and their own pages or the app update them.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginsClient.swift`

## Warn before turning off plugins sign-in relies on

`HermesPluginStakes.warning(for:turningOn:)` returns the plain-language warning a toggle needs first, or nil to apply it at once. Plugins Hermex or sign-in relies on are never hidden or blocked, but they get a warning first: upstream's own comment says disabling `basic` (dashboard_auth) makes password auth silently fail, which can lock the iPhone out of the server.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginsClient.swift`
