import Foundation
import Observation

/// The connect form's model, shared by onboarding's Connect page and Settings → Add Server
/// (#900). Connect first reads the public `/api/status` at the typed address. A Hermes
/// dashboard reveals username and password, signs in once on a `HermesConnection` of its
/// own and becomes a Hermes server (`AuthManager.addHermesServer`). Anything else goes on
/// to today's webui path: onboarding's `configure`, or Add Server's `addServer`, which
/// leaves the active server alone until the new one succeeds.
@MainActor
@Observable
final class OnboardingViewModel {
    /// Where the form runs, which picks its webui path.
    enum Entry { case onboarding, addServer }

    /// How this iPhone reaches the host. It changes only the placeholder, the help and
    /// which header rows show: it is not saved, and no request depends on it. The scheme
    /// still comes from the address parser (#900, Decision 2).
    enum ConnectionMode: CaseIterable, Identifiable {
        case sameWiFi, privateNetwork, cloudflareTunnel

        var id: Self { self }

        var title: String {
            switch self {
            case .sameWiFi: return String(localized: "Same Wi-Fi")
            case .privateNetwork: return String(localized: "Private network")
            case .cloudflareTunnel: return String(localized: "Cloudflare Tunnel")
            }
        }

        var subtitle: String {
            switch self {
            case .sameWiFi: return String(localized: "The host is on this network")
            case .privateNetwork: return String(localized: "Tailscale, NetBird…")
            case .cloudflareTunnel: return String(localized: "Your tunnel’s HTTPS address")
            }
        }

        var help: String {
            switch self {
            case .sameWiFi:
                return String(localized: "Enter the host’s local address and port. This iPhone must be on the same Wi-Fi as the host.")
            case .privateNetwork:
                return String(localized: "Enter the host’s name or IP on Tailscale, NetBird or another private network. Keep that app connected on this iPhone.")
            case .cloudflareTunnel:
                return String(localized: "Enter your tunnel’s HTTPS address. If Cloudflare Access protects it, add your service token below.")
            }
        }

        /// An example address, never localized.
        var placeholder: String {
            switch self {
            case .sameWiFi: return "http://192.168.1.5:9119"
            case .privateNetwork: return "http://my-mac.tailnet-name.ts.net:9119"
            case .cloudflareTunnel: return "https://hermes.example.com"
            }
        }
    }

    nonisolated static let emptyPasswordMessage = String(localized: "Enter the server password.")
    /// Cloudflare Access's service-token headers, which Cloudflare Tunnel opens empty.
    nonisolated static let accessHeaderNames = ["CF-Access-Client-Id", "CF-Access-Client-Secret"]

    let entry: Entry
    var serverURLString = "" {
        didSet {
            invalidateProbedAuthStatusIfNeeded()
            dropReusedSignInIfMoved()
        }
    }
    /// A Hermes dashboard's username; only a detected dashboard shows it.
    var username = ""
    var password = ""
    var customHeaders: [CustomHeader] = [] {
        didSet { invalidateProbedAuthStatusIfNeeded() }
    }
    var connectionMode: ConnectionMode = .privateNetwork {
        didSet { syncAccessHeaders(leaving: oldValue) }
    }
    var authStatus: AuthStatusResponse?
    /// What answered at the typed address: `.hermes` once `/api/status` showed a dashboard,
    /// `.webui` once the webui path got an answer. Nil until then, and again after an edit
    /// changes the address or the headers sent.
    private(set) var detectedKind: ServerKind?
    /// The sign-ins webui servers keep for exactly the detected dashboard's address.
    private(set) var savedSignIns: [AuthManager.SavedHermesSignIn] = []
    /// The saved sign-in the fields were filled from. Its `install_id` is still checked
    /// before the password goes out (#777). Its copies stay while the address still parses
    /// to the one it was offered for and no webui answers there (`dropReusedSignIn`).
    private(set) var reusedSignIn: AuthManager.SavedHermesSignIn?
    /// Add Server's webui answered that it needs a password, so its field shows.
    private(set) var webuiNeedsPassword = false
    /// The last Connect found a webui server saved at the dashboard's address, which
    /// `connect(authManager:replacingWebuiServer:)` can replace (#1027).
    private(set) var offersWebuiReplace = false
    /// Bot Mode (beta), which adding a Hermes server needs, as of the last detection.
    private(set) var isBotModeEnabled: Bool
    var connectionMessage: String?
    var errorMessage: String?
    var isWorking = false
    /// True while an operation owns the form: views disable the URL/password
    /// fields, header editor, and Return-key submission so a side effect that
    /// has already run (AuthManager.configure persists and activates server
    /// state) cannot be superseded by mid-flight edits (PR #294 re-gate).
    var isConnectionLocked = false

    @ObservationIgnored private let preferences: UserDefaults
    /// The URL session setup for the form's own Hermes connections; tests script the host with it.
    @ObservationIgnored private let hermesConfiguration: () -> URLSessionConfiguration
    // Identity + generation of the probe that produced `authStatus` or `detectedKind`.
    @ObservationIgnored private var probedConnectionIdentity: String?
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var isSyncingAccessRows = false

    init(
        entry: Entry = .onboarding,
        savedServer: URL? = nil,
        savedHeaders: [CustomHeader] = [],
        initialErrorMessage: String? = nil,
        preferences: UserDefaults = .standard,
        hermesConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.entry = entry
        self.preferences = preferences
        self.hermesConfiguration = hermesConfiguration
        isBotModeEnabled = BotModeGate.isEnabled(in: preferences)
        if let savedServer {
            serverURLString = savedServer.absoluteString
        }
        customHeaders = savedHeaders
        errorMessage = initialErrorMessage
        if initialErrorMessage != nil {
            // The banner belongs to the restored identity so later edits clear it.
            probedConnectionIdentity = nil
        }
    }

    var isPasswordRequired: Bool {
        // No auth → no password. Already signed in (trusted-header proxy) → no
        // password either. Passkey/OIDC-only → hide the field; connect()
        // surfaces the specific unsupported message instead. Unknown (nil)
        // keeps today's "show the field" default.
        guard authStatus?.authEnabled != false else { return false }
        guard authStatus?.isAlreadySignedIn != true else { return false }
        return authStatus?.passwordAuthEnabled != false
    }

    /// Username and password for a detected dashboard, once Bot Mode is on.
    var showsHermesSignIn: Bool { detectedKind == .hermes && isBotModeEnabled }

    /// A detected dashboard that can't be added until Bot Mode (beta) is turned on.
    var needsBotModeOptIn: Bool { detectedKind == .hermes && !isBotModeEnabled }

    /// The dashboard's password, or the webui's as today: onboarding shows it until a
    /// webui says it needs none, Add Server once a webui asks for one.
    var showsPasswordField: Bool {
        if detectedKind == .hermes { return isBotModeEnabled }
        return entry == .onboarding ? isPasswordRequired : webuiNeedsPassword
    }

    /// Off without an address, and for a detected dashboard until Bot Mode is on and both
    /// its username and password are filled in.
    var canSubmit: Bool {
        guard !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard detectedKind == .hermes else { return true }
        return isBotModeEnabled && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// The root Connect will use, for the "Will connect to" line: the URL the webui path
    /// saves once a webui answered, else the Hermes parser's (`BotConnection.address(_:)`).
    /// Nil while the text doesn't parse.
    var addressPreview: URL? {
        if detectedKind == .webui { return try? AuthManager.normalizedServerURL(from: serverURLString) }
        return try? BotConnection.address(serverURLString)
    }

    /// The opt-in's one tap: turns on Bot Mode (beta) for the app and shows the sign-in fields.
    func enableBotMode() {
        preferences.set(true, forKey: BotModeGate.isEnabledKey)
        isBotModeEnabled = true
    }

    /// Fills the username, password and headers from `signIn`. It is a copy: Connect still
    /// signs in once, the new server gets its own record and UUID, and the webui server's
    /// connection stays as it is.
    func useSavedSignIn(_ signIn: AuthManager.SavedHermesSignIn) {
        guard !isConnectionLocked, detectedKind == .hermes else { return }
        let offers = savedSignIns
        // Another saved sign-in's copies go first, so none of them outlives its offer.
        dropReusedSignIn()
        customHeaders = signIn.connection.headers ?? []
        // The saved headers are the ones that reach this address, so it stays a found dashboard.
        detectedKind = .hermes
        savedSignIns = offers
        probedConnectionIdentity = currentConnectionIdentity()
        username = signIn.connection.username
        password = signIn.connection.password
        reusedSignIn = signIn
    }

    // MARK: - Connection identity (issue #285)

    /// The header rows the form sends and saves: a name and a value, so Cloudflare
    /// Tunnel's empty Access rows never go out (#900).
    private var sentHeaders: [CustomHeader] {
        customHeaders.sanitizedForStorage().filter { !$0.sanitizedValue.isEmpty }
    }

    /// Effective headers exactly as the request path would apply them:
    /// applicable rows only, case-insensitive names, array order preserved with
    /// last-write-wins for duplicate names (matches
    /// `Array<CustomHeader>.apply(to:)` via `URLRequest.setValue`). This is the
    /// credential set that actually reaches the server, so reordering duplicate
    /// names or adding/removing a newline-broken row must change it.
    private func effectiveHeaderMap() -> [(name: String, value: String)] {
        var map: [(name: String, value: String)] = []
        for header in sentHeaders where header.isApplicable {
            let lowered = header.sanitizedName.lowercased()
            if let index = map.firstIndex(where: { $0.name == lowered }) {
                map[index].value = header.sanitizedValue
            } else {
                map.append((name: lowered, value: header.sanitizedValue))
            }
        }
        return map
    }

    private func currentConnectionIdentity() -> String {
        var urlPart: String
        do {
            let url = try AuthManager.normalizedServerURL(from: serverURLString)
            urlPart = url.absoluteString.lowercased()
        } catch {
            urlPart = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // A found dashboard signs in at the Hermes parser's URL, whose scheme can differ from
        // the webui's for the same text (`mac.local:9119` is http there and https here), so
        // while one is held that URL is part of the identity too (#900).
        if detectedKind == .hermes {
            urlPart += " hermes:" + ((try? BotConnection.address(serverURLString))?.absoluteString ?? "")
        }
        // Escape delimiters so distinct header sets cannot collide, then sort
        // canonical keys for stable serialization.
        let headerPart = effectiveHeaderMap()
            .map { name, value -> String in
                "\(Self.escapeForIdentity(name)):\(Self.escapeForIdentity(value))"
            }
            .sorted()
            .joined(separator: "|")
        return "\(urlPart)|\(headerPart)"
    }

    nonisolated private static func escapeForIdentity(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "%", with: "%25")
        out = out.replacingOccurrences(of: ":", with: "%3A")
        out = out.replacingOccurrences(of: "|", with: "%7C")
        return out
    }

    private func invalidateProbedAuthStatusIfNeeded() {
        // A mode switch only opens or drops empty Access rows, which send nothing, so it
        // keeps the probe and any banner, such as the advice that suggested the switch.
        guard !isSyncingAccessRows else { return }
        guard let probed = probedConnectionIdentity else {
            // No probe yet, but an inherited banner (re-login error) still has no
            // owner — clear it on any edit so stale copy can't survive.
            if errorMessage != nil || connectionMessage != nil {
                errorMessage = nil
                connectionMessage = nil
            }
            return
        }
        let current = currentConnectionIdentity()
        if current != probed {
            forgetProbe()
            connectionMessage = nil
            errorMessage = nil
        }
    }

    /// Drops what the last probe found, which no longer describes the typed address.
    private func forgetProbe() {
        authStatus = nil
        offersWebuiReplace = false
        detectedKind = nil
        savedSignIns = []
        probedConnectionIdentity = nil
    }

    /// A saved sign-in belongs to the address it was offered for: an edit that makes the
    /// text parse to any other, even one differing only in scheme, takes its copies out.
    private func dropReusedSignInIfMoved() {
        guard let reused = reusedSignIn,
              (try? BotConnection.address(serverURLString))
                != (try? BotConnection.address(reused.connection.address.absoluteString)) else { return }
        dropReusedSignIn()
    }

    /// Takes a saved sign-in's copies out of the form: its username and password unless
    /// edited, and every header row still carrying one of its values, renamed or not.
    private func dropReusedSignIn() {
        guard let reused = reusedSignIn else { return }
        reusedSignIn = nil
        if username == reused.connection.username { username = "" }
        if password == reused.connection.password { password = "" }
        let secrets = Set((reused.connection.headers ?? []).map(\.sanitizedValue).filter { !$0.isEmpty })
        let kept = customHeaders.filter { !secrets.contains($0.sanitizedValue) }
        guard kept.count != customHeaders.count else { return }
        customHeaders = connectionMode == .cloudflareTunnel ? Self.withAccessRows(kept) : kept
    }

    /// `headers` plus an empty row for each Access header it lacks.
    private static func withAccessRows(_ headers: [CustomHeader]) -> [CustomHeader] {
        headers + accessHeaderNames
            .filter { name in !headers.contains { $0.sanitizedName.caseInsensitiveCompare(name) == .orderedSame } }
            .map { CustomHeader(name: $0) }
    }

    /// Cloudflare Tunnel opens Access's two header rows, empty; leaving it removes those
    /// rows that are still empty. Neither changes what is sent (`sentHeaders`).
    private func syncAccessHeaders(leaving old: ConnectionMode) {
        guard old != connectionMode else { return }
        isSyncingAccessRows = true
        defer { isSyncingAccessRows = false }
        if connectionMode == .cloudflareTunnel {
            customHeaders = Self.withAccessRows(customHeaders)
        } else if old == .cloudflareTunnel {
            customHeaders.removeAll { header in
                header.sanitizedValue.isEmpty
                    && Self.accessHeaderNames.contains { $0.caseInsensitiveCompare(header.sanitizedName) == .orderedSame }
            }
        }
    }

    /// Begins a tracked async operation and returns its generation token used
    /// to fence settlement against newer overlapping operations.
    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    // MARK: - Server kind (#900)

    private enum Detection {
        case hermes(URL)
        case notHermes
        /// A Host-header 400 or an access proxy's own sign-in, with its advice.
        case refused(String)
    }

    /// Reads the public `/api/status` at the typed address with the form's headers, on a
    /// connection of its own. A JSON object carrying `auth_required` is a Hermes dashboard.
    /// A Host-header 400, or something in front of the host that wants its own sign-in
    /// (`.blocked`), shows its advice as is. Anything else, including an address or headers
    /// only the webui path accepts, is left to the webui path (#900, Decision 1).
    private func detectHermes() async -> Detection {
        guard let address = try? BotConnection.address(serverURLString),
              let headers = try? HermesHeaders(sentHeaders) else { return .notHermes }
        let probe = BotConnection(id: UUID(), name: "", address: address, username: "", password: "",
                                  headers: headers.values.isEmpty ? nil : headers.values)
        do {
            let status = try await HermesConnection(connection: probe, configuration: hermesConfiguration()).status()
            return status.fields?["auth_required"] != nil ? .hermes(address) : .notHermes
        } catch let failure as BotFailure where failure == .blocked || failure == .rejected(400) {
            return .refused(BotConnectionAdvice.message(for: failure, address: address))
        } catch {
            return .notHermes
        }
    }

    /// Callers have just checked that the inputs are the ones probed.
    private func foundHermes(at address: URL, authManager: AuthManager) {
        authStatus = nil
        detectedKind = .hermes
        probedConnectionIdentity = currentConnectionIdentity()
        savedSignIns = authManager.savedHermesSignIns(at: address)
        isBotModeEnabled = BotModeGate.isEnabled(in: preferences)
    }

    func testConnection(authManager: AuthManager) async {
        guard !isConnectionLocked else { return }
        errorMessage = nil
        connectionMessage = nil
        isWorking = true
        isConnectionLocked = true
        let token = beginOperation()
        var identityAtStart = currentConnectionIdentity()
        defer {
            if token == operationGeneration {
                isWorking = false
                isConnectionLocked = false
            }
        }

        let detection = await detectHermes()
        guard token == operationGeneration, identityAtStart == currentConnectionIdentity() else { return }
        switch detection {
        case .hermes(let address):
            foundHermes(at: address, authManager: authManager)
            return
        case .refused(let advice):
            forgetProbe()
            errorMessage = advice
            return
        case .notHermes:
            // A saved Hermes sign-in never goes down the webui path.
            dropReusedSignIn()
            identityAtStart = currentConnectionIdentity()
        }

        do {
            let status = try await authManager.testConnection(
                serverURLString: serverURLString,
                customHeaders: sentHeaders
            )
            guard token == operationGeneration else { return }
            guard identityAtStart == currentConnectionIdentity() else { return }
            probedConnectionIdentity = identityAtStart
            authStatus = status
            detectedKind = .webui
            if let message = AuthManager.unsupportedSignInMessage(for: status) {
                errorMessage = message
            } else if status.isAlreadySignedIn {
                connectionMessage = String(localized: "Connection ok. Already signed in by this server.")
            } else {
                connectionMessage = status.authEnabled == true
                    ? String(localized: "Connection ok. Password required.")
                    : String(localized: "Connection ok. Password not required.")
            }
        } catch {
            guard token == operationGeneration else { return }
            guard identityAtStart == currentConnectionIdentity() else { return }
            // A failed re-probe invalidates the prior successful status: the old
            // capability result no longer describes this identity.
            forgetProbe()
            errorMessage = error.localizedDescription
        }
    }

    /// Connect in onboarding, Add in Settings. The first one for an address finds out what
    /// answers there; a dashboard then waits for its username and password. Returns the
    /// server it added, or nil when nothing was added yet. Onboarding needs no result: the
    /// new server's sign-in replaces it. `replacingWebuiServer` is the confirmed Replace a
    /// saved webui server at a dashboard's address offers (`offersWebuiReplace`).
    @discardableResult
    func connect(authManager: AuthManager, replacingWebuiServer: Bool = false) async -> URL? {
        guard !isConnectionLocked else { return nil }
        errorMessage = nil
        connectionMessage = nil
        offersWebuiReplace = false

        if entry == .onboarding, detectedKind != .hermes,
           let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
            errorMessage = validationMessage
            return nil
        }

        isWorking = true
        // Inputs stay frozen across probe AND configure: AuthManager.configure
        // persists credentials and activates the captured URL/headers as a side
        // effect, so accepting edits mid-operation would let the old server be
        // configured under a form now showing a different one (PR #294 re-gate).
        isConnectionLocked = true
        let token = beginOperation()
        defer {
            if token == operationGeneration {
                isWorking = false
                isConnectionLocked = false
            }
        }

        if detectedKind == nil, authStatus == nil {
            let identityAtStart = currentConnectionIdentity()
            let detection = await detectHermes()
            guard token == operationGeneration, identityAtStart == currentConnectionIdentity() else { return nil }
            switch detection {
            case .hermes(let address):
                // Its username and password appear now; the next Connect signs in.
                foundHermes(at: address, authManager: authManager)
                return nil
            case .refused(let advice):
                forgetProbe()
                errorMessage = advice
                return nil
            case .notHermes:
                // A saved Hermes sign-in never goes down the webui path.
                dropReusedSignIn()
            }
        }

        if detectedKind == .hermes {
            return await addHermesServer(authManager: authManager, token: token, replacingWebuiServer: replacingWebuiServer)
        }
        switch entry {
        case .onboarding:
            await configureWebui(authManager: authManager, token: token)
            return nil
        case .addServer:
            return await addWebuiServer(authManager: authManager, token: token)
        }
    }

    /// Signs the detected dashboard in once with the form's username, password and headers
    /// on a connection of its own, then adds it as a Hermes server. A failure shows
    /// `BotConnectionAdvice`'s copy, and nothing is retried (#884). A webui server saved at
    /// the address is replaced only when `replacingWebuiServer`, and only after the sign-in
    /// succeeded; otherwise it stops here with the Replace offer (#1027).
    private func addHermesServer(authManager: AuthManager, token: Int, replacingWebuiServer: Bool) async -> URL? {
        guard isBotModeEnabled else { return nil }
        let identity = currentConnectionIdentity()
        let address: URL
        let headers: [CustomHeader]
        do {
            address = try BotConnection.address(serverURLString)
            headers = try HermesHeaders(sentHeaders).values
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        let saved = authManager.servers.first { $0.id == address.absoluteString }
        if let saved, !(replacingWebuiServer && saved.kind == .webui) {
            offersWebuiReplace = saved.kind == .webui
            errorMessage = offersWebuiReplace
                ? String(localized: "A webui server is saved at this address.")
                : String(localized: "This server is already configured.")
            return nil
        }
        let candidate = BotConnection(
            id: UUID(), name: address.host ?? "Hermes", address: address,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
            installID: reusedSignIn?.connection.installID, headers: headers.isEmpty ? nil : headers
        )
        let http = HermesConnection(connection: candidate, configuration: hermesConfiguration())
        do {
            try await http.signIn()
        } catch {
            guard token == operationGeneration, identity == currentConnectionIdentity() else { return nil }
            errorMessage = BotConnectionAdvice.message(for: error, address: address)
            return nil
        }
        // A sheet closed while it signed in adds nothing.
        guard token == operationGeneration, identity == currentConnectionIdentity(), !Task.isCancelled else { return nil }
        var record = candidate
        record.hermesVersion = http.serverVersion
        record.installID = http.serverInstallID ?? candidate.installID
        let added = saved == nil
            ? authManager.addHermesServer(record)
            : await authManager.replaceWebuiServer(with: record)
        guard added else {
            errorMessage = authManager.lastErrorMessage
            return nil
        }
        return address
    }

    /// Onboarding's webui path, as before #900: probe unless a probe for these inputs
    /// already answered, check the password, then `configure`.
    private func configureWebui(authManager: AuthManager, token: Int) async {
        if authStatus == nil {
            let identityAtStart = currentConnectionIdentity()
            do {
                let status = try await authManager.testConnection(
                    serverURLString: serverURLString,
                    customHeaders: sentHeaders
                )
                guard token == operationGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                probedConnectionIdentity = identityAtStart
                authStatus = status
                detectedKind = .webui
            } catch {
                guard token == operationGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                forgetProbe()
                errorMessage = error.localizedDescription
                return
            }

            if let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
                errorMessage = validationMessage
                return
            }
        } else if probedConnectionIdentity == nil {
            probedConnectionIdentity = currentConnectionIdentity()
        }

        // Fence the side effect: capture the identity configure was launched for
        // and refuse to publish its outcome under different inputs.
        let configureIdentity = currentConnectionIdentity()
        await authManager.configure(
            serverURLString: serverURLString,
            password: password,
            customHeaders: sentHeaders
        )
        guard token == operationGeneration else { return }
        guard configureIdentity == currentConnectionIdentity() else { return }
        errorMessage = authManager.lastErrorMessage
    }

    /// Add Server's webui path, as before #900: `addServer` reveals the password field when
    /// the server needs one, and the next Add sends it.
    private func addWebuiServer(authManager: AuthManager, token: Int) async -> URL? {
        let identityAtStart = currentConnectionIdentity()
        let outcome = await authManager.addServer(
            serverURLString: serverURLString,
            password: password,
            customHeaders: sentHeaders
        )
        guard token == operationGeneration, identityAtStart == currentConnectionIdentity() else { return nil }
        switch outcome {
        case .needsPassword:
            webuiNeedsPassword = true
            detectedKind = .webui
            probedConnectionIdentity = identityAtStart
            return nil
        case .failed:
            errorMessage = authManager.lastErrorMessage
            return nil
        case .added(let url):
            return url
        }
    }

    // MARK: - Testing hooks (issue #285 regression matrix)

    func probeConnectionIdentityForTesting() -> String {
        currentConnectionIdentity()
    }

    func seedProbedIdentityForTesting() {
        probedConnectionIdentity = currentConnectionIdentity()
    }

    nonisolated static func passwordValidationMessage(authStatus: AuthStatusResponse?, password: String) -> String? {
        guard authStatus?.authEnabled == true else { return nil }
        // A server that already signed this client in (trusted-header proxy)
        // has no password to demand (#3).
        guard authStatus?.isAlreadySignedIn != true else { return nil }
        // Passkey/OIDC-only servers don't take a password either — let
        // configure() report the specific unsupported message instead of
        // demanding one here (#255, #3).
        guard authStatus?.passwordAuthEnabled != false else { return nil }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPassword.isEmpty ? emptyPasswordMessage : nil
    }
}
