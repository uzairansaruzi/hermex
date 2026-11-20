# 0001. Bot artifacts

Area: bots

## Capture bot artifact context with the transcript

`BotArtifactContext` (connection, Profile, session and generation) is captured with the transcript and never reconstructed from the currently selected server. An artifact download then goes to the connection and session that produced it.

Lives in: `HermesMobile/Features/Bots/BotArtifact.swift`

## Leave bot artifact paths for the host to resolve

`BotArtifactReference.path` keeps paths server-side. Relative paths and `~` are resolved by the host's `fs/download` using the originating session and Profile, never by Foundation on iOS.

Lives in: `HermesMobile/Features/Bots/BotArtifact.swift`

## Check host-absolute paths before URL parsing

`BotArtifactReference.path` checks `BotAttachmentUpload.isHostAbsolute` before parsing the reference as a URL. A Windows host's `C:\…` would otherwise parse as a URL with scheme `C`.

Lives in: `HermesMobile/Features/Bots/BotArtifact.swift`

## Strip download URLs to their path for bot artifacts

Desktop may emit an authenticated download URL. `BotArtifactReference.path` extracts only its path and never carries the URL's token, Profile override or session override forward.

Lives in: `HermesMobile/Features/Bots/BotArtifact.swift`
