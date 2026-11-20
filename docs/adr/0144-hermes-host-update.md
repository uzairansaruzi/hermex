# 0144. Hermes host update

Area: settings-onboarding-auth

## Trust the update receipt over the exit code

`HermesUpdateMachine` is one update of a Hermes host started from Settings (#1075), as a pure reducer of what the host answers: `HermesUpdateModel` reads what `nextRead` names about every 3 seconds and hands the answer to `handle`, with the time since the model began. The host's receipt is the outcome, over any exit code, because the update restarts the dashboard, which then no longer tracks the process and can report an exit code from an earlier run's receipt. A receipt counts once it differs from `baseline`, the one the host held before this run; an exit code counts only while the dashboard still tracks the process (`pid`), and a null one keeps waiting. A read that gets no answer means the dashboard is restarting, and a receipt that says success is done once `/api/health` answers on the release it installed. Silence for `silenceLimit` means the dashboard isn't coming back, and `ceiling` ends a wait that hasn't finished on what the host last said; both count only time the app watched, so a gap between two answers longer than `longestRead` (the app was suspended, or another server was active) counts as one read.

Lives in: `HermesMobile/Features/Settings/HermesUpdateMachine.swift`

## Don't trust update status after a dashboard restart

After the dashboard restarts, `GET /api/actions/hermes-update/status` no longer tracks the process: `running` is false, `pid` is null, and `exit_code` comes from the log's completion marker or from the latest receipt, which can be an earlier run's.

Lives in: `HermesMobile/Networking/Hermes/HermesUpdateClient.swift`

## Follow an update the host reports after a failed start request

A start request that fails without the host's answer may still have started the update before its reply was lost (a dropped connection, a proxy's 5xx). So a run the host then reports is followed rather than offered again; otherwise the failure stands.

Lives in: `HermesMobile/Features/Settings/HermesUpdateMachine.swift`

## Check restart_blocked before ok in update apply

A webui update apply response that is restart-blocked always carries `ok: false`, so `outcome` checks `restartBlocked` first and returns `.restartBlocked` instead of mislabelling it `.failed`. Active chat or agent work blocking the restart is not a failure: the app surfaces the server's message and lets the user retry once work finishes.

Lives in: `HermesMobile/Models/ServerCatalog.swift`
