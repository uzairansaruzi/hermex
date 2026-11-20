# 0113. Screen streaming

Area: performance

## Write Screen frames straight to a layer, bypassing SwiftUI

`ScreenFrameStore` holds the newest picture and hands it straight to the layer on screen, so a remote-screen frame never runs or invalidates SwiftUI. A layer that attaches later, or again, shows the last picture. `ScreenCanvas` hosts that layer; it fits the view and never asks the desktop to resize.

Lives in: `HermesMobile/Features/Screen/ScreenCanvas.swift`, `HermesMobile/Features/Screen/ScreenSession.swift`

## Keep one screen frame in flight

`RFBClient` delivers frames to `onFrame` off the main actor and waits for `onFrame` before asking for the next update, so one frame is ever in flight and a slow phone slows the server rather than filling a buffer.

Lives in: `HermesMobile/Networking/Screen/RFBClient.swift`

## Coalesce pending Screen pointer moves

`ScreenInputQueue` holds input waiting for the socket, in order. A pointer move replaces a move still waiting with the same buttons, and whatever piled up during a send goes out as one frame, so a fast finger on a slow link falls behind by one position rather than by a queue. Keys and clicks are never dropped.

Lives in: `HermesMobile/Features/Screen/ScreenInput.swift`
