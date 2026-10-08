import SwiftUI

/// The two sides of a Hermes server's home (#709): the Bots inbox and the session list.
enum HermesHomeTab: String {
    case bots, sessions
}

/// How a Hermes server's home titles itself, and the switch between its two sides. The Bots
/// inbox and the session list each take one when they are the home's root.
struct HermesHome {
    let title: String
    let subtitle: String?
    let tab: Binding<HermesHomeTab>
}

/// The Hermes home's chrome (#709), the same on both sides: HERMEX at the leading edge, the
/// server's name as the title, search and the server's avatar trailing, and a bottom bar of
/// `(filter) [Bots | Sessions] (new chat)` whose ends each side fills.
struct HermesHomeChrome<Filter: View, NewChat: View, Avatar: View>: ViewModifier {
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    let home: HermesHome
    let searchLabel: LocalizedStringKey
    var isSearchDisabled = false
    let search: () -> Void
    @ViewBuilder let filter: Filter
    @ViewBuilder let newChat: NewChat
    @ViewBuilder let avatar: Avatar

    func body(content: Content) -> some View {
        content
            .navigationTitle(home.title)
            .navigationBarTitleDisplayMode(.large)
            .modifier(HermesHomeSubtitle(subtitle: home.subtitle))
            .toolbar {
                // The wordmark is art, not a control, so it sits on the bar without a glass button.
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarLeading) { wordmark }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { wordmark }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(searchLabel, systemImage: "magnifyingglass", action: search)
                        .disabled(isSearchDisabled)
                }
                if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
                ToolbarItem(placement: .topBarTrailing) { avatar }
                ToolbarItem(placement: .bottomBar) { filter }
                if #available(iOS 26, *) { ToolbarSpacer(.flexible, placement: .bottomBar) }
                ToolbarItem(placement: .bottomBar) { HermesHomeSwitch(tab: home.tab) }
                if #available(iOS 26, *) { ToolbarSpacer(.flexible, placement: .bottomBar) }
                ToolbarItem(placement: .bottomBar) { newChat }
            }
    }

    private var wordmark: some View {
        HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: headerLogoColorHex))
            .frame(width: 104)
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

private struct HermesHomeSubtitle: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if #available(iOS 26, *), let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}
