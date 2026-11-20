# 0060. Insights provider limits

Area: insights

## Load provider limits in a separate unkeyed task

`InsightsView` loads quota (`viewModel.loadLimits()`) in its own unkeyed `.task`. A cold account-limits probe can take several seconds upstream, the chart must not wait on it, and quota does not depend on the window. Keying the task to the window would restart the probe on every picker change, wasting traffic and letting the restarted load supersede an in-flight explicit refresh. This load never passes `refresh`; that belongs to explicit gestures.

Lives in: `HermesMobile/Features/Insights/InsightsView.swift`

## Load quota limits apart from analytics and never as an error

`InsightsViewModel.loadLimits` runs separately from `load()` so the chart never waits on a cold account-limits probe. Its failures never set `errorMessage` or `lastError`: quota is a bonus panel and must not put an error over the analytics the user came for. A failure with nothing on screen stays silent; one with cards showing keeps them as they were and marks them in `staleLimitIDs` (#1408), so a network blip does not look like a vanished subscription. `refresh` bypasses the server's 45 s probe cache and belongs only to the toolbar button and pull-to-refresh. Each load that settles the cards hands them to the Limits widget with a ticket taken before the first read, so a server switch meanwhile drops them (#1409); a failed providers read publishes nothing.

Lives in: `HermesMobile/Features/Insights/InsightsViewModel.swift`

## Remove a limit card only on an unsupported status

`LimitProbe` records what one refresh learned about one provider's limits (#1408). Only a status saying the server cannot report that provider removes its card: `unsupported` (hermex-push and webui), `no_key` or `invalid_key` (webui). Anything else that is not a usable card is a failure that keeps the last card: a thrown request, an unknown status or empty payload, and `unavailable`, which both servers also answer when the provider's own API cannot be reached.

Lives in: `HermesMobile/Features/Insights/InsightsViewModel.swift`

## Drop fractional seconds before parsing quota dates

`providerQuotaDate` parses upstream's `reset_at` and `fetched_at`, which appear live both as whole seconds (`2026-09-06T07:55:41Z`) and with microsecond precision (`2026-09-06T02:56:37.848820Z`). Microseconds are more precise than `ISO8601DateFormatter` accepts, so the fraction is dropped and the value re-parsed rather than failing the row.

Lives in: `HermesMobile/Features/Insights/InsightsModels.swift`

## Speak limit reset countdowns in wide form

`ProviderLimitRowView` is spoken as one phrase, and its `accessibilityLabel` substitutes the wide reset countdown (`providerLimitResetText` with width `.wide`), because VoiceOver reads the on-screen abbreviated "23h 35m" as letters.

Lives in: `HermesMobile/Features/Insights/ProviderLimitsCard.swift`
