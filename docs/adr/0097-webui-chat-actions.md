# 0097. webui approvals and Listen

Area: networking-webui

## Clear an approval card only on an explicit ok

webui's protective approval refusals answer HTTP 200 with `{"ok": false}` (`_handle_approval_respond` in `api/routes.py` @ 399cd7ab, whose `j()` helper defaults to 200). Treating only a non-2xx as failure read a deliberate refusal as success: the card was cleared with no explanation, the agent stayed blocked, and the next pending refresh made the card reappear. `ChatPendingActionCoordinator` clears a live card only when `ok == true` or `stale_cleared == true`, the one false that still means the card is finished; a missing `ok` is unknown and fails closed with an error and a pending refresh.

Lives in: `HermesMobile/Features/Chat/ChatPendingActionCoordinator.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Route over-cap Listen text to the on-device voice

`ServerTTSPolicy.maximumTextLength` is the server-enforced request cap: `/api/tts` answers `400 text too long` above it. Longer text goes straight to the on-device synthesizer; chunking is a non-goal (#15).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Always send an explicit TTS voice

The server's own default voice is `zh-CN-XiaoxiaoNeural`, so the client always sends `ServerTTSPolicy.defaultVoice`. A voice picker is a non-goal of #15; the default is the one the issue specified, verified live 2026-07-02.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
