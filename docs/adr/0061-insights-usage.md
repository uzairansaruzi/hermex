# 0061. Insights usage

Area: insights

## Offer 24 hours instead of Today on Hermes hosts

The insights handler's `days=1` means different things per server. On webui it is midnight to now, so `AnalyticsTimeframe.today` is labelled "Today", not "24h", and the local fallback filters on the same calendar day to match. A Hermes host (`insights.get`, #1074) reports no hours, counts messages over at most its newest 500 visible sessions, has no sessions list here, and treats `days=1` as a rolling 24 hours, so `InsightsFeatures.hermes` offers `.last24Hours` instead of Today (#1678).

Lives in: `HermesMobile/Features/Insights/InsightsViewModel.swift`

## Label server total_tokens as processed tokens

The server's `total_tokens` excludes cache reads. `UsageBucket.processedTokens` is input plus output only, matching it, and Insights labels the figure "Processed tokens" rather than total. The chart stacks cache reads as their own layer and the totals grid names them separately, so folding cache reads in or calling the figure "total" would make the labels disagree with the chart and misstate the server's figure.

Lives in: `HermesMobile/Features/Insights/InsightsViewModel.swift`, `HermesMobile/Features/Insights/UsageChartData.swift`

## Require a press before scrubbing the Usage chart

Pressing and scrubbing inspects a bar; releasing goes back to the window total. `UsageChartCard.selectionGesture` sequences a `LongPressGesture` (0.12 s) before the `DragGesture` because a bare drag would eat the enclosing scroll view's vertical swipes, and the page would stop scrolling wherever the chart is.

Lives in: `HermesMobile/Features/Insights/UsageChartCard.swift`

## Read server day strings as UTC wall-clock dates

The server sends bare `YYYY-MM-DD` day strings in its own local time. `usageCalendar` is a Gregorian calendar fixed to GMT, so the Usage screen treats days as wall-clock dates rather than instants and the device time zone cannot shift a bar to a neighbouring day.

Lives in: `HermesMobile/Features/Insights/UsageChartData.swift`
