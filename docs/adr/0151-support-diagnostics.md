# 0151. Support diagnostics

Area: settings-onboarding-auth

## Keep server identity out of support reports

`SupportReport` is what a bug report needs to know about this install and the active server (#1396), built from values the app already has: it makes no request. It holds no server address, name, username, header or credential, so neither `text` nor `issueURL` can carry one.

Lives in: `HermesMobile/Features/Settings/SupportReport.swift`

## Keep no host, URL or credential in connection attempt records

`HermesAttemptRecord` is what one Hermes connection attempt observed, stage by stage (#1395): the Details under a connect form's advice, and the text Copy Details exports. `HermesConnection` keeps the latest one in memory. A stage the attempt never ran stays `.notChecked`; an open dashboard's sign-in leaves `identity` unchecked, and a usable ticket passes only `liveAuthorization`, never the socket. A failure keeps only its typed category, never an error's description or user info, so the record holds no host, URL or credential.

Lives in: `HermesMobile/Networking/Bots/BotProtocol.swift`
