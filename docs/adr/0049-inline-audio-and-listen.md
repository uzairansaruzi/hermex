# 0049. Inline audio and Listen

Area: chat-transcript

## Reset an audio load cancelled by scrolling

A cancelled `.task` (for example the row scrolled off-screen mid-load) surfaces as a `nil` result in `InlineAudioPlayerModel.loadIfNeeded`. It is not treated as a real failure: the model resets to idle with its load key cleared, so the player can load again if the view reappears instead of being stuck on the error state forever.

Lives in: `HermesMobile/Features/Chat/InlineAudioPlayerView.swift`

## Release the audio session on pause

`InlineAudioPlayerModel` releases the shared `AVAudioSession` (`deactivateSession`, `.notifyOthersOnDeactivation`) on a manual pause too, so an audio app Hermex interrupted (Spotify, Podcasts) is told it can resume instead of staying blocked until the view disappears. If another clip takes over, its `activateSession()` immediately reclaims the session. If another clip is still playing, iOS refuses to deactivate a session with running I/O, so this never cuts off an active clip.

Lives in: `HermesMobile/Features/Chat/InlineAudioPlayerView.swift`

## Schedule the audio ticker in common run loop mode

`InlineAudioPlayerModel` adds its progress timer to the main run loop in `.common` mode so it keeps firing while the transcript is scrolling.

Lives in: `HermesMobile/Features/Chat/InlineAudioPlayerView.swift`

## Route Listen through the playback category

`ListenAudioSessionConfiguration` uses the `.playback` category, which forces the speaker rather than the receiver (earpiece) by default, and the `.spokenAudio` mode, Apple's recommended mode for synthesized speech (#252).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Activate the Listen audio session only when playback starts

Tapping Listen must not activate the audio session: a slow `/api/tts` fetch, or the on-device render, would otherwise silence other audio while Hermex has nothing to play (review on #35 and #332). Activation belongs to the moment decoded audio is about to play, and the session is never held while the on-device render runs. A failed server attempt hands the session back before the render runs, so other audio isn't held silent and the loading bar never shows the failed audio's length.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Resend Now Playing after a mid-play rate change

iOS shows Now Playing as Stopped right after a mid-play playback-rate change, so the Lock Screen would offer a dead play button. `ChatViewModel.setListenPlaybackSpeed` sends Now Playing again once that settles (`listenSpeedChangeSettleDelay`).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`

## Measure Hermes TTS length in Unicode scalars

A Hermes host splits text by Python's `len`, which counts Unicode scalars. `ServerTTSPolicy.shouldUseServerTTS` therefore measures a reply on a Hermes host in scalars, not Swift's `count`, so a reply whose characters combine several scalars ("é" as e + U+0301) is measured as the host measures it.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`, `HermesMobileTests/ChatViewModelSendTests.swift`
