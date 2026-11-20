# 0017. @ file references and mentions

Area: chat-composer

## Reload the @ panel only after the host applies a workspace move

A session's workspace can be switched underneath a chat (`/workspace`, or the composer's workspace picker) without the session id changing, and a folder listed against the old root says nothing about the new one. The view model tells `FilePathSearch` to forget every listing the moment the workspace moves. `reloadingOpenQuery` asks an open panel to load its query again only for a move the host already applied, such as a Hermes chat's folder move that `session.info` reports. A webui switch is optimistic: `/api/list` still answers from the old root until the server applies it, so an open `@` panel must not reload on it (#1113).

Lives in: `HermesMobile/Features/Chat/FilePathSearch.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Never offer @ paths containing whitespace

`FilePathSearch` drops anything a reference cannot name: an entry the server marked as a symlink pointing outside the workspace, any path with a `..` component, and any path containing whitespace. The whitespace rule is the reference syntax's, not the filesystem's: the only form verified against upstream is `@` plus the plain path followed by a space, so the space inside `My File.swift` ends the reference. Such a path would insert and then never read back as one, so it is not offered.

Lives in: `HermesMobile/Features/Chat/FilePathSearch.swift`

## Rescan file chip references on every transcript swap

A cache-first transcript swapped for the server's copy can rewrite a message in the middle of the list without changing the count or the last id. `ChatViewModel` bumps `transcriptRevision` on the swap, and `ChatView` keys its file chip rescan on it alongside `messages.count`, so the swap itself is the signal.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobile/Features/Chat/ChatView.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Offer @mentions only in Bot Chat

The host delivers `@`mentions only in a Bot Chat (`tools/bot_mode_dm.py`), so the composer offers them only there.

Lives in: `HermesMobile/Features/Chat/HermesSlashCommands.swift`

## Send Bot Chat mentions as a note after the prompt

A Bot Chat's mentions travel as Desktop's note after the prompt, resolved from the typed text only (`mentions.annotation(for:)`). The chat shows the prompt without the note (#523).

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`
