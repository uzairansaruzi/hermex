import SwiftUI
import Observation

@MainActor struct BotConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var setup: BotConnectionSetup
    @State private var operation: Task<Void, Never>?
    @State private var confirmingRemoval = false
    @State private var copiedPrompt = false
    @State private var copiedAddress = false
    @State private var statusCheck: Task<Void, Never>?
    /// The form loads the saved record once: coming back from the pushed headers editor
    /// reruns `.task`, which must not replace the edits in progress, and checks the
    /// status again only if leaving cancelled that check.
    @State private var loaded = false
    @FocusState private var passwordFocused: Bool
    /// Set when the host refused the saved password: the field opens focused with the
    /// stored password kept, so typing replaces it and Connect alone retries as is.
    private let focusesPassword: Bool
    /// True when the form is the whole screen, a signed-out Hermes server's sign-in, so
    /// there is nothing for Done to close.
    private let isRoot: Bool
    /// Runs once a sign-in is saved, even if the form closed while it connected.
    private let onSaved: () -> Void

    /// `error` opens the form showing why it is needed, such as the host refusing the password.
    init(server: URL, focusesPassword: Bool = false, isRoot: Bool = false, error: String? = nil,
         onSaved: @escaping () -> Void = {}) {
        _setup = State(initialValue: BotConnectionSetup(server: server, error: error))
        self.focusesPassword = focusesPassword; self.isRoot = isRoot; self.onSaved = onSaved
    }

    var body: some View {
        Form {
            if let saved = setup.saved { statusSection(saved) }
            Section {
                Text("Connect to your dashboard").font(.title3.bold())
                Text("Use your Hermes dashboard sign-in.").foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            Section {
                if setup.isServerSignIn {
                    // A Hermes server's address is its identity: removing the server is how
                    // it changes, through Settings → Servers.
                    Text(verbatim: setup.address).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityLabel(Text("Hermes address")).accessibilityValue(setup.address)
                        .accessibilityIdentifier("hermes-connection-address")
                } else {
                    TextField("Hermes address", text: $setup.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("hermes-connection-address")
                }
                TextField("Username", text: $setup.username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $setup.password).textContentType(.password)
                    .focused($passwordFocused)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // Under the password, so the focused field's keyboard never covers it.
                    if let error = setup.errorMessage {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("hermes-connection-error")
                    }
                    if !setup.isServerSignIn {
                        // The trailing mark keeps a URL ending in a neutral character, such as an
                        // IPv6 literal's "]", in one left-to-right run inside right-to-left text.
                        if let preview = setup.addressPreview {
                            Text("Will connect to \(preview.absoluteString + "\u{200E}")")
                                .accessibilityIdentifier("hermes-connection-address-preview")
                        }
                        Text("Domains, Tailscale names and IP addresses work. You can include http:// or https://.")
                    }
                }
            }
            .disabled(setup.isConnecting)
            headersSection
            Section {
                Button(setup.isConnecting ? String(localized: "Connecting…") : String(localized: "Connect")) {
                    operation = Task { if await setup.connect() { onSaved(); if !Task.isCancelled { dismiss() } } }
                }
                .frame(maxWidth: .infinity)
                .disabled(!setup.canConnect)
                .accessibilityIdentifier("hermes-connection-connect")
                if setup.offersHostReplacement {
                    Button("Connect to this host instead", role: .destructive) {
                        operation = Task {
                            if await setup.connect(replacingHost: true) { onSaved(); if !Task.isCancelled { dismiss() } }
                        }
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
            if setup.offersRemoval {
                Section {
                    Button("Remove Hermes connection…", role: .destructive) { confirmingRemoval = true }
                        .disabled(setup.isConnecting)
                }
            }
        }
        .navigationTitle("Hermes connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isRoot { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            if !loaded {
                loaded = true
                setup.load()
                if focusesPassword { passwordFocused = true }
            }
            if setup.hostStatus == nil || setup.hostStatus == .checking { await setup.checkStatus() }
        }
        .onDisappear { operation?.cancel(); statusCheck?.cancel(); setup.cancel() }
        .confirmationDialog("Remove this connection from Hermex?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Hermes connection", role: .destructive) {
                operation = Task { if await setup.remove(), !Task.isCancelled { dismiss() } }
            }
        } message: {
            Text("Saved sign-in details, this connection’s drafts and its notification keys will be deleted. This iPhone stops receiving this host’s notifications. Bots and their work remain on the host.")
        }
    }

    /// The Connection Headers row, which pushes the shared editor, and a footer that puts
    /// a rejected header or a half Cloudflare Access pair above what headers are for.
    private var headersSection: some View {
        Section {
            NavigationLink {
                ScrollView {
                    CustomHeadersEditor(headers: $setup.headers)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Connection Headers")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                let count = setup.headers.sanitizedForStorage().count
                LabeledContent("Connection Headers", value: count == 0 ? String(localized: "None") : count.formatted())
            }
            .accessibilityIdentifier("hermes-connection-headers")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let rejection = setup.headerRejection {
                    Label {
                        Text(rejection)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("hermes-connection-headers-rejection")
                }
                if let warning = setup.accessPairWarning {
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("hermes-connection-headers-warning")
                }
                Text("Sent with every request to this Hermes host, for a proxy such as Cloudflare Access.")
            }
        }
        .disabled(setup.isConnecting)
    }

    /// Read-only rows from the host's public status. Gateway rows appear only after
    /// the host answered; the version falls back to the one stored at sign-in.
    @ViewBuilder private func statusSection(_ saved: BotConnection) -> some View {
        let live: BotHostStatus? = if case .reachable(let status) = setup.hostStatus { status } else { nil }
        Section {
            statusRow("Reachability", value: setup.hostStatus?.title ?? String(localized: "Checking…"),
                      note: setup.hostStatus?.note)
            if let version = live?.version {
                statusRow("Hermes", value: version)
            } else if let version = saved.hermesVersion {
                statusRow("Hermes", value: version, note: String(localized: "at last sign-in"))
            }
            if let live {
                statusRow("Messaging gateway", value: live.gatewayTitle, note: live.gatewayNote)
                if let configured = live.platformsConfigured, configured > 0, let connected = live.platformsConnected {
                    statusRow("Platforms", value: String(localized: "\(connected) of \(configured) connected"))
                }
            }
            statusRow("Notifications", value: setup.notificationRelay.map {
                String(localized: "On · \($0.host ?? $0.absoluteString)")
            } ?? String(localized: "Off"))
            HStack {
                Text(saved.address.absoluteString).textSelection(.enabled)
                Spacer()
                Button(copiedAddress ? String(localized: "Copied") : String(localized: "Copy"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = saved.address.absoluteString
                    copiedAddress = true
                }
                .buttonStyle(.borderless)
            }
            Button("Check again") {
                statusCheck?.cancel()
                statusCheck = Task { await setup.checkStatus() }
            }
            .disabled(setup.hostStatus == .checking)
        } header: {
            Text("Status")
        } footer: {
            if live != nil {
                Text("The messaging gateway runs scheduled Tasks and messaging platforms. Bot chat notifications still arrive while it is stopped.")
            }
        }
    }

    private func statusRow(_ label: LocalizedStringKey, value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label, value: value)
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension BotConnectionSetup.HostStatus {
    var title: String {
        switch self {
        case .checking: return String(localized: "Checking…")
        case .reachable: return String(localized: "Reachable")
        case .unreachable(.unreachable): return String(localized: "Can’t reach this address")
        case .unreachable(.blocked): return String(localized: "An access check blocked this request")
        case .unreachable(.answered(let code)): return String(localized: "The host answered \(code)")
        case .unreachable(.notHermes): return String(localized: "This address isn’t a Hermes dashboard")
        }
    }

    var note: String? {
        if case .unreachable(.unreachable(let reason)) = self { return reason }
        return nil
    }
}

extension BotHostStatus {
    /// Upstream reports a dead gateway process as `stopped`, `startup_failed` or a
    /// watchdog `degraded`, so `gateway_running` decides whether scheduled Tasks run.
    var gatewayStopped: Bool {
        gatewayRunning == false || (gatewayRunning == nil && ["stopped", "startup_failed"].contains(gatewayState))
    }

    var gatewayTitle: String {
        if heartbeatStale != nil && !gatewayStopped { return String(localized: "Not responding") }
        switch gatewayState ?? gatewayRunning.map({ $0 ? "running" : "stopped" }) ?? "" {
        case "starting": return String(localized: "Starting")
        case "running": return String(localized: "Running")
        case "draining": return String(localized: "Draining")
        case "degraded": return String(localized: "Degraded")
        case "startup_failed": return String(localized: "Startup failed")
        case "stopped": return String(localized: "Stopped")
        default: return String(localized: "Unknown")
        }
    }

    /// Only scheduled Tasks depend on the gateway: Bot chat and WebUI reply
    /// notifications come from the process running the turn, so the copy never
    /// claims those stop.
    var gatewayNote: String? {
        if gatewayStopped {
            let consequence = String(localized: "Scheduled Tasks won’t run until it starts.")
            guard let reason = gatewayExitReason, !reason.isEmpty else { return consequence }
            return reason + "\n" + consequence
        }
        if heartbeatStale != nil { return String(localized: "Scheduled Tasks may not run until it responds.") }
        return nil
    }
}

/// Owns one sign-in attempt. Parsing failures and late transport replies obey the
/// same lifetime, including attempts cancelled before a client was constructed.
@MainActor @Observable final class BotConnectionSetup {
    let server: URL
    /// True when `server` is a Hermes server and this record is its own sign-in (#899): the
    /// address is the server's and can't change, and the record can't be removed here, only
    /// with the server in Settings → Servers.
    let isServerSignIn: Bool
    var name = ""
    var address = ""
    var username = ""
    var password = ""
    /// The Connection Headers being edited. Saved with the connection by `connect()`,
    /// without blank rows.
    var headers: [CustomHeader] = []
    private(set) var saved: BotConnection?
    private(set) var errorMessage: String?
    private(set) var isConnecting = false
    /// The address whose host reported a different `install_id` on the last attempt.
    private(set) var differentHostAddress: URL?
    /// The saved host's public status; nil while no connection is saved.
    private(set) var hostStatus: HostStatus?
    /// The relay this server's notifications are paired with; nil when they are off.
    private(set) var notificationRelay: URL?
    @ObservationIgnored private let store: BotConnectionStore
    @ObservationIgnored private let makeWire: (BotConnection) -> any BotTransport
    @ObservationIgnored private let discard: (BotConnection) async -> Void
    @ObservationIgnored private var client: (any BotTransport)?
    @ObservationIgnored private let probe: (URL, HermesHeaders) async -> Result<BotHostStatus, BotHostProbeFailure>
    @ObservationIgnored private let relay: (URL) -> URL?
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var statusCheck: UUID?

    enum HostStatus: Equatable {
        case checking, reachable(BotHostStatus), unreachable(BotHostProbeFailure)
    }

    /// `isServerSignIn` defaults to whether the registry lists `server` as a Hermes server.
    /// `error` is shown until the first Connect.
    init(server: URL, isServerSignIn: Bool? = nil, error: String? = nil, store: BotConnectionStore? = nil,
         makeWire: ((BotConnection) -> any BotTransport)? = nil,
         discard: ((BotConnection) async -> Void)? = nil,
         probe: ((URL, HermesHeaders) async -> Result<BotHostStatus, BotHostProbeFailure>)? = nil,
         relay: ((URL) -> URL?)? = nil) {
        self.server = server; self.store = store ?? BotConnectionStore()
        self.isServerSignIn = isServerSignIn
            ?? ServerRegistry.shared.servers.contains { $0.id == server.absoluteString && $0.kind == .hermes }
        // The candidate is not saved yet, so it signs in on its own cookie jar, never the
        // server's shared one.
        self.makeWire = makeWire ?? { BotClient(connection: $0) }
        self.probe = probe ?? { await BotHostStatusProbe().check($0, headers: $1) }
        self.relay = relay ?? { PushRegistrar.shared?.pairing(for: $0)?.relayURL }
        self.discard = discard ?? { old in
            await PushRegistrar.shared?.forget(for: server)
            try? await BotHistoryCache.shared.remove(server: server, connectionID: old.id)
            await ChatDraftStore.shared.discardBotDrafts(server: server, connectionID: old.id)
            BotAvatarStore.shared.removeAll(connectionID: old.id)
            BotUnreadStore().remove(connectionID: old.id)
            BotRoomOrganizeStore().remove(connectionID: old.id)
            BotSectionOrderStore().remove(server: server, connectionID: old.id)
        }
        errorMessage = error
    }

    /// The root `connect()` would use for the typed text, or nil while it doesn't parse.
    /// Parse errors wait for Connect so they never nag mid-word.
    var addressPreview: URL? { try? BotConnection.address(address) }

    var canConnect: Bool {
        !isConnecting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
            && headerRejection == nil
    }

    /// Why the edited headers can't be sent to Hermes (`HermesHeaders`), shown under the
    /// Connection Headers row; Connect stays off until it is fixed. Nil when they can.
    var headerRejection: String? {
        do { _ = try HermesHeaders(headers.sanitizedForStorage()); return nil } catch { return error.localizedDescription }
    }

    /// Shown under the Connection Headers row when only one of Cloudflare Access's two
    /// service-token headers has a value. Access treats such a request as signed out,
    /// but Connect stays on and sends what was entered.
    var accessPairWarning: String? {
        let filled = Set(headers.filter { !$0.sanitizedValue.isEmpty }.map { $0.sanitizedName.lowercased() })
        guard filled.contains("cf-access-client-id") != filled.contains("cf-access-client-secret") else { return nil }
        return String(localized: "Cloudflare Access needs both CF-Access-Client-Id and CF-Access-Client-Secret.")
    }

    /// Remove is offered for a saved side connection, never for a Hermes server's own sign-in.
    var offersRemoval: Bool { saved != nil && !isServerSignIn }

    /// The replace action is offered only for the address that was refused, so editing
    /// the address to the right one never leaves a data-clearing button behind.
    var offersHostReplacement: Bool {
        !isConnecting && differentHostAddress != nil && differentHostAddress == (try? BotConnection.address(address))
    }

    func load() {
        do {
            saved = try store.load(server: server)
            // A Hermes server signed out has no record, but its address is still its own.
            name = saved?.name ?? ""; address = isServerSignIn ? server.absoluteString : saved?.address.absoluteString ?? ""
            username = saved?.username ?? ""; password = saved?.password ?? ""
            headers = saved?.headers ?? []
        } catch { errorMessage = String(localized: "Could not read saved sign-in details.") }
        notificationRelay = relay(server)
    }

    func cancel() {
        attempt = nil; client?.close(); client = nil; isConnecting = false
        statusCheck = nil
    }

    /// Reads the saved host's public status once, with its saved headers. Nothing retries;
    /// a newer check, `cancel()` or a changed saved address drops a late reply.
    func checkStatus() async {
        guard let checked = saved else { hostStatus = nil; return }
        let id = UUID(); statusCheck = id; hostStatus = .checking
        let result = await probe(checked.address, HermesHeaders(saved: checked))
        guard statusCheck == id, !Task.isCancelled, saved?.address == checked.address else { return }
        statusCheck = nil
        switch result {
        case .success(let status): hostStatus = .reachable(status)
        case .failure(let failure): hostStatus = .unreachable(failure)
        }
    }

    /// Signs in with the form's headers and saves the connection with them. The UUID, and
    /// with it drafts, cache and push pairing, is kept when the host reports the saved
    /// `install_id` or when address and username are unchanged, whatever the headers;
    /// otherwise the old connection's data is discarded. An unchanged address must still
    /// reach the saved install before the password is sent. `replacingHost` is the user's
    /// answer to `.differentHost`: it drops that expectation and always starts a new connection.
    func connect(replacingHost: Bool = false) async -> Bool {
        guard !isConnecting, !Task.isCancelled else { return false }
        let id = UUID(); attempt = id; isConnecting = true; errorMessage = nil; differentHostAddress = nil
        defer { if attempt == id { isConnecting = false; client = nil; attempt = nil } }
        var attempted: URL?
        do {
            let admitted = try HermesHeaders(headers.sanitizedForStorage()).values
            let sent = admitted.isEmpty ? nil : admitted
            let url = isServerSignIn ? server : try BotConnection.address(address); attempted = url
            let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? (url.host ?? "Hermes") : name
            let expected = replacingHost || saved?.address != url ? nil : saved?.installID
            let wire = makeWire(BotConnection(id: UUID(), name: label, address: url, username: account,
                                              password: password, installID: expected, headers: sent))
            client = wire
            defer { wire.close() }
            try await wire.connect()
            guard attempt == id, !Task.isCancelled else { return false }
            let live = wire.serverInstallID
            let sameInstall = live != nil && live == saved?.installID
            let sameAccount = saved?.address == url && saved?.username == account
            let kept = replacingHost ? nil : (sameInstall || sameAccount ? saved : nil)
            let candidate = BotConnection(id: kept?.id ?? UUID(), name: label, address: url, username: account,
                password: password, hermesVersion: wire.serverVersion, installID: live ?? kept?.installID, headers: sent)
            let result = try await wire.call(.profilesList(includeSessions: true))
            guard attempt == id, !Task.isCancelled else { return false }
            guard result["profiles"].list != nil else { throw BotFailure.unsupported }
            let old = saved
            do { try store.save(candidate, server: server) } catch {
                errorMessage = String(localized: "Could not save sign-in details on this iPhone.")
                return false
            }
            saved = candidate
            // The old host's status and any check still in flight describe a host
            // this screen no longer shows.
            if old?.address != candidate.address { statusCheck = nil; hostStatus = nil }
            // Persistence is the commit point, with no suspension after the last
            // cancellation check. Old-account cleanup must finish even if the
            // sheet disappears afterwards; a committed replacement is success.
            if let old, old.id != candidate.id {
                let discard = discard
                await Task { await discard(old) }.value
                notificationRelay = relay(server)
            }
            return true
        } catch {
            guard attempt == id, !Task.isCancelled else { return false }
            if error as? BotFailure == .differentHost { differentHostAddress = attempted }
            // Only the header policy and the address parse throw before `attempted` is set,
            // with a `HermesHeaders.Rejection` or a `BotAddressError`.
            errorMessage = attempted.map { BotConnectionAdvice.message(for: error, address: $0) }
                ?? error.localizedDescription
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
