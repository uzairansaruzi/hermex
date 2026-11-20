# 0136. Session selection and new-chat placeholders

Area: sessions

## Resolve the deep link before restoring the stored selection

`SessionNavigationState` restores the stored selection only when no explicit route already won: deep links, shared drafts and App Intent requests take precedence. A pending or in-flight deep link (not yet resolved into a destination) also blocks the restore, and the stored ID is kept for a later restore. The deep-link resolution in `SessionListView` is awaited, not fire-and-forget, so the cold-start `.task` resolves it before `restoreLastSelectedSessionIfNeeded()`; otherwise the restore races the deep link's network load and wins with the previous session. The session rows still start loading immediately so a slow direct session request cannot leave the sidebar empty.

Lives in: `HermesMobile/Features/SessionList/SessionListView.swift`, `HermesMobile/Features/SessionList/SessionNavigationState.swift`

## Suppress empty new-chat placeholders synchronously on return

Returning from a new chat hides its empty Untitled placeholder synchronously, so it cannot flash during the navigation transition. The refresh that follows then adopts the server's latest metadata for a new chat that became contentful.

Lives in: `HermesMobile/Features/SessionList/SessionListView.swift`

## Ignore sort timestamps when hiding empty placeholders

The placeholder filter on `SessionSummary` mirrors hermes-webui's visible-sidebar safety net: it hides only the known empty Untitled shape and keeps rows with content, pending work, streaming state, or explicit user or server state. Sort timestamps such as `lastMessageAt` are ignored, because `compact()` sets them from `updated_at` even for zero-message sessions.

Lives in: `HermesMobile/Models/Session.swift`
