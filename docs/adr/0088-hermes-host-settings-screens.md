# 0088. Hermes host settings screens

Area: networking-hermes

## Drop a screen's socket client in the background and read again on return

The app ends a Hermes server's socket in the background without telling its screens. `ArchivedSessionsView` and `HermesDefaultModelView` drop their client on `.background` and read again on `.active` when no client is held (`holdsConnection`); Control Center and banners (`.inactive`) keep it. A write out when the app left is not resent; the read shows what landed.

Lives in: `HermesMobile/Features/Settings/ArchivedSessionsView.swift`, `HermesMobile/Features/Settings/HermesDefaultModelView.swift`

## Treat a dropped migrate request as started

In `ServeEveryProfileModel.migrate`, a non-cancellation `URLError` from `client.migrate()` is not a failure: the migration restarts the gateway, and a request the restart dropped started the migration as surely as an answer. The model goes on to wait for the restarted gateway.

Lives in: `HermesMobile/Features/Settings/ServeEveryProfileView.swift`

## Decide gateway health from `gateway_running`

Upstream reports a dead gateway process as `stopped`, `startup_failed` or a watchdog `degraded`, so `BotHostStatus.gatewayStopped` trusts `gateway_running` to decide whether scheduled Tasks run. It falls back to `gateway_state` (`stopped` or `startup_failed`) only when `gateway_running` is absent.

Lives in: `HermesMobile/Features/Bots/BotConnectionView.swift`
