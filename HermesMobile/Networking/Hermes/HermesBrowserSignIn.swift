import AuthenticationServices
import CryptoKit
import Foundation
import Network
import SwiftUI

/// Signs a Hermes host in through the system browser (#708), as RFC 8252 describes for a
/// native app: a loopback listener on `127.0.0.1`, the host's `/auth/native/authorize` in an
/// ephemeral `ASWebAuthenticationSession`, and PKCE. The host brokers its own provider's
/// pages (an OIDC IdP, or its `/login` form for a password provider) and redirects to the
/// listener with a single-use code, which `HermesConnection.signIn(browserCode:verifier:)`
/// trades for tokens. The onboarding and Add Server form and a Hermes server's sign-in form
/// use it for a host whose status asks for it (`isRequired(by:)`).
///
/// Checked on a phone against a 0.21.5 host in the slice 8.1 spike: the HTTPS hop to the
/// loopback port is never upgraded to HTTPS, the listener survives the app being suspended
/// while the user is in a password manager, and the ephemeral session shows no "wants to
/// use … to sign in" alert. A listener iOS reclaims shows a "can't connect" page in the
/// sheet; closing it and signing in again recovers.
@MainActor enum HermesBrowserSignIn {
    /// The scheme the listener's `302` bounces to, which closes the sheet. It needs no
    /// registration: the session watches for it.
    static let callbackScheme = "hermexsignin"
    /// The defaults key of the testing toggle.
    nonisolated static let forcedKey = "hermesForcesBrowserSignIn"

    /// Shows the host's authorize page and returns once the sheet closes on the callback
    /// scheme. The views make it from their `webAuthenticationSession`; tests script it.
    struct Presenter {
        let present: @MainActor (URL) async throws -> Void

        /// A form that can't show a browser, which a browser host's sign-in then refuses.
        static let unavailable = Presenter { _ in throw BotFailure.browserSignInFailed }
    }

    /// Whether `status`, a host's public `/api/status`, asks for browser sign-in: the host
    /// offers it (`auth_flows ∋ native_pkce`) and has no `basic` password provider, or
    /// `forced` (the testing toggle) and it offers it at all.
    nonisolated static func isRequired(by status: BotJSON, forced: Bool = isForcedForTesting) -> Bool {
        guard status["auth_flows"].list?.contains(.string("native_pkce")) == true else { return false }
        return forced || status["auth_providers"].list?.contains(.string("basic")) != true
    }

    /// The Developer toggle that signs a password host in through the browser too, so the
    /// browser path can be tested against one. Debug and Hermex Branch builds only.
    nonisolated static var isForcedForTesting: Bool {
        get { offersTestingToggle && UserDefaults.standard.bool(forKey: forcedKey) }
        set { UserDefaults.standard.set(newValue, forKey: forcedKey) }
    }

    /// Debug builds and the side-by-side Hermex Branch build, which is a Release build.
    nonisolated static var offersTestingToggle: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.bundleIdentifier?.hasSuffix(".branch") == true
        #endif
    }

    /// Runs one browser sign-in for `http`, a connection not yet saved, and leaves it signed
    /// in as a browser sign-in's connection (`http.connection`), which the caller saves.
    /// Closing the sheet throws `CancellationError`; a sheet that closed without a matching
    /// callback, or a code the host no longer accepts, throws `.browserSignInFailed`.
    static func signIn(_ http: HermesConnection, presenter: Presenter) async throws {
        let verifier = randomURLSafe(32), state = randomURLSafe(16)
        let listener = HermesLoopbackListener(bounce: "\(callbackScheme)://done", state: state)
        defer { listener.stop() }
        let port: NWEndpoint.Port
        do { port = try await listener.start() } catch { throw BotFailure.browserSignInFailed }
        let url = try authorizeURL(base: http.connection.address, challenge: challenge(for: verifier),
                                   redirect: "http://127.0.0.1:\(port.rawValue)/callback", state: state)
        do {
            try await presenter.present(url)
        } catch where listener.code == nil {
            // An error after the code arrived is only the sheet closing; without one, the
            // user closed it, the form's task was cancelled, or it never showed.
            if error is CancellationError || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                throw CancellationError()
            }
            throw error is BotFailure ? error : BotFailure.browserSignInFailed
        } catch {}
        guard let code = listener.code else { throw BotFailure.browserSignInFailed }
        try await http.signIn(browserCode: code, verifier: verifier)
    }

    /// `/auth/native/authorize` on `base` with every query value fully percent-encoded,
    /// since some proxies' filters refuse an unencoded `redirect_uri=http://…`. No
    /// `provider`: the host picks its only interactive provider itself and shows its own
    /// chooser when it has several.
    static func authorizeURL(base: URL, challenge: String, redirect: String, state: String) throws -> URL {
        guard var parts = URLComponents(url: base.appendingPathComponent("auth/native/authorize"),
                                        resolvingAgainstBaseURL: false) else { throw BotFailure.invalidAddress }
        parts.percentEncodedQueryItems = [
            URLQueryItem(name: "code_challenge", value: encoded(challenge)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: encoded(redirect)),
            URLQueryItem(name: "state", value: encoded(state))
        ]
        guard let url = parts.url else { throw BotFailure.invalidAddress }
        return url
    }

    /// The S256 PKCE challenge for `verifier`: its SHA-256, base64url without padding.
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Everything outside RFC 3986's unreserved characters, percent-encoded.
    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension HermesBrowserSignIn.Presenter {
    /// Shows the authorize page in `session`, ephemeral, so the sheet keeps no cookies and
    /// asks nothing before it opens.
    init(_ session: WebAuthenticationSession) {
        self.init { url in
            _ = try await session.authenticate(using: url, callback: .customScheme(HermesBrowserSignIn.callbackScheme),
                                               preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
        }
    }
}

/// The loopback receiver for one browser sign-in, from the 8.1 spike: binds `127.0.0.1` on
/// an ephemeral port, keeps the first `GET /callback` whose `state` matches, and answers
/// every callback `302 <bounce>` so the custom-scheme bounce closes the sheet. Everything
/// runs on the main queue, so `code` is set before the bounce goes out, and nothing here is
/// touched from another thread.
final class HermesLoopbackListener: @unchecked Sendable {
    /// The code from the first callback carrying the expected `state`.
    private(set) var code: String?
    private var listener: NWListener?
    private let bounce: String
    private let state: String
    /// Whether `start` has answered.
    private var started = false

    init(bounce: String, state: String) {
        self.bounce = bounce
        self.state = state
    }

    /// Binds loopback on an ephemeral port and returns it once the listener is ready.
    func start() async throws -> NWEndpoint.Port {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.started, let listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    self.started = true
                    continuation.resume(returning: port)
                case .failed(let error):
                    self.started = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.started = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The most a request may send before its request line ends.
    private static let requestLineLimit = 16_384

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffered: Data())
    }

    /// Reads until the request line is complete, however TCP splits it.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.requestLineLimit) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            let buffered = buffered + (data ?? Data())
            if let target = Self.requestTarget(in: buffered) {
                self.handle(target, on: connection)
            } else if isComplete || error != nil || buffered.count >= Self.requestLineLimit {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: buffered)
            }
        }
    }

    /// The request target of `request`'s request line (`GET <target> HTTP/1.1`), or nil
    /// until that line has ended.
    static func requestTarget(in request: Data) -> String? {
        guard let end = request.firstRange(of: Data("\r\n".utf8)) else { return nil }
        let line = String(decoding: request[..<end.lowerBound], as: UTF8.self)
        return line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    }

    private func handle(_ target: String, on connection: NWConnection) {
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        guard components?.path == "/callback" else {
            return respond(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        let items = components?.queryItems ?? []
        if code == nil, items.first(where: { $0.name == "state" })?.value == state,
           let value = items.first(where: { $0.name == "code" })?.value, !value.isEmpty {
            code = value
        }
        respond(connection, "HTTP/1.1 302 Found\r\nLocation: \(bounce)\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    private func respond(_ connection: NWConnection, _ response: String) {
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
