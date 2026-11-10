import SwiftUI

/// Whether a Bot Chat's latest turn used the bot's screen (#1632), from
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

/// Opens a Bot Chat's Screen from its card, taking over once it is live when `takingOver`. A
/// reference, like `HermesUpdateSignInAction`, so a pass of the Bots home invalidates no chat.
final class BotScreenOpener {
    var handler: (_ takingOver: Bool) -> Void = { _ in }

    func callAsFunction(takingOver: Bool) { handler(takingOver) }
}

extension EnvironmentValues {
    /// Set by the Bots home only while its own Screen entries show, so nil hides the chat's card.
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

/// The line in a Bot Chat's transcript while the bot uses its screen and after (#1632), with the
/// Screen's two entries: watch it, or take it over.
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
            Button("Open", action: open)
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
