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
    /// True while an operation owns the form: views disable the URL/password
    /// fields, header editor, and Return-key submission so a side effect that
    /// has already run (AuthManager.configure persists and activates server
    /// state) cannot be superseded by mid-flight edits (PR #294 re-gate).
    var isConnectionLocked = false

    // Identity + generation of the probe that produced `authStatus`.
    @ObservationIgnored private var probedConnectionIdentity: String?
    @ObservationIgnored private var operationGeneration = 0

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

    // MARK: - Connection identity (issue #285)

    /// Effective headers exactly as the request path would apply them:
    /// applicable rows only, case-insensitive names, array order preserved with
    /// last-write-wins for duplicate names (matches
    /// `Array<CustomHeader>.apply(to:)` via `URLRequest.setValue`). This is the
    /// credential set that actually reaches the server, so reordering duplicate
    /// names or adding/removing a newline-broken row must change it.
    private func effectiveHeaderMap() -> [(name: String, value: String)] {
        var map: [(name: String, value: String)] = []
        for header in customHeaders where header.isApplicable {
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
        let urlPart: String
        do {
            let url = try AuthManager.normalizedServerURL(from: serverURLString)
            urlPart = url.absoluteString.lowercased()
        } catch {
            urlPart = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            if errorMessage != nil || connectionMessage != nil {
                errorMessage = nil
                connectionMessage = nil
            }
            return
        }
        let current = currentConnectionIdentity()
        if current != probed {
            authStatus = nil
            connectionMessage = nil
            errorMessage = nil
            probedConnectionIdentity = nil
        }
    }

    /// Begins a tracked async operation and returns its generation token used
    /// to fence settlement against newer overlapping operations.
    private func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    func testConnection(authManager: AuthManager) async {
        guard !isConnectionLocked else { return }
        errorMessage = nil
        connectionMessage = nil
        isWorking = true
        isConnectionLocked = true
        let token = beginOperation()
        let identityAtStart = currentConnectionIdentity()
        defer {
            if token == operationGeneration {
                isWorking = false
                isConnectionLocked = false
            }
        }

        do {
            let status = try await authManager.testConnection(
                serverURLString: serverURLString,
                customHeaders: customHeaders
            )
            guard token == operationGeneration else { return }
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
            guard token == operationGeneration else { return }
            guard identityAtStart == currentConnectionIdentity() else { return }
            // A failed re-probe invalidates the prior successful status: the old
            // capability result no longer describes this identity.
            authStatus = nil
            probedConnectionIdentity = nil
            errorMessage = error.localizedDescription
        }
    }

    func connect(authManager: AuthManager) async {
        guard !isConnectionLocked else { return }
        errorMessage = nil
        connectionMessage = nil

        if let validationMessage = Self.passwordValidationMessage(authStatus: authStatus, password: password) {
            errorMessage = validationMessage
            return
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

        if authStatus == nil {
            let identityAtStart = currentConnectionIdentity()
            do {
                let status = try await authManager.testConnection(
                    serverURLString: serverURLString,
                    customHeaders: customHeaders
                )
                guard token == operationGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                probedConnectionIdentity = identityAtStart
                authStatus = status
            } catch {
                guard token == operationGeneration else { return }
                guard identityAtStart == currentConnectionIdentity() else { return }
                authStatus = nil
                probedConnectionIdentity = nil
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
            customHeaders: customHeaders
        )
        guard token == operationGeneration else { return }
        guard configureIdentity == currentConnectionIdentity() else { return }
        errorMessage = authManager.lastErrorMessage
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
