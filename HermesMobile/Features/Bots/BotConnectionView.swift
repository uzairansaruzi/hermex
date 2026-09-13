import SwiftUI

@MainActor struct BotConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    let server: URL
    @State private var saved: BotConnection?
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var confirmingRemoval = false
    @State private var client: BotClient?
    @State private var connectTask: Task<Void, Never>?
    private let store = BotConnectionStore()

    var body: some View {
        Form {
            Section {
                Text(server.host ?? server.absoluteString).font(.footnote).foregroundStyle(.secondary)
                TextField("Name", text: $name)
                TextField("Hermes address", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username", text: $username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
            } header: { Text("Bot connection") } footer: {
                Text("This connection belongs to the selected Hermex server. Use the address and password of your existing Hermes backend on LAN or Tailscale.")
            }
            Section {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button(isConnecting ? String(localized: "Connecting…") : String(localized: "Connect")) {
                    connectTask = Task { await connect() }
                }
                .disabled(isConnecting || address.isEmpty || username.isEmpty || password.isEmpty)
            } footer: {
                if let note = saved?.untestedVersionNote { Text(note) }
            }
            Section("Setup in Hermes Desktop") {
                Text("Keep Hermes Desktop running. In Settings → Advanced, enable Keep computer awake. The display may dim.")
                Text("In Settings → Plugins, enable Bots for the intended Profile. Applies to selects the Profile configuration being edited.")
                Text("Desktop and Hermex must use the same password-protected backend. Remote gateway connects Desktop to a backend; it does not expose Desktop’s private local backend to your phone.")
                Text("Open each bot’s Bot Chat in Desktop first. Do not start a second backend using the same Profile storage.")
                Text("Connecting loads the bot roster and may recover archived Bot Chats. Opening a chat may resume unfinished work. Approvals are answered in Desktop.")
            }
            if saved != nil {
                Section {
                    Button("Remove bot connection…", role: .destructive) { confirmingRemoval = true }
                }
            }
        }
        .navigationTitle("Bot connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task {
            do {
                saved = try store.load(server: server)
                name = saved?.name ?? ""
                address = saved?.address.absoluteString ?? ""
                username = saved?.username ?? ""
                password = saved?.password ?? ""
            } catch { errorMessage = String(localized: "Could not read saved sign-in details.") }
        }
        .onDisappear { connectTask?.cancel(); client?.close(); client = nil }
        .confirmationDialog("Remove this connection from Hermex?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove bot connection", role: .destructive) {
                Task {
                    do {
                        try store.remove(server: server)
                        if let saved {
                            await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: saved.id)
                            BotAvatarStore.shared.removeAll(connectionID: saved.id)
                            BotUnreadStore().remove(connectionID: saved.id)
                        }
                        dismiss()
                    } catch { errorMessage = String(localized: "Could not remove saved sign-in details.") }
                }
            }
        } message: {
            Text("Saved sign-in details and this connection’s drafts will be deleted. Bots and their work remain on the host.")
        }
    }

    private func connect() async {
        guard !isConnecting else { return }
        isConnecting = true; errorMessage = nil
        defer { if !Task.isCancelled { isConnecting = false } }
        do {
            let url = try BotConnection.address(address)
            let sameAccount = saved?.address == url && saved?.username == username
            var candidate = BotConnection(id: sameAccount ? saved!.id : UUID(),
                                          name: name.isEmpty ? (url.host ?? "Hermes") : name,
                                          address: url, username: username, password: password)
            let wire = BotClient(connection: candidate)
            client = wire
            defer { wire.close() }
            try await wire.connect()
            guard !Task.isCancelled, client === wire else { return }
            candidate.hermesVersion = wire.serverVersion
            let result = try await wire.call("profiles.list", ["include_sessions": .bool(true)])
            guard !Task.isCancelled, client === wire else { return }
            guard result["profiles"].list != nil else { throw BotFailure.unsupported }
            try store.save(candidate, server: server)
            if let saved, saved.id != candidate.id {
                await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: saved.id)
                BotAvatarStore.shared.removeAll(connectionID: saved.id)
            }
            guard !Task.isCancelled, client === wire else { return }
            saved = candidate
            // An untested release keeps the screen up so the note is seen once; Done closes it.
            if candidate.untestedVersionNote == nil { dismiss() }
        } catch {
            guard !Task.isCancelled, client != nil else { return }
            errorMessage = (error as? BotFailure)?.localizedDescription ?? String(localized: "Could not save sign-in details or connect to Hermes.")
        }
    }
}
