# 0121. Transcript image cache keys

Area: persistence-cache

## Namespace attachment thumbnail keys by server and session

`TranscriptImageCache` is process-wide and survives the logged-in subtree's `.id(server)` teardown, so `AttachmentImageCacheKey` includes the server (and session) namespace rather than the relative path alone. Its `cacheKey` carries an `attachment|` kind prefix and the namespace's length so it stays apart from media keys and the namespace boundary stays fixed.

Lives in: `HermesMobile/Features/Chat/MessageBubbleView.swift`

## Scope linked-image keys by server and session

`TranscriptMediaImageCacheKey` is scoped by server and session so identical `MEDIA:` paths in different sessions or servers can't reuse each other's cached image and bypass the session-aware fetch. Its `cacheKey` carries a `media|` kind prefix and the namespace's length, keeping it apart from attachment keys.

Lives in: `HermesMobile/Features/Chat/TranscriptMediaView.swift`

## Key Hermes thumbnails by connection, Profile and stored key

`HermesChatTurnCoordinator.attachmentCacheNamespace` keys a Hermes session's thumbnails in the process-wide `TranscriptImageCache` as `hermes|<connection id>|<Profile>|<stored key>`, so no other connection, Profile or session ever shows them.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`
