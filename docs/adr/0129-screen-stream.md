# 0129. Screen stream

Area: screen

## Send no input before the RFB handshake finishes

The host's filter reads the first 14 client bytes of the screen stream as the handshake, so a key sent before the handshake is done would corrupt it. `ScreenSession` gates input on `isStreamReady`, which is set only once the handshake completes.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Treat a refused gateway join as final

In `ScreenSession.streamOnce`, `BotFailure.stale` from `client.connect()` means the connection was replaced: only a replaced connection refuses to join, and this client can never reach the host again, so the session settles to `.failed`. A `.stale` from a call is only a socket lost between calls, which a retry fixes. The two must not be handled the same way.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Map a host's 4001 close to a capture failure

Close code 4001 means a bot's screen stopped, but a host's desktop has no such state: there its capture failed, and the next status read usually says why. `ScreenStreamOutcome` maps 4001 to `.settled(.stopped)` for `.botDesktop` and to `.captureFailed` for `.hostDesktop`.

Lives in: `HermesMobile/Features/Screen/ScreenSession.swift`

## Inflate Tight data last in a decoder step

`RFBDecoder.readTightData` takes a rectangle's pixel data as it is when it is under 12 bytes, and otherwise inflates it on its persistent zlib stream. Tight's stream-reset bits apply there, once every byte has arrived, and inflating is the last thing the step does. A step that runs out of bytes is run again on the next chunk, so inflating earlier would feed the stream the same bytes twice.

Lives in: `HermesMobile/Networking/Screen/RFBDecoder.swift`

## Drain zlib input after each Tight rectangle

`RFBInflater.drain` reads what follows the pixels in a block. The output can fill before the end of the server's sync flush, and input left unread would be missing from the next rectangle's data on the same persistent stream.

Lives in: `HermesMobile/Networking/Screen/RFBDecoder.swift`
