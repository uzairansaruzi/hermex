import SwiftUI

enum HermesHomeTab: String {
    case bots, sessions
}

struct HermesHome {
    let title: String
    let avatar: SessionsHeader.Avatar
    let tab: Binding<HermesHomeTab>
    var isSidebar = false
}

struct HermesHomeSearch {
    let label: LocalizedStringKey
    var isDisabled = false
    let open: () -> Void
}

struct HermesHomeChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome
    let search: HermesHomeSearch
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat
    @Environment(\.splitDetailHasVerticalBar) private var detailHasVerticalBar

    func body(content: Content) -> some View {
        VerticalBarReader { hasVerticalBar in
            let ownsRail = hasVerticalBar && !home.isSidebar
            let detailOwnsRail = home.isSidebar && detailHasVerticalBar
            content
                .modifier(RailTopInset(isActive: ownsRail))
                .modifier(HiddenBottomScrollEdge())
                .themedPageBackground()
                .navigationTitle(ownsRail ? "" : home.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(ownsRail ? .automatic : .hidden, for: .navigationBar)
                .toolbar(removing: ownsRail ? .title : nil)
                .toolbar {
                    if #available(iOS 27.1, *), ownsRail {
                        HermesHomeRailItems(home: home, search: search, filter: filter, newChat: newChat)
                    } else if !detailOwnsRail {
                        bottomBarItems
                    }
                }
                .environment(\.homeBarOwnsSearch, ownsRail || detailOwnsRail)
        }
    }

    @ToolbarContentBuilder private var bottomBarItems: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) { filter }
        if #available(iOS 26, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
        }
        ToolbarItem(placement: .bottomBar) { newChat }
    }
}

struct HermesHomeDetailBar<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome?
    let search: HermesHomeSearch
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    func body(content: Content) -> some View {
        content.verticalBarToolbar { hasVerticalBar in
            if #available(iOS 27.1, *), hasVerticalBar, let home, home.isSidebar {
                HermesHomeRailItems(home: home, search: search, filter: filter, newChat: newChat)
            }
        }
    }
}

@available(iOS 27.1, *)
private struct HermesHomeRailItems<Filter: View, NewChat: View>: ToolbarContent {
    let home: HermesHome
    let search: HermesHomeSearch
    let filter: Filter
    let newChat: NewChat

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { newChat }
        ToolbarItem(placement: .topBarTrailing) {
            Button(search.label, systemImage: "magnifyingglass", action: search.open)
                .disabled(search.isDisabled)
        }
        ToolbarItem(placement: .topBarTrailing) { filter }
        ToolbarItem(placement: .bottomBar) { HermesHomeSideButton(side: .bots, tab: home.tab) }
        ToolbarItem(placement: .bottomBar) { HermesHomeSideButton(side: .sessions, tab: home.tab) }
        ToolbarItem(placement: .bottomBar) { HermesHomeAvatarMenu(avatar: home.avatar) }
            .axisBehavior(.verticalPreferred)
    }
}

extension EnvironmentValues {
    @Entry var homeBarOwnsSearch = false
    @Entry var splitDetailHasVerticalBar = false
}

extension View {
    func verticalBarToolbar<Items: ToolbarContent>(
        @ToolbarContentBuilder _ items: @escaping (_ hasVerticalBar: Bool) -> Items
    ) -> some View {
        VerticalBarReader { hasVerticalBar in self.toolbar { items(hasVerticalBar) } }
    }
}

struct VerticalBarReader<Content: View>: View {
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sawBar = false
    let content: (Bool) -> Content

    var body: some View {
        content(edge != nil || sawBar)
            .onChange(of: edge != nil, initial: true) { if edge != nil { sawBar = true } }
            .onChange(of: [horizontalSizeClass, verticalSizeClass]) { sawBar = edge != nil }
    }
}

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

private struct RailTopInset: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, isActive ? 24 : 0, for: .scrollContent)
            .ignoresSafeArea(.container, edges: isActive ? .top : [])
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

private struct HermesHomeSwitch: View {
    @Binding var tab: HermesHomeTab

    var body: some View {
        Picker(selection: $tab) {
            Text("Bots").tag(HermesHomeTab.bots)
            Text("Sessions").tag(HermesHomeTab.sessions)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 200)
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}
