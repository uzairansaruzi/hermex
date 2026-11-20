# 0043. Chat screen lifecycle

Area: chat-transcript

## Count on-screen ChatViews in ChatContinuity instead of naming one owner

An iPad window crossing compact and regular width, or an iPhone Duo folding, swaps the navigation stack for the split view, and SwiftUI makes a new `ChatView` in the other branch (#1528). Whoever says which chat is open holds a `ChatContinuity` for as long as it is open and hands it to the `ChatView` of either branch; the new view takes the old one's model, with its loaded history, its stream, its follow latch, and the reader's place in the transcript. SwiftUI gives no order to the swap: the new view can appear before or after the old one leaves, and a split view can build an extra `ChatView` that appears and leaves while another stays on screen. So `ChatContinuity` counts the views on screen rather than naming one owner.

Lives in: `HermesMobile/Features/Chat/ChatTranscriptSupportingViews.swift`

## Detect navigation push completion through UIKit viewDidAppear

`NavigationStack` does not expose push completion directly. `NavigationAppearanceCompletionObserver` is a `UIViewControllerRepresentable` that reports the first completed UIKit appearance transition for a SwiftUI destination, because `viewDidAppear` and the transition coordinator stay synchronized with the system animation speed.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Fold the previous turn when a new stream starts, not in the stream handler

A new turn starting folds the previous one, even one that opened itself after failing or being stopped. `ChatView` removes the previous turn's key from `viewModel.expandedTurnKeys` in `.onChange(of: viewModel.activeStreamID)`, not in `handleActiveStreamChange`, because a rebuilt view also runs that handler as it appears, with the same turn still going.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`
