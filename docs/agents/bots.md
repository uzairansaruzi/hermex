# Bot Mode

Bots use the selected configured Hermex server's optional direct-Hermes connection.
The connection is a separate Hermes Desktop HTTP/WebSocket backend, not webui.
The connection record, credentials and stable UUID live in server-scoped Keychain
storage. A different endpoint or username gets a new UUID. Password/name edits
retain the identity. Removing the connection deletes its drafts; removing the
configured server deletes both its connection and all its drafts.

`BotClient` owns an ephemeral cookie session and one WebSocket. HTTP paths live in
`BotEndpoint`. Password login requires the basic auth gate, verifies identity,
and mints a fresh single-use ticket for each socket. JSON-RPC uses text frames
with the `hermes-gateway-v1` and ticket subprotocols. There is no bootstrap-token,
OAuth, webui fallback, server provisioning or competing-backend path.

`BotConversation` owns one server/connection/Profile view lifetime. It resolves
exact-title Bot Chat, keeps canonical root, compression tip and runtime IDs
separate, and rejects a changed root before resume. Lookup can recover archived
history; resume can auto-continue unfinished backend work. Neither is guaranteed
to be read-only. Approvals remain in Desktop.

History is memory-only. Open/recovery replaces it from a full resume snapshot.
Replay detects discontinuity but never appends text to an overlapping snapshot.
Live events coalesce inflight snapshot reads using `omit_messages`; that installed
handler path avoids history database reads. Completion and session-state events
request full history. There is no transcript cache or speculative REST adapter.
Socket loss shows disconnected/unknown. Foreground and explicit reconnect reload
canonical identity, history and current state before enabling commands.

Bot drafts extend `ChatDraftStore` with server + connection UUID + Profile context.
Before sending, the client flushes an unresolved marker to disk. An acknowledged
send consumes the draft; explicit admission failures preserve its text. An
ambiguous outcome stays held across navigation and relaunch. The user can check
Desktop and explicitly discard the held text; that action never resends it.
Identical text in recovered history cannot reliably attribute a submission.

Stop affects current conversation work, including Desktop work, queued prompts,
pending approvals and process-wide speech playback. Confirmation actions carry
connection-generation and turn-revision guards and are single-use. No Stop retry
occurs after disconnect. Acknowledgement alone does not establish completion;
current idle does. The accepted server race remains: a Stop already sent may reach
later Desktop work because the ordinary RPC has no expected-turn guard.

New Bot code belongs only to the main app and XCTest target. Share-extension,
App Intent, deep-link and Live Activity commands still route to webui sessions.
The Sessions/Bots switch returns to Sessions for existing external entry points.

The implementation issue links the installed contract evidence, signed-build and
test results, and remaining manual gates. Physical-phone transport, native
accessibility and integrated live behavior must be validated before declaring
the MVP complete. Simulator or isolated fixtures are not physical-phone evidence.
