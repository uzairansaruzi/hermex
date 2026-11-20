import SwiftUI

enum BotScreenUse: Equatable {
    case active
    case ended

    static let toolName = "computer_use"
}

final class BotScreenOpener {
    var handler: (_ takingOver: Bool) -> Void = { _ in }

    func callAsFunction(takingOver: Bool) { handler(takingOver) }
}

extension EnvironmentValues {
    @Entry var openBotScreen: BotScreenOpener? = nil
}

struct BotScreenOpenerModifier: ViewModifier {
    let isOffered: Bool
    let handler: (_ takingOver: Bool) -> Void
    @State private var opener = BotScreenOpener()

    func body(content: Content) -> some View {
        opener.handler = handler
        return content.environment(\.openBotScreen, isOffered ? opener : nil)
    }
}

struct SessionScreenModifier: ViewModifier {
    let chat: HermesSessionChat
    @AppStorage private var isScreenEnabled: Bool
    @State private var hostLacksScreen = false
    @State private var presentation: Presentation?
    @State private var opener = BotScreenOpener()

    init(chat: HermesSessionChat) {
        self.chat = chat
        _isScreenEnabled = AppStorage(wrappedValue: false, BotScreenSettings.key(for: chat.server))
    }

    func body(content: Content) -> some View {
        let present = $presentation
        opener.handler = { takingOver in present.wrappedValue = Presentation(takesOver: takingOver) }
        return content
            .environment(\.openBotScreen, isScreenEnabled && !hostLacksScreen ? opener : nil)
            .fullScreenCover(item: $presentation) { presentation in
                let profile = chat.target.profile
                ScreenView(profile: profile,
                           title: HermesProfileNameCache.shared.names(for: chat.server).first { $0.profile == profile }?.title ?? profile,
                           server: chat.server, connection: chat.connection, takesOverWhenLive: presentation.takesOver) {
                    hostLacksScreen = true
                }
            }
            .onChange(of: isScreenEnabled) { if !isScreenEnabled { presentation = nil } }
    }

    private struct Presentation: Identifiable {
        let id = UUID()
        let takesOver: Bool
    }
}

@MainActor @Observable final class ScreenShortcut {
    static let shared = ScreenShortcut()

    private(set) var opener: BotScreenOpener?
    private(set) var hasChat = false
    @ObservationIgnored private var owner: UUID?

    func offer(_ opener: BotScreenOpener?, from owner: UUID) {
        self.owner = owner
        if !hasChat { hasChat = true }
        if self.opener !== opener { self.opener = opener }
    }

    func withdraw(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        hasChat = false
        opener = nil
    }
}

struct BotScreenCard: View {
    let use: BotScreenUse
    let open: () -> Void
    let takeOver: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label.fixedSize()
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                label.fixedSize(horizontal: false, vertical: true)
                buttons
            }
        }
        .pendingRequestBlockSurface()
    }

    private var label: some View {
        Label {
            (use == .active ? Text("Using its screen") : Text("Used its screen"))
                .font(AppFont.subheadline())
        } icon: {
            Image(systemName: "display")
                .foregroundStyle(use == .active ? AnyShapeStyle(.tint) : AnyShapeStyle(.appSecondary))
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(String(localized: "screen.card.open", defaultValue: "Open",
                          comment: "Screen card button: open the bot's Screen to watch it, a verb"), action: open)
                .buttonStyle(.bordered)
                .accessibilityLabel(Text("Open Screen"))
            Button("Take Over", action: takeOver)
                .buttonStyle(.borderedProminent)
        }
        .lineLimit(1)
        .fixedSize()
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }
}
