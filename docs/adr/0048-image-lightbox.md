# 0048. Image lightbox

Area: chat-transcript

## Open the lightbox pager with a unit-point anchor

`ImageLightboxPager` opens on the tapped page through a computed start anchor: across n pages, page i sits at unit point i / (n - 1). Its stack is not lazy, and the starting `scrollPosition` id alone does not move a stack that is not lazy.

Lives in: `HermesMobile/Features/Chat/ImageLightboxPager.swift`

## Limit the lightbox dismiss pan to one finger

`ZoomableImageView`'s dismiss pan sets `maximumNumberOfTouches = 1`, so a two-finger pinch that drifts downward stays a zoom instead of closing the viewer.

Lives in: `HermesMobile/Features/Chat/ImageLightboxView.swift`

## Run the dismiss pan alongside the scroll pan only

At fit scale the scroll view's own pan has nothing to scroll, so `ZoomableImageView`'s coordinator lets the dismiss pan recognize simultaneously with it, which avoids a `require(toFail:)` delay on every touch. Nothing else pairs with the dismiss drag: sharing with the pinch would let a zoom and a dismiss animate the same image view at once.

Lives in: `HermesMobile/Features/Chat/ImageLightboxView.swift`

## Leave a zoomed image's transform to the scroll view

When a dismiss drag in `ZoomableImageView` is cancelled while the scroll view is zoomed, the image view's transform is not reset. Once zoomed, the transform belongs to the `UIScrollView`; resetting it would snap the image back to fit while `zoomScale` still says otherwise.

Lives in: `HermesMobile/Features/Chat/ImageLightboxView.swift`
