# 0172. File references in chat

Area: workspace-git

## Treat bare relative paths as web links, not file links

`FileReference.parse` recognizes a link to a session workspace file the way an agent writes it in chat: a `file:` or `sandbox:` URL, an absolute path under the workspace, or a `./`, `../` or `~/` path, each with an optional `:line[:column]` suffix or `#L12[C3]` fragment. Its `path` is workspace-relative and `/`-joined, the same identity the file tree and `/api/file` use. Bare relative paths (`src/main.swift`) are not file links, because a relative web URL looks the same, so they keep the ordinary link behaviour.

Lives in: `HermesMobile/Features/Workspace/FileReference.swift`

## Don't workspace-scope chat media paths

`FileReference.absoluteMediaPath` accepts the same syntax as `parse` but without its workspace containment. The server keeps chat images in its own attachment store (`~/.hermes/webui/attachments/`), well outside any workspace, and `/api/media` owns the allow-list that decides what it will serve, so a containment check would only hide images the server is happy to hand over. `./` and `../` need a workspace root to resolve against; an absolute path or `file:` URL does not. Bare relative paths stay unrecognized unless `resolvesBarePaths`: a Hermes reply's `out/chart.png` is its folder's (#1679).

Lives in: `HermesMobile/Features/Workspace/FileReference.swift`

## Keep BinaryFilePreview Foundation-only beside FileReference

`BinaryFilePreview` says, by extension, what a preview does with a file it can't draw as text or an image. The workspace preview, chat file links and chat attachments share the one list, and the Files tree never prefetches either kind as text. It stays Foundation-only and beside `FileReference` so `scripts/benchmark-streaming-scans` can compile it on the host.

Lives in: `HermesMobile/Features/Workspace/FileReference.swift`
