import SwiftUI
import Observation

@MainActor struct BotConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var setup: BotConnectionSetup
    @State private var operation: Task<Void, Never>?
    @State private var confirmingRemoval = false
    @State private var copiedPrompt = false

    init(server: URL) { _setup = State(initialValue: BotConnectionSetup(server: server)) }

    var body: some View {
        Form {
            Section {
                Text("Connect to your dashboard").font(.title3.bold())
                Text("Use your Hermes dashboard sign-in.").foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            Section {
                TextField("Hermes address", text: $setup.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("hermes-connection-address")
                TextField("Username", text: $setup.username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $setup.password).textContentType(.password)
            } footer: {
                Text("Domains, Tailscale names and IP addresses work. You can include http:// or https://.")
            }
            .disabled(setup.isConnecting)
            Section {
                if let error = setup.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("hermes-connection-error")
                }
                Button(setup.isConnecting ? String(localized: "Connecting…") : String(localized: "Connect")) {
                    operation = Task { if await setup.connect(), !Task.isCancelled { dismiss() } }
                }
                .frame(maxWidth: .infinity)
                .disabled(!setup.canConnect)
                .accessibilityIdentifier("hermes-connection-connect")
                if setup.offersHostReplacement {
                    Button("Connect to this host instead", role: .destructive) {
                        operation = Task { if await setup.connect(replacingHost: true), !Task.isCancelled { dismiss() } }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("hermes-connection-replace-host")
                }
            } footer: {
                if setup.offersHostReplacement {
                    Text("Connecting to this host instead clears this connection’s drafts, cached chats and notification pairing on this iPhone.")
                }
            }
            Section("Need your connection details?") {
                Text("Copy a prompt for your Hermes agent. It will check your setup and help you find the right address and sign-in details.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(copiedPrompt ? String(localized: "Copied") : String(localized: "Copy setup prompt"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = BotConnectionSetup.prompt
                    copiedPrompt = true
                }
                DisclosureGroup("Manual setup") {
                    Text("Keep Hermes Desktop running. In Settings → Advanced, enable Keep computer awake. The display may dim.")
                    Text("In Settings → Plugins, enable Bots for the intended Profile. Applies to selects the Profile configuration being edited.")
                    Text("Desktop and Hermex must use the same password-protected backend. Remote gateway connects Desktop to a backend; it does not expose Desktop’s private local backend to your phone.")
                    Text("Open each bot’s Bot Chat in Desktop first. Do not start a second backend using the same Profile storage.")
                }
            }
            Section {
                DisclosureGroup("Connection name · optional") {
                    TextField("Name", text: $setup.name).disabled(setup.isConnecting)
                }
            }
            if setup.saved != nil {
                Section {
                    Button("Remove Hermes connection…", role: .destructive) { confirmingRemoval = true }
                        .disabled(setup.isConnecting)
                }
            }
        }
        .navigationTitle("Hermes connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { setup.load() }
        .onDisappear { operation?.cancel(); setup.cancel() }
        .confirmationDialog("Remove this connection from Hermex?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Hermes connection", role: .destructive) {
                operation = Task { if await setup.remove(), !Task.isCancelled { dismiss() } }
            }
        } message: {
            Text("Saved sign-in details, this connection’s drafts and its notification keys will be deleted. This iPhone stops receiving this host’s notifications. Bots and their work remain on the host.")
        }
    }
}

/// Owns one sign-in attempt. Parsing failures and late transport replies obey the
/// same lifetime, including attempts cancelled before a client was constructed.
@MainActor @Observable final class BotConnectionSetup {
    let server: URL
    var name = ""
    var address = ""
    var username = ""
    var password = ""
    private(set) var saved: BotConnection?
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    /// The address whose host reported a different `install_id` on the last attempt.
    private(set) var differentHostAddress: URL?
    @ObservationIgnored private let store: BotConnectionStore
    @ObservationIgnored private let makeWire: (BotConnection) -> any BotTransport
    @ObservationIgnored private let discard: (BotConnection) async -> Void
    @ObservationIgnored private var client: (any BotTransport)?
    @ObservationIgnored private var attempt: UUID?

    init(server: URL, store: BotConnectionStore? = nil,
         makeWire: ((BotConnection) -> any BotTransport)? = nil,
         discard: ((BotConnection) async -> Void)? = nil) {
        self.server = server; self.store = store ?? BotConnectionStore()
        self.makeWire = makeWire ?? { BotClient(connection: $0) }
        self.discard = discard ?? { old in
            await PushRegistrar.shared?.forget(for: server)
            try? await BotHistoryCache.shared.remove(server: server, connectionID: old.id)
            await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: old.id)
            BotAvatarStore.shared.removeAll(connectionID: old.id)
            BotUnreadStore().remove(connectionID: old.id)
            BotRoomOrganizeStore().remove(connectionID: old.id)
            BotSectionOrderStore().remove(server: server, connectionID: old.id)
        }
    }

    var canConnect: Bool {
        !isConnecting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// The replace action is offered only for the address that was refused, so editing
    /// the address to the right one never leaves a data-clearing button behind.
    var offersHostReplacement: Bool {
        !isConnecting && differentHostAddress != nil && differentHostAddress == (try? BotConnection.address(address))
    }

    func load() {
        do {
            saved = try store.load(server: server)
            name = saved?.name ?? ""; address = saved?.address.absoluteString ?? ""
            username = saved?.username ?? ""; password = saved?.password ?? ""
        } catch { errorMessage = String(localized: "Could not read saved sign-in details.") }
    }

    func cancel() {
        attempt = nil; client?.close(); client = nil; isConnecting = false
    }

    /// Signs in and saves the connection. The UUID, and with it drafts, cache and push
    /// pairing, is kept when the host reports the saved `install_id` or when address and
    /// username are unchanged; otherwise the old connection's data is discarded. An
    /// unchanged address must still reach the saved install before the password is sent.
    /// `replacingHost` is the user's answer to `.differentHost`: it drops that expectation
    /// and always starts a new connection.
    func connect(replacingHost: Bool = false) async -> Bool {
        guard !isConnecting, !Task.isCancelled else { return false }
        let id = UUID(); attempt = id; isConnecting = true; errorMessage = nil; differentHostAddress = nil
        defer { if attempt == id { isConnecting = false; client = nil; attempt = nil } }
        var attempted: URL?
        do {
            let url = try BotConnection.address(address); attempted = url
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? (url.host ?? "Hermes") : name
            let expected = replacingHost || saved?.address != url ? nil : saved?.installID
            let wire = makeWire(BotConnection(id: UUID(), name: label, address: url, username: account,
                                              password: password, installID: expected))
            client = wire
            defer { wire.close() }
            try await wire.connect()
            guard attempt == id, !Task.isCancelled else { return false }
            let live = wire.serverInstallID
            let sameInstall = live != nil && live == saved?.installID
            let sameAccount = saved?.address == url && saved?.username == account
            let kept = replacingHost ? nil : (sameInstall || sameAccount ? saved : nil)
            let candidate = BotConnection(id: kept?.id ?? UUID(), name: label, address: url, username: account,
                password: password, hermesVersion: wire.serverVersion, installID: live ?? kept?.installID)
            let result = try await wire.call("profiles.list", ["include_sessions": .bool(true)])
            guard attempt == id, !Task.isCancelled else { return false }
            guard result["profiles"].list != nil else { throw BotFailure.unsupported }
            let old = saved
            do { try store.save(candidate, server: server) } catch {
                errorMessage = String(localized: "Could not save sign-in details on this iPhone.")
                return false
            }
            saved = candidate
            // Persistence is the commit point, with no suspension after the last
            // cancellation check. Old-account cleanup must finish even if the
            // sheet disappears afterwards; a committed replacement is success.
            if let old, old.id != candidate.id {
                let discard = discard
                await Task { await discard(old) }.value
            }
            return true
        } catch {
            guard attempt == id, !Task.isCancelled else { return false }
            if error as? BotFailure == .differentHost { differentHostAddress = attempted }
            // Only the address parse throws before `attempted` is set.
            errorMessage = attempted.map { BotConnectionAdvice.message(for: error, address: $0) }
                ?? (error as? BotFailure ?? .invalidAddress).localizedDescription
            return false
        }
    }

    func remove() async -> Bool {
        guard !isConnecting, !Task.isCancelled else { return false }
        let id = UUID(); attempt = id; isConnecting = true; errorMessage = nil
        defer { if attempt == id { isConnecting = false; attempt = nil } }
        do {
            let old = saved
            try store.remove(server: server)
            saved = nil
            if let old {
                let discard = discard
                await Task { await discard(old) }.value
            }
            return true
        } catch {
            guard attempt == id, !Task.isCancelled else { return false }
            errorMessage = String(localized: "Could not remove saved sign-in details.")
            return false
        }
    }

    /// Generic instructions only: no credentials or configured host is copied.
    /// The agent discovers its installed version instead of following pinned CLI recipes.
    static let prompt = """
    Help me connect the Hermex iPhone app to my existing Hermes dashboard for Bots and notifications. Hermex already connects to hermes-webui, but this is a separate direct dashboard connection.

    Inspect this machine's Hermes installation and current dashboard/Desktop setup first. Check the installed version's supported setup instructions and whether its dashboard supports username/password sign-in and Bot chats. Reuse the backend and Profile storage already used by my bots; do not start a second backend against the same storage.

    Find the dashboard address reachable from my iPhone, including scheme and port, and the sign-in username. A localhost address only works on this machine, so ask whether I use LAN, Tailscale/VPN or an existing HTTPS tunnel when needed. Do not assume the WebUI address or login is the dashboard's.

    Tell me whether I should use my existing dashboard password. Do not print secrets, invent credentials or claim to recover a hashed password. If setup or a password reset is needed, explain the exact changes and ask me before changing credentials, starting/restarting services, installing anything, or changing network exposure. Help me set up the supported connection after I approve.

    Finish with the Hermes address and username to enter in Hermex, where to obtain or set the password, and any remaining steps. Do not claim the iPhone can connect until reachability and authenticated dashboard access have been checked.
    """
}

/// The unconnected inbox uses the same drawn faces as the bot editor. Each short
/// playful bit returns to neutral, and covered/inactive screens render still faces.
struct BotConnectionWelcomeView: View {
    let isCovered: Bool
    let onConnect: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var avatarSize = 72.0

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 2) {
                face("welcome-circle", shape: .circle, color: "#f97316")
                face("welcome-triangle", shape: .triangle, color: "#22c55e").padding(.top, 22)
                face("welcome-squircle", shape: .squircle, color: "#8b5cf6").padding(.top, 8)
            }
            .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("Your bots, together.").font(.title2.bold())
                Text("Bots live in your Hermes dashboard. WebUI uses a separate connection, so sign in once here to bring them to Hermex.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Button("Connect", action: onConnect)
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .background(Color(uiColor: .label), in: Capsule()).buttonStyle(.plain)
        }
        .frame(maxWidth: 360).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func face(_ name: String, shape: BotAvatarShape, color: String) -> some View {
        let appearance = BotProfileAppearance(look: ["shape": .string(shape.rawValue), "color": .string(color),
            "expression": .string(BotAvatarExpression.neutral.rawValue)], fallbackTitle: name)
        let size = min(avatarSize, 92)
        if scenePhase == .active && !isCovered && !reduceMotion {
            BotInteractiveFaceView(name: name, appearance: appearance, size: size)
        } else {
            BotAnimatedFaceView(name: name, appearance: appearance, size: size, motion: .still)
        }
    }
}
