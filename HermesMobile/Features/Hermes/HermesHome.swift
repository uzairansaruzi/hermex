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
}

/// The Hermes home's bar chrome (#709), the same on both sides: no top bar, since each side's
/// list leads with the session list's header (`SessionsHeader`), and a bottom bar of
/// `(filter) [Bots | Sessions] (new chat)` whose ends each side fills. The title names a pushed
/// screen's back button, and stays inline so a pushed screen such as Tasks keeps the one-line bar.
struct HermesHomeChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    func body(content: Content) -> some View {
        content
            .navigationTitle(home.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
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
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}
