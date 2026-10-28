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

/// The Hermes home's bar chrome (#709), the same on both sides. On iPhone and iPad each list
/// leads with `SessionsHeader` and has a bottom bar of `(filter) [Bots | Sessions] (new chat)`.
/// Mac Catalyst puts those actions beside the list header instead, so this modifier only hides
/// its navigation bar there. The title names a pushed screen's back button on mobile.
/// On iOS 26 the bar's glass pills float over the list: the system's bottom scroll edge effect
/// read as a solid band behind them, so it is hidden.
struct HermesHomeChrome<Filter: View, NewChat: View>: ViewModifier {
    let home: HermesHome
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .toolbar(.hidden, for: .navigationBar)
        #else
        content
            .modifier(HiddenBottomScrollEdge())
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
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// The mobile bottom bar does not fit a Mac sidebar. Keep the same actions beside the
/// list header so they remain visible at every window size without toolbar overflow.
struct HermesHomeDesktopControls<Filter: View, NewChat: View>: View {
    let home: HermesHome
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat

    var body: some View {
        HStack(spacing: 8) {
            filter.labelStyle(.iconOnly)
            Spacer(minLength: 0)
            HermesHomeSwitch(tab: home.tab)
            Spacer(minLength: 0)
            newChat.labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
#endif

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
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}
