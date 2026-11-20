import SwiftUI

enum ChatMotion {
    static func press(duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: duration, extraBounce: 0)
    }

    static func quickState(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0)
    }

    static func composerChrome(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)
    }

    static func keyboard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
    }

    static func scrollToLatest(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    static func clarificationToggle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    static func freshRowTransition(isUserRow: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let insertion: AnyTransition = isUserRow ? .opacity.combined(with: .offset(y: 8)) : .opacity
        return .asymmetric(insertion: insertion, removal: .identity)
            .animation(.smooth(duration: 0.22, extraBounce: 0))
    }
}
