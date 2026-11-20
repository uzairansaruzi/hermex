# 0056. Transcript media and attachments

Area: chat-transcript

## Load attachment images through APIClient, not AsyncImage

`RemoteAttachmentImage` loads attachment images through the authenticated `APIClient` instead of `AsyncImage`, which uses `URLSession.shared` and may not carry the server's auth cookie. `TranscriptImageCache` deduplicates concurrent requests and keeps the thumbnails in memory.

Lives in: `HermesMobile/Features/Chat/MessageBubbleView.swift`, `HermesMobile/Features/Chat/TranscriptImageCache.swift`

## Leave media path containment to the server

`TranscriptMediaParser` turns standard `![alt](path)` images in an assistant message into transcript media when they name a raster image on the server's filesystem, with no workspace containment check on the phone. Containment is the server's job: `/api/media` owns the allow-list, and chat images live in the server's attachment store rather than in any workspace, so an image outside the workspace is the normal case rather than an attack. The phone normalizes the path and `/api/media` decides what it will serve.

Lives in: `HermesMobile/Features/Chat/TranscriptMedia.swift`, `HermesMobileTests/TranscriptMarkdownImageTests.swift`

## Sniff audio before image decode for extensionless media

`TranscriptMediaPreviewViewModel` checks extensionless remote media for audio (`isAudioData`) before the image decode, because a WAV header is a RIFF container, which sends ImageIO looking for a WebP codec.

Lives in: `HermesMobile/Features/Chat/TranscriptMediaPreviewViewModel.swift`

## Check both attachment name and path for an audio extension

`AttachmentAudioDetection.isAudio` checks the display name's extension first, then falls back to the path's. A human display name like "Voice note" carries no extension even when the path ends in `.m4a`, so a single `name ?? path` candidate would miss it.

Lives in: `HermesMobile/Models/AttachmentAudioDetection.swift`

## Match attachments by lowercased basename

`MessageAttachment.identityKey` matches the same attachment across two representations, such as an optimistic local bubble and its server-reloaded copy, by the lowercased last path component of the first non-empty `name` or `path`, not the raw value. The server returns an attachment's `path` inconsistently on reload (usually a bare filename, occasionally the full upload path), so raw values fail to match an optimistic bubble's full upload path against its reloaded bare filename. Voice notes are the live case: #330 dropped their `[Attached files: <path>]` marker, which had silently backfilled the path on reload, so basename matching is now the only reliable key. It returns `nil` when the attachment has no usable name or path.

Lives in: `HermesMobile/Models/MessageAttachment.swift`

## Key inline audio players by attachment, not row position

In `MessageBubbleView.attachmentPreviews` each inline audio player takes its identity from the attachment (`path`, else `name`, else index). A transcript bubble's id is positional (`transcript:<index>`), so without this a recycled row would keep its old `@State` player model, and stale audio bytes, for a different clip.

Lives in: `HermesMobile/Features/Chat/MessageBubbleView.swift`

## Keep a detached Hermes chat's nil audio load key

A bubble hands its `InlineAudioPlayerView` the attachment source's load key unchanged. A detached Hermes chat's key is `nil`, which makes the player wait for the attach; a stand-in key would load now and show the failure.

Lives in: `HermesMobile/Features/Chat/MessageBubbleView.swift`, `HermesMobile/Features/Chat/InlineAudioPlayerView.swift`, `HermesMobileTests/HermesChatAttachmentTests.swift`
