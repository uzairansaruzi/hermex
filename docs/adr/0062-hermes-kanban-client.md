# 0062. Hermes Kanban client

Area: kanban

## Strip host paths and process data from Kanban replies

`HermesKanbanClient` serves Kanban on a Hermes host (#1043) from the host's Kanban plugin under `/api/plugins/kanban`, read and written (#1044) over the sign-in, cookie jar and headers (#898) the server's Bot screens share, and adapts each reply to the Kanban models webui fills. Keys whose values are host paths or process data, `HermesKanbanClient.hostOnlyKeys` (`workspace_path`, `stored_path`, a log's `path`, `db_path`, `default_workdir`, an archived Board's `new_path`, `worker_pid`, `claim_lock`), are dropped at every depth before decoding, so no view or log can show them.

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Adapt Hermes Kanban replies to the webui models

The host has no read-only mode, so every reply `HermesKanbanClient` decodes reads `read_only: false`. The host's `/board` takes neither the Assigned Profile filter nor Only Mine, so both run in the client; Only Mine is `mine`, the Profile the Sessions side lists (#1677). Block and unblock are Status changes, a prerequisite reply is filled with the request's ids because the host echoes none, and a 400 or 409 throws `KanbanWriteRefusal` with the host's `detail`. A 404 on `/config` is a host without the Kanban plugin.

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Send the assignee each Card route expects for unassigned

`HermesKanbanClient.createKanbanCard` sends no `status`, because the host ignores it and starts a Card in Triage, To Do or Ready by its own rule, and sends a null assignee for no Assigned Profile, because `""` is a 400. `HermesKanbanClient.editKanbanCard` is the opposite: an unassigned Card is `""`, because null leaves the assignee as it is. Edit never sends `tenant`, which the host can't change after create.

Lives in: `HermesMobile/Networking/Hermes/HermesKanbanClient.swift`

## Validate Hermes Kanban Columns from the Board itself

`KanbanCompatibilityValidator` checks the handshake before any Kanban data shows. A webui Board must be a `changed` envelope whose Columns `/config` names. A Hermes host's `/config` names no Columns and its Board has no `changed`, so there the Board's own Columns are the configured ones. Either way a Card Status outside them flags as unsupported.

Lives in: `HermesMobile/Models/Kanban.swift`

## Read a Board's read_only from the Boards envelope

The verified Boards contract carries `read_only` on the envelope, not on each Board entry. A missing per-Board value must not override an explicit writable envelope value, so a Board without its own `read_only` takes the envelope's, while an explicit per-Board `read_only: true` still blocks comments and Card writes.

Lives in: `HermesMobileTests/KanbanFeatureStateTests.swift`, `HermesMobile/Features/Kanban/KanbanFeatureState.swift`
