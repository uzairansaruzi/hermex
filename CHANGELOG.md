# Changelog

Notable changes to Hermex. Version headings correspond to App Store releases;
unreleased changes accumulate at the top. Format follows
[Keep a Changelog](https://keepachangelog.com/) with Added / Changed / Fixed /
Security sections per release.

## [Unreleased]

### Added
- Bot Mode (beta, off until enabled in Settings): connect directly to a Hermes
  agent host and chat with its bots from a Bots inbox. Create, duplicate,
  edit, and delete bots, including their face, model, capabilities, and
  instructions. Follow tools, reasoning, and delegated work live; steer,
  queue, or interrupt a working bot; answer approvals, questions, and
  credential prompts; send attachments; mention teammates and files with `@`
  and skills with `/`; dictate on-device; search bots and messages; and take
  part in group rooms.
- Optional push notifications through an open-source relay you can self-host.
  Notification text is encrypted on your Hermes host and decrypted only on
  the iPhone. Turn them on from the Hermes connection screen and tune them
  under Settings > Interaction. Tapping a notification opens the right
  session or bot.
- Live Activities for working bots and WebUI runs keep updating while the
  phone is locked, and show tool counts and how fresh the update is.
- Session rows show unread replies.
- Select text in responses and ask Hermex about the selection.
- Steering hints appear inline in the transcript.
- A custom photo and camera picker for attachments.
- The Usage screen shows provider account limits.
- An optional "Buy Uzi a coffee" link, and rating requests at quiet moments.

### Fixed
- Live streams resume from the last event after a reconnect, and the reconnect
  probe retries after a transport drop.
- Pending approvals stay visible across stream transitions, and clarification
  requests stay above the keyboard.
- Long conversations scroll with less lag and do less math formatting work.
- Native composer text gestures and manual composer scrolling work again, and
  the profile chip stays inside the composer.
- Attachment thumbnails are cached per server.
- Reduce Motion is honored in chat, Git toasts, and onboarding.
- Interface strings added since 1.6 that showed in English in every language
  are now translated.

## [1.6.0] - 2026-09-05

### Added
- Redesigned chat transcript: settled tool calls, live tool activity, and
  thinking render as compact log rows, finished turns fold behind one
  elapsed-time row, a working-for counter sits at the transcript tail, and
  each message carries a timestamp and copy button. Expanded rows are capped at
  a scrollable window and new rows fade in.
- Pill-shaped Liquid Glass composer with a toolbar row when focused, combined
  model and effort controls with provider glyphs, and haptics for disclosures,
  copies, and Git actions.
- Reference workspace files from the composer with `@path` chips.
- Slash and skill autocomplete triggers at the caret, ranks by match quality,
  and shows a picked skill as a chip in the composer and in the sent bubble.
- Workspace file tree that loads lazily, a syntax-coloured source viewer for
  files, file-type icons, and chat file links that open in the viewer.
- Git review surface that shows every changed file in one diff.
- Markdown workspace images render inline and zoom in a full-bleed viewer;
  Markdown files render in workspace previews.
- Tasks list rebuilt as an agenda with filters, row actions, and recent runs
  across all tasks; Task Detail redesigned with per-task run history and a
  model, provider, and profile picker.
- Insights rebuilt as a Usage screen with a window chart.
- Session rows show Approval, Input, and Working states, and search results
  show why they matched.
- `/clear` clears the session's server-side history.
- Settings > Default Model and Default Profile share the composer's model
  picker; Providers gets matching glyphs and list chrome.
- The clarification card pins above the composer.
- Attachments can be sent without composer text.

### Changed
- Reasoning effort changes are scoped to the session instead of applying
  globally.
- The "Checking stream" chip and status polls stay hidden while transport
  heartbeats are fresh.
- HTTP 403 responses surface the server's reason.

### Fixed
- Partial streams survive relaunch, foreground stream recovery no longer races
  itself, and late events after a response completes are ignored.
- Unsent composer text, attachments, and settings persist as drafts.
- The default model persists with its provider and the picker exposes the full
  model catalog.
- Trusted-header and OIDC sign-in report their real state, and stale auth
  status is invalidated when the URL or headers change during onboarding.
- Incoming shares are transactional and no longer leave half-staged imports.
- "Working for" and "Worked for" count from the server's turn start.
- Transcript scroll position survives reloads and disclosure toggles, and
  auto-follow is an explicit latch.
- CLI and messaging sessions can be continued from the app, and duplicating a
  session uses the server's duplicate endpoint instead of branching.
- Kanban restores the browsed Board per server after relaunch, and the Board
  picker stays visible for long Board names.
- Server First dictation runs until the user stops it, and oversized
  transcription uploads are rejected before they fail.
- Inline assignment math renders correctly.
- Streaming thinking stays responsive, cached-message lookups are batched, and
  settled Markdown math layouts are cached.

## [1.5.0] - 2026-08-04

### Added
- Kanban boards: browse cards by status column, view card detail with comments
  and operational history, create and edit cards, move cards through their
  workflow, act on many cards at once with accessible bulk actions, manage
  boards with shared active-board controls, preview and run the dispatcher from
  a toolbar sheet, and stay current through live updates with offline
  reconciliation.
- Settings toggles to hide unused parts of the app: session-list entries
  (Tasks, Kanban, Skills, Memory, Insights, Active Profile, Projects) and chat
  controls (Files button, Git actions). Everything stays visible by default.
- Opt-in response speed metrics.
- Public open-source release of the Hermex codebase.

### Fixed
- Interrupted backend streams now recover instead of stalling the response.
- Opening a transcript no longer jitters.
- Reopening a chat bounds the cached transcript instead of loading it all.
- Deep-linked sessions no longer lose the race to last-session restore.
- The file browser keeps the latest directory navigation.
- The session list refreshes after returning from a new chat.
