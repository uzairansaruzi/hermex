import AuthenticationServices
import CryptoKit
import Foundation
import Network
import SwiftUI

@MainActor enum HermesBrowserSignIn {
    static let callbackScheme = "hermexsignin"
    struct Presenter {
        let present: @MainActor (URL) async throws -> Void

        static let unavailable = Presenter { _ in throw BotFailure.browserSignInFailed }
    }

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
            if error is CancellationError || (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                throw CancellationError()
            }
            throw error is BotFailure ? error : BotFailure.browserSignInFailed
        } catch {}
        guard let code = listener.code else { throw BotFailure.browserSignInFailed }
        try await http.signIn(browserCode: code, verifier: verifier)
    }

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

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

extension HermesBrowserSignIn.Presenter {
    init(_ session: WebAuthenticationSession) {
        self.init { url in
            _ = try await session.authenticate(using: url, callback: .customScheme(HermesBrowserSignIn.callbackScheme),
                                               preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
        }
    }
}

final class HermesLoopbackListener: @unchecked Sendable {
    private(set) var code: String?
    private var listener: NWListener?
    private let bounce: String
    private let state: String
    private var started = false

    init(bounce: String, state: String) {
        self.bounce = bounce
        self.state = state
    }

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

    private static let requestLineLimit = 16_384

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffered: Data())
    }

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
