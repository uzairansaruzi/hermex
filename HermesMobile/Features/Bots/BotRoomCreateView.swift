import SwiftUI

@MainActor struct BotRoomCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var creator: BotRoomCreator
    @State private var naming = false
    @FocusState private var focused: Field?
    private enum Field { case members, name }
    let avatars: [String: UIImage]
    let onCreated: (BotGroupRoom) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if naming { nameStep }
                else { membersStep }
            }
            .navigationTitle("New Group Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(naming && !creator.locked ? "Back" : "Cancel",
                           systemImage: naming && !creator.locked ? "chevron.backward" : "xmark") {
                        if naming && !creator.locked { naming = false; focused = .members }
                        else { dismiss() }
                    }
                }
                if !naming {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") { naming = true; focused = .name }
                            .disabled(!creator.mayContinue)
                    }
                }
            }
            .task { focused = .members }
            .onChange(of: creator.created) {
                if let room = creator.created { onCreated(room); dismiss() }
            }
            .onChange(of: scenePhase) { if scenePhase != .active { creator.suspend() } }
            .onDisappear { creator.suspend() }
        }
        .interactiveDismissDisabled(creator.busy)
    }

    private var membersStep: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("To:").foregroundStyle(.secondary)
                    if !creator.selected.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            chips
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(creator.selected) { bot in chip(bot) }
                            }
                        }
                    }
                    TextField("Add another", text: $creator.query)
                        .focused($focused, equals: .members)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Find group members")
                }
                .padding(.vertical, 8)
            } footer: {
                if creator.selected.count == 6 { Text("Groups can have up to six members.") }
                else { Text("Choose two to six bots.") }
            }
            Section {
                ForEach(creator.remaining) { bot in
                    Button { creator.select(bot) } label: {
                        HStack(spacing: 14) {
                            BotAvatarView(profile: bot, avatar: avatars[bot.id], size: 36, motion: .still)
                            Text(bot.name).foregroundStyle(.primary)
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(creator.selected.count >= 6)
                    .accessibilityLabel("Add \(bot.name)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    private var chips: some View {
        HStack(spacing: 8) { ForEach(creator.selected) { bot in chip(bot) } }
            .fixedSize(horizontal: true, vertical: false)
    }
    private func chip(_ bot: BotProfile) -> some View {
        Button { creator.remove(bot) } label: {
            HStack(spacing: 6) {
                BotAvatarView(profile: bot, avatar: avatars[bot.id], size: 24, motion: .still)
                Text(bot.name)
                Image(systemName: "xmark").font(.caption)
            }
            .padding(8).background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(bot.name)")
    }
    private var nameStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                BotRoomAvatars(room: creator.preview, roster: creator.roster, avatars: avatars, size: 84)
                    .padding(.top, 48)
                TextField("Group name", text: $creator.name)
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                    .focused($focused, equals: .name).disabled(creator.locked)
                    .submitLabel(.done)
                    .onSubmit { if creator.mayCreate { Task { await creator.create() } } }
                if !BotRoomRPC.validName(creator.name) {
                    Text("Enter a name of up to 200 characters.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = creator.message { Text(message).font(.callout) }
                Button(creator.busy ? "Creating…" : creator.locked ? "Try Again" : "Create") {
                    focused = nil
                    Task { await creator.create() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!creator.mayCreate)
            }
            .padding(20)
        }
    }
}
