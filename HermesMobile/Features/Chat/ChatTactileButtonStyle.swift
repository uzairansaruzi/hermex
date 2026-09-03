import SwiftUI
import UIKit

struct ChatTactileButtonStyle: ButtonStyle {
    enum Variant {
        case icon
        case compactControl
        case capsule
        case card
        case thumbnail

        var pressedScale: CGFloat {
            switch self {
            case .icon:
                0.945
            case .compactControl:
                1
            case .capsule:
                0.975
            case .card:
                0.985
            case .thumbnail:
                0.98
            }
        }

        var pressedOpacity: Double {
            switch self {
            case .icon, .compactControl:
                0.94
            case .capsule, .card, .thumbnail:
                0.96
            }
        }

        var duration: TimeInterval {
            switch self {
            case .icon, .compactControl:
                0.16
            case .capsule, .card, .thumbnail:
                0.20
            }
        }

        var scaleAnchor: UnitPoint {
            switch self {
            case .compactControl:
                .leading
            case .icon, .capsule, .card, .thumbnail:
                .center
            }
        }
    }

    struct Shadow {
        let color: Color
        let opacity: Double
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
        let pressedOpacity: Double
        let pressedRadius: CGFloat
        let pressedY: CGFloat

        init(
            color: Color,
            opacity: Double,
            radius: CGFloat,
            x: CGFloat = 0,
            y: CGFloat,
            pressedOpacity: Double,
            pressedRadius: CGFloat,
            pressedY: CGFloat
        ) {
            self.color = color
            self.opacity = opacity
            self.radius = radius
            self.x = x
            self.y = y
            self.pressedOpacity = pressedOpacity
            self.pressedRadius = pressedRadius
            self.pressedY = pressedY
        }
    }

    let variant: Variant
    let shadow: Shadow?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        let shadow = shadow ?? Shadow(
            color: .clear,
            opacity: 0,
            radius: 0,
            y: 0,
            pressedOpacity: 0,
            pressedRadius: 0,
            pressedY: 0
        )

        configuration.label
            .scaleEffect(reduceMotion ? 1 : (isPressed ? variant.pressedScale : 1), anchor: variant.scaleAnchor)
            .opacity(isEnabled ? (isPressed ? variant.pressedOpacity : 1) : 0.62)
            .shadow(
                color: shadow.color.opacity(isPressed ? shadow.pressedOpacity : shadow.opacity),
                radius: isPressed ? shadow.pressedRadius : shadow.radius,
                x: shadow.x,
                y: isPressed ? shadow.pressedY : shadow.y
            )
            .animation(animation, value: isPressed)
    }

    private var animation: Animation? {
        ChatMotion.press(duration: variant.duration, reduceMotion: reduceMotion)
    }
}

extension ButtonStyle where Self == ChatTactileButtonStyle {
    static func chatTactile(
        _ variant: ChatTactileButtonStyle.Variant,
        shadow: ChatTactileButtonStyle.Shadow? = nil
    ) -> ChatTactileButtonStyle {
        ChatTactileButtonStyle(variant: variant, shadow: shadow)
    }
}

struct ChatUIKitMenuButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    private let menu: () -> UIMenu
    private let label: Label
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let loadsMenuEagerly: Bool

    init(
        horizontalPadding: CGFloat = 0,
        verticalPadding: CGFloat = 0,
        loadsMenuEagerly: Bool = false,
        @ViewBuilder label: () -> Label,
        menu: @escaping () -> UIMenu
    ) {
        self.label = label()
        self.menu = menu
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.loadsMenuEagerly = loadsMenuEagerly
    }

    var body: some View {
        label
            .opacity(isEnabled ? 1 : 0.62)
            .overlay {
                ChatUIKitMenuButtonBacker(
                    horizontalPadding: horizontalPadding,
                    verticalPadding: verticalPadding,
                    loadsMenuEagerly: loadsMenuEagerly,
                    menu: menu
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

private struct ChatUIKitMenuButtonBacker: UIViewControllerRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let loadsMenuEagerly: Bool
    let menu: () -> UIMenu

    func makeCoordinator() -> Coordinator {
        Coordinator(menu: menu)
    }

    func makeUIViewController(context: Context) -> ChatMenuButtonHostController {
        let controller = ChatMenuButtonHostController()
        let button = controller.button

        controller.setHitPadding(horizontal: horizontalPadding, vertical: verticalPadding)
        button.menu = loadsMenuEagerly
            ? context.coordinator.menu()
            : deferredMenu(using: context.coordinator)
        button.isEnabled = isEnabled
        button.isAccessibilityElement = false

        return controller
    }

    func updateUIViewController(_ uiViewController: ChatMenuButtonHostController, context: Context) {
        context.coordinator.menu = menu
        uiViewController.setHitPadding(horizontal: horizontalPadding, vertical: verticalPadding)
        uiViewController.button.isEnabled = isEnabled
        if loadsMenuEagerly {
            uiViewController.button.menu = menu()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: ChatMenuButtonHostController,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIView.noIntrinsicMetric,
            height: proposal.height ?? UIView.noIntrinsicMetric
        )
    }

    final class Coordinator {
        var menu: () -> UIMenu

        init(menu: @escaping () -> UIMenu) {
            self.menu = menu
        }
    }

    private func deferredMenu(using coordinator: Coordinator) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(coordinator.menu().children)
            }
        ])
    }
}

private final class ChatMenuButtonHostController: UIViewController {
    let button = UIButton(type: .custom)
    private let container = ChatMenuButtonContainerView()

    func setHitPadding(horizontal: CGFloat, vertical: CGFloat) {
        container.horizontalPadding = horizontal
        container.verticalPadding = vertical
    }

    override func loadView() {
        container.backgroundColor = .clear
        container.isOpaque = false
        container.isAccessibilityElement = false
        container.button = button
        view = container

        button.showsMenuAsPrimaryAction = true
        button.backgroundColor = .clear
        button.setTitle(nil, for: .normal)
        button.setImage(nil, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

private final class ChatMenuButtonContainerView: UIView {
    var horizontalPadding: CGFloat = 0
    var verticalPadding: CGFloat = 0
    weak var button: UIButton?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard
            isUserInteractionEnabled,
            !isHidden,
            alpha >= 0.01,
            let button,
            button.isEnabled,
            !button.isHidden,
            button.alpha >= 0.01
        else {
            return nil
        }

        let expandedBounds = bounds.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
        return expandedBounds.contains(point) ? button : nil
    }
}

extension View {
    func chatMinimumHitTarget<HitShape: Shape>(
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 8,
        in shape: HitShape
    ) -> some View {
        modifier(ChatMinimumHitTargetModifier(
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            shape: shape
        ))
    }
}

private struct ChatMinimumHitTargetModifier<HitShape: Shape>: ViewModifier {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let shape: HitShape

    func body(content: Content) -> some View {
        // Expand the hit shape without making compact composer controls consume row space.
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(shape)
            .padding(.horizontal, -horizontalPadding)
            .padding(.vertical, -verticalPadding)
    }
}

struct ChatDecisionButtonStyle: ButtonStyle {
    enum Emphasis {
        case primary
        case secondary
        case destructive
    }

    let emphasis: Emphasis

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(backgroundColor(isPressed: isPressed), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.975 : 1))
            .opacity(isEnabled ? (isPressed ? 0.96 : 1) : 0.62)
            .animation(animation, value: isPressed)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return Color(.secondaryLabel)
        }

        switch emphasis {
        case .primary:
            return colorScheme == .dark ? .black : .white
        case .secondary:
            return .primary
        case .destructive:
            return .red
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        }

        switch emphasis {
        case .primary:
            return colorScheme == .dark ? .white : .black
        case .secondary:
            return colorScheme == .dark ? Color.white.opacity(isPressed ? 0.12 : 0.08) : Color.black.opacity(isPressed ? 0.07 : 0.045)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.16 : 0.10)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .primary:
            return .clear
        case .secondary:
            return Color(.separator).opacity(colorScheme == .dark ? 0.36 : 0.24)
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.36 : 0.26)
        }
    }

    private var animation: Animation? {
        ChatMotion.press(duration: 0.18, reduceMotion: reduceMotion)
    }
}

extension ButtonStyle where Self == ChatDecisionButtonStyle {
    static func chatDecision(_ emphasis: ChatDecisionButtonStyle.Emphasis) -> ChatDecisionButtonStyle {
        ChatDecisionButtonStyle(emphasis: emphasis)
    }
}
