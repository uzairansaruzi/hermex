import SwiftUI

/// Horizontal scroller for the composer toolbar row (add, model, reasoning,
/// workspace, profile, git branch, mic, context meter). The Stop/Send circle
/// stays outside it, pinned to the row's trailing edge.
struct ComposerToolbarScroller<Content: View>: View {
    private let content: Content

    private let itemSpacing: CGFloat = 8
    private let minimumRowHeight: CGFloat = 44

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: itemSpacing) {
                content
            }
            .frame(minHeight: minimumRowHeight, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        // Horizontal only, and inert when everything fits, so the row never
        // feels draggable for no reason.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // Taps on toolbar controls must never dismiss the keyboard first.
        .scrollDismissesKeyboard(.never)
        // The toolbar sits on glass, so its edges fade through a mask.
        .horizontalOverflowFades(.mask)
    }
}
