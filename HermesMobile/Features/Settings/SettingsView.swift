import SwiftUI

/// Settings' index (#1252): the configured servers, then one row per page. The Hermex pages
/// apply on this iPhone to every server; a server's own settings live on its page. Nothing
/// here waits on the network, so the index opens instantly.
struct SettingsView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    let onDefaultProfileSelected: (DefaultProfileSelection) -> Void

    init(
        authManager: AuthManager,
        server: URL,
        onDefaultProfileSelected: @escaping (DefaultProfileSelection) -> Void = { _ in }
    ) {
        self.authManager = authManager
        self.server = server
        self.onDefaultProfileSelected = onDefaultProfileSelected
    }

    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    @State private var isPresentingAddServer = false
    /// Read from the Keychain on each appear, so it follows a change made on the page.
    @State private var isPushOn = false

    var body: some View {
        List {
            Section(String(localized: "Servers")) {
                ForEach(authManager.servers) { account in
                    NavigationLink {
                        SettingsServerPage(
                            authManager: authManager,
                            account: account,
                            onDefaultProfileSelected: onDefaultProfileSelected
                        )
                    } label: {
                        SettingsServerRow(
                            account: account,
                            isActive: account.id == authManager.activeServerID,
                            movedTo: account.kind == .webui
                                ? authManager.moveRecord(forSource: account.id).map { MoveToHermesModel.name($0.destination) } : nil
                        )
                    }
                }

                Button {
                    isPresentingAddServer = true
                } label: {
                    SettingsLabel(title: String(localized: "Add Server"), systemImage: "plus.circle")
                }
                .accessibilityHint("Adds another Hermes server.")
            }

            Section {
                NavigationLink {
                    SettingsAppearancePage()
                } label: {
                    LabeledContent {
                        Text((AppTheme(rawValue: appThemeRawValue) ?? .system).title)
                    } label: {
                        SettingsLabel(title: String(localized: "Appearance"), systemImage: "circle.lefthalf.filled")
                    }
                }

                NavigationLink {
                    SettingsComposerPage()
                } label: {
                    SettingsLabel(title: String(localized: "Composer"), systemImage: "keyboard")
                }

                NavigationLink {
                    SettingsChatPage()
                } label: {
                    SettingsLabel(title: String(localized: "Chat"), systemImage: "text.bubble")
                }

                NavigationLink {
                    SettingsNotificationsPage(server: server)
                } label: {
                    #if targetEnvironment(macCatalyst)
                    SettingsLabel(title: String(localized: "Notifications"), systemImage: "bell")
                    #else
                    LabeledContent {
                        Text(isPushOn ? String(localized: "Push on") : String(localized: "Push off"))
                    } label: {
                        SettingsLabel(title: String(localized: "Notifications"), systemImage: "bell")
                    }
                    #endif
                }

                NavigationLink {
                    SettingsGeneralPage()
                } label: {
                    SettingsLabel(title: String(localized: "General"), systemImage: "gearshape")
                }
            } header: {
                Text(verbatim: "Hermex")
            } footer: {
                #if !targetEnvironment(macCatalyst)
                Text("Applies on this iPhone to every server.")
                #endif
            }

            Section {
                NavigationLink {
                    SettingsAboutPage()
                } label: {
                    LabeledContent {
                        Text(SettingsAboutPage.appVersion)
                    } label: {
                        SettingsLabel(title: String(localized: "About Hermex"), systemImage: "info.circle")
                    }
                }

                if SettingsDeveloperPage.isAvailable {
                    NavigationLink {
                        SettingsDeveloperPage()
                    } label: {
                        SettingsLabel(title: "Developer", systemImage: "hammer")
                    }
                }
            }
        }
        .macReadableForm(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .onAppear {
            isPushOn = PushRegistrar.shared?.pairing(for: server) != nil
        }
        .sheet(isPresented: $isPresentingAddServer) {
            AddServerView(authManager: authManager)
        }
    }
}

/// A server on the index: avatar, name, then its kind and host, or where it moved (B3, #1218).
/// The active server carries a checkmark.
private struct SettingsServerRow: View {
    let account: ServerAccount
    let isActive: Bool
    var movedTo: String?

    private var hostFallback: String {
        URL(string: account.urlString)?.host ?? account.urlString
    }

    private var name: String {
        account.displayName.isEmpty ? hostFallback : account.displayName
    }

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: account.displayName,
            storedInitials: account.initials,
            fallbackFullName: hostFallback
        )
    }

    /// The kind is a product name, so it stays untranslated.
    private var detail: String {
        if let movedTo { return String(localized: "Moved to \(movedTo)") }
        return (account.kind == .hermes ? "Hermes" : "webui") + " · " + hostFallback
    }

    var body: some View {
        HStack(spacing: 12) {
            ServerAvatarBadge(initials: previewInitials, colorHex: account.headerLogoColorHex)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isActive {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens server details to switch, edit, or remove.")
    }

    private var accessibilityLabel: String {
        let base = isActive ? String(localized: "\(name), \(account.urlString), active server") : String(localized: "\(name), \(account.urlString)")
        if let movedTo { return base + ", " + String(localized: "Moved to \(movedTo)") }
        return account.kind == .webui ? base + ", " + String(localized: "legacy webui server") : base
    }
}

#Preview {
    NavigationStack {
        SettingsView(authManager: AuthManager(), server: URL(staticString: "https://webui.example.test"))
    }
}
