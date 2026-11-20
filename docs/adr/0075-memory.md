# 0075. Memory

Area: memory

## Decode projectContextShadowed as a bool or a list

Upstream webui (`routes.py` @ 312d3fab, verified live 2026-07-03) returns `projectContextShadowed` as a list of shadowed-file objects, while the API docs describe a boolean flag. Memory decoding accepts both: `true` or a non-empty list means the active document shadows another file.

Lives in: `HermesMobile/Models/Memory.swift`

## Write Hermes memory files in the agent's canonical format

`MemoryCanonicalizer` rewrites MEMORY.md and USER.md text in the agent's own entry format, joined by `\n§\n`, before `HermesMemoryClient` and the host's file routes write it (#1073). The agent's drift check (`_detect_external_drift` in `tools/memory_tool_store.py`) refuses to replace or remove entries in a file whose trimmed text is not the join of its parsed entries. `MemoryCanonicalizer.trimmed` strips the characters Python's `str.isspace()` matches, which adds U+001C-U+001F to Foundation's whitespace and newlines, so the result matches what the agent's `str.strip` produces.

Lives in: `HermesMobile/Models/Memory.swift`

## Count memory characters as Python does

The Hermes host counts limits with Python's `len`, which counts Unicode scalars. `MemoryCanonicalizer.scalarCount` counts scalars too, because an emoji with a skin tone is 2 there where Swift's `count` sees 1, and `count` would undercount against the host's limit.

Lives in: `HermesMobile/Models/Memory.swift`

## Refuse a Hermes Memory save when the file changed since the editor opened

`HermesMemoryClient` serves one Profile (#1073): its notes and user profile are `memories/MEMORY.md` and `USER.md` in the Profile's folder, read and written through the host's managed file routes, and its soul is `/api/profiles/{name}/soul`. `saveMemory` re-reads the file first and throws `MemoryConflict` when it no longer matches the text the editor opened with, unless it already holds what is being saved, so a retry after a save that landed but whose reply or refresh was lost overwrites nothing. The write takes no lock, so the agent can still write between the read and the write; that small window is accepted to use the host's public file routes. The folder comes from the Profile's `profiles.list` row on every load and save, is the only host path these routes are sent, and is never shown, logged or kept; the file routes stay on the dashboard's machine even when a Profile's terminal runs over SSH (#1566). The host's config says which sections are on and their limits, and only its `memory` section is decoded.

Lives in: `HermesMobile/Networking/APIClient+Memory.swift`

## Never surface host paths in Hermes Memory errors

`HermesMemoryClient.accepted` returns a 2xx reply's body. A 4xx the host explains in `detail`, a 403 included (a file it cannot write, or a path outside a locked files root), reads as that reason only when the reason contains no `/` or `\`. A 403 or 502-504 with no reason is attributed to the proxy or tunnel in front of the host. Anything else becomes `APIError.http` without its body, because the body can carry a host path.

Lives in: `HermesMobile/Networking/APIClient+Memory.swift`
