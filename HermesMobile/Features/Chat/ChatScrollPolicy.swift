import CoreGraphics
import Foundation
import SwiftUI

/// Pure decision rules for the chat transcript's auto-scroll behavior.
///
/// Auto-follow is an explicit latch driven by scroll gestures rather than a
/// distance test: touching the transcript switches it off, and only a gesture
/// that settles at the true bottom, a scroll-to-bottom tap, or a send switches
/// it back on. Layout growth from streaming tokens never flips the latch on its
/// own, so a reader parked above the end stays parked. The distance thresholds
/// below only drive the scroll-to-bottom button and the reading-older chrome.
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

    /// Extra distance past the bottom threshold required before the composer
    /// chrome collapses into its compact "reading older" presentation.
    static let readingOlderHysteresis: CGFloat = 64

    /// Strict bottom tolerance (pt) that re-arms follow when a gesture ends there.
    static let followReArmThreshold: CGFloat = 12

    /// How long a finished drag waits for momentum to announce itself before the
    /// release position is treated as final. Finger-lift velocity is not a
    /// reliable signal: a gentle fling can report zero and still decelerate.
    static let dragSettleDelay: TimeInterval = 0.16

    /// Gap between momentum ticks that means deceleration has stopped.
    static let momentumSettleDelay: TimeInterval = 0.05

    /// How long the bottom size-change anchor stays suspended after a disclosure
    /// toggle. Covers the disclosure animation plus a frame, since the row's
    /// height changes on every frame of that animation.
    static let disclosureAnchorSuspension: TimeInterval = 0.25

    /// Scroll-gesture events that drive the follow latch.
    enum FollowEvent: Equatable {
        /// An explicit jump to the latest content: scroll-to-bottom tap or send.
        case reset
        /// The user started dragging the transcript.
        case userScrollBegin
        /// The user's gesture settled: a drag with no momentum after
        /// `dragSettleDelay`, or deceleration coming to rest.
        case userScrollEnd(isAtBottom: Bool)
        /// The content offset changed for any other reason: streaming growth,
        /// keyboard presentation, a programmatic scroll, or a live gesture.
        case contentScrolled(isAtBottom: Bool, isUserScrolling: Bool)
    }

    /// Reduces one event onto the current latch state.
    static func resolveFollow(current: Bool, event: FollowEvent) -> Bool {
        switch event {
        case .reset:
            return true
        case .userScrollBegin:
            return false
        case .userScrollEnd(let isAtBottom):
            return isAtBottom
        case .contentScrolled(let isAtBottom, let isUserScrolling):
            if isUserScrolling {
                return false
            }
            return isAtBottom ? true : current
        }
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

    /// True once the user has scrolled far enough above the bottom that the
    /// composer chrome should collapse. The hysteresis keeps the chrome stable
    /// when hovering right around the bottom threshold.
    static func shouldEnterReadingOlder(distanceFromBottom: CGFloat, isStreaming: Bool) -> Bool {
        distanceFromBottom > bottomThreshold(isStreaming: isStreaming) + readingOlderHysteresis
    }
}

/// Transcript disclosure controls (reasoning blocks, tool cards, tool groups)
/// call this right before they toggle so the transcript can suspend its bottom
/// anchor and keep the tapped row stationary through the size change.
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
