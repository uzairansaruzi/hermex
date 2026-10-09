import CoreGraphics

enum HermesRadius {
    static let r0: CGFloat = 0
    static let r4: CGFloat = 4
    static let r8: CGFloat = 8
    static let r12: CGFloat = 12
    static let r16: CGFloat = 16
    static let r20: CGFloat = 20
    static let r24: CGFloat = 24

    static let control: CGFloat = r8
    static let field: CGFloat = r12
    static let card: CGFloat = r16
    static let prominent: CGFloat = r20
    static let chrome: CGFloat = r24
    // No .full or .pill member. A fully-rounded edge is `Capsule()`, used directly at its
    // existing call sites — a platform-owned shape, not a HermesRadius numeric value. Enforced by
    // scripts/hermex_radius_full_pill_audit.py, not a comment.
}
