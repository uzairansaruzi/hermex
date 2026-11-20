# 0053. Right-to-left chat layout

Area: chat-transcript

## Use natural text alignment in wrapped UITextViews

A `UITextView` wrapped for SwiftUI does not inherit SwiftUI's `layoutDirection`. The message text view sets `textAlignment = .natural` so each paragraph aligns by its own writing direction: RTL message text reads right-aligned while LTR stays left-aligned (#294).

Lives in: `HermesMobile/Features/Chat/ChatMessageActions.swift`

## Force left-to-right for code, math and tool bodies in RTL chats

`ForcedLeftToRightModifier` pins a subtree to left-to-right regardless of the chat's layout direction, so code, math, data tables, tool-call bodies, file paths and images never render mirrored inside an RTL message (#259). A fixed `layoutDirection` also isolates the subtree's bidi resolution from the parent paragraph direction. An RTL parent still places the view by its own leading edge, on the right; the alignment guides must not be remapped for it, because flipping them lines siblings up edge to edge and stretches the column off-screen (#1068).

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Lay out math left-to-right in RTL chats

Math and LaTeX are read left-to-right regardless of the chat direction (#259). `DisplayMathView` applies `forcedLeftToRight()`, since mirroring would reverse equations inside an RTL message.

Lives in: `HermesMobile/Features/Chat/DisplayMathView.swift`

## Re-clamp the transcript's horizontal offset on content-width changes under RTL

`ChatVerticalScrollAxisGuardView` pins the vertical-only transcript's horizontal offset to its layout-direction-aware leading edge. Under RTL that rest offset depends on `contentSize.width`, so a width change (a wide table or streaming code block loading) re-clamps immediately instead of waiting for the next offset or bounds change (#259).

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`
