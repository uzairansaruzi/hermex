# 0179. Hermes workspace files

Area: workspace-git

## Build a child's path from its folder and name, never the listing's path

`HermesWorkspaceFileClient` reads a Hermes chat's workspace files (#1112) through the host's `/api/fs/*` routes on the sign-in its Bot screens share. Those routes read any host path a signed-in client names, so the fence is the client's own rule, not a security boundary: a workspace-relative path becomes `cwd + "/" + path` only when it is relative and climbs nowhere (`hostPath`). A child's path is always its folder's plus its name, never the listing's `path`, which the host resolves (`/private/var/…` for `/var/…`) and so can leave the folder that was asked for; `HermesSkillsClient.entries` follows the same rule. A file's download sends its host path without the stored key, so it works before the host has stored a new chat (#1138); a MEDIA path keeps the stored key so the host resolves it against the session. Rows, previews and errors carry only relative paths. Checked at the `HERMES_AGENT_TESTED_SHA` pin (ca678285) in `hermes_cli/web_routers/files.py`.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`, `HermesMobile/Networking/Hermes/HermesSkillsClient.swift`

## Refuse host paths ending in characters Python strips

The host calls Python's `str.strip()` on the path, so a read of a path ending in a stripped character can return a sibling. `HermesWorkspaceFileClient.hostPath` refuses such a path. Python strips four ASCII separators in addition to Unicode whitespace.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`

## Hide a refusal reason that names a host path

`HermesWorkspaceFileClient.send` turns one request's status into its failure (`HermesCronClient.accepted`). A reason that names a path, as an `OSError`'s can, reads as the generic failure instead, so no host path reaches the screen. A dropped request reads as the webui's network failure.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`

## Count lines by newline byte, not by Character

`HermesWorkspaceFileClient.lineCount` counts newline bytes in the text's UTF-8, because Swift reads `\r\n` as one Character that is not `\n`.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`

## Treat a 200 listing with an error as the folder's failure

The host answers a folder it can't read with 200 `{entries: [], error}`. `HermesWorkspaceFileClient` reads that as the folder's failure, not an empty folder: `ENOENT` and `ENOTDIR` are a missing folder, `EACCES` is not.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`, `HermesMobileTests/HermesWorkspaceFileClientTests.swift`

## Export a file from its bytes, not its preview

The host decodes text with replacement characters, so the preview is not the file. Save and Share download the file's own bytes instead of re-encoding the preview.

Lives in: `HermesMobile/Networking/Hermes/HermesWorkspaceFileClient.swift`, `HermesMobileTests/HermesWorkspaceFileClientTests.swift`

## Search workspace files on a client of its own

Files' workspace search (#1389) runs over the workspace's folder with the `@` panel's whole-folder `complete.path` word, named by its folder rather than the chat's runtime. Files is pushed over the chat, which detaches as it goes (#902), so `HermesChatTurnCoordinator.searchWorkspaceFiles` joins the connection's shared socket on a client of its own for each search and leaves when it answers; the chat stays detached. A search cancelled while the socket opens leaves at once, so a socket only it wanted closes.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`
