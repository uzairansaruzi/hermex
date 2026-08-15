import SwiftUI

enum ChatMotion {
    static func press(duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: duration, extraBounce: 0)
    }

    static func quickState(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.10) : .easeInOut(duration: 0.16)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.10) : .smooth(duration: 0.18, extraBounce: 0)
    }

    // MARK: - Card disclosure (orchestrated two-axis reveal)
    //
    // Opening a card is three overlapping phases, not one event:
    //
    //   0ms ─── chrome widens (horizontal) ──▶ 220ms
    //         120ms ─── height expands (vertical) ──────▶ 460ms
    //                     240ms ─── rows fade in, staggered ──▶
    //
    // The phases overlap deliberately. Run back-to-back they read as three
    // disconnected steps; overlapped they read as one coordinated motion. The
    // vertical phase starts while the horizontal is still settling and carries
    // most of the travel, which is why it gets the longest curve.
    //
    // Total ≈ 500ms to the last staggered row. That is the top of the drawer
    // budget: slow enough to register as a deliberate reveal, short enough not
    // to feel like waiting.

    /// Phase 1 — the chrome widening. Short; it only has to register.
    static func cardChrome(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.22)
    }

    /// Phase 2 — the height expanding. Owns the layout change and most of the
    /// perceived motion, so it gets a lightly damped spring rather than an ease.
    static func cardExpand(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: 0.34, bounce: 0.10).delay(cardVerticalLeadIn)
    }

    /// Phase 3 — contents arriving, once there is room for them.
    static func cardContent(reduceMotion: Bool, delay: Double = 0) -> Animation? {
        if reduceMotion {
            return .easeOut(duration: 0.10)
        }
        return .easeOut(duration: 0.20).delay(delay)
    }

    /// Per-row delay so an expanded card populates from the top down instead of
    /// appearing all at once.
    ///
    /// Capped deliberately: a 70-tool block staggered row-by-row would take
    /// seconds and stop reading as polish. The first rows carry the sense of
    /// the card filling; everything after arrives together.
    static func cardRowDelay(index: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        let step = 0.045
        let maxStaggeredRows = 6
        return Double(min(index, maxStaggeredRows)) * step
    }

    /// When the vertical expansion joins the horizontal one.
    static let cardVerticalLeadIn: Double = 0.12

    /// When contents start arriving — after the height is visibly underway, so
    /// they emerge from inside the opened card rather than racing its edge.
    static let cardContentLeadIn: Double = 0.24

    static func composerChrome(reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22, extraBounce: 0)
    }

    static func scrollToLatest(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    /// Bottom-follow scrolling and active-row height growth while a response
    /// streams in. Short enough to keep up with the ~48ms word-reveal cadence;
    /// each new flush retargets the previous animation so the streaming edge
    /// glides instead of stepping per flush.
    static func streamingFollow(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    static func typingIndicator(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// Transition for content revealed inside an expanding card.
    ///
    /// Explicitly **not** `.move(edge: .top)`: that slides content in from the
    /// container's top edge while the container is still only a few points
    /// tall, so the content visibly flies down through the card from above it.
    /// Scaling from a `.top` anchor expands the content downward from where the
    /// card actually opens, which is what "populating from within" means.
    static func cardContentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        // Pure opacity: any scale or offset means content animates *into*
        // position, which reads as arriving from somewhere else. Contents
        // should be laid out correctly from frame one and only fade up.
        return .opacity
    }

    /// Reveal for a tall card *body* whose insertion is committed by the same
    /// tap that drives the delayed height spring (`cardExpand`).
    ///
    /// A plain `.opacity` transition inherits that spring — including its
    /// 0.12s lead-in — so the body becomes readable while the window is still
    /// closed: the text sits at its final position, peeking through the gap,
    /// and the card then visibly drops down around it. Frame captures of the
    /// thinking-card reveal show exactly that (the "markdown flies in from the
    /// top" report).
    ///
    /// This transition owns its insertion curve instead: the fade starts at
    /// `cardContentLeadIn`, once the window is visibly opening, so the text
    /// emerges from inside the card. Removal stays on the caller's transaction
    /// so collapse runs in one beat.
    static func cardBodyRevealTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(cardContent(reduceMotion: false, delay: cardContentLeadIn)),
            removal: .opacity
        )
    }
}
