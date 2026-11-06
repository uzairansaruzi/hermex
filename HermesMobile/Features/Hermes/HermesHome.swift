import SwiftUI

/// The two sides of a Hermes server's home (#709): the Bots inbox and the session list.
enum HermesHomeTab: String {
    case bots, sessions
}

/// What both sides of a Hermes server's home share: the server's name, which titles a pushed
/// screen's back button, the server's avatar in the header, and the switch between the sides.
struct HermesHome {
    let title: String
    let avatar: SessionsHeader.Avatar
    let tab: Binding<HermesHomeTab>
    /// The home is a split's sidebar, whose bars stay horizontal beside a vertical one.
    var isSidebar = false
}

/// The home's search button, which each side fills: the Sessions side grows the header's field,
/// the Bots side opens its search sheet.
struct HermesHomeSearch {
    let label: LocalizedStringKey
    var isDisabled = false
    let open: () -> Void
}

/// The Hermes home's bar chrome (#709), the same on both sides: no top bar, since each side's
/// list leads with the session list's header (`SessionsHeader`), and a bottom bar of
/// `(filter) [Bots | Sessions] (new chat)` whose ends each side fills. The title names a pushed
/// screen's back button, and stays inline so a pushed screen such as Tasks keeps the one-line bar.
/// On iOS 26 the bar's glass pills float over the list: the system's bottom scroll edge effect
/// read as a solid band behind them, so it is hidden.
///
/// Where the system draws a vertical bar (iPhone Duo), the header's search and avatar move into
/// it with the bar's buttons: New Chat, Search and the filter at its top, and Bots, Sessions and
/// the avatar at its foot. The header then drops its pill (`homeBarOwnsSearch`).
struct HermesHomeChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome
    let search: HermesHomeSearch
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    func body(content: Content) -> some View {
        VerticalBarReader { hasVerticalBar in
            let usesVerticalBar = hasVerticalBar && !home.isSidebar
            content
                .modifier(HiddenBottomScrollEdge())
                .themedPageBackground()
                .navigationTitle(home.title)
                .navigationBarTitleDisplayMode(.inline)
                // The vertical bar carries the navigation bar's items, so it stays; its title would
                // be a row of its own above the header.
                .toolbar(usesVerticalBar ? .automatic : .hidden, for: .navigationBar)
                .toolbar(removing: usesVerticalBar ? .title : nil)
                .toolbar {
                    if #available(iOS 27.1, *), usesVerticalBar {
                        verticalBarItems
                    } else {
                        bottomBarItems
                    }
                }
                .environment(\.homeBarOwnsSearch, usesVerticalBar)
        }
    }

    @ToolbarContentBuilder private var bottomBarItems: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) { filter }
        if #available(iOS 26, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            // The segmented control is its own pill; a glass one around it would double it.
            ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
        }
        ToolbarItem(placement: .bottomBar) { newChat }
    }

    /// The segmented switch is too wide for a vertical bar, so each side gets its own button.
    @available(iOS 27.1, *)
    @ToolbarContentBuilder private var verticalBarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { newChat }
        ToolbarItem(placement: .topBarTrailing) {
            Button(search.label, systemImage: "magnifyingglass", action: search.open)
                .disabled(search.isDisabled)
        }
        ToolbarItem(placement: .topBarTrailing) { filter }
        ToolbarItem(placement: .bottomBar) { HermesHomeSideButton(side: .bots, tab: home.tab) }
        ToolbarItem(placement: .bottomBar) { HermesHomeSideButton(side: .sessions, tab: home.tab) }
        // A custom label otherwise falls back to a horizontal bar of its own.
        ToolbarItem(placement: .bottomBar) { HermesHomeAvatarMenu(avatar: home.avatar) }
            .axisBehavior(.verticalPreferred)
    }
}

extension EnvironmentValues {
    /// The home's bar holds search and the avatar, so `SessionsHeader` leaves them out.
    @Entry var homeBarOwnsSearch = false
}

/// Calls `content` with whether the system draws a vertical bar here (iOS 27.1, iPhone Duo). In a
/// split it is the detail column's: the sidebar's bars stay horizontal (`HermesHome.isSidebar`).
private struct VerticalBarReader<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarEdgeReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let content: (Bool) -> Content

    var body: some View {
        content(edge != nil)
    }
}

/// One side of the home in a vertical bar, filled while it shows.
private struct HermesHomeSideButton: View {
    let side: HermesHomeTab
    @Binding var tab: HermesHomeTab

    var body: some View {
        let isSelected = tab == side
        Button {
            tab = side
        } label: {
            switch side {
            case .bots: Label("Bots", image: "LucideBot")
            case .sessions: Label("Sessions", systemImage: isSelected ? "text.bubble.fill" : "text.bubble")
            }
        }
        .tint(isSelected ? .accentColor : .primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The header's avatar as a bar button: a tap opens Settings and a hold switches servers.
private struct HermesHomeAvatarMenu: View {
    let avatar: SessionsHeader.Avatar

    var body: some View {
        Menu {
            AvatarServerSwitcherMenu(model: avatar.servers, switchToServer: avatar.switchToServer,
                                     addServer: avatar.addServer, manageServers: avatar.manageServers)
        } label: {
            Text(avatar.initials)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(avatar.foreground)
                .frame(width: 30, height: 30)
                .background(avatar.color, in: Circle())
        } primaryAction: {
            avatar.openSettings()
        }
        .accessibilityLabel("Settings")
        .accessibilityHint("Opens Settings. Long press to switch servers.")
    }
}

private struct HiddenBottomScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            content
        }
    }
}

/// `[Bots | Sessions]`. It keeps a system bar's size at accessibility text sizes; a long press
/// shows the Large Content Viewer instead.
private struct HermesHomeSwitch: View {
    @Binding var tab: HermesHomeTab

    var body: some View {
        // The segments name themselves; the picker needs no label of its own.
        Picker(selection: $tab) {
            Text("Bots").tag(HermesHomeTab.bots)
            Text("Sessions").tag(HermesHomeTab.sessions)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        // A bare `.fixedSize()` hugs the longer label (#1344); the minimum gives both segments
        // room, and a longer translation still widens the switch instead of truncating.
        .frame(minWidth: 200)
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}
