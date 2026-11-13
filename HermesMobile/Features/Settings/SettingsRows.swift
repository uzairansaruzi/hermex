import SwiftData
import SwiftUI
import UIKit

extension View {
    /// A Settings page's list (#1252): inset grouped, titled inline under the index's large title.
    func settingsPage(_ title: String) -> some View {
        listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Profile a server page lists and writes to, a menu of the others when the host has more than one.
struct ServerProfileRow: View {
    let profiles: [String]
    let selection: String
    var footer: LocalizedStringKey?
    let onSelect: (String) -> Void

    var body: some View {
        Section {
            if profiles.count > 1 {
                Picker("Profile", selection: Binding(get: { selection }, set: onSelect)) {
                    ForEach(profiles, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .pickerStyle(.menu)
            } else {
                LabeledContent("Profile") { Text(verbatim: selection) }
            }
        } appFooter: {
            if let footer { Text(footer) }
        }
    }
}

/// A Settings row's title beside its gray glyph, with an optional note under the title for what
/// the row needs explained.
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    var note: String?

    var body: some View {
        Label {
            if let note {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(note)
                        .font(AppFont.footnote())
                        .foregroundStyle(.appSecondary)
                }
            } else {
                Text(title)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.appSecondary)
        }
    }
}

/// A row that opens a web page or iOS Settings, marked with an outward arrow.
struct SettingsExternalLink: View {
    let title: String
    let systemImage: String
    let destination: URL
    var accessibilityLabel: String?

    var body: some View {
        Link(destination: destination) {
            LabeledContent {
                Image(systemName: "arrow.up.forward")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(.appTertiary)
            } label: {
                SettingsLabel(title: title, systemImage: systemImage)
            }
        }
        .foregroundStyle(.appPrimary)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

/// Small circular avatar (initials + per-server Header Logo Color) for server rows.
struct ServerAvatarBadge: View {
    let initials: String
    let colorHex: String
    var size: CGFloat = 32

    var body: some View {
        Text(initials)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(HeaderLogoColor.prefersDarkForeground(for: colorHex) ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(HeaderLogoColor.color(for: colorHex), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct SettingsStatusPill: View {
    let label: String
    var tint: Color = Color(.appTextSecondary)

    var body: some View {
        Text(label)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct SettingsTextFieldRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .words
    var isSecure = false
    var submitLabel: SubmitLabel = .return
    /// Title above a full-width field at every text size, for values too long for the
    /// trailing field, such as a server address.
    var isStacked = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize || isStacked {
                VStack(alignment: .leading, spacing: 6) {
                    titleLabel
                    textField
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 12) {
                    titleLabel

                    Spacer(minLength: 12)

                    textField
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 190)
                }
            }
        }
    }

    private var titleLabel: some View {
        Text(title)
            .font(AppFont.subheadline())
    }

    @ViewBuilder
    private var textField: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(AppFont.subheadline())
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled()
        .keyboardType(keyboardType)
        .submitLabel(submitLabel)
        .onSubmit { onSubmit?() }
    }
}

struct HeaderLogoColorSettings: View {
    @Binding var selectedHex: String
    let customColor: Binding<Color>

    private var selectedColorName: String {
        HeaderLogoColor.displayName(for: selectedHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Header Logo Color")
                    .foregroundStyle(.appPrimary)

                Spacer(minLength: 12)

                Text(selectedColorName)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.appSecondary)
            }
            .font(AppFont.subheadline())

            HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: selectedHex))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                ForEach(HeaderLogoColor.presets) { preset in
                    HeaderLogoColorPresetButton(
                        preset: preset,
                        isSelected: HeaderLogoColor.normalizedHex(selectedHex) == preset.hex
                    ) {
                        selectedHex = preset.hex
                    }
                }
            }

            ColorPicker("Custom", selection: customColor, supportsOpacity: false)
                .font(AppFont.subheadline())
        }
    }
}

private struct HeaderLogoColorPresetButton: View {
    let preset: HeaderLogoColorPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(preset.color)
                    .overlay(Circle().stroke(Color(.appText).opacity(0.18), lineWidth: 1))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(preset.hex == "#FFFFFF" ? .black : .white)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 34, height: 34)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(preset.name) header logo color"))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Updates the Sessions header logo color.")
    }
}

/// A server page's Main Page switches (#190): which entries the home lists above its sessions.
/// The switches are app-wide, so a webui page and a Hermes page (#1585) show the same ones;
/// `includesWebuiEntries` adds the two only a webui home has, Active Profile and Bot Mode.
struct MainPageSettingsSection: View {
    let includesWebuiEntries: Bool

    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasks = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanban = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkills = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemory = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsights = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) private var showsActiveProfile = true
    @AppStorage(SectionVisibilitySettings.projectsKey) private var showsProjects = true
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false

    var body: some View {
        Section {
            Toggle(isOn: $showsTasks) {
                SettingsLabel(title: String(localized: "Tasks"), systemImage: "calendar.badge.clock")
            }

            Toggle(isOn: $showsKanban) {
                SettingsLabel(title: String(localized: "Kanban"), systemImage: "rectangle.split.3x1")
            }

            Toggle(isOn: $showsSkills) {
                SettingsLabel(title: String(localized: "Skills"), systemImage: "hammer")
            }

            Toggle(isOn: $showsMemory) {
                SettingsLabel(title: String(localized: "Memory"), systemImage: "brain")
            }

            Toggle(isOn: $showsInsights) {
                SettingsLabel(title: String(localized: "Usage"), systemImage: "chart.bar")
            }

            if includesWebuiEntries {
                Toggle(isOn: $showsActiveProfile) {
                    SettingsLabel(title: String(localized: "Active Profile"), systemImage: "person.crop.circle")
                }
            }

            Toggle(isOn: $showsProjects) {
                SettingsLabel(title: String(localized: "Projects"), systemImage: "folder.badge.gearshape")
            }

            if includesWebuiEntries {
                Toggle(isOn: $isBotModeEnabled) {
                    SettingsLabel(
                        title: String(localized: "Bot Mode (beta)"),
                        systemImage: "cpu",
                        note: String(localized: "Adds a Bots row to this server's home.")
                    )
                }
            }
        } header: {
            Text("Main Page")
        } appFooter: {
            Text("An entry you turn off comes back only from here.")
        }
    }
}

/// A Hermes server's CLI and Messaging Sessions switch (#1674), on until turned off. It hides
/// every row with a source chip from that server's list; the host keeps them.
struct HermesCliSessionsToggle: View {
    @AppStorage private var showsCliSessions: Bool

    init(server: URL) {
        _showsCliSessions = AppStorage(wrappedValue: true, SessionRowDisplaySettings.showCliSessionsKey(for: server))
    }

    var body: some View {
        Toggle(isOn: $showsCliSessions) {
            SettingsLabel(title: String(localized: "CLI and Messaging Sessions"), systemImage: "terminal")
        }
    }
}

/// The Cron Sessions switch on a server page's Sessions section: off, a home lists no cron
/// session, Scheduled included. App-wide, like the Main Page switches.
struct CronSessionsToggle: View {
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true

    var body: some View {
        Toggle(isOn: $showsCronSessions) {
            SettingsLabel(title: String(localized: "Cron Sessions"), systemImage: "clock.arrow.2.circlepath")
        }
    }
}

/// The Message Count and Workspace switches on a server page's Sessions section: whether a
/// session row shows them. App-wide, like the Main Page switches.
struct SessionRowDisplayToggles: View {
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true

    var body: some View {
        Toggle(isOn: $showsSessionMessageCount) {
            SettingsLabel(title: String(localized: "Message Count"), systemImage: "number")
        }

        Toggle(isOn: $showsSessionWorkspace) {
            SettingsLabel(title: String(localized: "Workspace"), systemImage: "folder")
        }
    }
}

/// The active server page's Offline Data section: Clear Offline Cache deletes this server's
/// offline data (`clear`), never another server's, its drafts, or its push pairing. The alert
/// sits on the button, since a Section's own modifiers run once per row (#1255).
struct OfflineDataSection: View {
    let server: URL

    @Environment(\.modelContext) private var modelContext
    @State private var isConfirming = false
    @State private var isClearing = false
    @State private var statusMessage: String?

    var body: some View {
        Section {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                if isClearing {
                    ProgressView()
                } else {
                    Text("Clear Offline Cache")
                }
            }
            .disabled(isClearing)
            .alert("Clear this server's cache?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Cache", role: .destructive) {
                    Task { await clearTapped() }
                }
            } message: {
                Text("This server's cached sessions and messages will be deleted. Other servers and online server data are not affected.")
            }
        } header: {
            Text("Offline Data")
        } appFooter: {
            Text(statusMessage ?? String(localized: "Clears this server's cache only."))
        }
    }

    private func clearTapped() async {
        guard !isClearing else { return }
        isClearing = true
        do {
            try await Self.clear(server: server, in: modelContext)
            statusMessage = String(localized: "This server's offline cache was cleared.")
        } catch {
            statusMessage = String(localized: "Could not clear offline cache.")
        }
        isClearing = false
    }

    /// Deletes `server`'s cached sessions and messages, Bot room history, and Bot roster, leaving
    /// every other server's (#18). Each refills on the server's next online load.
    @MainActor
    static func clear(
        server: URL,
        in context: ModelContext,
        history: BotHistoryCache = .shared,
        roster: BotRosterCache = .shared
    ) async throws {
        try CacheStore.clearCache(for: server, in: context)
        try await history.remove(server: server)
        await roster.remove(server: server)
    }
}
