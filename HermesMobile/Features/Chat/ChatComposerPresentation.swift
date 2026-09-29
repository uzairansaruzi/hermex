import SwiftUI

/// Shared geometry for Sessions and the text-only Bot composer.
enum ChatComposerMetrics {
    static let cardCornerRadius: CGFloat = 26
    static let actionSize: CGFloat = 44
    static let pillInset: CGFloat = 5
}

struct ChatComposerSurfaceStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isExpanded: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isExpanded ? ChatComposerMetrics.cardCornerRadius
                : (ChatComposerMetrics.actionSize + ChatComposerMetrics.pillInset * 2) / 2,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        content
            .adaptiveGlass(.regular, isInteractive: true, fallbackMaterial: .ultraThinMaterial, in: shape)
            .clipShape(shape)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 6)
    }
}

struct ChatComposerActionAppearance {
    let isStop: Bool
    let isDisabled: Bool
    let colorScheme: ColorScheme
    let tintsPrimaryActions: Bool
    let themeHex: String

    private var usesTheme: Bool {
        PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions, controlIsEnabled: !isDisabled
        )
    }

    var background: Color {
        if isStop { return Color.red.opacity(colorScheme == .dark ? 0.22 : 0.14) }
        if usesTheme { return HeaderLogoColor.color(for: themeHex) }
        if isDisabled { return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12) }
        return colorScheme == .dark ? .white : .black
    }

    var foreground: Color {
        if isStop { return .red }
        if usesTheme { return HeaderLogoColor.prefersDarkForeground(for: themeHex) ? .black : .white }
        if isDisabled { return Color(.secondaryLabel) }
        return colorScheme == .dark ? .black : .white
    }
}

/// A row the send-choice card can list. Bots list `BotPromptMode`; Sessions
/// list `StreamingSendBehavior`.
protocol SendChoice: Hashable {
    var title: String { get }
    var systemImage: String { get }
}

/// The send-choice card: the "+" picker's chrome (scrim, material panel, the
/// same present and dismiss motion) holding what a send can do to a running
/// turn. It sits bottom-trailing, by the Send button that opened it, and a
/// pick submits at once. Bot Chat opens it when a send lands on a working bot;
/// the Sessions composer opens it on a long-press of Send mid-run.
struct SendChoiceCard<Choice: SendChoice>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isVisible = false
    @State private var isDismissing = false
    @State private var transitionTask: Task<Void, Never>?

    let choices: [Choice]
    let onPick: (Choice) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = HermexAttachmentPickerLayoutMetrics.menuWidth(containerWidth: proxy.size.width)
            ZStack(alignment: .bottomTrailing) {
                Button(action: dismiss) {
                    Color.black.opacity(isVisible ? 0.08 : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDismissing)
                .accessibilityLabel("Close send choices")

                VStack(spacing: 0) {
                    ForEach(choices, id: \.self) { choice in
                        HermexAttachmentMenuRow(title: Text(choice.title), systemImage: choice.systemImage) {
                            finish { onPick(choice) }
                        }
                    }
                }
                .padding(.vertical, 12)
                .frame(width: width)
                .modifier(HermexAttachmentPanelSurface(reduceTransparency: reduceTransparency))
                .compositingGroup()
                .clipShape(.rect(cornerRadius: 46, style: .continuous))
                .padding(.trailing, HermexAttachmentPickerLayoutMetrics.menuLeadingPadding)
                .padding(.bottom, 74)
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(isVisible ? 1 : 0.96, anchor: .bottomTrailing)
                .offset(y: isVisible ? 0 : 8)
                .allowsHitTesting(!isDismissing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Send choices")
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .onAppear(perform: present)
        .onDisappear { transitionTask?.cancel(); transitionTask = nil }
    }

    private func present() {
        guard !isVisible else { return }
        guard !reduceMotion else { isVisible = true; return }
        transitionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { isVisible = true }
            transitionTask = nil
        }
    }

    private func dismiss() { finish(onDismiss) }

    /// Fades the card out, then hands control back; a pick and a dismissal
    /// leave the same way.
    private func finish(_ completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        transitionTask?.cancel()
        guard !reduceMotion else { completion(); return }
        withAnimation(.easeInOut(duration: 0.16)) { isVisible = false }
        transitionTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled else { return }
            completion()
        }
    }
}
