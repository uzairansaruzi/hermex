# 0163. Liquid Glass chrome

Area: ui-theming

## Keep glass on the material path inside clipped containers

Liquid Glass is composited outside the SwiftUI layer tree, so it ignores an ancestor's clip or mask and draws over neighbouring views. `adaptiveGlass(inheritsClipping:)` keeps the surface on the material fallback even when Liquid Glass is available. Controls inside a masked scroller need it.

Lives in: `HermesMobile/Features/Shared/AdaptiveGlassModifier.swift`

## Use a flat material fill for tight sidebar List row pills

The sidebar Projects "All" capsule uses a flat translucent `.appMaterial(.thinMaterial)` fill rather than Liquid Glass. The glass elevation shadow would spill past the tightly sized List row and get clipped by the next row's opaque background.

Lives in: `HermesMobile/Features/SessionList/SessionListComponents.swift`

## Use a fixed corner radius on pending-request option buttons

The iOS 26 glass style for pending approval and clarification option buttons uses `.rect(cornerRadius: 14)`, not `.capsule`. A capsule's radius grows with the button's height, so on tall multi-line options the curved ends bow inward and clip the text. A fixed radius keeps the outline clear of the label at any line count and matches the pre-iOS 26 fallbacks.

Lives in: `HermesMobile/Features/Chat/PendingRequestSurfaces.swift`

## Style the toolbar cluster only below iOS 26

`LegacyToolbarClusterStyle` adds a material capsule and padding to `ChatView`'s trailing toolbar cluster only below iOS 26, where the system supplies no pill. On iOS 26+ the navigation toolbar already renders the item inside a Liquid Glass pill: styling it again stacked a second capsule and produced a double border (#333), and our padding stretched a lone 44 pt button's round glass into an oval beside the round back button.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Leave the Chat navigation bar transparent on iOS 26+

`ChatNavigationBackground` covers the transcript behind the Chat title only before iOS 26. On iOS 26+ the bar stays transparent and relies on the transcript's native scroll-edge effect, which runs to the screen's top edge. A forced bar background stops at the bar and leaves a gap wherever no status bar sits above it, such as the folded iPhone Duo.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`
