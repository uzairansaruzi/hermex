import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    nonisolated static let emptyPasswordMessage = String(localized: "Enter the server password.")

    var serverURLString = "" {
        didSet { invalidateProbedAuthStatusIfNeeded() }
    }
    var password = ""
    var customHeaders: [CustomHeader] = [] {
        didSet { invalidateProbedAuthStatusIfNeeded() }
    }
    var authStatus: AuthStatusResponse?
    var connectionMessage: String?
    var errorMessage: String?
    var isWorking = false

    @ObservationIgnored private var probedConnectionIdentity: String?
    @ObservationIgnored private var probeGeneration = 0

    init(
        savedServer: URL? = nil,
        savedHeaders: [CustomHeader] = [],
        initialErrorMessage: String? = nil
    ) {
        if let savedServer {
            serverURLString = savedServer.absoluteString
        }
        customHeaders = savedHeaders
        errorMessage = initialErrorMessage
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

    // MARK: - Connection identity (issue #285)

    private func currentConnectionIdentity() -> String {
        let urlPart: String
        do {
            let url = try AuthManager.normalizedServerURL(from: serverURLString)
            urlPart = url.absoluteString.lowercased()
        } catch {
            urlPart = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // Encode header names/values so delimiters (":" and "|") inside a
        // header value cannot collide with the identity serialization (e.g.
        // "X: 1|y:2" as one header vs "X: 1" + "Y: 2" as two). Values are not
        // lowercased — header values are case-sensitive.
        let headerPart = customHeaders.sanitizedForStorage()
            .map { header -> String in
                let name = Self.escapeForIdentity(header.sanitizedName.lowercased())
                let value = Self.escapeForIdentity(header.sanitizedValue)
                return "\(name):\(value)"
            }
            .sorted()
            .joined(separator: "|")
        return "\(urlPart)|\(headerPart)"
    }

    nonisolated private static func escapeForIdentity(_ raw: String) -> String {
        // Must escape "%" first so ":"/"|" escapes don't double-escape.
        var out = raw.replacingOccurrences(of: "%", with: "%25")
        out = out.replacingOccurrences(of: ":", with: "%3A")
        out = out.replacingOccurrences(of: "|", with: "%7C")
        return out
    }

    private func invalidateProbedAuthStatusIfNeeded() {
        guard let probed = probedConnectionIdentity else { return }
        let current = currentConnectionIdentity()
        if current != probed {
            authStatus = nil
            connectionMessage = nil
            errorMessage = nil
            probedConnectionIdentity = nil
        }
    }

    func testConnection(authManager: AuthManager) async {
        errorMessage = nil
        connectionMessage = nil
        isWorking = true
        defer { isWorking = false }

        probeGeneration += 1
        let generation = probeGeneration
        let identityAtStart = currentConnectionIdentity()

        do {
            let status = try await authManager.testConnection(
                serverURLString: serverURLString,
                customHeaders: customHeaders
            )
            guard generation == probeGeneration else { return }
            guard identityAtStart == currentConnectionIdentity() else { return }
            probedConnectionIdentity = identityAtStart
            authStatus = status
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
            guard generation == probeGeneration else { return }
            guard identityAtStart == currentConnectionIdentity() else { return }
            probedConnectionIdentity = identityAtStart
            errorMessage = error.localizedDescription
        }
    }

    func connect(authManager: AuthManager) async {
        errorMessage = nil
        connectionMessage = nil

        if let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
            errorMessage = validationMessage
            return
        }

        isWorking = true
        defer { isWorking = false }

        if authStatus == nil {
            probeGeneration += 1
            let generation = probeGeneration
            let identityAtStart = currentConnectionIdentity()
            do {
                let status = try await authManager.testConnection(
                    serverURLString: serverURLString,
                    customHeaders: customHeaders
                )
                guard generation == probeGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                probedConnectionIdentity = identityAtStart
                authStatus = status
            } catch {
                guard generation == probeGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                probedConnectionIdentity = identityAtStart
                errorMessage = error.localizedDescription
                return
            }

            if let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
                errorMessage = validationMessage
                return
            }
        } else if probedConnectionIdentity == nil {
            // Auth status exists but probe identity was never recorded (e.g. restored
            // from a previous session). Seed it so future edits can invalidate.
            probedConnectionIdentity = currentConnectionIdentity()
        }

        await authManager.configure(
            serverURLString: serverURLString,
            password: password,
            customHeaders: customHeaders
        )
        errorMessage = authManager.lastErrorMessage
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
