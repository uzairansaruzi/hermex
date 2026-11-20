# 0039. SSE client

Area: chat-streaming

## Deliver SSE transport errors before shutting down LDSwiftEventSource

Reconnection is owned by the consumers (chat stream resume, approval and clarify fallback
polling), so the library must not retry on its own and `SSEClient`'s
`connectionErrorHandler` returns `.shutdown`. LDSwiftEventSource skips `handler.onError`
when that handler returns `.shutdown` (see its `dispatchError`), which left a dropped socket
silent: a long-lived monitor stream's consumer kept treating the stream as attached and
never fell back to polling or reopened it. The handler therefore calls `handler.onError`
itself so `.transportError` reaches the consumer.

Lives in: `HermesMobile/Networking/SSEClient.swift`, `HermesMobileTests/SSEClientTests.swift`

## Decode both `error` and `message` on SSE apperror

`apperror` is one of the four socket-closing frames (`stream_end`, `cancel`, `error`,
`apperror`). The API docs describe its payload as `{error, type, session, terminal_state?}`,
while the pinned upstream emits `{message, type, hint, details, …}`, so `SSEClient` decodes
both `error` and `message`. Mapping it onto `.error` reuses the existing terminal error path
(surface the message, finish the stream) unchanged.

Lives in: `HermesMobile/Networking/SSEClient.swift`

## Decode display_kind under both camelCase and snake_case keys

`ChatMessage` decoding reads `displayKind` and falls back to `display_kind`, because the
REST client decodes with snake_case conversion while the SSE `done` payload's primary path
uses a plain decoder. Dropping either key loses the steer and system display semantics on
one of the two paths.

Lives in: `HermesMobile/Models/ChatMessage.swift`
