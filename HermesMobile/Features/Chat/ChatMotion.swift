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

    /// Expanding or collapsing the clarification card above the composer. The
    /// card slides its own height past the bar's bottom edge on one ease-out
    /// clock, sized like the keyboard's; Reduce Motion snaps.
    static func clarificationToggle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// Entrance for a transcript row born moments ago: user rows fade up,
    /// assistant rows fade. The animation rides on the transition itself, so
    /// the row animates without wrapping the message append in `withAnimation`
    /// and without animating layout (the bottom anchor still snaps). Removal
    /// stays instant so an optimistic rollback never lingers. Reduce Motion
    /// disables the entrance entirely.
    static func freshRowTransition(isUserRow: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let insertion: AnyTransition = isUserRow ? .opacity.combined(with: .offset(y: 8)) : .opacity
        return .asymmetric(insertion: insertion, removal: .identity)
            .animation(.smooth(duration: 0.22, extraBounce: 0))
    }
}
