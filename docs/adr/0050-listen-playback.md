# 0050. Listen playback

Area: chat-transcript

## Toggle Listen off by listeningMessageID to debounce double taps

Tapping the message that is already listening, whether fetching server audio or playing on either engine, toggles it off. `ChatViewModel` matches on `listeningMessageID` alone, not `isSpeaking`, which also debounces rapid double taps: the second tap stops cleanly instead of firing a second speech request into webui's ~2 s `/api/tts` rate limit or stacking audio (#15).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Activate the Listen audio session only once audio is in hand

Server speech can be slow or unreachable, and activating the non-mixable playback session before the fetch would silence other audio while Hermex has nothing to play (review on #35). `ChatViewModel` does not activate it when Listen starts; `startListenAudioPlayback` activates it once decodable audio is in hand, immediately before playback, so neither the network wait nor the on-device render holds it. The session routes speech to the speaker, not the earpiece (#252). If `play()` fails, it is released again so other audio resumes while the on-device voice renders, and the loading bar is left untouched.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Resend Now Playing after a Listen speed change settles

iOS reads Now Playing's state from the audio itself, and a rate change mid-play makes it report Stopped about 60 ms later while speech carries on, so the Lock Screen would show a paused reply whose play button does nothing. `ChatViewModel` sends Now Playing again (`updateListenNowPlaying`) once that settles, after `listenSpeedChangeSettleDelay`, which puts it back to Playing.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## End Listen on an AVAudioPlayer decode error

A mid-playback decode error fires `audioPlayerDecodeErrorDidOccur` instead of, or as well as, the finish callback; without handling it the Listen state stays stuck "listening" forever. `ListenAudioPlayer` routes it to `onFinish` too. A double fire is harmless because the completion handler drops callbacks from a player that is no longer active.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## End the on-device render on didFinish, not on an empty buffer

`AVSpeechSynthesizer.write` delivers a zero-length buffer at each internal chunk boundary of a long utterance and keeps delivering audio afterwards; only `speechSynthesizer(_:didFinish:)` marks the end. A 4,210-character Spanish reply produced 21 empty buffers and 307.9 s of audio on macOS, and `didFinish` arrived right after the last buffer. Treating the first empty buffer as the end cut a long reply after its first sentence. `OnDeviceSpeechRender` ignores empty buffers and completes on `didFinish`.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
