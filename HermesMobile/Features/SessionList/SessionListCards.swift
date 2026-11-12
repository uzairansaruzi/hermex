import SwiftUI

/// The slot at the top of a session list (webui and Hermes) that shows at most one card.
struct SessionListCardSlot: View {
    let hasSharedImport: Bool
    @AppStorage(TipJar.completedResponseCountKey) private var completedResponses = 0
    @AppStorage(TipJar.dismissedReleaseKey) private var tipDismissedRelease: String?
    @AppStorage(GitHubStar.dismissedReleaseKey) private var starDismissedRelease: String?

    var body: some View {
        switch SessionListCard.current(completedResponses: completedResponses, tipDismissedRelease: tipDismissedRelease,
                                       starDismissedRelease: starDismissedRelease, hasSharedImport: hasSharedImport) {
        case .tip:
            TipJarCard()
                .padding(.horizontal, 16)
                .sessionsScreenListRow()
        case .star:
            GitHubStarCard()
                .padding(.horizontal, 16)
                .sessionsScreenListRow()
        case nil:
            EmptyView()
        }
    }
}

/// Asks for support. Opening either link hides the card for good; the membership page sells any perks.
struct TipJarCard: View {
    var body: some View {
        SessionListCardShell(
            card: .tip,
            title: "Keep Hermex going",
            message: "Hermex is free and open source, with no ads and no tracking. Supporters make that possible.",
            faceShape: "circle"
        ) {
            VStack(spacing: 4) {
                SessionListCardButton(title: "Become a supporter", destination: AppConfig.membershipURL)
                    .accessibilityLabel("Become a supporter, opens in browser")

                Link(destination: AppConfig.tipURL) {
                    Text("or buy Uzi a coffee")
                        .foregroundStyle(.appSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .font(AppFont.subheadline())
                .accessibilityLabel("Buy Uzi a coffee, opens in browser")
            }
        }
    }
}

/// Asks for a GitHub star. The app cannot see a star, so opening the link hides the card for good.
struct GitHubStarCard: View {
    var body: some View {
        SessionListCardShell(
            card: .star,
            title: "Star Hermex on GitHub",
            message: "Hermex is free and open source. A star costs nothing and helps more people find it.",
            faceShape: "star",
            // The tip card's eyes, moved in from the star's arm.
            eyeLayout: .classic.centered(x: 0.06, y: 0)
        ) {
            SessionListCardButton(title: "Star on GitHub", systemImage: "star.fill", destination: AppConfig.repositoryURL)
                .accessibilityLabel("Star on GitHub, opens GitHub")
        }
    }
}

/// The yellow capsule button both cards lead with.
private struct SessionListCardButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
        }
        .font(AppFont.subheadline(weight: .semibold))
        .buttonStyle(.appProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Color(red: 1, green: 224 / 255, blue: 0))
    }
}

/// The shell the session list cards share: a greeting face, title, "Not now" X, body and
/// actions. Any link opened from `actions` hides the card for good.
private struct SessionListCardShell<Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isAppThemed) private var isThemed
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var greetingPhase = SessionListCardGreeting.Phase.neutral
    @State private var isVisible = false
    @AppStorage private var dismissedRelease: String?

    let card: SessionListCard
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    /// A `BotAvatarShape` raw value for the yellow face.
    let faceShape: String
    /// Nil keeps the shape's own eye placement.
    let eyeLayout: BotAvatarEyeLayout?
    let actions: Actions

    init(card: SessionListCard, title: LocalizedStringKey, message: LocalizedStringKey, faceShape: String,
         eyeLayout: BotAvatarEyeLayout? = nil, @ViewBuilder actions: () -> Actions) {
        self.card = card
        self.title = title
        self.message = message
        self.faceShape = faceShape
        self.eyeLayout = eyeLayout
        self.actions = actions()
        _dismissedRelease = AppStorage(card.dismissedReleaseKey)
    }

    private var state: SessionListCardState { SessionListCardState(card: card, defaults: .standard) }

    private var dismissed: Bool { dismissedRelease == state.release }

    private var canAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !dismissed
    }

    private var faceSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 36 : 50 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                face(canAnimate ? greetingPhase : .neutral)
                Text(title)
                    .font(AppFont.headline())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: faceSize, alignment: .leading)
                closeButton
            }
            Text(message)
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .environment(\.openURL, OpenURLAction { url in
                    state.recordLinkOpened()
                    return .systemAction(url)
                })
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isThemed ? Color(.appSurface) : colorScheme == .dark ? Color(white: 0.14) : .white,
                    in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .padding(.vertical, 12)
        .onAppear {
            isVisible = true
            RatingPromptState.shared.recordCardShown(card)
        }
        .onDisappear { isVisible = false }
        .task(id: canAnimate) {
            guard isVisible, scenePhase == .active, !dismissed else { return }
            await SessionListCardGreeting.shared.play(reduceMotion: reduceMotion) { greetingPhase = $0 }
        }
    }

    private func face(_ phase: SessionListCardGreeting.Phase) -> some View {
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
            look: ["shape": .string(faceShape), "color": .string("#ffe000"),
                   "expression": .string(expression)],
            fallbackTitle: "Hermex"
        )
        return BotAvatarMarkView(name: "Hermex", appearance: appearance,
                                 size: faceSize,
                                 pose: pose,
                                 eyeLayout: eyeLayout)
            .animation(canAnimate ? .easeInOut(duration: 0.18) : nil, value: phase)
            .accessibilityHidden(true)
    }

    /// "Not now": hides the card until the next feature release.
    private var closeButton: some View {
        Button {
            state.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.appSecondary)
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
