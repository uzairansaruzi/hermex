import SwiftUI

struct TipJarCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var greetingPhase = TipJarGreetingState.Phase.neutral

    @State private var isVisible = false
    @AppStorage(TipJar.dismissedReleaseKey) private var dismissedRelease: String?

    private var dismissed: Bool {
        dismissedRelease == TipJarPromptState(defaults: .standard).release
    }

    private var canAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !dismissed
    }

    private var faceSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 36 : 50 }

    private let accent = Color(red: 1, green: 224 / 255, blue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                companion
                Text("Keep Hermex going")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: faceSize, alignment: .leading)
                closeButton
            }
            Text("Hermex is free and open source, with no ads and no tracking. Supporters make that possible.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            links
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 0.14) : .white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .padding(.vertical, 12)
        .onAppear {
            isVisible = true
            RatingPromptState.shared.recordTipCardShown()
        }
        .onDisappear { isVisible = false }
        .task(id: canAnimate) {
            guard isVisible, scenePhase == .active, !dismissed else { return }
            await TipJarGreetingState.shared.play(reduceMotion: reduceMotion) { greetingPhase = $0 }
        }
    }

    private var companion: some View {
        face(canAnimate ? greetingPhase : .neutral)
    }

    private func face(_ phase: TipJarGreetingState.Phase) -> some View {
        let expression: String
        switch phase {
        case .curious: expression = "curious"
        case .happy: expression = "happy"
        default: expression = "neutral"
        }
        let pose: BotFacePose
        switch phase {
        case .blink: pose = .blink
        case .hop: pose = BotFacePose(lift: 0.14, scaleX: 0.96, scaleY: 1.04)
        case .glanceDown: pose = BotFacePose(gazeY: 0.09)
        default: pose = .rest
        }
        let appearance = BotProfileAppearance(
            look: ["shape": .string("circle"), "color": .string("#ffe000"),
                   "expression": .string(expression)],
            fallbackTitle: "Hermex"
        )
        return BotAvatarMarkView(name: "Hermex", appearance: appearance,
                                 size: faceSize,
                                 pose: pose)
            .animation(canAnimate ? .easeInOut(duration: 0.18) : nil, value: phase)
            .accessibilityHidden(true)
    }

    /// Opening either link hides the card for good; the membership page sells any perks.
    private var links: some View {
        VStack(spacing: 4) {
            Link(destination: AppConfig.membershipURL) {
                Text("Become a supporter")
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(accent)
            .accessibilityLabel("Become a supporter, opens in browser")

            Link(destination: AppConfig.tipURL) {
                Text("or buy Uzi a coffee")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .font(.subheadline)
            .accessibilityLabel("Buy Uzi a coffee, opens in browser")
        }
        .environment(\.openURL, OpenURLAction { url in
            TipJarPromptState(defaults: .standard).recordLinkOpened()
            return .systemAction(url)
        })
    }

    /// "Not now": hides the card until the next feature release.
    private var closeButton: some View {
        Button {
            TipJarPromptState(defaults: .standard).dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.fill.tertiary, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding([.top, .trailing], -12)
        .accessibilityLabel("Not now")
    }
}
