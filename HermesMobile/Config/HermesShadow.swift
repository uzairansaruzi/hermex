import SwiftUI

enum HermesShadow {
    case none
    case controlSubtleResting
    case controlSubtlePressed
    case controlElevatedResting
    case controlElevatedPressed
    case popover
    case chrome
    case overlay

    struct Resolved: Equatable {
        let opacity: Double
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    func resolved(for colorScheme: ColorScheme) -> Resolved {
        let isDark = colorScheme == .dark
        switch self {
        case .none:
            return Resolved(opacity: 0, radius: 0, x: 0, y: 0)
        case .controlSubtleResting:
            return Resolved(opacity: 0.12, radius: 4, x: 0, y: 1)
        case .controlSubtlePressed:
            return Resolved(opacity: 0.06, radius: 1, x: 0, y: 0)
        case .controlElevatedResting:
            return Resolved(opacity: isDark ? 0.32 : 0.18, radius: 16, x: 0, y: 8)
        case .controlElevatedPressed:
            return Resolved(opacity: isDark ? 0.18 : 0.10, radius: 8, x: 0, y: 3)
        case .popover:
            return Resolved(opacity: 0.14, radius: 12, x: 0, y: 4)
        case .chrome:
            return Resolved(opacity: isDark ? 0.28 : 0.12, radius: 14, x: 0, y: 6)
        case .overlay:
            return Resolved(opacity: 0.22, radius: 18, x: 0, y: 12)
        }
    }
}

private struct HermesShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let token: HermesShadow

    func body(content: Content) -> some View {
        let r = token.resolved(for: colorScheme)
        // The one intentional `.shadow(` call this family's own implementation introduces — SH-2's
        // completeness gate excludes this file by name rather than treating this line as a residual.
        return content.shadow(color: Color.black.opacity(r.opacity), radius: r.radius, x: r.x, y: r.y)
    }
}

extension View {
    func hermesShadow(_ token: HermesShadow) -> some View {
        modifier(HermesShadowModifier(token: token))
    }
}
