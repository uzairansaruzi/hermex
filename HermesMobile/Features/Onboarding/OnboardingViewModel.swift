import Foundation
import Observation

/// The Add Server sheet's model (`AddServerView`), from first launch and from Settings (#900,
/// #1540). Its first Connect reads the public `/api/status` at the typed address. A Hermes
/// dashboard reveals its sign-in, signs in once on a `HermesConnection` of its own and
/// becomes a Hermes server (`AuthManager.addHermesServer`). Anything else goes on to the
/// webui path: onboarding's `configure`, or Add Server's `addServer`, which leaves the active
/// server alone until the new one succeeds. Move to Hermes's host choice opens Add Server
/// with a `MoveSource` (#1266).
@MainActor
@Observable
final class OnboardingViewModel {
    /// Where the form runs, which picks its webui path.
    enum Entry { case onboarding, addServer }

    /// The webui server a Move to Hermes opened this sign-in for (#1266). The form then accepts
    /// only a Hermes dashboard and adds it without switching to it, so the move's sheet stays
    /// and scans it next. Its headers are offered, never filled in on their own.
    struct MoveSource {
        let name: String
        let headers: [CustomHeader]
    }

    nonisolated static let emptyPasswordMessage = String(localized: "Enter the server password.")
    /// Cloudflare Access's service-token headers, which Connection Options edits as two fields.
    nonisolated private static let accessClientIDHeader = "CF-Access-Client-Id"
    nonisolated private static let accessClientSecretHeader = "CF-Access-Client-Secret"

    let entry: Entry
    let moveSource: MoveSource?
    var serverURLString = "" {
        didSet {
            invalidateProbedAuthStatusIfNeeded()
            dropReusedSignInIfMoved()
        }
    }
    /// A Hermes dashboard's username; only a detected dashboard shows it. An edit to it or the
    /// password drops the failed attempt's Details, which describe the old credentials (#1395).
    var username = "" {
        didSet { if username != oldValue { lastAttempt = nil } }
    }
    var password = "" {
        didSet { if password != oldValue { lastAttempt = nil } }
    }
    /// Every header row the form holds, Cloudflare Access's included; only rows with a name
    /// and a value are sent or saved (`sentHeaders`).
    var customHeaders: [CustomHeader] = [] {
        didSet { invalidateProbedAuthStatusIfNeeded() }
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
    /// A webui answered that it needs a password, or onboarding signs a saved one in again,
    /// so its field shows.
    private(set) var webuiNeedsPassword = false
    /// The last Connect found a webui server saved at the dashboard's address, which
    /// `connect(authManager:replacingWebuiServer:)` can replace (#1027).
    private(set) var offersWebuiReplace = false
    /// How the detected dashboard offers to sign in (`HermesSignInMethod.offered(by:)`), the
    /// default first; empty until one answers.
    private(set) var offeredSignInMethods: [HermesSignInMethod] = []
    /// The release the detected dashboard reports, for the sheet's "Hermes <version>" line.
    private(set) var hermesVersion: String?
    /// How Connect signs the detected dashboard in: a password, the browser (#708), whose page
    /// Connect shows, or none (#1314), which Connect signs in to as it is. Only the first asks
    /// for a username and password. The host's default, until the Password | Browser picker
    /// (`offersSignInChoice`) changes it; an error from the other method goes with the change.
    var signInMethod: HermesSignInMethod = .password {
        didSet { if signInMethod != oldValue { errorMessage = nil } }
    }
    /// `useMoveSourceHeaders` filled the move source's headers in, so the offer is gone.
    private(set) var usedMoveSourceHeaders = false
    var errorMessage: String?
    /// What the last failed Hermes status read or sign-in observed (#1395). Each Connect starts
    /// without one; a credential edit, or an edit that drops the error, drops it.
    private var lastAttempt: HermesAttemptRecord?
    /// The failed Hermes attempt behind `errorMessage`, shown as its Details: none once a webui
    /// answered at the address, since the error is then the webui's.
    var failedAttempt: HermesAttemptRecord? {
        errorMessage == nil || detectedKind == .webui ? nil : lastAttempt
    }
    var isWorking = false
    /// True while an operation owns the form: views disable the URL/password
    /// fields, header editor, and Return-key submission so a side effect that
    /// has already run (AuthManager.configure persists and activates server
    /// state) cannot be superseded by mid-flight edits (PR #294 re-gate).
    var isConnectionLocked = false

    /// The URL session setup for the form's own Hermes connections; tests script the host with it.
    @ObservationIgnored private let hermesConfiguration: () -> URLSessionConfiguration
    // Identity + generation of the probe that produced `authStatus` or `detectedKind`.
    @ObservationIgnored private var probedConnectionIdentity: String?
    @ObservationIgnored private var operationGeneration = 0

    init(
        entry: Entry = .onboarding,
        moveSource: MoveSource? = nil,
        savedServer: URL? = nil,
        savedHeaders: [CustomHeader] = [],
        initialErrorMessage: String? = nil,
        hermesConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.entry = entry
        self.moveSource = moveSource
        self.hermesConfiguration = hermesConfiguration
        if let savedServer {
            serverURLString = savedServer.absoluteString
            // Only a webui server signs in again here, and it had a password to sign out of.
            webuiNeedsPassword = true
        }
        customHeaders = savedHeaders
        errorMessage = initialErrorMessage
        if initialErrorMessage != nil {
            // The banner belongs to the restored identity so later edits clear it.
            probedConnectionIdentity = nil
        }
    }

    /// A detected dashboard's sign-in: its username and password, its browser sign-in, or the
    /// warning that it has none.
    var showsHermesSignIn: Bool { detectedKind == .hermes }

    /// The username field and the saved sign-ins to copy, for a dashboard with a password.
    var showsHermesCredentials: Bool { showsHermesSignIn && signInMethod == .password }

    /// The Password | Browser picker, for a detected dashboard that offers both.
    var offersSignInChoice: Bool { showsHermesSignIn && offeredSignInMethods.count > 1 }

    /// Why the form's headers can't go with the browser sign-in picked or required: an
    /// `Authorization` row, which its own bearer takes the place of. Shown under the picker,
    /// and Connect stays off until it is fixed. Other refusals show when Connect sends them.
    var browserHeaderRejection: String? {
        guard showsHermesSignIn, signInMethod == .browser else { return nil }
        do { _ = try HermesHeaders(sentHeaders, signsInWithBrowser: true); return nil }
        catch HermesHeaders.Rejection.authorization { return HermesHeaders.Rejection.authorization.localizedDescription }
        catch { return nil }
    }

    /// The dashboard's password, or a webui's once it asks for one: the address comes first.
    var showsPasswordField: Bool {
        detectedKind == .hermes ? signInMethod == .password : webuiNeedsPassword
    }

    /// Off without an address, for a detected dashboard with a password until both its
    /// username and password are filled in, and for its browser sign-in while
    /// `browserHeaderRejection` stands.
    var canSubmit: Bool {
        guard !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard detectedKind == .hermes else { return true }
        switch signInMethod {
        case .password: return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .browser: return browserHeaderRejection == nil
        case .open: return true
        }
    }

    /// The root Connect will use, for the "Will connect to" line: the URL the webui path
    /// saves once a webui answered, else the Hermes parser's (`BotConnection.address(_:)`).
    /// Nil while the text doesn't parse.
    var addressPreview: URL? {
        if detectedKind == .webui { return try? AuthManager.normalizedServerURL(from: serverURLString) }
        return try? BotConnection.address(serverURLString)
    }

    /// Fills the username, password and headers from `signIn`. It is a copy: Connect still
    /// signs in once, the new server gets its own record and UUID, and the webui server's
    /// connection stays as it is.
    func useSavedSignIn(_ signIn: AuthManager.SavedHermesSignIn) {
        guard !isConnectionLocked, detectedKind == .hermes, signInMethod == .password else { return }
        let offers = savedSignIns
        let methods = offeredSignInMethods
        let version = hermesVersion
        // Another saved sign-in's copies go first, so none of them outlives its offer.
        dropReusedSignIn()
        customHeaders = signIn.connection.headers ?? []
        // The saved headers are the ones that reach this address, so it stays a found dashboard
        // with the same sign-ins on offer.
        detectedKind = .hermes
        offeredSignInMethods = methods
        hermesVersion = version
        savedSignIns = offers
        probedConnectionIdentity = currentConnectionIdentity()
        username = signIn.connection.username
        password = signIn.connection.password
        reusedSignIn = signIn
    }

    /// The headers section's "Use <webui server>'s Headers" row, until it is used.
    var offersMoveSourceHeaders: Bool {
        !usedMoveSourceHeaders && moveSource?.headers.isEmpty == false
    }

    /// Fills in exactly the move source's headers, in place of rows with the same names and of
    /// empty rows, keeping any other row already filled in.
    func useMoveSourceHeaders() {
        guard !isConnectionLocked, let headers = moveSource?.headers, !headers.isEmpty else { return }
        let names = Set(headers.map { $0.sanitizedName.lowercased() })
        customHeaders = customHeaders.filter { !$0.sanitizedValue.isEmpty && !names.contains($0.sanitizedName.lowercased()) }
            + headers
        usedMoveSourceHeaders = true
    }

    // MARK: - Connection Options' headers (#1540)

    /// Cloudflare Access's service-token Client ID, Connection Options' first field.
    var accessClientID: String {
        get { headerValue(named: Self.accessClientIDHeader) }
        set { setHeaderValue(newValue, named: Self.accessClientIDHeader) }
    }

    /// Cloudflare Access's service-token Client Secret, Connection Options' second field.
    var accessClientSecret: String {
        get { headerValue(named: Self.accessClientSecretHeader) }
        set { setHeaderValue(newValue, named: Self.accessClientSecretHeader) }
    }

    /// The rows Connection Options' header editor shows: every row but Cloudflare Access's two.
    var otherHeaders: [CustomHeader] {
        get { customHeaders.filter { !Self.isAccessHeader($0) } }
        set { customHeaders = customHeaders.filter(Self.isAccessHeader) + newValue }
    }

    nonisolated private static func isAccessHeader(_ header: CustomHeader) -> Bool {
        [accessClientIDHeader, accessClientSecretHeader]
            .contains { $0.caseInsensitiveCompare(header.sanitizedName) == .orderedSame }
    }

    private func headerValue(named name: String) -> String {
        customHeaders.last { $0.sanitizedName.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    /// Sets the last row named `name`, adding one if needed; an empty value removes the rows,
    /// so a field left empty sends nothing.
    private func setHeaderValue(_ value: String, named name: String) {
        let matches = { (header: CustomHeader) in header.sanitizedName.caseInsensitiveCompare(name) == .orderedSame }
        if value.isEmpty {
            customHeaders.removeAll(where: matches)
        } else if let index = customHeaders.lastIndex(where: matches) {
            customHeaders[index].value = value
        } else {
            customHeaders.append(CustomHeader(name: name, value: value))
        }
    }

    // MARK: - Connection identity (issue #285)

    /// The header rows the form sends and saves: a name and a value, so an empty row never
    /// goes out (#900).
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
        guard let probed = probedConnectionIdentity else {
            // No probe yet, but an inherited banner (re-login error) still has no
            // owner — clear it on any edit so stale copy can't survive.
            if errorMessage != nil { errorMessage = nil }
            return
        }
        if currentConnectionIdentity() != probed {
            forgetProbe()
            errorMessage = nil
        }
    }

    /// Drops what the last probe found, which no longer describes the typed address.
    private func forgetProbe() {
        authStatus = nil
        offersWebuiReplace = false
        detectedKind = nil
        offeredSignInMethods = []
        hermesVersion = nil
        signInMethod = .password
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
        customHeaders = kept
    }

    /// Begins a tracked async operation and returns its generation token used
    /// to fence settlement against newer overlapping operations.
    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    // MARK: - Server kind (#900)

    /// `notHermes` and `refused` carry a failed status read's attempt record, for the error's Details.
    private enum Detection {
        /// The dashboard's address, how it signs in, and the release it reports.
        case hermes(URL, [HermesSignInMethod], String?)
        case notHermes(HermesAttemptRecord?)
        /// A Host-header 400 or an access proxy's own sign-in, with its advice.
        case refused(String, HermesAttemptRecord?)
    }

    /// Reads the public `/api/status` at the typed address with the form's headers, on a
    /// connection of its own. A JSON object carrying the `auth_required` flag is a Hermes dashboard.
    /// A Host-header 400, or something in front of the host that wants its own sign-in
    /// (`.blocked`), shows its advice as is. Anything else, including an address or headers
    /// only the webui path accepts, is left to the webui path (#900, Decision 1).
    private func detectHermes() async -> Detection {
        guard let address = try? BotConnection.address(serverURLString),
              let headers = try? HermesHeaders(sentHeaders) else { return .notHermes(nil) }
        let probe = BotConnection(id: UUID(), name: "", address: address, username: "", password: "",
                                  headers: headers.values.isEmpty ? nil : headers.values)
        let http = HermesConnection(connection: probe, configuration: hermesConfiguration())
        do {
            let status = try await http.status()
            guard let methods = HermesSignInMethod.offered(by: status) else { return .notHermes(nil) }
            return .hermes(address, methods, status["version"].text)
        } catch let failure as BotFailure where failure == .blocked || failure == .rejected(400) {
            return .refused(BotConnectionAdvice.message(for: failure, address: address), http.lastAttempt)
        } catch {
            return .notHermes(http.lastAttempt)
        }
    }

    /// Callers have just checked that the inputs are the ones probed. `methods` is never empty.
    private func foundHermes(at address: URL, signInMethods methods: [HermesSignInMethod], version: String?,
                             authManager: AuthManager) {
        authStatus = nil
        detectedKind = .hermes
        offeredSignInMethods = methods
        hermesVersion = version
        signInMethod = methods.first ?? .password
        probedConnectionIdentity = currentConnectionIdentity()
        savedSignIns = methods.contains(.password) ? authManager.savedHermesSignIns(at: address) : []
    }

    /// Onboarding has no server switcher, so the address of a saved Hermes server switches to
    /// it from Connect, with no probe or sign-in (#1331): its home opens, or
    /// its own sign-in form when it has no saved sign-in. Returns whether it switched.
    private func opensSavedHermesServer(authManager: AuthManager) -> Bool {
        guard entry == .onboarding, let address = try? BotConnection.address(serverURLString),
              let saved = authManager.servers.first(where: { $0.id == address.absoluteString && $0.kind == .hermes })
        else { return false }
        authManager.switchActiveServer(to: saved)
        return true
    }

    /// The sheet's Continue, Connect or Sign In with Browser. The first one for an address finds
    /// out what answers there; a dashboard then waits for its sign-in, if it has one, and a
    /// webui for its password, if it asks for one. Returns the server it added or signed in,
    /// or nil when nothing was added yet. In onboarding a saved Hermes server's address opens
    /// that server (`opensSavedHermesServer`). `replacingWebuiServer` is the confirmed Replace a
    /// saved webui server at a dashboard's address offers (`offersWebuiReplace`).
    /// A dashboard that signs in through the browser shows its sign-in page with `browser`.
    @discardableResult
    func connect(authManager: AuthManager, replacingWebuiServer: Bool = false,
                 browser: HermesBrowserSignIn.Presenter = .unavailable) async -> URL? {
        guard !isConnectionLocked else { return nil }
        errorMessage = nil
        offersWebuiReplace = false
        lastAttempt = nil

        if opensSavedHermesServer(authManager: authManager) { return nil }

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
            case .hermes(let address, let methods, let version):
                foundHermes(at: address, signInMethods: methods, version: version, authManager: authManager)
                return nil
            case .refused(let advice, let attempt):
                forgetProbe()
                errorMessage = advice
                lastAttempt = attempt
                return nil
            case .notHermes(let attempt):
                // A saved Hermes sign-in never goes down the webui path.
                dropReusedSignIn()
                lastAttempt = attempt
            }
        }

        if moveSource != nil, detectedKind != .hermes {
            errorMessage = (try? BotConnection.address(serverURLString))
                .map { BotConnectionAdvice.message(for: BotFailure.notDashboard, address: $0) }
                ?? BotFailure.notDashboard.localizedDescription
            return nil
        }
        if detectedKind == .hermes {
            return await addHermesServer(authManager: authManager, token: token, replacingWebuiServer: replacingWebuiServer,
                                         browser: browser)
        }
        switch entry {
        case .onboarding:
            return await configureWebui(authManager: authManager, token: token)
        case .addServer:
            return await addWebuiServer(authManager: authManager, token: token)
        }
    }

    /// Signs the detected dashboard in once with the form's username, password and headers,
    /// or with no credentials when it has no sign-in, on a connection of its own, then adds it
    /// as a Hermes server, switching to it unless a move opened the form. A failure shows
    /// `BotConnectionAdvice`'s copy, and nothing is retried (#884). A webui server saved at the
    /// address is replaced only when `replacingWebuiServer`, and only after the sign-in
    /// succeeded; otherwise it stops here with the Replace offer (#1027), which a move never
    /// makes: it could remove its own source.
    private func addHermesServer(authManager: AuthManager, token: Int, replacingWebuiServer: Bool,
                                 browser: HermesBrowserSignIn.Presenter) async -> URL? {
        let identity = currentConnectionIdentity()
        let address: URL
        let headers: [CustomHeader]
        do {
            address = try BotConnection.address(serverURLString)
            headers = try HermesHeaders(sentHeaders, signsInWithBrowser: signInMethod == .browser).values
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        let saved = authManager.servers.first { $0.id == address.absoluteString }
        if let saved, !(replacingWebuiServer && saved.kind == .webui) {
            offersWebuiReplace = saved.kind == .webui && moveSource == nil
            errorMessage = offersWebuiReplace
                ? String(localized: "A webui server is saved at this address.")
                : String(localized: "This server is already configured.")
            return nil
        }
        let isOpen = signInMethod == .open
        let candidate = BotConnection(
            id: UUID(), name: address.host ?? "Hermes", address: address,
            username: isOpen ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines), password: isOpen ? "" : password,
            installID: reusedSignIn?.connection.installID, headers: headers.isEmpty ? nil : headers
        )
        let http = HermesConnection(connection: candidate, configuration: hermesConfiguration())
        do {
            if signInMethod == .browser {
                try await HermesBrowserSignIn.signIn(http, presenter: browser)
            } else {
                try await http.signIn()
            }
        } catch {
            guard token == operationGeneration, identity == currentConnectionIdentity(),
                  !(error is CancellationError) else { return nil }
            errorMessage = BotConnectionAdvice.message(for: error, address: address)
            lastAttempt = http.lastAttempt
            return nil
        }
        // A sheet closed while it signed in adds nothing.
        guard token == operationGeneration, identity == currentConnectionIdentity(), !Task.isCancelled else { return nil }
        var record = http.connection
        record.hermesVersion = http.serverVersion
        record.installID = http.serverInstallID ?? candidate.installID
        let added = saved == nil
            ? authManager.addHermesServer(record, activating: moveSource == nil)
            : await authManager.replaceWebuiServer(with: record)
        guard added else {
            errorMessage = authManager.lastErrorMessage
            return nil
        }
        return address
    }

    /// Onboarding's webui path: probe unless a probe for these inputs already answered, ask for
    /// the password when it needs one, then `configure`. Returns the server it signed in.
    private func configureWebui(authManager: AuthManager, token: Int) async -> URL? {
        if authStatus == nil {
            let identityAtStart = currentConnectionIdentity()
            do {
                let status = try await authManager.testConnection(
                    serverURLString: serverURLString,
                    customHeaders: sentHeaders
                )
                guard token == operationGeneration else { return nil }
                guard identityAtStart == currentConnectionIdentity() else { return nil }
                probedConnectionIdentity = identityAtStart
                authStatus = status
                detectedKind = .webui
            } catch {
                guard token == operationGeneration else { return nil }
                guard identityAtStart == currentConnectionIdentity() else { return nil }
                forgetProbe()
                errorMessage = error.localizedDescription
                return nil
            }

            if let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
                // The first time it asks, the field appears; an empty one already shown is an error.
                if webuiNeedsPassword { errorMessage = validationMessage }
                webuiNeedsPassword = true
                return nil
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
        guard token == operationGeneration else { return nil }
        guard configureIdentity == currentConnectionIdentity() else { return nil }
        errorMessage = authManager.lastErrorMessage
        guard errorMessage == nil, case .loggedIn(let server) = authManager.state else { return nil }
        return server
    }

    /// Add Server's webui path: `addServer` reveals the password field when the server needs
    /// one, and the next Connect sends it.
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
        case .failed(let serverAnswered):
            errorMessage = authManager.lastErrorMessage
            // A webui answered, so the error is its own, not the failed Hermes status read's.
            if serverAnswered { lastAttempt = nil }
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
