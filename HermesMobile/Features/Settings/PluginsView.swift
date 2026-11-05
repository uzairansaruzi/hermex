import SwiftUI

/// A Hermes server's Plugins page (#1582), opened from its Settings page: one Profile's plugins with
/// search and filters, each row's switch applying at once unless Hermex or sign-in relies on it. **+**
/// installs after a review, and a user install swipes to Remove, or to its own page for the two
/// plugins Hermex manages itself.
struct PluginsView: View {
    @State private var model: PluginsModel
    @State private var isConfirmingRestart = false
    @State private var installProfile: InstallProfile?
    @State private var isShowingPushSettings = false
    @State private var screenProfile: InstallProfile?
    @State private var openedPlugin: String?
    private let connection: BotConnection
    private let server: URL

    init(connection: BotConnection, server: URL) {
        self.connection = connection
        self.server = server
        _model = State(initialValue: PluginsModel(client: HermesPluginsClient(saved: connection, server: server)))
    }

    var body: some View {
        List {
            if let profile = model.profile {
                ServerProfileRow(profiles: model.profiles, selection: profile) { name in
                    Task { await model.select(name) }
                }
            }
            noticeSection
            if let setup = model.setup { PluginSetupSection(setup: setup, model: model) }
            Picker("View", selection: $model.tab) {
                Text("Installed").tag(PluginsModel.Tab.installed)
                Text("Discover").tag(PluginsModel.Tab.discover)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            switch model.tab {
            case .installed: content
            case .discover:
                if let profile = model.profile { PluginDiscoverSections(model: model, profile: profile) }
            }
        }
        .settingsPage(String(localized: "Plugins"))
        .listSectionSpacing(.compact)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: model.tab == .installed ? Text("Search installed") : Text("Search plugins"))
        // Closing search otherwise slides the bar back and resizes the list for the keyboard at once,
        // which drops frames on a phone. The list stays still, and scrolling reaches what's under the keyboard.
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .ignoresSafeArea(.keyboard)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    installProfile = model.profile.map(InstallProfile.init)
                } label: {
                    Label("Install Plugin", systemImage: "plus")
                }
                .disabled(model.profile == nil)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .task(id: model.tab) {
            if model.tab == .discover { await model.loadCatalog() }
        }
        .onChange(of: model.tab) { model.query = "" }
        .sheet(item: $installProfile) { PluginInstallSheet(model: model, profile: $0.name) }
        .navigationDestination(isPresented: $isShowingPushSettings) { SettingsNotificationsPage(server: server) }
        .navigationDestination(item: $openedPlugin) { PluginDetailView(key: $0, model: model) }
        .sheet(item: $model.updateReview) { PluginUpdateReviewSheet(review: $0, model: model) }
        .fullScreenCover(item: $screenProfile, onDismiss: { Task { await model.load() } }) { profile in
            ScreenView(profile: profile.name, title: profile.name, server: server, connection: connection, removesFromItsProfile: true) {}
        }
        .alert(pendingRemovalTitle, isPresented: isPresentingPendingRemoval, presenting: model.pendingRemoval) { _ in
            Button("Remove", role: .destructive) { model.confirmPendingRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This deletes its files from \(model.profile ?? "") on the host. You can install it again later.")
        }
        .alert(pendingToggleTitle, isPresented: isPresentingPendingToggle, presenting: model.pendingToggle) { pending in
            Button(pending.turningOn ? String(localized: "Turn On") : String(localized: "Turn Off"), role: .destructive) {
                model.confirmPendingToggle()
            }
            Button(pending.turningOn ? String(localized: "Keep Off") : String(localized: "Keep On"), role: .cancel) {}
        } message: { pending in
            Text(verbatim: pending.warning)
        }
        .alert("Restart the gateway?", isPresented: $isConfirmingRestart) {
            Button("Restart", role: .destructive) { Task { await model.restartGateway() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running work on \(model.profile ?? "") stops. If this host runs one gateway for all its Profiles, work on the others stops too.")
        }
    }

    private var isPresentingPendingToggle: Binding<Bool> {
        Binding(get: { model.pendingToggle != nil }, set: { if !$0 { model.pendingToggle = nil } })
    }

    private var isPresentingPendingRemoval: Binding<Bool> {
        Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })
    }

    private var pendingRemovalTitle: String {
        guard let plugin = model.pendingRemoval else { return "" }
        return String(localized: "Remove \(plugin.name) from \(model.profile ?? "")?")
    }

    private var pendingToggleTitle: String {
        guard let pending = model.pendingToggle else { return "" }
        return pending.turningOn ? String(localized: "Turn on \(pending.plugin.name)?")
            : String(localized: "Turn off \(pending.plugin.name)?")
    }

    /// What the host last reported, and the restart it asked for. The restart stays until it's requested.
    @ViewBuilder
    private var noticeSection: some View {
        if model.notice != nil || model.needsRestart {
            Section {
                if let notice = model.notice { PluginNoticeRow(notice: notice) }
                if model.needsRestart {
                    Button("Restart Gateway…") { isConfirmingRestart = true }
                        .disabled(model.isRestarting)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading plugins…")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Plugins", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            PluginFilterChips(model: model)
            let groups = model.groups
            if groups.isEmpty {
                ContentUnavailableView("No Plugins Match", systemImage: "puzzlepiece.extension")
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.plugins) { plugin in
                        PluginRow(plugin: plugin, isOn: model.isOn(plugin), isBusy: model.isToggling(plugin),
                                  removalReason: model.removalReason(for: plugin),
                                  onOpen: { openedPlugin = plugin.key },
                                  onUpdate: { Task { await model.update(plugin) } }) { turningOn in
                            model.requestToggle(plugin, to: turningOn)
                        }
                        .swipeActions { pluginActions(plugin) }
                        .contextMenu { pluginActions(plugin) }
                    }
                } header: {
                    Text(group.kind.title)
                }
            }
        }
    }
}

private extension PluginsView {
    /// A user install's way out. hermex-push and hermex-screen go to the pages that manage them,
    /// because each has its own pairing or hold to undo. Bundled plugins have none.
    @ViewBuilder
    func pluginActions(_ plugin: HermesPlugin) -> some View {
        if plugin.key == "hermex-push" {
            Button("Manage", systemImage: "gearshape") { isShowingPushSettings = true }
        } else if plugin.key == "hermex-screen" {
            Button("Manage", systemImage: "gearshape") { screenProfile = model.profile.map(InstallProfile.init) }
        } else if !plugin.isBundled {
            Button("Remove", systemImage: "trash", role: .destructive) { model.pendingRemoval = plugin }
        }
    }
}

/// The Profile a sheet was opened for, fixed for as long as it's up.
private struct InstallProfile: Identifiable {
    let name: String
    var id: String { name }

    init(_ name: String) { self.name = name }
}

private extension PluginsModel.Group.Kind {
    var title: String {
        switch self {
        case .updates: String(localized: "Updates")
        case .yours: String(localized: "Yours")
        case .bundled: String(localized: "Bundled")
        }
    }
}

private extension PluginsModel.Filter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .enabled: String(localized: "Enabled")
        case .off: String(localized: "Off")
        case .updates: String(localized: "Updates")
        case .yours: String(localized: "Yours")
        }
    }
}

/// The filters, each with how many rows it holds, in a row that scrolls sideways.
private struct PluginFilterChips: View {
    let model: PluginsModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PluginsModel.Filter.allCases, id: \.self) { filter in
                    PluginChip(title: "\(filter.title) \(model.count(of: filter))", isSelected: model.filter == filter) {
                        model.filter = filter
                    }
                }
            }
        }
        .scrollClipDisabled()
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// One dense plugin row: tap it for its page, and the switch shows the state asked for and stays off
/// limits until the host answers. An update has its own button, one plugin at a time.
private struct PluginRow: View {
    let plugin: HermesPlugin
    let isOn: Bool
    let isBusy: Bool
    /// Why Nous took this plugin out of the catalog, when it did.
    let removalReason: String?
    let onOpen: () -> Void
    let onUpdate: () -> Void
    let onChange: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: plugin.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !plugin.summary.isEmpty {
                        Text(verbatim: plugin.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    }
                    Text(verbatim: details)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let removalReason {
                        Text(removalReason.isEmpty ? String(localized: "Removed from the catalog.")
                                                   : String(localized: "Removed from the catalog: \(removalReason)"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if plugin.hasUpdate {
                Button(String(localized: "Update"), action: onUpdate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .accessibilityLabel(Text("Update \(plugin.name)"))
            }
            Toggle(isOn: Binding(get: { isOn }, set: onChange)) { Text(verbatim: plugin.name) }
                .labelsHidden()
                .disabled(isBusy)
        }
    }

    /// Its folder, which tells apart plugins with the same name, then its version and origin. While
    /// the host works, which can take minutes on a toggle that syncs packages, it says so instead.
    private var details: String {
        if isBusy { return String(localized: "Applying…") }
        return [plugin.category, plugin.version, plugin.origin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct PluginNoticeRow: View {
    let notice: PluginsModel.Notice

    var body: some View {
        switch notice {
        case .reported(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .font(.footnote)
        case .refused(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                .font(.footnote)
        case .unconfirmed(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange) }
                .font(.footnote)
        }
    }
}
