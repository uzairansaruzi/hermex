# 0153. Hermes Tasks client and Run Now

Area: tasks

## Give Run Now the provisioning deadline

`HermesCronClient.runCron` uses the host's trigger (#1041), which runs the Task before it answers with the job, so it gets `HermesConnection.Deadline.provisioning`. A tunnel can still give up first (Cloudflare's 524 after about 100 s) while the run goes on, so the screens follow it on the list. A paused Task is resumed as it runs; one already running is refused with 409 and the host's `detail`.

Lives in: `HermesMobile/Networking/Hermes/HermesCronClient.swift`

## Keep following a Hermes Run Now through gateway timeouts

`TaskDetailViewModel.followRunNow` sends the trigger on its own task, which nothing there cancels, and reads the Tasks list every `runNowReadInterval` until the host gives its outcome: the trigger's reply, or a read showing the run finished (#1041). The Task shows as running only once a read does. A gateway timeout (504), Cloudflare's 524, a request timeout or a dropped connection (`isUnansweredTrigger`) is a hop giving up while the host goes on with the run, so reads continue and no error shows. A refusal shows the host's reason unless a read right after it shows the Task running or finished, as a 409 "already running" does; reads that keep failing end Run Now with the read's error rather than waiting with nothing to show. Cancelling the caller, as a screen does when it goes away, ends the reads and leaves the run to the host, and the trigger's reply goes to that run's own stream so a late one can never stand in for a later run's outcome.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Detect a finished Hermes Run Now from host timestamps

A finished run stamps `last_run_at`. A pending Run Now decides the run finished by comparing the host's own `last_run_at` against the value from before the tap, never the phone's clock, so clock skew between phone and host cannot fake or hide completion.

Lives in: `HermesMobile/Features/Tasks/TaskDetailViewModel.swift`

## Treat a cron 424 as saved with a warning

`HermesCronClient.createCron` reads a 424 as the job having been saved while the host's scheduler could not register it, so it returns a saved result without the job, carrying the host's warning, and the list reloads. `toastNotifications` is never sent because the host has no toast setting.

Lives in: `HermesMobile/Networking/Hermes/HermesCronClient.swift`
