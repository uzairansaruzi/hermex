# 0027. Composer voice input

Area: chat-composer

## Tell mic tap from hold by timing with one DragGesture

`ComposerVoiceControlButton.pressGesture` uses a single `DragGesture(minimumDistance: 0)`. Touch-down schedules a delayed `DispatchWorkItem` that starts a voice note; a release before it fires cancels it and counts as a tap, which starts dictation. Composing `LongPressGesture`, `TapGesture`, and `highPriorityGesture` was far less reliable because the press kept claiming the touch and the tap never won. Because the delay is timer-driven, not movement-driven, a perfectly still hold still records.

Lives in: `HermesMobile/Features/Chat/ChatComposerVoiceControls.swift`

## Handle VoiceOver activation of the mic explicitly

VoiceOver synthesizes an activation rather than a real touch, so the `DragGesture` tap path never fires for it. `ComposerVoiceControlButton` adds an `accessibilityAction` that calls `onTap()`, and a separate named "Record voice note" action covers the hold, which VoiceOver cannot perform.

Lives in: `HermesMobile/Features/Chat/ChatComposerVoiceControls.swift`

## Cancel an in-flight voice note when the app backgrounds

Backgrounding stops `ComposerVoiceNoteRecorder`'s run-loop ticker. When the scene leaves `.active`, `ChatComposerView` calls `cancelVoiceNote()` rather than leave the recording silently stalled.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`

## Leave the audio session alone while dictation captures the mic

Switching the shared `AVAudioSession` to `.playback` would tear down composer dictation's live recording engine. `ListenAudioSessionController.activate` returns early when `ComposerAudioCaptureState.shared.isCapturing`, mirroring the same guard in `InlineAudioPlayerView` so the two playback paths stay consistent.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Record server STT as 24 kHz mono AAC at 48 kbps

`ComposerVoiceInputController.serverRecordingSettings` records mono AAC tuned for server speech-to-text (#1355). At 44.1 kHz a 32 kbps encode spread its bits over a band speech models discard, and server STT dropped noticeably more words than on an Opus voice note of the same speech; 24 kHz keeps the speech band and 48 kbps there matched the voice note. At about 22 MB per hour recording runs until the user stops it, and past the upload ceiling (about 55 minutes) the byte guard takes over.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`

## Cap server STT uploads at 19 MiB

`maximumServerRecordingUploadBytes` is 19 MiB, leaving 1 MiB below webui's configurable 20 MiB default for the multipart envelope. A lower custom server limit still goes through the existing fallback. A Hermes host takes up to 25 MiB of decoded audio (#1071).

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`

## Treat an empty successful transcript as silence

A Hermes host answers silence with `{ok: true, transcript: ""}` (#1071). When server transcription returns an empty transcript that reports success, `ComposerVoiceInputController` inserts nothing and reports no failure. webui's transcriber drops `ok` from an empty reply, so on webui an empty transcript still takes the failure fallback.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`

## Keep Locale.current first when choosing a dictation locale

`ComposerSpeechLocalePolicy` keeps `Locale.current` (app language plus device region) as the first candidate, so users whose dictation already works keep the same recognizer. The user's preferred languages and `en-US` follow to cover regions whose pairing has no on-device model, such as `en_PK`.

Lives in: `HermesMobile/Features/Chat/ComposerVoiceInputController.swift`

## Send voice notes with the bare transcript as text

`ChatViewModel.sendVoiceNote` sends the bare transcript as the API message text, not `PendingAttachment.chatMessageText(...)`, which would append an "[Attached files: <clip>.m4a]" suffix. The webui server strips attachment metadata before the model call and never embeds audio, so that suffix is the agent's only signal about a non-image attachment and makes it try to inspect or transcribe the clip instead of answering the transcript (#330). The clip still rides in `messageAttachments` and `apiPayloads` purely so the inline player renders and persists; it never reaches the model.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
