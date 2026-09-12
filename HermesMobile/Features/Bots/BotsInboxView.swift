import SwiftUI

@MainActor struct BotsInboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    let server: URL
    let showSessions: () -> Void
    @State private var inbox: BotInbox
    @State private var search = ""
    @State private var showingSetup = false
    @State private var revision = UUID()
    /// The bot whose chat is open. One destination serves the hero tiles and the
    /// rows, so a row shows no disclosure accessory and tiles sharing a row keep
    /// separate tap targets.
    @State private var openProfile: BotProfile?

    init(server: URL, showSessions: @escaping () -> Void) {
        self.server = server
        self.showSessions = showSessions
        _inbox = State(initialValue: BotInbox(server: server))
    }

    var body: some View {
        let rows = inbox.rows(matching: search)
        List {
            Picker("Screen", selection: Binding(get: { true }, set: { if !$0 { showSessions() } })) {
                Text("Sessions").tag(false)
                Text("Bots").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if inbox.connection != nil {
                if let errorMessage = inbox.errorMessage {
                    Text(errorMessage).font(.callout)
                    Button("Reconnect") { revision = UUID() }
                } else if inbox.link == .connecting && inbox.profiles.isEmpty {
                    Text("Connecting…")
                } else if inbox.profiles.isEmpty && inbox.link == .live {
                    Text("No bots found. Create one in Hermes Desktop, then refresh.")
                }
                if let notice = inbox.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).listRowSeparator(.hidden)
                }
                if !rows.pinned.isEmpty {
                    // Pinned bots sit above the list as large tiles, as in Desktop's mobile roster.
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(rows.pinned) { profile in
                            Button { openProfile = profile } label: {
                                BotHeroTile(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { organizeMenu(profile) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowSeparator(.hidden)
                }
                ForEach(rows.others) { profile in
                    row(profile, dimmed: false)
                }
                ForEach(rows.hidden) { profile in
                    row(profile, dimmed: true)
                }
                if inbox.hiddenCount > 0 && search.isEmpty {
                    Button(inbox.showsHidden ? "Hide hidden bots" : "Show hidden bots (\(inbox.hiddenCount))") {
                        inbox.showsHidden.toggle()
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
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
        .navigationDestination(item: $openProfile) { profile in
            if let connection = inbox.connection { chat(profile, connection) }
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

    private func row(_ profile: BotProfile, dimmed: Bool) -> some View {
        Button { openProfile = profile } label: {
            BotInboxRow(profile: profile, avatar: inbox.avatars[profile.id], unread: inbox.isUnread(profile))
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? 0.5 : 1)
        .contextMenu { organizeMenu(profile) }
        .listRowSeparator(.hidden)
        .padding(.vertical, 12)
    }

    private func chat(_ profile: BotProfile, _ connection: BotConnection) -> some View {
        BotChatView(server: server, connection: connection, profile: profile)
            .id(profile.id + connection.id.uuidString)
            .onAppear { inbox.markSeen(profile) }
            .onDisappear { inbox.noteReturn(from: profile) }
    }

    /// Pin and hide write Desktop's own roster fields; both stay inert until the
    /// inbox is live and no write for this bot is in flight.
    @ViewBuilder private func organizeMenu(_ profile: BotProfile) -> some View {
        Button {
            Task { await inbox.setPinned(!profile.pinned, profile) }
        } label: {
            Label(profile.pinned ? "Unpin" : "Pin", systemImage: profile.pinned ? "pin.slash" : "pin")
        }
        Button {
            Task { await inbox.setHidden(!profile.hidden, profile) }
        } label: {
            Label(profile.hidden ? "Unhide" : "Hide bot", systemImage: profile.hidden ? "eye" : "eye.slash")
        }
        .disabled(!inbox.mayEdit(profile))
    }
}

/// A pinned bot: the avatar large and centered with the name beneath it.
private struct BotHeroTile: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    var body: some View {
        VStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 84)
            HStack(spacing: 6) {
                Text(profile.name).font(.body).foregroundStyle(.secondary)
                if unread { BotUnreadDot() }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One roster row: avatar, name with an optional short Desktop description chip,
/// the last activity, then the canonical preview with a trailing unread mark.
/// The avatar is decorative; VoiceOver reads the text as one element.
private struct BotInboxRow: View {
    let profile: BotProfile
    let avatar: UIImage?
    let unread: Bool
    /// A description short enough to read as a role sits beside the name; a
    /// longer one only stands in for the preview when the chat has none.
    private var chip: String? {
        guard let description = profile.description, description.count <= 24,
              profile.preview?.isEmpty == false else { return nil }
        return description
    }
    private var subline: String {
        if let preview = profile.preview, !preview.isEmpty { return preview }
        return profile.description ?? profile.id
    }
    var body: some View {
        HStack(spacing: 14) {
            BotAvatarView(profile: profile, avatar: avatar, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    if let chip {
                        Text(chip).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                            .layoutPriority(-1)
                    }
                    Spacer(minLength: 8)
                    if let date = profile.lastActive {
                        Text(BotInboxDateLabel.text(for: date)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(subline).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if unread { BotUnreadDot() }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Desktop avatar fitted into a square, or a letter tile on a tinted circle.
/// Desktop assets are shapes on a transparent background, so they are not clipped.
private struct BotAvatarView: View {
    let profile: BotProfile
    let avatar: UIImage?
    let size: CGFloat
    private var color: Color {
        let colors: [Color] = [.green, .orange, .purple, .pink, .blue, .teal]
        let value = profile.id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[value]
    }
    var body: some View {
        if let avatar {
            Image(uiImage: avatar).resizable().scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(String(profile.name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .background(color.opacity(0.2), in: Circle())
                .foregroundStyle(color).accessibilityHidden(true)
        }
    }
}

/// Static unread mark. It never animates; VoiceOver reads it as "Unread".
private struct BotUnreadDot: View {
    var body: some View {
        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
            .accessibilityLabel("Unread")
    }
}

/// Last-activity label in the roster's style: the time today, the weekday within
/// the past week, otherwise the month and day.
enum BotInboxDateLabel {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo, date < now {
            return date.formatted(style.weekday(.wide))
        }
        return date.formatted(style.month(.abbreviated).day())
    }
}
