import XCTest
import UIKit
@testable import HermesMobile

@MainActor final class BotAttachmentSendingTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private func make(_ wire: BotFixtureWire, connectionID: UUID = UUID(),
                      drafts: ChatDraftStore, copies: BotAttachmentCopies) -> BotConversation {
        let connection = BotConnection(id: connectionID, name: "Mac", address: URL(string: "https://bot.example")!, username: "u", password: "fixture")
        return BotConversation(server: server, connection: connection,
                               profile: BotProfile(.object(["name": .string("inbox-triage")]))!,
                               wire: wire, drafts: drafts, attachmentCopies: copies)
    }
    private func store(_ persistence: BotMemoryDrafts = BotMemoryDrafts()) -> ChatDraftStore {
        ChatDraftStore(persistence: persistence, debounceDuration: .seconds(60))
    }
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

    func testTransparentImageStaysPNGWhenStaged() async throws {
        let copies = BotAttachmentCopies()
        let model = make(BotFixtureWire(), drafts: store(), copies: copies)
        await model.recover()
        await model.attachments.stage(data: transparentPhoto, filename: "overlay.png")
        let item = try XCTUnwrap(model.attachments.items.first)
        XCTAssertEqual(item.name, "overlay.png")
        XCTAssertEqual(item.mime, "image/png")
        let file = try XCTUnwrap(item.draftFileName)
        let bytes = try await copies.data(named: file)
        XCTAssertTrue(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        model.suspend()
    }

    func testPickerStagesLocallyRestoresOnlyItsConnectionAndRemovalDeletesCopy() async throws {
        let drafts = store(); let copies = BotAttachmentCopies(); let id = UUID(); let wire = BotFixtureWire()
        let model = make(wire, connectionID: id, drafts: drafts, copies: copies)
        await model.recover()
        await model.attachments.stage(data: Data("hello".utf8), filename: "note.txt")
        XCTAssertEqual(model.attachments.items.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "file.attach" || $0.0 == "prompt.submit" })
        model.suspend()
        let restored = make(BotFixtureWire(), connectionID: id, drafts: drafts, copies: copies)
        await restored.recover()
        XCTAssertEqual(restored.attachments.items.count, 1)
        let other = make(BotFixtureWire(), drafts: drafts, copies: copies)
        await other.recover(); XCTAssertTrue(other.attachments.items.isEmpty)
        await restored.attachments.remove(try XCTUnwrap(restored.attachments.items.first?.id))
        let remaining = await copies.count
        XCTAssertEqual(remaining, 0)
        let saved = await drafts.draft(for: restored.draftKey)
        XCTAssertTrue(saved?.attachments.isEmpty ?? true)
        restored.suspend(); other.suspend()
    }

    func testMixedSendUsesOnlyAcknowledgedReferencesAndNeverSharedImageQueue() async throws {
        let copies = BotAttachmentCopies(); let wire = BotFixtureWire()
        let model = make(wire, drafts: store(), copies: copies); await model.recover()
        await model.attachments.stage(data: photo, filename: "photo.jpg")
        await model.attachments.stage(data: Data("%PDF-test".utf8), filename: "report.pdf")
        wire.imageUpload = { _, _, context in
            XCTAssertEqual(context.profile, "inbox-triage"); XCTAssertEqual(context.sessionID, "tip")
            return "/profile/images/acknowledged.jpg"
        }
        wire.attachFile = { params in
            XCTAssertEqual(params["session_id"], .string("runtime"))
            XCTAssertTrue(params["data_url"]?.text?.hasPrefix("data:application/pdf;base64,") == true)
            return .object(["attached": .bool(true), "path": .string("/profile/attachments/report.pdf"),
                            "ref_text": .string("@file:/profile/attachments/report.pdf"), "future": .bool(true)])
        }
        model.editDraft("Compare these")
        XCTAssertNil(model.preparePrompt(.steer))
        await model.send()
        let prompts = wire.calls.filter { $0.0 == "prompt.submit" }
        XCTAssertEqual(prompts.count, 1)
        let text = try XCTUnwrap(prompts.first?.1["text"]?.text)
        XCTAssertTrue(text.contains("Compare these")); XCTAssertTrue(text.contains("image_url: /profile/images/acknowledged.jpg"))
        XCTAssertTrue(text.contains("@file:/profile/attachments/report.pdf"))
        XCTAssertFalse(wire.calls.contains { $0.0.hasPrefix("image.") })
        XCTAssertTrue(model.attachments.items.isEmpty); XCTAssertTrue(model.draft.isEmpty)
        let count = await copies.count; XCTAssertEqual(count, 0)
        model.suspend()
    }

    func testSwitchDuringImageUploadCannotSubmitToEitherBot() async {
        let copies = BotAttachmentCopies(); let drafts = store(); let wire = BotFixtureWire()
        let first = make(wire, drafts: drafts, copies: copies); await first.recover()
        let secondWire = BotFixtureWire(); let second = make(secondWire, drafts: drafts, copies: copies)
        await first.attachments.stage(data: photo, filename: "image.jpg")
        wire.imageUpload = { _, _, _ in
            first.suspend(); await second.recover()
            return "/old-profile/images/upload.jpg"
        }
        await first.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertFalse(secondWire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertTrue(second.attachments.items.isEmpty)
        XCTAssertEqual(first.attachments.items.count, 1)
        second.suspend()
    }

    func testInterruptedUploadRestoresASendableDraftAfterRelaunch() async {
        let copies = BotAttachmentCopies(); let persistence = BotMemoryDrafts()
        let drafts = store(persistence); let wire = BotFixtureWire(); let id = UUID()
        let model = make(wire, connectionID: id, drafts: drafts, copies: copies)
        await model.recover()
        model.editDraft("Test")
        await model.attachments.stage(data: photo, filename: "image.jpg")
        wire.imageUpload = { _, _, _ in
            model.suspend()
            throw CancellationError()
        }
        await model.send()
        let restored = make(BotFixtureWire(), connectionID: id, drafts: store(persistence), copies: copies)
        await restored.recover()
        XCTAssertFalse(restored.uncertainSend)
        XCTAssertNotNil(restored.preparePrompt(.send))
        XCTAssertEqual(restored.draft, "Test")
        XCTAssertEqual(restored.attachments.items.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        restored.suspend()
    }

    func testFailedSecondUploadKeepsEntireDraftAndDoesNotSubmit() async {
        let copies = BotAttachmentCopies(); let wire = BotFixtureWire()
        let model = make(wire, drafts: store(), copies: copies); await model.recover()
        await model.attachments.stage(data: photo, filename: "image.jpg")
        await model.attachments.stage(data: Data("text".utf8), filename: "note.txt")
        wire.imageUpload = { _, _, _ in "/images/photo.jpg" }
        wire.attachFile = { _ in throw BotFailure.rejected(-32601) }
        model.editDraft("Keep both")
        await model.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertFalse(model.uncertainSend)
        XCTAssertEqual(model.attachments.items.count, 2); XCTAssertEqual(model.draft, "Keep both")
        model.suspend()
    }

    func testUnknownPromptOutcomeRestoresCopiesAcrossRelaunch() async throws {
        let copies = BotAttachmentCopies(); let persistence = BotMemoryDrafts(); let drafts = store(persistence)
        let wire = BotFixtureWire(); let id = UUID()
        let model = make(wire, connectionID: id, drafts: drafts, copies: copies); await model.recover()
        await model.attachments.stage(data: photo, filename: "image.jpg")
        wire.imageUpload = { _, _, _ in "/images/photo.jpg" }
        wire.submitFailure = .transport
        await model.send(); model.suspend()
        let restored = make(BotFixtureWire(), connectionID: id, drafts: store(persistence), copies: copies)
        await restored.recover()
        XCTAssertFalse(restored.uncertainSend); XCTAssertNotNil(restored.preparePrompt(.send))
        XCTAssertEqual(restored.attachments.items.count, 1)
        let count = await copies.count; XCTAssertEqual(count, 1)
        restored.suspend()
    }

    func testAutomaticDraftRecoveryPreservesAttachmentsAndDoesNotResend() async throws {
        let copies = BotAttachmentCopies(); let persistence = BotMemoryDrafts()
        let wire = BotFixtureWire(); let id = UUID()
        let model = make(wire, connectionID: id, drafts: store(persistence), copies: copies)
        await model.recover(); model.editDraft("Test")
        await model.attachments.stage(data: photo, filename: "image.jpg")
        wire.imageUpload = { _, _, _ in "/images/photo.jpg" }
        wire.submitFailure = .transport
        await model.send(); model.suspend()
        let restoredWire = BotFixtureWire()
        let restored = make(restoredWire, connectionID: id, drafts: store(persistence), copies: copies)
        await restored.recover()
        XCTAssertFalse(restored.uncertainSend)
        XCTAssertNotNil(restored.preparePrompt(.send))
        XCTAssertEqual(restored.draft, "Test")
        XCTAssertEqual(restored.attachments.items.count, 1)
        XCTAssertFalse(restoredWire.calls.contains { $0.0 == "prompt.submit" })
        restored.suspend()
        let reopened = make(BotFixtureWire(), connectionID: id, drafts: store(persistence), copies: copies)
        await reopened.recover()
        XCTAssertNotNil(reopened.preparePrompt(.send))
        XCTAssertEqual(reopened.attachments.items.count, 1)
        reopened.suspend()
    }

    func testOversizeUnsupportedAndEmptyImportsNeverCreateCopies() async {
        let copies = BotAttachmentCopies(); let model = make(BotFixtureWire(), drafts: store(), copies: copies)
        await model.recover()
        for (data, name) in [(Data(), "empty.txt"), (Data([1]), "program.exe"),
                              (Data(repeating: 0, count: BotAttachmentDraft.maximumFileBytes + 1), "large.txt")] {
            await model.attachments.stage(data: data, filename: name)
            XCTAssertTrue(model.attachments.items.isEmpty); XCTAssertNotNil(model.attachments.errorMessage)
        }
        let count = await copies.count; XCTAssertEqual(count, 0)
        model.suspend()
    }

    func testCancelledProviderDoesNotRestoreAnAttachmentAfterNavigation() async {
        let copies = BotAttachmentCopies(); let model = make(BotFixtureWire(), drafts: store(), copies: copies)
        await model.recover()
        await model.attachments.importValue {
            model.suspend()
            return (Data("late".utf8), "late.txt")
        }
        XCTAssertTrue(model.attachments.items.isEmpty)
        let count = await copies.count; XCTAssertEqual(count, 0)
    }
}

actor BotAttachmentCopies: ChatDraftAttachmentStoring {
    private var values: [String: Data] = [:]
    var count: Int { values.count }
    func save(data: Data, suggestedFilename: String) -> String {
        let name = UUID().uuidString + "-" + suggestedFilename; values[name] = data; return name
    }
    func data(named fileName: String) throws -> Data {
        guard let data = values[fileName] else { throw BotAttachmentFailure.unreadable }; return data
    }
    func delete(named fileName: String) { values[fileName] = nil }
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) {}
}

extension BotAttachmentSendingTests {
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
        let path = try await BotAttachmentUpload.image(
            session: session, base: URL(string: "https://bot.example")!,
            data: transparentPhoto, filename: "overlay.png", profile: "inbox-triage"
        )
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
        let path = try await BotAttachmentUpload.image(session: session, base: URL(string: "https://bot.example")!,
                                                      data: photo, filename: "photo.jpg", profile: "inbox-triage")
        XCTAssertEqual(path, "/profile/images/photo.jpg")
        for body in [#"{"path":"/images/photo.jpg"}"#, #"{"ok":true,"path":"https://other.example/photo.jpg"}"#] {
            BotArtifactHTTPFixture.handler = { _ in (200, [:], Data(body.utf8)) }
            do {
                _ = try await BotAttachmentUpload.image(session: session, base: URL(string: "https://bot.example")!,
                                                       data: photo, filename: "photo.jpg", profile: "inbox-triage")
                XCTFail("Missing or invalid acknowledgment accepted")
            } catch { XCTAssertEqual(error as? BotFailure, .unsupported) }
        }
    }

    func testQueuedUploadFailureDoesNotRejectQueueModeOrRefreshTheTurn() async throws {
        for cancelled in [false, true] {
            let wire = BotFixtureWire(); wire.running = true
            let model = make(wire, drafts: store(), copies: BotAttachmentCopies())
            await model.recover()
            await model.attachments.stage(data: photo, filename: "image.jpg")
            let reads = wire.calls.filter { $0.0 == "session.resume" }.count
            wire.imageUpload = { _, _, _ in
                if cancelled {
                    model.cancelAttachmentUpload()
                    try Task.checkCancellation()
                }
                throw BotFailure.rejected(-32601)
            }
            await model.submit(try XCTUnwrap(model.preparePrompt(.queue)))
            XCTAssertEqual(model.errorMessage, cancelled
                ? "Upload cancelled. Your message and attachments are still here."
                : BotFailure.rejected(-32601).localizedDescription)
            XCTAssertFalse(model.uncertainSend)
            XCTAssertTrue(model.maySubmit(.queue))
            XCTAssertEqual(model.attachments.items.count, 1)
            XCTAssertEqual(wire.calls.filter { $0.0 == "session.resume" }.count, reads)
            XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
            model.suspend()
        }
    }

    func testCancelUploadStopsBeforePromptAndReleasesLocalDraft() async {
        let wire = BotFixtureWire(); let model = make(wire, drafts: store(), copies: BotAttachmentCopies())
        await model.recover(); await model.attachments.stage(data: photo, filename: "image.jpg")
        wire.imageUpload = { _, _, _ in
            model.cancelAttachmentUpload()
            try Task.checkCancellation()
            return "/images/never-used.jpg"
        }
        await model.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertFalse(model.uncertainSend); XCTAssertFalse(model.isUploadingAttachments)
        XCTAssertTrue(model.maySend); XCTAssertEqual(model.attachments.items.count, 1)
        model.suspend()
    }
}
