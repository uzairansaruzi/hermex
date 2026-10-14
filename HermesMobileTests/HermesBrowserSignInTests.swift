import AuthenticationServices
import XCTest
@testable import HermesMobile

/// The browser sign-in (#708) against a scripted host. The presenter stands in for the sheet:
/// it reads the authorize URL and makes the browser's loopback hop to the real listener.
@MainActor final class HermesBrowserSignInTests: XCTestCase {
    private let candidate = BotConnection(id: UUID(), name: "Host", address: URL(string: "https://hermes.example")!,
                                          username: "", password: "")

    override func tearDown() {
        HermesHostFixture.reset()
        super.tearDown()
    }

    /// The expected value is Python's `urlsafe_b64encode(sha256(verifier))` without padding;
    /// it has both `-` and `_`, so it also pins the base64url alphabet.
    func testTheChallengeIsTheVerifiersBase64URLSHA256() {
        XCTAssertEqual(HermesBrowserSignIn.challenge(for: "dBjftJeZ4CVP-mJ92K1QfAa5uVjc3BX7hQ7qPABkBmo"),
                       "xwIIcHDBtRlDiY_-Sglen_9PWYflAK7874Eg3NIugTk")
    }

    func testTheAuthorizeURLEncodesEveryValueAndNamesNoProvider() throws {
        let url = try HermesBrowserSignIn.authorizeURL(base: candidate.address, challenge: "c-1",
                                                      redirect: "http://127.0.0.1:5000/callback", state: "s+t")
        XCTAssertEqual(url.absoluteString, "https://hermes.example/auth/native/authorize?code_challenge=c-1"
            + "&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback&state=s%2Bt")
    }

    /// Browser sign-in when the host offers it and no password provider, or when the testing
    /// toggle asks for it on a host that offers it; never on a host without it.
    func testOnlyAHostOfferingBrowserSignInWithoutAPasswordRequiresIt() {
        let rows: [(providers: [String], flows: [String], forced: Bool, required: Bool)] = [
            (["nous"], ["cookie", "native_pkce"], false, true),
            (["basic"], ["cookie", "native_pkce"], false, false),
            (["basic"], ["cookie", "native_pkce"], true, true),
            (["nous"], ["cookie"], false, false),
            (["basic"], [], true, false)
        ]
        for row in rows {
            let status = BotJSON.object(["auth_providers": .array(row.providers.map(BotJSON.string)),
                                         "auth_flows": .array(row.flows.map(BotJSON.string))])
            XCTAssertEqual(HermesBrowserSignIn.isRequired(by: status, forced: row.forced), row.required, "\(row)")
        }
    }

    /// Only the callback carrying the sign-in's `state` is kept, every callback is bounced to
    /// close the sheet, and the code and its verifier become a browser sign-in's connection
    /// that checks its identity with the bearer.
    func testTheLoopbackCodeWithItsStateBecomesASignedInBrowserConnection() async throws {
        var exchanged: BotJSON?
        let http = HermesConnection(connection: candidate, configuration: HermesHostFixture.configuration { request in
            switch request.url?.path {
            case "/api/status": return .json(200, Self.browserStatus)
            case "/auth/native/token":
                exchanged = try? JSONDecoder().decode(BotJSON.self, from: apiTestBodyData(from: request) ?? Data())
                return .json(200, Self.tokens)
            case "/api/auth/me": return .json(200, .object(["provider": .string("nous"), "user_id": .string("u1")]))
            default: return nil
            }
        })
        var authorize: URL?, bounces: [String?] = []
        let presenter = HermesBrowserSignIn.Presenter { url in
            authorize = url
            bounces.append(try await Self.callback(url, code: "stray", state: "someone-else"))
            bounces.append(try await Self.callback(url, code: "code-1"))
        }

        try await HermesBrowserSignIn.signIn(http, presenter: presenter)

        XCTAssertEqual(bounces, ["hermexsignin://done", "hermexsignin://done"])
        XCTAssertEqual(exchanged?["code"].text, "code-1", "The stray callback's code was never used")
        let query = try XCTUnwrap(authorize.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        let verifier = try XCTUnwrap(exchanged?["code_verifier"].text)
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, HermesBrowserSignIn.challenge(for: verifier))
        XCTAssertEqual(http.connection.oauth, HermesOAuth(provider: "nous", userID: "u1", refreshToken: "refresh-1"))
        XCTAssertEqual(http.connection.username, "u1")
        XCTAssertEqual(http.connection.password, "")
        let identity = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == "/api/auth/me" })
        XCTAssertEqual(identity.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(HermesHostFixture.count("/auth/password-login"), 0)
    }

    /// Closing the sheet, or cancelling the form's task, is a cancel, with nothing exchanged; a code the host refuses, as it
    /// does once 120 seconds pass or the code was used, is a failed browser sign-in.
    func testClosingTheSheetCancelsAndARefusedCodeFails() async throws {
        let http = HermesConnection(connection: candidate, configuration: HermesHostFixture.configuration { request in
            request.url?.path == "/auth/native/token"
                ? .json(400, .object(["detail": .string("Invalid or expired authorization code.")])) : nil
        })
        for closing in [ASWebAuthenticationSessionError(.canceledLogin), CancellationError()] as [Error] {
            let closed = HermesBrowserSignIn.Presenter { _ in throw closing }
            do { try await HermesBrowserSignIn.signIn(http, presenter: closed); XCTFail("Expected a cancel") } catch {
                XCTAssertTrue(error is CancellationError, "\(closing) became \(error)")
            }
        }
        XCTAssertEqual(HermesHostFixture.count("/auth/native/token"), 0)

        let late = HermesBrowserSignIn.Presenter { url in _ = try await Self.callback(url, code: "code-1") }
        do { try await HermesBrowserSignIn.signIn(http, presenter: late); XCTFail("Expected a refused code") } catch {
            XCTAssertEqual(error as? BotFailure, .browserSignInFailed)
        }
        XCTAssertNil(http.connection.oauth)
    }

    /// A callback that TCP splits is read until its request line ends.
    func testTheListenerWaitsForTheWholeRequestLine() {
        let request = "GET /callback?code=c1&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        XCTAssertNil(HermesLoopbackListener.requestTarget(in: Data("GET /callback?code=c1&sta".utf8)))
        XCTAssertNil(HermesLoopbackListener.requestTarget(in: Data("GET /callback?code=c1&state=s1 HTTP/1.1".utf8)))
        XCTAssertEqual(HermesLoopbackListener.requestTarget(in: Data(request.utf8)), "/callback?code=c1&state=s1")
    }

    // MARK: - Fixtures

    /// A 0.21.5 host whose only provider signs in through the browser.
    static let browserStatus = BotJSON.object([
        "auth_required": .bool(true), "auth_providers": .array([.string("nous")]),
        "auth_flows": .array([.string("cookie"), .string("native_pkce")]), "version": .string("0.21.5")
    ])

    static let tokens = BotJSON.object([
        "access_token": .string("access-1"), "refresh_token": .string("refresh-1"), "token_type": .string("Bearer"),
        "expires_at": .number(1_791_993_215), "provider": .string("nous"), "user_id": .string("u1")
    ])

    /// Makes the host's redirect to the authorize URL's loopback `redirect_uri` with `code`
    /// and, unless given, the authorize URL's own `state`, and returns the listener's bounce.
    static func callback(_ authorize: URL, code: String, state: String? = nil) async throws -> String? {
        let query = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirect = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
        var parts = try XCTUnwrap(URLComponents(string: redirect))
        parts.queryItems = [URLQueryItem(name: "code", value: code),
                            URLQueryItem(name: "state", value: state ?? query.first { $0.name == "state" }?.value)]
        let (_, response) = try await URLSession(configuration: .ephemeral)
            .data(from: try XCTUnwrap(parts.url), delegate: NoRedirects())
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
    }

    /// Keeps the listener's `302`, as the sheet sees it, instead of following it.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
