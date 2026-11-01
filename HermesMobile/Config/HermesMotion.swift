import SwiftUI

enum HermesMotion {
    enum Duration {
        static let d0: TimeInterval = 0
        static let d100: TimeInterval = 0.1
        static let d150: TimeInterval = 0.15
        static let d200: TimeInterval = 0.2
        static let d250: TimeInterval = 0.25
        static let d300: TimeInterval = 0.3
    }

    enum Easing: Equatable {
        case enter, exit, state, spatial, emphasized, easeOut
    }

    enum Properties {
        static let opacityHidden: Double = 0
        static let opacityVisible: Double = 1
        static let scalePress: CGFloat = 0.975
        static let scaleEnter: CGFloat = 0.95
        static let distanceShort: CGFloat = 8
        static let directionEdges: [Edge] = [.top, .bottom, .leading, .trailing]
    }

    enum Springs {
        static var responsive: Animation { .spring(response: 0.30, dampingFraction: 0.70) }
        static var settle: Animation { .spring(response: 0.35, dampingFraction: 0.80) }
    }

    struct MotionBundle: Equatable {
        let duration: TimeInterval
        let easing: Easing
        let detail: String
    }

    enum Bundle {
        static let feedbackPress = MotionBundle(duration: Duration.d100, easing: .state, detail: "0.975 scale")
        static let stateChange = MotionBundle(duration: Duration.d150, easing: .state, detail: "color/opacity")
        static let contentEnter = MotionBundle(duration: Duration.d200, easing: .enter, detail: "fade + 8 pt slide")
        static let contentExit = MotionBundle(duration: Duration.d150, easing: .exit, detail: "fade + 8 pt slide")
        static let overlayEnter = MotionBundle(duration: Duration.d250, easing: .spatial, detail: "directional overlays use fade + edge move, centered overlays use fade + 0.95→1 scale")
        static let overlayExit = MotionBundle(duration: Duration.d200, easing: .exit, detail: "directional overlays use fade + edge move, centered overlays use fade + 1→0.95 scale")
        static let contentReposition = MotionBundle(duration: Duration.d250, easing: .spatial, detail: "transform")
        static let scrollFollow = MotionBundle(duration: Duration.d200, easing: .easeOut, detail: "")
    }

    static func animation(for bundle: MotionBundle) -> Animation {
        switch bundle.easing {
        case .enter, .easeOut:
            return .easeOut(duration: bundle.duration)
        case .exit:
            return .easeIn(duration: bundle.duration)
        case .state:
            return .easeInOut(duration: bundle.duration)
        case .spatial:
            return .smooth(duration: bundle.duration, extraBounce: 0)
        case .emphasized:
            return .snappy(duration: bundle.duration, extraBounce: 0)
        }
    }
}
