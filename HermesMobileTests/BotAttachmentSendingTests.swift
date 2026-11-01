import XCTest
import UIKit
@testable import HermesMobile

/// How a Hermes chat's files go to the host: an image staged as the host receives it, then
/// uploaded over HTTP to the Profile's image store, which answers with the stored path.
@MainActor final class BotAttachmentSendingTests: XCTestCase {
    private var photo: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private var transparentPhoto: Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).pngData { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testTransparentImageStaysPNGAndAnOpaqueOneBecomesJPEG() throws {
        let png = try BotAttachmentUpload.prepare(data: transparentPhoto, filename: "overlay.png")
        XCTAssertEqual(png.name, "overlay.png")
        XCTAssertEqual(png.mime, "image/png")
        XCTAssertTrue(png.image)
        XCTAssertTrue(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let jpeg = try BotAttachmentUpload.prepare(data: photo, filename: "photo.heic")
        XCTAssertEqual(jpeg.name, "photo.jpg")
        XCTAssertEqual(jpeg.mime, "image/jpeg")
    }

    func testOnlySupportedTypesArePrepared() throws {
        let text = try BotAttachmentUpload.prepare(data: Data("notes".utf8), filename: "notes.md")
        XCTAssertEqual(text.data, Data("notes".utf8), "a document goes as it is")
        XCTAssertFalse(text.image)
        XCTAssertThrowsError(try BotAttachmentUpload.prepare(data: Data([1]), filename: "tool.exe")) {
            XCTAssertEqual($0 as? BotAttachmentFailure, .type)
        }
        XCTAssertThrowsError(try BotAttachmentUpload.prepare(data: Data([1, 2, 3]), filename: "broken.png")) {
            XCTAssertEqual($0 as? BotAttachmentFailure, .unreadable)
        }
    }

    func testPNGImageHTTPUploadUsesPNGDataURL() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); BotArtifactHTTPFixture.handler = nil }
        BotArtifactHTTPFixture.handler = { request in
            let payload = apiTestBodyData(from: request).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: String]
            }
            XCTAssertEqual(payload?["filename"], "overlay.png")
            XCTAssertTrue(payload?["data_url"]?.hasPrefix("data:image/png;base64,") == true)
            return (200, [:], Data(#"{"ok":true,"path":"/profile/images/overlay.png"}"#.utf8))
        }
        let path = try await BotAttachmentUpload.send(try BotAttachmentUpload.request(
            data: transparentPhoto, filename: "overlay.png", profile: "inbox-triage", base: URL(string: "https://bot.example")!
        ), on: session)
        XCTAssertEqual(path, "/profile/images/overlay.png")
    }

    func testImageHTTPUploadUsesProfileAndReturnedPathAndRejectsMissingAcknowledgment() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BotArtifactHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); BotArtifactHTTPFixture.handler = nil }
        BotArtifactHTTPFixture.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/chat/image-upload")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "inbox-triage")])
            return (200, [:], Data(#"{"ok":true,"path":"/profile/images/photo.jpg","future":42}"#.utf8))
        }
        let request = try BotAttachmentUpload.request(data: photo, filename: "photo.jpg", profile: "inbox-triage",
                                                      base: URL(string: "https://bot.example")!)
        let path = try await BotAttachmentUpload.send(request, on: session)
        XCTAssertEqual(path, "/profile/images/photo.jpg")
        for body in [#"{"path":"/images/photo.jpg"}"#, #"{"ok":true,"path":"https://other.example/photo.jpg"}"#] {
            BotArtifactHTTPFixture.handler = { _ in (200, [:], Data(body.utf8)) }
            do {
                _ = try await BotAttachmentUpload.send(request, on: session)
                XCTFail("Missing or invalid acknowledgment accepted")
            } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
    }
}

actor BotAttachmentCopies: ChatDraftAttachmentStoring {
    private var values: [String: Data] = [:]
    var count: Int { values.count }
    func retainedFileBytes() async throws -> [String: Int] { values.mapValues(\.count) }
    func save(data: Data, suggestedFilename: String) -> String {
        let name = UUID().uuidString + "-" + suggestedFilename; values[name] = data; return name
    }
    func data(named fileName: String) throws -> Data {
        guard let data = values[fileName] else { throw BotAttachmentFailure.unreadable }; return data
    }
    func delete(named fileName: String) { values[fileName] = nil }
    func fileURL(named fileName: String) throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) {}
}
