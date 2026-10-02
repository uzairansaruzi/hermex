import XCTest
import UniformTypeIdentifiers
@testable import HermesMobile

@MainActor final class BotArtifactTests: XCTestCase {
    private let address = URL(string: "https://bot.example")!
    private func context(connectionID: UUID = UUID()) -> BotArtifactContext {
        BotArtifactContext(connectionID: connectionID, profile: "inbox-triage", sessionID: "compression-tip", generation: 1)
    }

    func testMixedTextAndLocalArtifactsKeepOrderAndServerRelativePaths() {
        let text = "Before\n![chart](./charts/result.png)\n[Report](<reports/Quarter One.pdf>)\nMEDIA:audio/result.mp3\nAfter"
        let segments = TranscriptMediaParser.segments(in: text, includesLocalFileLinks: true)
        let refs = segments.compactMap { if case .media(let ref) = $0 { return ref.rawReference }; return nil }
        XCTAssertEqual(refs, ["./charts/result.png", "reports/Quarter One.pdf", "audio/result.mp3"])
        XCTAssertEqual(segments.first, .text("Before\n"))
        XCTAssertEqual(segments.last, .text("\nAfter"))
        XCTAssertEqual(TranscriptMediaParser.segments(in: "[Report](./report.pdf)"), [.text("[Report](./report.pdf)")])
    }

    func testCodeSamplesAndExternalLinksStayText() {
        let text = "`[file](./x.pdf)`\n```\n![image](./x.png)\n```\n[Website](https://example.org/page)"
        XCTAssertEqual(TranscriptMediaParser.segments(in: text, includesLocalFileLinks: true), [.text(text)])
    }

    func testDownloadURLBindsProfileAndDurableSessionAndDoesNotResolveOnPhone() throws {
        let scope = context()
        let url = try XCTUnwrap(HermesREST.downloadArtifact(path: "../files/a & b.pdf", profile: scope.profile,
                                                            sessionID: scope.sessionID).request(base: address).url)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, address.host)
        XCTAssertEqual(url.path, "/api/fs/download")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["path": "../files/a & b.pdf", "profile": scope.profile, "session_id": "compression-tip"])
        XCTAssertEqual(try BotArtifactReference.path("file:///server/a%20b.pdf", address: address), "/server/a b.pdf")
        XCTAssertEqual(try BotArtifactReference.path("~/result.pdf", address: address), "~/result.pdf")
    }

    func testReferencesCannotSelectAnotherHostOrOverrideSession() throws {
        for path in ["https://other.example/a.pdf", "//other.example/a.pdf", "data:text/plain;base64,YQ==", "file://other/server/a.pdf", ""] {
            XCTAssertThrowsError(try BotArtifactReference.path(path, address: address))
        }
        let url = try XCTUnwrap(HermesREST.downloadArtifact(
            path: "https://bot.example/api/fs/download?path=a.pdf&profile=other&session_id=other&token=secret",
            profile: "inbox-triage", sessionID: "compression-tip").request(base: address).url)
        XCTAssertFalse(url.absoluteString.contains("secret"))
        XCTAssertFalse(url.absoluteString.contains("other"))
    }

    func testResponseWithoutLengthCannotExceedLimit() throws {
        var buffer = BotArtifactBuffer(limit: 5)
        try buffer.append(Data([1, 2, 3]))
        XCTAssertThrowsError(try buffer.append(Data([4, 5, 6])))
        XCTAssertEqual(buffer.data, Data([1, 2, 3]))
        try buffer.append(Data([4, 5]))
        XCTAssertEqual(buffer.data.count, 5)
    }

    func testHTTPDownloadPreservesRawPDFAndRejectsErrorsAndOversize() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); BotArtifactHTTPFixture.handler = nil }
        let request = try HermesREST.downloadArtifact(path: "report.pdf", profile: "inbox-triage", sessionID: "compression-tip")
            .request(base: address)
        let url = request.url
        let pdf = Data("%PDF-fixture".utf8)
        BotArtifactHTTPFixture.handler = { request in
            XCTAssertEqual(request.url, url)
            return (200, ["Content-Type": "application/pdf"], pdf)
        }
        let bytes = try await BotArtifactDownload.data(session: session, request: request)
        XCTAssertEqual(bytes, pdf)
        for status in [401, 403, 404, 302] {
            BotArtifactHTTPFixture.handler = { _ in (status, [:], Data()) }
            do { _ = try await BotArtifactDownload.data(session: session, request: request); XCTFail("Expected rejection") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
        BotArtifactHTTPFixture.handler = { _ in (200, ["Content-Length": "\(BotArtifactBuffer.maximumBytes + 1)"], Data()) }
        do { _ = try await BotArtifactDownload.data(session: session, request: request); XCTFail("Expected size rejection") }
        catch { XCTAssertTrue(error is BotArtifactFailure) }
    }

    func testCancellingDownloadStopsItsHTTPTask() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        let started = expectation(description: "HTTP request started")
        let stopped = expectation(description: "HTTP request cancelled")
        BotArtifactHTTPFixture.startHook = { fixture in
            let response = HTTPURLResponse(url: fixture.request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            fixture.client?.urlProtocol(fixture, didReceive: response, cacheStoragePolicy: .notAllowed)
            started.fulfill()
        }
        BotArtifactHTTPFixture.stopHook = { stopped.fulfill() }
        defer {
            session.invalidateAndCancel()
            BotArtifactHTTPFixture.startHook = nil
            BotArtifactHTTPFixture.stopHook = nil
        }
        let request = URLRequest(url: address.appendingPathComponent("api/fs/download"))
        let task = Task { try await BotArtifactDownload.data(session: session, request: request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download returned bytes") }
        catch { /* URLSession and AsyncBytes may report different cancellation errors. */ }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testPreviewExportReusesTheOneDownloadUnderItsSanitizedFilename() async throws {
        let model = BotArtifactPreviewModel()
        let pdf = Data("%PDF-fixture".utf8)
        var downloads = 0
        await model.load(name: "Quarter One.pdf") { downloads += 1; return pdf }
        let export = try XCTUnwrap(model.export)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(export.data, pdf)
        XCTAssertEqual(export.filename, "Quarter One.pdf")
        XCTAssertEqual(export.contentType, .pdf)
        XCTAssertEqual(model.fileURL?.lastPathComponent, "Quarter One.pdf")

        await model.load(name: "README") { Data("notes".utf8) }
        XCTAssertEqual(model.export?.filename, "README")
        XCTAssertEqual(model.export?.contentType, .data)
        await model.load(name: "..") { Data("dots".utf8) }
        XCTAssertEqual(model.export?.filename, "File")
        XCTAssertEqual(model.export?.contentType, .data)
    }

    func testPreviewHasNothingToExportAfterAFailedOrOversizedDownload() async throws {
        let model = BotArtifactPreviewModel()
        await model.load(name: "report.pdf") { Data("%PDF-fixture".utf8) }
        XCTAssertEqual(model.export?.filename, "report.pdf")
        await model.load(name: "report.pdf") { throw BotArtifactFailure.tooLarge }
        XCTAssertNil(model.export)
        XCTAssertNil(model.fileURL)
        XCTAssertEqual(model.errorMessage, BotArtifactFailure.tooLarge.localizedDescription)
        await model.load(name: "report.pdf") { throw URLError(.notConnectedToInternet) }
        XCTAssertNil(model.export)
        XCTAssertEqual(model.errorMessage, URLError(.notConnectedToInternet).localizedDescription)
    }

    func testPreviewCleanupAndLateDownloadCannotRecreateDismissedPreview() async throws {
        let model = BotArtifactPreviewModel()
        await model.load(name: "report.pdf") { Data("%PDF-fixture".utf8) }
        let url = try XCTUnwrap(model.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.export?.filename, "report.pdf")
        model.cleanup()
        XCTAssertNil(model.export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let started = expectation(description: "download started")
        var finish: CheckedContinuation<Data, Never>?
        let pending = Task {
            await model.load(name: "late.pdf") {
                await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.cleanup()
        finish?.resume(returning: Data("late".utf8))
        await pending.value
        XCTAssertNil(model.fileURL)
        XCTAssertNil(model.export)
        XCTAssertNil(model.errorMessage)
    }

    func testSwitchDuringDownloadRejectsStaleBytesAndEqualProfileOnOtherConnection() async throws {
        let wire = BotFixtureWire()
        let connection = BotConnection(id: UUID(), name: "Fixture", address: address, username: "u", password: "p")
        let profile = BotProfile(.object(["name": .string("inbox-triage")]))!
        let model = BotConversation(server: address, connection: connection, profile: profile, wire: wire,
                                    drafts: ChatDraftStore(persistence: BotMemoryDrafts()))
        await model.recover()
        let scope = try XCTUnwrap(model.artifactContext)
        XCTAssertEqual(scope.sessionID, "tip")
        let started = expectation(description: "download started")
        var finish: CheckedContinuation<Data, Never>?
        wire.downloadArtifact = { _, received in
            XCTAssertEqual(received, scope)
            return await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
        }
        let pending = Task { try await model.artifactData(path: "same.pdf", context: scope) }
        await fulfillment(of: [started], timeout: 2)
        model.suspend()
        finish?.resume(returning: Data("old server".utf8))
        do { _ = try await pending.value; XCTFail("Stale data must not be published") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        await model.recover()
        do { _ = try await model.artifactData(path: "same.pdf", context: context()); XCTFail("Other connection must fail") }
        catch { XCTAssertEqual(error as? BotFailure, .stale) }
        model.suspend()
    }
}

final class BotArtifactHTTPFixture: URLProtocol {
    static var startHook: ((BotArtifactHTTPFixture) -> Void)?
    static var stopHook: (() -> Void)?
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let hook = Self.startHook { hook(self); return }
        guard let handler = Self.handler else { return }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.stopHook?() }
}
