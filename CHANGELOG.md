# Changelog

Notable changes to Hermex. Version headings correspond to App Store releases;
unreleased changes accumulate at the top. Format follows
[Keep a Changelog](https://keepachangelog.com/) with Added / Changed / Fixed /
Security sections per release.

## [Unreleased]

## [1.9.0] - Unreleased

### Added
- Lock Hermex with Face ID or the device passcode. The lock is off until
  enabled, and the app switcher hides chats while it is on.
- PDFs, Office and iWork documents, and other files Hermex can't preview open
  in Quick Look, up to 25 MB, from Files, chat file links, and attachments.
- Chat settings to dismiss the keyboard after sending and to start reading a
  completed response from its beginning.
- Press ↑ on a hardware keyboard to recall your last message; staged documents
  show a preview instead of a generic icon.
- Approval cards say what Allow session and Always allow cover.
- Push: Settings offers hermex-push plugin updates and can restart Hermes from
  the phone after one. Banners name the bot and use the phone's language.
- Bot Mode: answer password-vault, save-login, and 2FA prompts on the phone;
  open and reply inside room threads; see who is in a new group chat; copy a
  reply from its footer; and save or share a previewed attachment.
- Bot Mode: add a Hermes host as its own server from onboarding or Settings,
  with custom headers for hosts behind Cloudflare Access or another proxy.

### Changed
- Tapping a finished Live Activity removes it.
- Listen uses the server's saved text-to-speech voice and provider. Very long
  responses, or a failed server request, still fall back to on-device speech.
- Retained draft attachments share a 200 MB storage budget, reclaiming the
  oldest unused copies first.
- Bot Mode keeps its connection through Control Center and banners, and closes
  it when Hermex moves to the background.

### Fixed
- After a Hermes Agent update, sends refused until Hermes WebUI restarts
  explain the problem and offer a fix prompt instead of a raw HTTP 409.
- A long /goal notice no longer hides the newest tool calls and replies.
- Long transcript text stays behind the navigation bar instead of overlapping
  the title.
- Inline LaTeX renders sub- and superscripts and tuples accurately.
- Dictation keeps the screen awake and its orientation while recording.
- A queued keyboard dismissal no longer interrupts newer typing.
- Live Activity taps open the session on the server that owns it. A stale Bot
  activity that is waiting on you says so instead of "Not connected".
- Bot Mode: failed turns say why, a rejected password opens the sign-in form,
  sign-in errors name the real problem, withdrawn requests say why, and a
  pasted dashboard link is accepted. Reattaching mid-turn keeps the running
  turn's tool rows and reasoning. Hosts older than Hermes 0.21.3 are refused
  with an explanation.
- Push plugin updates work on current Hermes without a terminal prompt, and a
  slow plugin check no longer overwrites an update's result.

## [1.8.0] - 2026-10-01

### Added
- Long-press Send during a session run to choose Queue, Steer, or Stop and send
  for that message without changing the default.
- File-edit tool rows show added and removed line counts and expandable diffs.
  Diff and patch code blocks also highlight additions and deletions.
- Web links open in an in-app Safari sheet, and forked chats link back to their
  parent session.
- The working pill shows elapsed time, and long user messages can be folded.
- Undo a session archive from its confirmation toast. Search sessions with
  multiple words in any order, and switch chats with iPad keyboard shortcuts.
- Bot Mode: Tapback reactions that sync with Hermes Desktop, editable
  quick-reply chips, message timestamps, and Desktop sections in the inbox.
  Move bots between sections from the phone.
- Bot Mode: answer requests to connect an app, and view host status on the
  Hermes connection screen. Working bots and bots waiting for an answer sort
  first in the inbox; chat titles also show waiting and failed states.
- A notification prompt after the first run starts, and a Send Test
  Notification button in Settings for push-paired servers.

### Changed
- Chat opening, typing, streaming, and scrolling do less repeated work. Code
  highlighting runs off the main thread, transcript image caches have memory
  limits, and large workspace Markdown and diff previews render lazily.
- Bot replies use the streaming renderer, finished Bot turns fold behind a
  Worked for row, and Bot Chat uses the session chat's haptics. Working bot
  faces settle into a still pose after a short animation.
- Chat has a comfortable reading width on larger screens, clearer table edges,
  smoother Send and Stop transitions, autocomplete selection feedback, and a
  shorter landscape composer.
- Session times update while the list is idle. The list restores the last chat
  sooner, the iPad sidebar keeps its state when switching chats, and Kanban
  keeps the loaded board when returning from a card or refreshing in the
  background.
- Shared-file imports, cache writes, model picking, networking, and Live
  Activity updates use less memory or do less repeated work.
- The support link now points to memberships.

### Fixed
- Session streams wait while offline and reconnect when the network returns,
  showing Waiting for network instead of exhausting retries.
- Queued messages survive leaving a chat mid-run. A refused steering request
  no longer stops the active run.
- New chats use the selected profile; chats started from the session list
  under a project filter join that project. Sessions refresh on foregrounding.
- The composer stays above the keyboard after returning from Files, and
  dismissing a chat no longer unexpectedly restores keyboard focus. Camera
  dismissal does less work on the main thread.
- Local reply notifications name and open the right chat and include failed
  runs. Approval and question push alerts still arrive during a Live Activity,
  with Time Sensitive approval alerts supported through Focus. Denied
  notification permission is reported accurately.
- Bot approvals and questions work with Hermes 0.21.4, and app-connection
  responses use the shape expected by 0.21.4 and 0.21.5 hosts. Credential
  prompts support Password AutoFill and clear the previous request's secret.
- Bot host identity survives address changes, and tapping the Bot transcript
  dismisses the keyboard.
- Plain HTTP connections work with local hostnames and Tailscale addresses.
  On-device dictation tries the user's other languages when the current locale
  has no model.
- Session rows no longer pulse a redundant streaming dot, and transcript link
  rows avoid unnecessary redraws.
- App and share-extension privacy manifests declare required-reason APIs.

## [1.7.0] - 2026-09-24

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
