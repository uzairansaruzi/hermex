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

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}
