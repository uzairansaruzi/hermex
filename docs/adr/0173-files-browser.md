# 0173. Files browser

Area: workspace-git

## List a Hermes folder only when it is tapped

`WorkspaceFileClient.opensTopLevelFolders` says whether Files opens every top-level folder on first visit (`FileTree.defaultExpandedPaths`). A Hermes host lists folders one at a time and can block for seconds on a protected one, so a Hermes tree opens with every folder closed, lists only the chat's folder, and lists a folder only when it is tapped (#1138). Every row is the folder's relative path plus the entry's name, though the host answers with resolved `/private/…` paths.

Lives in: `HermesMobile/Networking/APIClient+Workspace.swift`, `HermesMobile/Features/Workspace/FileBrowserViewModel.swift`, `HermesMobileTests/FileBrowserViewModelTests.swift`

## Commit a folder listing only while the folder is still in the tree

`FileBrowserViewModel` commits a directory's listing only if `tree.node(at:)` still shows that path as a directory. A root refresh that finished meanwhile may have dropped it, and an orphaned listing would be shown as current if the folder ever came back.

Lives in: `HermesMobile/Features/Workspace/FileBrowserViewModel.swift`

## Open a Workspace search hit without selecting it

Files' Workspace search (#1389) opens a hit through `FileBrowserViewModel.openWorkspaceHit` as a file node without selecting it: selecting lists and expands every folder above it, and a Hermes folder lists only when it is tapped (#1233). Folders aren't shown among the hits, since opening one would list every folder above it. Every prefetch stops, since none was for this file.

Lives in: `HermesMobile/Features/Workspace/FileBrowserViewModel.swift`

## Key remembered folder expansion by the client's scope

`FileTreeExpansionStore` remembers which folders are open, keyed by the client's `scope` so one server's or one chat's layout never shows up under another: server and workspace on webui; server, Profile, session and folder on Hermes. A missing record means "use the default expansion".

Lives in: `HermesMobile/Features/Workspace/FileBrowserViewModel.swift`

## Present the file share sheet as a UIActivityViewController

`FileShareSheet` is the system share sheet for one local file, presented in a `.sheet`, because `ShareLink` can't be presented programmatically after an async download finishes. The caller owns the file and deletes it once the sheet is gone, which is after the activity UI finishes in both the completed and cancelled paths.

Lives in: `HermesMobile/Features/Workspace/FileExportSupport.swift`
