import AuthenticationServices
import SwiftUI

struct ConnectedAppsView: View {
    @State private var model: ConnectedAppsModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    init(connection: BotConnection, server: URL) {
        _model = State(initialValue: ConnectedAppsModel(client: HermesConnectedAppsClient(saved: connection, server: server)))
    }

    var body: some View {
        AppList {
            if let profile = model.profile {
                ServerProfileRow(profiles: model.profiles, selection: profile,
                                 footer: "Connected apps run through Nous Portal. Connecting your first app creates a free Nous identity on this server if it has none.") { name in
                    Task { await model.select(name) }
                }
                .disabled(model.busyApp != nil)
            }
            content
        }
        .settingsPage(String(localized: "Connected Apps"))
        .listSectionSpacing(.compact)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search apps"))
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .ignoresSafeArea(.keyboard)
        .scrollDismissesKeyboard(.immediately)
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Couldn't Update Connected Apps", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading apps…")
            }
            .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Connected Apps", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .deadEnd(let deadEnd):
            ContentUnavailableView {
                Label(deadEnd.title, systemImage: deadEnd.systemImage)
            } description: {
                Text(deadEnd.explanation)
            } actions: {
                Button("Refresh") { Task { await model.load() } }
            }
            .listRowBackground(Color.clear)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        let connected = model.connected
        let available = model.available
        if !connected.isEmpty {
            Section("Connected") {
                ForEach(connected) { row($0) }
            }
        }
        if !model.categories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PluginChip(title: String(localized: "All"), isSelected: model.category == nil) { model.category = nil }
                    ForEach(model.categories, id: \.self) { category in
                        PluginChip(title: category, isSelected: model.category == category) { model.category = category }
                    }
                }
            }
            .scrollClipDisabled()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(available) { section in
            Section {
                ForEach(section.apps) { row($0) }
            } header: {
                Text(verbatim: section.id)
            }
        }
        if connected.isEmpty, available.isEmpty, !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func row(_ app: HermesConnectedApp) -> some View {
        let row = ConnectedAppRow(app: app, isBusy: model.busyApp == app.id, isLocked: model.busyApp != nil,
                                  connect: { Task { await model.connect(app, browse: browse) } },
                                  cancel: { Task { await model.cancel(app) } })
        if app.accounts.contains(where: { !$0.isPending }) {
            NavigationLink {
                ConnectedAppDetailView(appID: app.id, name: app.name, model: model)
            } label: {
                row
            }
        } else {
            row
        }
    }

    private func browse(_ link: URL) async {
        _ = try? await webAuthenticationSession.authenticate(
            using: link, callback: .customScheme(HermesConnectedAppsClient.returnScheme),
            preferredBrowserSession: .shared, additionalHeaderFields: [:])
    }
}

private struct ConnectedAppRow: View {
    let app: HermesConnectedApp
    let isBusy: Bool
    let isLocked: Bool
    let connect: () -> Void
    let cancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 12) {
                ConnectedAppLogo(app: app, side: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.name)
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.appPrimary)
                    if let note {
                        note
                            .font(AppFont.footnote())
                            .foregroundStyle(.appSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            controls
        }
        .opacity(app.state == .turnedOff ? 0.5 : 1)
    }

    private var note: Text? {
        switch app.state {
        case .waiting: Text("Waiting for sign-in")
        case .needsReconnect: Text("Needs reconnecting")
        case .turnedOff: Text("Turned off in Nous Portal")
        case .notConnected, .connected: app.summary.map { Text(verbatim: $0) }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if isBusy {
            Text("Working…")
                .font(AppFont.footnote())
                .foregroundStyle(.appSecondary)
        } else {
            switch app.state {
            case .notConnected: action("Connect", connect)
            case .needsReconnect: action("Reconnect", connect)
            case .waiting:
                HStack(spacing: 4) {
                    action("Continue", connect)
                    Button(action: cancel) { Text("Cancel") }
                        .buttonStyle(.borderless)
                        .font(AppFont.footnote())
                        .tint(Color(.appTextSecondary))
                        .disabled(isLocked)
                        .accessibilityLabel(Text("Cancel") + Text(verbatim: ", \(app.name)"))
                }
            case .connected:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Connected"))
            case .turnedOff: EmptyView()
            }
        }
    }

    private func action(_ title: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(title) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .font(AppFont.footnote(weight: .semibold))
            .disabled(isLocked)
            .accessibilityLabel(Text(title) + Text(verbatim: ", \(app.name)"))
    }
}

struct ConnectedAppLogo: View {
    let app: HermesConnectedApp
    let side: CGFloat

    var body: some View {
        Group {
            if let logo = UIImage(named: "ConnectedApps/\(app.id)") {
                Image(uiImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.16)
                    .background(.white)
            } else {
                Text(verbatim: String(app.name.prefix(1)).uppercased())
                    .font(AppFont.fixed(size: side * 0.45, weight: .semibold))
                    .foregroundStyle(.appSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.appFill))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ConnectedAppDetailView: View {
    let appID: String
    let name: String
    let model: ConnectedAppsModel

    @State private var removing: HermesConnectedApp.Account?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let app = model.app(appID)
        AppList {
            if let app {
                Section {
                    VStack(spacing: 8) {
                        ConnectedAppLogo(app: app, side: 64)
                        if let summary = app.summary {
                            Text(verbatim: summary)
                                .font(AppFont.subheadline())
                                .foregroundStyle(.appSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section("Accounts") {
                    ForEach(app.accounts) { account in
                        LabeledContent {
                            Button("Disconnect", role: .destructive) { removing = account }
                                .buttonStyle(.borderless)
                                .disabled(model.busyApp != nil)
                                .accessibilityLabel(Text("Disconnect") + Text(verbatim: ", \(account.title)"))
                        } label: {
                            Text(verbatim: account.title)
                                .foregroundStyle(.appPrimary)
                            Text(account.isConnected ? "Connected" : account.isPending ? "Waiting for sign-in" : "Needs reconnecting")
                                .font(AppFont.footnote())
                                .foregroundStyle(.appSecondary)
                        }
                    }
                }
            }
        }
        .settingsPage(name)
        .alert(Text("Disconnect \(name)?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { account in
            Button("Disconnect", role: .destructive) {
                guard let app else { return }
                Task { await model.disconnect(account, of: app) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Hermes on this server will lose access to this \(name) account for the \(model.profile ?? "") Profile.")
        }
        .onChange(of: app?.accounts.isEmpty != false) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}

private extension HermesConnectedAppsDeadEnd {
    var title: LocalizedStringKey {
        switch self {
        case .hostTooOld: "This Hermes Is Too Old"
        case .unavailable: "Connected Apps Aren't Available"
        case .needsNousSignIn: "Nous Sign-In Needed"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .hostTooOld: "Connected apps need a newer Hermes release. Update Hermes on your server, then refresh."
        case .unavailable: "They are turned off on this server, or this Profile's Nous account doesn't include them."
        case .needsNousSignIn: "This Profile isn't signed in to Nous Portal. Sign in on the server, then refresh."
        }
    }

    var systemImage: String {
        switch self {
        case .hostTooOld: "arrow.up.circle"
        case .unavailable: "nosign"
        case .needsNousSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }
}
