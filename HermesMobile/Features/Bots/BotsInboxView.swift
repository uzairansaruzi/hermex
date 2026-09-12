import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: URL
    let showSessions: () -> Void
    @State private var inbox: BotInbox
    @State private var search = ""
    @State private var showingSetup = false
    @State private var revision = UUID()

    init(server: URL, showSessions: @escaping () -> Void) {
        self.server = server
        self.showSessions = showSessions
        _inbox = State(initialValue: BotInbox(server: server))
    }

    private var filteredProfiles: [BotProfile] {
        inbox.profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        List {
            Picker("Screen", selection: Binding(get: { true }, set: { if !$0 { showSessions() } })) {
                Text("Sessions").tag(false)
                Text("Bots").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if let connection = inbox.connection {
                Text(connection.name)
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                if let errorMessage = inbox.errorMessage {
                    Text(errorMessage).font(.callout)
                    Button("Reconnect") { revision = UUID() }
                } else if inbox.link == .connecting {
                    Text("Connecting…")
                } else if inbox.profiles.isEmpty {
                    Text("No bots found. Create one in Hermes Desktop, then refresh.")
                }
                ForEach(filteredProfiles) { profile in
                    NavigationLink {
                        BotChatView(server: server, connection: connection, profile: profile)
                            .id(profile.id + connection.id.uuidString)
                            .onAppear { inbox.markSeen(profile) }
                            .onDisappear { inbox.noteReturn(from: profile) }
                    } label: {
                        BotInboxRow(profile: profile, avatar: inbox.avatars[profile.id])
                    }
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 10)
                }
            } else {
                ContentUnavailableView("Connect to Hermes", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Use your existing Hermes setup to talk to your bots."))
                Button("Connect to Hermes") { showingSetup = true }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Bots")
        .searchable(text: $search, prompt: "Search bots")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bot connection", systemImage: "gearshape") { showingSetup = true }
            }
        }
        .sheet(isPresented: $showingSetup, onDismiss: { revision = UUID() }) {
            NavigationStack { BotConnectionView(server: server) }
        }
        // The subscription lives while the inbox is on screen and the app is active;
        // returning, refreshing and reconnecting all go through the same open().
        .task(id: revision) { await inbox.open() }
        .refreshable { await inbox.open() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { revision = UUID() }
            else { inbox.close() }
        }
        .onDisappear { inbox.close() }
    }
}

/// One roster row: the Desktop avatar when the host has one, otherwise a letter
/// tile; the server name; and the canonical preview, else the description, else
/// the Profile name. The avatar is decorative; VoiceOver reads the text as one element.
private struct BotInboxRow: View {
    let profile: BotProfile
    let avatar: UIImage?
    private var color: Color {
        let colors: [Color] = [.green, .orange, .purple, .pink, .blue, .teal]
        let value = profile.id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[value]
    }
    private var subline: String {
        if let preview = profile.preview, !preview.isEmpty { return preview }
        return profile.description ?? profile.id
    }
    var body: some View {
        HStack(spacing: 16) {
            tile
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(.headline)
                    Spacer()
                    if let date = profile.lastActive {
                        Text(SessionRelativeDateFormatter.shared.localizedString(for: date, relativeTo: Date())).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(subline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var tile: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
        } else {
            Text(String(profile.name.prefix(1))).font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(color).accessibilityHidden(true)
        }
    }
}
