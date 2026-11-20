# 0107. Connections and large payloads

Area: performance

## Share process-wide URLSessions across APIClients

`APIClient` uses the process-wide `sharedSession` and `sharedPublicMediaSession` by default, so a newly opened chat reuses the warm connection pool (keep-alive, HTTP/2, TLS) the session list already holds instead of paying a fresh handshake (#688). They carry nothing server-specific: cookies live in the shared jar either way (it holds each server's auth cookie), and custom headers are applied per request. `sharedSession` has no session delegate; redirects are guarded per task. Never invalidate it.

Lives in: `HermesMobile/Networking/APIClient.swift`

## Decode the plugin catalog off the main thread

`HermesPluginsClient` decodes the host's plugin catalog off the main thread because it runs to megabytes.

Lives in: `HermesMobile/Networking/Hermes/HermesPluginsClient.swift`

## Download catalog images to a file and downsample

`PluginImageLoader.image(at:maxPixels:)` downloads to a file, so a huge banner never sits in memory whole, and removes the file once ImageIO has decoded a downsampled copy.

Lives in: `HermesMobile/Features/Settings/PluginDiscoverView.swift`

## Hold one Move import batch at a time

`WebuiSessionTransfer` holds one pending import batch at a time, so memory stays near one import (25 MB) plus the exports in flight. Review maps each source Profile to one destination, so a group rarely flushes early for a change of destination.

Lives in: `HermesMobile/Features/MoveToHermes/WebuiSessionTransfer.swift`

## Join pre-encoded sessions into the Move import body

The import request for a batch is `{"sessions": [...], "profile": ...}`, joined from each chat's existing encoding so megabytes of messages are never encoded twice.

Lives in: `HermesMobile/Features/MoveToHermes/WebuiSessionTransfer.swift`

## Memory-map staged share attachments

`HermesShareDraft.loadAttachments` maps each staged attachment in the directory rather than reading it, so reserving an import on the main actor stays cheap; pages fault in at upload time. This holds because the mapping stays valid after the reservation is consumed and its files are removed, and nothing rewrites a staged file in place. A staged file that is gone or empty joins the payload's skips.

Lives in: `HermesMobile/Features/Share/SharedDraftStore.swift`

## Sniff audio container type from magic bytes, not AVFoundation

`AttachmentAudioDetection.containerType(of:)` judges the audio container from its magic bytes: WAV, MP3 (ID3 tag or bare frame sync), CAF, M4A, FLAC, and Ogg, for extensionless media and exports where nothing else names the type. Asking AVFoundation or AudioToolbox to open the data starts the audio subsystem, which takes seconds on a cold simulator and is wasted work for a preview nobody has pressed play on.

Lives in: `HermesMobile/Models/AttachmentAudioDetection.swift`
