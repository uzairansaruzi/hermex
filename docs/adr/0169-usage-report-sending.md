# 0169. Usage report sending

Area: usage-reports

## Read the ended week's tallies only after the device await

`UsageReports.sendEndedWeek` awaits `device()` before it loads the ended week's tallies, so turning reports off during that await, even if they are turned on again, leaves nothing to send. From that read to the request nothing awaits, so the consent check (`isRecording`, `consent.acceptedVersion`) sits just before the post. Reading the tallies before the await would send a week the user withdrew consent for.

Lives in: `HermesMobile/Config/UsageReports.swift`

## Roll the tallies over before awaiting in the preview

`UsageReports.preview` calls `rollOver(now)` before it awaits `device()`. If the rollover ran after the await, a resume in a later week with the captured `now` would discard that later week's tallies.

Lives in: `HermesMobile/Config/UsageReports.swift`
