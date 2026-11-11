import SwiftUI

/// Whether a Hermes chat's latest turn used the bot's screen (#1632, #1633), from
/// `HermesChatTurnCoordinator.screenUse`.
enum BotScreenUse: Equatable {
    /// The running turn has called `computer_use`.
    case active
    /// The turn that used it is over, or its stream dropped.
    case ended

    /// The tool the host names on `tool.start` when the bot acts on its screen. A browser tool
    /// doesn't count: it doesn't mean the screen is in use.
    static let toolName = "computer_use"
}

/// Opens a chat's Screen from its card or ⌘⇧S, taking over once it is live when `takingOver`. A
/// reference, like `HermesUpdateSignInAction`, so a pass of the Bots home invalidates no chat.
final class BotScreenOpener {
    var handler: (_ takingOver: Bool) -> Void = { _ in }

    func callAsFunction(takingOver: Bool) { handler(takingOver) }
}

extension EnvironmentValues {
    /// Set by the Bots home only while its own Screen entries show, and for a session chat by
    /// `SessionScreenModifier` behind the same gate, so nil hides the chat's card and header button.
    @Entry var openBotScreen: BotScreenOpener? = nil
}

/// Installs `openBotScreen` for a bot's chat while `isOffered`, keeping one opener in state.
struct BotScreenOpenerModifier: ViewModifier {
    let isOffered: Bool
    let handler: (_ takingOver: Bool) -> Void
    @State private var opener = BotScreenOpener()

    func body(content: Content) -> some View {
        opener.handler = handler
        return content.environment(\.openBotScreen, isOffered ? opener : nil)
    }
}

/// A session chat's Screen (#1633): its own Profile's, on the chat's server and connection, never
/// the Bots home's selected bot. Applied where each session `ChatView(hermesSession:)` is built,
/// inside its `.id`, it installs `openBotScreen` behind the Bots home's gate (the server's switch,
/// and no -32601 on `display.*`) and presents the Screen. Turning the switch off closes it.
struct SessionScreenModifier: ViewModifier {
    let chat: HermesSessionChat
    @AppStorage private var isScreenEnabled: Bool
    /// The host answered `display.*` with -32601. The Bots home keeps its own, so the card may
    /// show once more here before it hides.
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

/// ⌘⇧S's Screen (#1633): the chat on screen offers its card's opener here, and `HermexCommands`
/// reads it ahead of the scene's actions. A shared registry rather than a focused or environment
/// value, because a session pushed from a chat, from Archived or from Settings is a
/// `navigationDestination` no list's value reliably reaches. A Bot Chat offers the same Screen the
/// Bots home's own action would.
@MainActor @Observable final class ScreenShortcut {
    static let shared = ScreenShortcut()

    private(set) var opener: BotScreenOpener?
    /// A chat is on screen, with or without a Screen to open. While one is, the Bots home's
    /// selected bot isn't what ⌘⇧S opens.
    private(set) var hasChat = false
    /// The `ChatView` on screen: only it withdraws, so a chat popping back into view before the
    /// pushed one leaves keeps its own.
    @ObservationIgnored private var owner: UUID?

    /// The chat `owner` is on screen, offering `opener`, or nil while it has no Screen to open.
    func offer(_ opener: BotScreenOpener?, from owner: UUID) {
        self.owner = owner
        if !hasChat { hasChat = true }
        if self.opener !== opener { self.opener = opener }
    }

    /// The chat `owner` left the screen.
    func withdraw(_ owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        hasChat = false
        opener = nil
    }
}

/// The line in a Hermes chat's transcript while the bot uses its screen and after (#1632, #1633),
/// with the Screen's two entries: watch it, or take it over.
struct BotScreenCard: View {
    let use: BotScreenUse
    let open: () -> Void
    let takeOver: () -> Void

    var body: some View {
        // One line while the label and both buttons fit whole; otherwise the buttons go under
        // the label, so neither ever wraps inside a capsule.
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
