import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    enum Entry { case onboarding, addServer }

    struct MoveSource {
        let name: String
        let headers: [CustomHeader]
    }

    nonisolated static let emptyPasswordMessage = String(localized: "Enter the server password.")
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
    var username = "" {
        didSet { if username != oldValue { lastAttempt = nil } }
    }
    var password = "" {
        didSet { if password != oldValue { lastAttempt = nil } }
    }
    var customHeaders: [CustomHeader] = [] {
        didSet { invalidateProbedAuthStatusIfNeeded() }
    }
    var authStatus: AuthStatusResponse?
    private(set) var detectedKind: ServerKind?
    private(set) var savedSignIns: [AuthManager.SavedHermesSignIn] = []
    private(set) var reusedSignIn: AuthManager.SavedHermesSignIn?
    private(set) var webuiNeedsPassword = false
    private(set) var offersWebuiReplace = false
    private(set) var offeredSignInMethods: [HermesSignInMethod] = []
    private(set) var hermesVersion: String?
    var signInMethod: HermesSignInMethod = .password {
        didSet { if signInMethod != oldValue { errorMessage = nil } }
    }
    private(set) var usedMoveSourceHeaders = false
    var errorMessage: String?
    private var lastAttempt: HermesAttemptRecord?
    var failedAttempt: HermesAttemptRecord? {
        errorMessage == nil || detectedKind == .webui ? nil : lastAttempt
    }
    var isWorking = false
    var isConnectionLocked = false

    @ObservationIgnored private let hermesConfiguration: () -> URLSessionConfiguration
    @ObservationIgnored private let hermesGateway: HermesGateway.Options
    @ObservationIgnored private var probedConnectionIdentity: String?
    @ObservationIgnored private var operationGeneration = 0

    init(
        entry: Entry = .onboarding,
        moveSource: MoveSource? = nil,
        savedServer: URL? = nil,
        savedHeaders: [CustomHeader] = [],
        initialErrorMessage: String? = nil,
        hermesConfiguration: @escaping () -> URLSessionConfiguration = { .ephemeral },
        hermesGateway: HermesGateway.Options = HermesGateway.Options()
    ) {
        self.entry = entry
        self.moveSource = moveSource
        self.hermesConfiguration = hermesConfiguration
        self.hermesGateway = hermesGateway
        if let savedServer {
            serverURLString = savedServer.absoluteString
            webuiNeedsPassword = true
        }
        customHeaders = savedHeaders
        errorMessage = initialErrorMessage
        if initialErrorMessage != nil {
            probedConnectionIdentity = nil
        }
    }

    var showsHermesSignIn: Bool { detectedKind == .hermes }

    var showsHermesCredentials: Bool { showsHermesSignIn && signInMethod == .password }

    var offersSignInChoice: Bool { showsHermesSignIn && offeredSignInMethods.count > 1 }

    var browserHeaderRejection: String? {
        guard showsHermesSignIn, signInMethod == .browser else { return nil }
        do { _ = try HermesHeaders(sentHeaders, signsInWithBrowser: true); return nil }
        catch HermesHeaders.Rejection.authorization { return HermesHeaders.Rejection.authorization.localizedDescription }
        catch { return nil }
    }

    var showsPasswordField: Bool {
        detectedKind == .hermes ? signInMethod == .password : webuiNeedsPassword
    }

    var canSubmit: Bool {
        guard !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard detectedKind == .hermes else { return true }
        switch signInMethod {
        case .password: return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .browser: return browserHeaderRejection == nil
        case .open: return true
        }
    }

    var addressPreview: URL? {
        if detectedKind == .webui { return try? AuthManager.normalizedServerURL(from: serverURLString) }
        return try? BotConnection.address(serverURLString)
    }

    func useSavedSignIn(_ signIn: AuthManager.SavedHermesSignIn) {
        guard !isConnectionLocked, detectedKind == .hermes, signInMethod == .password else { return }
        let offers = savedSignIns
        let methods = offeredSignInMethods
        let version = hermesVersion
        dropReusedSignIn()
        customHeaders = signIn.connection.headers ?? []
        detectedKind = .hermes
        offeredSignInMethods = methods
        hermesVersion = version
        savedSignIns = offers
        probedConnectionIdentity = currentConnectionIdentity()
        username = signIn.connection.username
        password = signIn.connection.password
        reusedSignIn = signIn
    }

    var offersMoveSourceHeaders: Bool {
        !usedMoveSourceHeaders && moveSource?.headers.isEmpty == false
    }

    func useMoveSourceHeaders() {
        guard !isConnectionLocked, let headers = moveSource?.headers, !headers.isEmpty else { return }
        let names = Set(headers.map { $0.sanitizedName.lowercased() })
        customHeaders = customHeaders.filter { !$0.sanitizedValue.isEmpty && !names.contains($0.sanitizedName.lowercased()) }
            + headers
        usedMoveSourceHeaders = true
    }

    var accessClientID: String {
        get { headerValue(named: Self.accessClientIDHeader) }
        set { setHeaderValue(newValue, named: Self.accessClientIDHeader) }
    }

    var accessClientSecret: String {
        get { headerValue(named: Self.accessClientSecretHeader) }
        set { setHeaderValue(newValue, named: Self.accessClientSecretHeader) }
    }

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

    private var sentHeaders: [CustomHeader] {
        customHeaders.sanitizedForStorage().filter { !$0.sanitizedValue.isEmpty }
    }

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
        if detectedKind == .hermes {
            urlPart += " hermes:" + ((try? BotConnection.address(serverURLString))?.absoluteString ?? "")
        }
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
            if errorMessage != nil { errorMessage = nil }
            if !showsPasswordField { password = "" }
            return
        }
        if currentConnectionIdentity() != probed {
            forgetProbe()
            password = ""
            webuiNeedsPassword = false
            errorMessage = nil
        }
    }

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

    private func dropReusedSignInIfMoved() {
        guard let reused = reusedSignIn,
              (try? BotConnection.address(serverURLString))
                != (try? BotConnection.address(reused.connection.address.absoluteString)) else { return }
        dropReusedSignIn()
    }

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

    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    private enum Detection {
        case hermes(URL, [HermesSignInMethod], String?)
        case notHermes(HermesAttemptRecord?)
        case refused(String, HermesAttemptRecord?)
    }

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

    private func opensSavedHermesServer(authManager: AuthManager) -> Bool {
        guard entry == .onboarding, let address = try? BotConnection.address(serverURLString),
              let saved = authManager.servers.first(where: { $0.id == address.absoluteString && $0.kind == .hermes })
        else { return false }
        authManager.switchActiveServer(to: saved)
        return true
    }

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
        let http = HermesConnection(connection: candidate, configuration: hermesConfiguration(), gateway: hermesGateway)
        let socket = BotClient(http: http)
        defer { socket.close() }
        do {
            if signInMethod == .browser {
                try await HermesBrowserSignIn.signIn(http, presenter: browser)
            } else {
                try await http.signIn()
            }
            try await socket.connect()
        } catch {
            guard token == operationGeneration, identity == currentConnectionIdentity(),
                  !(error is CancellationError), !Task.isCancelled else { return nil }
            errorMessage = BotConnectionAdvice.message(for: error, address: address)
            lastAttempt = http.lastAttempt
            return nil
        }
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
                if webuiNeedsPassword { errorMessage = validationMessage }
                webuiNeedsPassword = true
                return nil
            }
        } else if probedConnectionIdentity == nil {
            probedConnectionIdentity = currentConnectionIdentity()
        }

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
            if serverAnswered { lastAttempt = nil }
            return nil
        case .added(let url):
            return url
        }
    }

    func probeConnectionIdentityForTesting() -> String {
        currentConnectionIdentity()
    }

    func seedProbedIdentityForTesting() {
        probedConnectionIdentity = currentConnectionIdentity()
    }

    nonisolated static func passwordValidationMessage(authStatus: AuthStatusResponse?, password: String) -> String? {
        guard authStatus?.authEnabled == true else { return nil }
        guard authStatus?.isAlreadySignedIn != true else { return nil }
        guard authStatus?.passwordAuthEnabled != false else { return nil }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPassword.isEmpty ? emptyPasswordMessage : nil
    }
}
