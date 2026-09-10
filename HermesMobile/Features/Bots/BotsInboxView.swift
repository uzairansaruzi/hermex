import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: URL
    let showSessions: () -> Void
    @State private var connection: BotConnection?
    @State private var profiles: [BotProfile] = []
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var showingSetup = false
    @State private var revision = UUID()
    @State private var loadOwner = UUID()
    @State private var wire: BotClient?
    private let store = BotConnectionStore()

    private var filteredProfiles: [BotProfile] {
        profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        List {
            Picker("Screen", selection: Binding(get: { true }, set: { if !$0 { showSessions() } })) {
                Text("Sessions").tag(false)
                Text("Bots").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if let connection {
                Text(connection.name)
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                if let errorMessage {
                    Text(errorMessage).font(.callout)
                    Button("Reconnect") { revision = UUID() }
                } else if loading {
                    Text("Connecting…")
                } else if profiles.isEmpty {
                    Text("No bots found. Create one in Hermes Desktop, then refresh.")
                }
                ForEach(filteredProfiles) { profile in
                    NavigationLink {
                        BotChatView(server: server, connection: connection, profile: profile)
                            .id(profile.id + connection.id.uuidString)
                    } label: {
                        BotInboxRow(profile: profile)
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
        .task(id: revision) { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { revision = UUID() }
            else { wire?.close() }
        }
        .onDisappear { loadOwner = UUID(); wire?.close(); wire = nil }
    }

    private func load() async {
        wire?.close()
        let owner = UUID()
        loadOwner = owner
        // The stored client identity is the load owner; a replacement invalidates late results.
        do {
            let saved = try store.load(server: server)
            if connection?.id != saved?.id { profiles = [] }
            connection = saved
            guard let saved else { return }
            let client = BotClient(connection: saved)
            wire = client; loading = true; errorMessage = nil
            defer { if wire === client { loading = false } }
            try await client.connect()
            guard !Task.isCancelled, wire === client else { return }
            let roster = try await client.call("profiles.list", ["include_sessions": .bool(true)])
            guard !Task.isCancelled, wire === client else { return }
            guard let rows = roster["profiles"].list else { throw BotFailure.unsupported }
            var seen = Set<String>()
            profiles = rows.compactMap(BotProfile.init).filter { seen.insert($0.id).inserted }
            client.close()
        } catch {
            guard !Task.isCancelled, loadOwner == owner else { return }
            errorMessage = (error as? BotFailure ?? .transport).localizedDescription
            loading = false
        }
    }
}

private struct BotInboxRow: View {
    let profile: BotProfile
    private var color: Color {
        let colors: [Color] = [.green, .orange, .purple, .pink, .blue, .teal]
        let value = profile.id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[value]
    }
    var body: some View {
        HStack(spacing: 16) {
            Text(String(profile.name.prefix(1))).font(.title2.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(.headline)
                    Spacer()
                    if let date = profile.lastActive {
                        Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(profile.preview?.isEmpty == false ? profile.preview! : profile.id)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
