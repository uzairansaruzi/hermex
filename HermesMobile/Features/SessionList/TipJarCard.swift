import SwiftUI

struct TipJarCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var greetingPhase = TipJarGreetingState.Phase.neutral

    @State private var isVisible = false
    @AppStorage(TipJar.dismissedKey) private var dismissed = false

    private var canAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !dismissed
    }

    private let accent = Color(red: 1, green: 224 / 255, blue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                companion
                Text("Enjoying Hermex?")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("It's free and open source. If it's earned a coffee, that would mean a lot.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { actions }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }
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
                                 size: dynamicTypeSize.isAccessibilitySize ? 36 : 50,
                                 pose: pose)
            .animation(canAnimate ? .easeInOut(duration: 0.18) : nil, value: phase)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        Link(destination: AppConfig.tipURL) {
            Text("Buy Uzi a coffee")
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(accent)
        .accessibilityLabel("Buy Uzi a coffee, opens in browser")
        .environment(\.openURL, OpenURLAction { url in
            TipJarPromptState(defaults: .standard).recordLinkOpened()
            return .systemAction(url)
        })
        Button("Not now") {
            TipJarPromptState(defaults: .standard).dismiss()
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
    }
}
