# 0137. Diagnostics and support report

Area: settings

## Keep only non-identifying fields from MetricKit payloads

`DiagnosticReport.reports(fromPayload:)` makes one report per diagnostic in MetricKit's payload JSON (`MXDiagnosticPayload.jsonRepresentation()`), read tolerantly: a missing or mistyped field leaves that field nil and never drops the diagnostic. It reads only the kind, window, app version, codes, measurement and bounded stack frames. Exception and termination messages, VM region info, signposts, and device, OS and locale metadata can hold user text, paths or device details, and never leave this function.

Lives in: `HermesMobile/Features/Settings/DiagnosticsLog.swift`

## Order a report's window dates before building a range

`DiagnosticReport.windowDescription` builds its range from the min and max of `windowStart` and `windowEnd` rather than in stored order, because a stored report whose dates were swapped would make `..<` trap.

Lives in: `HermesMobile/Features/Settings/SettingsDiagnosticsPage.swift`

## Percent-encode + in the bug report URL

`SupportReport.issueURL` replaces `+` with `%2B` in the percent-encoded query. `URLComponents` leaves `+` as is and GitHub reads it as a space, and a canary release version looks like `0.21.4+…`.

Lives in: `HermesMobile/Features/Settings/SupportReport.swift`
