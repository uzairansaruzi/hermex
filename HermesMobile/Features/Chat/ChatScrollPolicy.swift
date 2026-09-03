import CoreGraphics
import Foundation
import SwiftUI

/// Pure decision rules for the chat transcript's auto-scroll behavior.
///
/// Auto-follow is an explicit latch rather than a distance test.
///
/// Follow switches **off** when a drag begins, when a live gesture moves the
/// offset, or when a scroll with no gesture carries the reader away from the
/// bottom (a status-bar tap, VoiceOver, or a hardware-keyboard scroll).
///
/// Follow switches **on** when a scroll-to-bottom tap or a send resets it, when
/// a gesture settles at the true bottom, or when a non-gesture offset change
/// lands at the true bottom from nearby (a collapse near the end clamping the
/// offset). Landing at the bottom from far above is a relayout artifact, never
/// a reason to follow.
///
/// Layout growth from streaming tokens and keyboard inset changes never flip
/// the latch on their own, so a reader parked above the end stays parked. The
/// distance thresholds below drive the scroll-to-bottom button, the
/// reading-older chrome, and how far a gesture-free scroll must carry the
/// reader before it counts as leaving.
enum ChatScrollPolicy {
    /// Existing transcripts should enter at their latest content as part of the
    /// scroll view's first layout, before the destination becomes visible.
    static let initialTranscriptAnchor = UnitPoint.bottom

    /// Rich Markdown can finish measuring after the scroll view's initial
    /// layout. Keep those size changes bottom-pinned only while follow is
    /// latched on and no disclosure toggle is settling; otherwise return nil so
    /// the reader's offset, and the row they just tapped, stay where they are.
    static func sizeChangeAnchor(
        shouldFollowLatestMessage: Bool,
        isDisclosureSettling: Bool = false
    ) -> UnitPoint? {
        shouldFollowLatestMessage && !isDisclosureSettling ? .bottom : nil
    }

    /// Distance (pt) from the bottom within which the scroll-to-bottom button
    /// stays hidden while idle.
    static let bottomDetectionThreshold: CGFloat = 80

    /// Looser bottom threshold while a response is streaming, so small layout
    /// jitter from incoming tokens does not flash the scroll-to-bottom button.
    static let streamingBottomDetectionThreshold: CGFloat = 160

    /// Strict bottom tolerance (pt) that re-arms follow when a gesture ends there.
    static let followReArmThreshold: CGFloat = 12

    /// How long a finished drag waits for momentum to announce itself before the
    /// release position is treated as final. Finger-lift velocity is not a
    /// reliable signal: a gentle fling can report zero and still decelerate.
    static let dragSettleDelay: TimeInterval = 0.16

    /// Gap between momentum ticks that means deceleration has stopped.
    static let momentumSettleDelay: TimeInterval = 0.05

    /// How long follow scrolls and the bottom size-change anchor stay suspended
    /// after a disclosure toggle. Covers the disclosure animation plus a frame.
    static let disclosureAnchorSuspension: TimeInterval = 0.25

    /// The offset pin armed by a disclosure toggle releases once the content
    /// size has been quiet this long. Lazy rows can keep laying out well past
    /// the animation, and SwiftUI re-applies the bottom anchor on each of those
    /// size changes after a status-bar scroll, so a fixed window is not enough.
    static let disclosureHoldQuietPeriod: TimeInterval = 0.3

    /// Upper bound on the pin, so a transcript that never goes quiet (streaming
    /// tokens) still returns to normal scrolling.
    static let disclosureHoldMaximum: TimeInterval = 2

    /// Scroll-gesture events that drive the follow latch.
    enum FollowEvent: Equatable {
        /// An explicit jump to the latest content: scroll-to-bottom tap or send.
        case reset
        /// The user started dragging the transcript.
        case userScrollBegin
        /// The user's gesture settled: a drag with no momentum after
        /// `dragSettleDelay`, or deceleration coming to rest. Re-arms at the
        /// bottom; elsewhere it keeps whatever the latch already is, so a
        /// send or scroll-to-bottom tap that landed while the gesture was
        /// still settling is not undone by the late settle report.
        case userScrollEnd(isAtBottom: Bool)
        /// The content offset changed for any other reason: streaming growth,
        /// keyboard presentation, a programmatic scroll, or a live gesture.
        /// `movedAwayFromBottom` marks a scroll with no gesture that carried
        /// the reader away from the bottom (see `isScrollingAwayFromBottom`);
        /// `wasNearBottom` is where the previous report left the reader.
        case contentScrolled(
            isAtBottom: Bool,
            isUserScrolling: Bool,
            movedAwayFromBottom: Bool = false,
            wasNearBottom: Bool = true
        )
    }

    /// The scroll geometry one metrics report is derived from.
    struct ScrollGeometry: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var visibleHeight: CGFloat

        var distanceFromBottom: CGFloat {
            max(0, contentHeight - visibleHeight - offsetY)
        }
    }

    /// True when a report without a gesture shows the reader farther from the
    /// bottom than the last one, past the streaming threshold, in the same
    /// viewport. While follow is on the bottom anchor snaps every size change
    /// back to zero distance, so only an actual scroll (status-bar tap,
    /// VoiceOver, hardware keyboard) can move the reader out that far. Keyboard
    /// insets change the viewport and are excluded; the scroll observer
    /// suppresses the check while a disclosure pin holds the offset.
    static func isScrollingAwayFromBottom(previous: ScrollGeometry?, current: ScrollGeometry) -> Bool {
        guard let previous, previous.visibleHeight == current.visibleHeight else { return false }
        let distance = current.distanceFromBottom
        return distance > previous.distanceFromBottom + 0.5
            && distance > streamingBottomDetectionThreshold
    }

    /// The follow latch. `isFollowing` is the answer; the second flag lets an
    /// explicit reset outlive a gesture that was still coasting when it landed.
    struct FollowLatch: Equatable {
        var isFollowing = true
        /// Set by `.reset`. Until the gesture settles or a new drag begins, live
        /// offset changes still flagged as user scrolling belong to momentum
        /// that predates the explicit action and must not switch follow off.
        var ignoresCoastingGesture = false
    }

    /// Reduces one event onto the current latch state.
    static func resolveFollow(current: FollowLatch, event: FollowEvent) -> FollowLatch {
        var latch = current
        switch event {
        case .reset:
            latch.isFollowing = true
            latch.ignoresCoastingGesture = true
        case .userScrollBegin:
            latch.isFollowing = false
            latch.ignoresCoastingGesture = false
        case .userScrollEnd(let isAtBottom):
            latch.isFollowing = isAtBottom || current.isFollowing
            latch.ignoresCoastingGesture = false
        case .contentScrolled(let isAtBottom, let isUserScrolling, let movedAwayFromBottom, let wasNearBottom):
            if isUserScrolling {
                if !current.ignoresCoastingGesture {
                    latch.isFollowing = false
                }
            } else if movedAwayFromBottom {
                latch.isFollowing = false
            } else if isAtBottom, wasNearBottom {
                latch.isFollowing = true
            }
        }
        return latch
    }

    static func isAtBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= followReArmThreshold
    }

    static func bottomThreshold(isStreaming: Bool) -> CGFloat {
        isStreaming ? streamingBottomDetectionThreshold : bottomDetectionThreshold
    }

    static func isNearBottom(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom <= bottomThreshold(isStreaming: isStreaming)
    }
}

/// Transcript disclosure controls (reasoning blocks, tool cards, tool groups,
/// turn folds) call this right before they toggle so the transcript can pin
/// the reader's offset and suspend follow scrolls through the size change.
struct ChatDisclosureToggledKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var chatDisclosureToggled: () -> Void {
        get { self[ChatDisclosureToggledKey.self] }
        set { self[ChatDisclosureToggledKey.self] = newValue }
    }
}

/// Keeps transcript reconciliation and other state-heavy startup work out of
/// the system navigation transition. Cache preparation remains synchronous so
/// an available transcript can participate in the destination's first layout.
enum ChatInitialAppearancePolicy {
    static func shouldBeginAsyncWork(hasCompletedAppearance: Bool) -> Bool {
        hasCompletedAppearance
    }
}
