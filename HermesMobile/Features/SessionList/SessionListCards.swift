import SwiftUI

struct SessionListCardSlot: View {
    let hasSharedImport: Bool
    var pluginUpdateServer: URL?
    var openNotifications: () -> Void = {}
    @AppStorage(TipJar.completedResponseCountKey) private var completedResponses = 0
    @AppStorage(TipJar.dismissedReleaseKey) private var tipDismissedRelease: String?
    @AppStorage(GitHubStar.dismissedReleaseKey) private var starDismissedRelease: String?
    @AppStorage(UsageReports.Keys.acceptedVersion) private var acceptedUsageVersion: Int?
    @AppStorage(UsageReports.Keys.declinedVersion) private var declinedUsageVersion: Int?
    @AppStorage(UsageReports.Keys.debugForcesCard) private var forcesUsageReportsCard = false
    #if DEBUG
    @AppStorage(HermexPushUpdateOffers.debugForcesCardKey) private var forcesPluginUpdateCard = false
    #endif

    private var pluginOffer: HermexPushUpdateOffer? {
        guard let pluginUpdateServer else { return nil }
        #if DEBUG
        if forcesPluginUpdateCard { return HermexPushUpdateOffers.debugOffer }
        #endif
        return HermexPushUpdateOffers.shared.cardOffer(for: pluginUpdateServer)
    }

    var body: some View {
        let consent = UsageReportConsent(acceptedVersion: acceptedUsageVersion, declinedVersion: declinedUsageVersion)
        let pluginOffer = pluginOffer
        switch SessionListCard.current(completedResponses: completedResponses, tipDismissedRelease: tipDismissedRelease,
                                       starDismissedRelease: starDismissedRelease, usageReportConsent: consent,
                                       forcesUsageReportsCard: forcesUsageReportsCard, offersPluginUpdate: pluginOffer != nil,
                                       hasSharedImport: hasSharedImport) {
        case .pluginUpdate:
            if let pluginOffer, let pluginUpdateServer {
                HermexPushUpdateCard(offer: pluginOffer, open: openNotifications) {
                    HermexPushUpdateOffers.shared.dismiss(pluginOffer, for: pluginUpdateServer)
                }
                .padding(.horizontal, 16)
                .sessionsScreenListRow()
            }
        case .usageReports:
            if let question = consent.question() {
                UsageReportsCard(question: question)
                    .padding(.horizontal, 16)
                    .sessionsScreenListRow()
            }
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

struct UsageReportsCard: View {
    let question: UsageReportConsent.Question
    @State private var isShowingPreview = false

    var body: some View {
        SessionListCardShell(card: .usageReports, title: title, message: message, faceShape: "circle",
                             hasCloseButton: false) {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    SessionListCardAnswerButton(title: "No thanks") { UsageReports.shared.decline() }
                    SessionListCardAnswerButton(title: "Allow", isProminent: true) { UsageReports.shared.allow() }
                }
                Button {
                    isShowingPreview = true
                } label: {
                    HStack(spacing: 4) {
                        Text("See what’s sent")
                        Image(systemName: "chevron.forward")
                            .font(AppFont.caption(weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.appSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(AppFont.subheadline())
            }
            .padding(.top, 2)
        }
        .sheet(isPresented: $isShowingPreview) {
            UsageReportPreviewSheet()
        }
    }

    private var title: LocalizedStringKey {
        switch question {
        case .allow: "Help improve Hermex"
        case .moreFields: "Usage reports can say more"
        }
    }

    private var message: Text {
        switch question {
        case .allow:
            Text("Send a weekly usage summary to the developer. Never message text, server addresses or file names.")
        case .moreFields(let fields):
            Text("This version adds \(Text(fields.formatted(.list(type: .and))).bold()) to the weekly summary. No thanks keeps sending the summary you already allowed.")
        }
    }
}

struct HermexPushUpdateCard: View {
    let offer: HermexPushUpdateOffer
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        SessionListCardShell(card: .pluginUpdate, title: title, message: message, faceShape: "circle", dismiss: dismiss) {
            SessionListCardAnswerButton(title: offer.kind == .restart ? "Open Notifications" : "Update plugin…",
                                        isProminent: true, action: open)
                .accessibilityHint("Opens Notifications settings.")
        }
    }

    private var title: LocalizedStringKey {
        offer.kind == .restart ? "Restart Hermes to finish" : "Plugin update available"
    }

    private var message: Text {
        let minimum = HermexPushPlugin.minimumVersion.description
        switch offer.kind {
        case .required(let loaded?):
            return Text("Your Hermes host has hermex-push \(loaded.description) loaded. This version of Hermex needs \(minimum) or newer.")
        case .required(nil):
            return Text("Your Hermes host has an older hermex-push. This version of Hermex needs \(minimum) or newer.")
        case .newer(let loaded):
            return Text("Your Hermes host found a newer hermex-push than the \(loaded.description) it runs.")
        case .restart:
            return Text("Hermes loads the new plugin when it restarts.")
        }
    }
}

struct TipJarCard: View {
    var body: some View {
        SessionListCardShell(
            card: .tip,
            title: "Keep Hermex going",
            message: Text("Hermex is free and open source, with no ads and no tracking. Supporters make that possible."),
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

struct GitHubStarCard: View {
    var body: some View {
        SessionListCardShell(
            card: .star,
            title: "Star Hermex on GitHub",
            message: Text("Hermex is free and open source. A star costs nothing and helps more people find it."),
            faceShape: "star",
            eyeLayout: .classic.centered(x: 0.06, y: 0)
        ) {
            SessionListCardButton(title: "Star on GitHub", systemImage: "star.fill", destination: AppConfig.repositoryURL)
                .accessibilityLabel("Star on GitHub, opens GitHub")
        }
    }
}

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
        .tint(.sessionListCardYellow)
    }
}

private extension Color {
    static let sessionListCardYellow = Color(red: 1, green: 224 / 255, blue: 0)
}

private struct SessionListCardAnswerButton: View {
    let title: LocalizedStringKey
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(isProminent ? AnyShapeStyle(Color.black) : AnyShapeStyle(.appPrimary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isProminent ? Color.sessionListCardYellow : Color(.secondarySystemFill), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionListCardShell<Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isAppThemed) private var isThemed
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var greetingPhase = SessionListCardGreeting.Phase.neutral
    @State private var isVisible = false

    let card: SessionListCard
    let title: LocalizedStringKey
    let message: Text
    let faceShape: String
    let eyeLayout: BotAvatarEyeLayout?
    let hasCloseButton: Bool
    let dismiss: (() -> Void)?
    let actions: Actions

    init(card: SessionListCard, title: LocalizedStringKey, message: Text, faceShape: String,
         eyeLayout: BotAvatarEyeLayout? = nil, hasCloseButton: Bool = true, dismiss: (() -> Void)? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.card = card
        self.title = title
        self.message = message
        self.faceShape = faceShape
        self.eyeLayout = eyeLayout
        self.hasCloseButton = hasCloseButton
        self.dismiss = dismiss
        self.actions = actions()
    }

    private var state: SessionListCardState { SessionListCardState(card: card, defaults: .standard) }

    private var canAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion
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
                if hasCloseButton { closeButton }
            }
            message
                .font(AppFont.subheadline())
                .foregroundStyle(.appSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .environment(\.openURL, OpenURLAction { url in
                    state.openLinkFromCard()
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
            UsageReports.shared.record(card, \.shown)
        }
        .onDisappear { isVisible = false }
        .task(id: canAnimate) {
            guard isVisible, scenePhase == .active else { return }
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

    private var closeButton: some View {
        Button {
            if let dismiss { dismiss() } else { state.dismissFromCard() }
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
