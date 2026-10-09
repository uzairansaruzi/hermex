import XCTest
import UIKit
@testable import HermesMobile

/// Photos and files in a Hermes session's main chat (#1012): staged as local copies, then
/// uploaded by Send or Queue through the Bot path (image-upload plus the vision-tool line,
/// `file.attach` for documents), over #901's socket-level host and an HTTP fixture.
@MainActor final class HermesChatAttachmentTests: XCTestCase {
    // MARK: Sending

    /// Staging uploads nothing. Send stores the image, then submits the typed text with
    /// Hermes's vision-tool instruction line; the bubble shows the text and a chip.
    func testSendUploadsTheImageAndSubmitsItsInstructionLine() async throws {
        let chat = await openChat()
        var upload: (query: String?, body: [String: String]?)?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/chat/image-upload" else { return nil }
            upload = (request.url?.query, apiTestBodyData(from: request).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: String]
            })
            return .json(200, .object(["ok": .bool(true), "path": .string(Self.storedImage),
                                       "name": .string("dashboard_20261004_031500_ab12cd34_photo.jpg"),
                                       "bytes": .number(4), "mime_type": .string("image/jpeg")]))
        }
        await chat.model.uploadAttachment(data: photo, filename: "photo.jpg", previewData: photo)
        let staged = try XCTUnwrap(chat.model.pendingAttachments.first)
        XCTAssertEqual(staged.name, "photo.jpg")
        XCTAssertNil(upload, "staging keeps a local copy only")

        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        let sent = await chat.model.sendMessage("What is this?")
        XCTAssertTrue(sent)
        XCTAssertEqual(upload?.query, "profile=default")
        XCTAssertEqual(upload?.body?["filename"], "photo.jpg")
        XCTAssertTrue(upload?.body?["data_url"]?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string(
            "What is this?\n\n[The user attached an image: dashboard_20261004_031500_ab12cd34_photo.jpg]\n"
                + "[Examine it with the vision_analyze tool using image_url: \(Self.storedImage)]"
        )])
        let row = try XCTUnwrap(chat.model.messages.last)
        XCTAssertEqual(row.content, "What is this?")
        XCTAssertEqual(row.attachments, [MessageAttachment(name: "photo.jpg", mime: "image/jpeg", size: staged.size, isImage: true)])
        XCTAssertEqual(chat.model.pendingAttachments, [])
        let copies = await chat.copies.count
        XCTAssertEqual(copies, 0, "the accepted send deletes the local copy")
    }

    /// A document goes through `file.attach` on the attached runtime, and its `ref_text`
    /// goes into the prompt exactly as the host wrote it.
    func testFileAttachRefTextGoesIntoThePromptVerbatim() async throws {
        let chat = await openChat()
        let ref = "@file:`/home/u/.hermes/attachments/\(Self.uuid)-Q3 report.pdf`"
        chat.host.always("file.attach", .init(result: .object([
            "attached": .bool(true), "name": .string("\(Self.uuid)-Q3 report.pdf"),
            "path": .string("/home/u/.hermes/attachments/\(Self.uuid)-Q3 report.pdf"),
            "ref_text": .string(ref), "uploaded": .bool(true)
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        await chat.model.uploadAttachment(data: Data("%PDF-1.4 test".utf8), filename: "Q3 report.pdf")
        XCTAssertEqual(chat.writes("file.attach"), [], "staging keeps a local copy only")

        let sent = await chat.model.sendMessage("Summarize it")
        XCTAssertTrue(sent)
        let attach = try XCTUnwrap(chat.writes("file.attach").first)
        XCTAssertEqual(attach["session_id"], .string("runtime"))
        XCTAssertTrue(attach["name"]?.text?.hasSuffix("-Q3 report.pdf") == true)
        XCTAssertTrue(attach["data_url"]?.text?.hasPrefix("data:application/pdf;base64,") == true)
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("Summarize it\n\n" + ref)])
        XCTAssertEqual(chat.model.messages.last?.attachments?.map(\.name), ["Q3 report.pdf"])
    }

    /// One failed upload of two: nothing is submitted, and the text and both files stay.
    func testAFailedUploadSubmitsNothingAndKeepsTheDraft() async {
        let chat = await openChat()
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/chat/image-upload"
                ? .json(200, .object(["ok": .bool(true), "path": .string(Self.storedImage)])) : nil
        }
        chat.host.always("file.attach", .init(error: 5028))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        await chat.model.uploadAttachment(data: photo, filename: "photo.jpg", previewData: photo)
        await chat.model.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")

        let sent = await chat.model.sendMessage("Compare these")
        XCTAssertFalse(sent, "false keeps the draft in the composer")
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        XCTAssertEqual(chat.model.pendingAttachments.map(\.name), ["photo.jpg", "notes.txt"])
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.model.sendErrorMessage,
                       "Couldn't upload the attachments. Your message and attachments are still here.")
        let copies = await chat.copies.count
        XCTAssertEqual(copies, 2)
    }

    /// Cancel during an upload: nothing is submitted, and the text and file stay.
    func testCancellingTheUploadSubmitsNothingAndKeepsTheDraft() async {
        let chat = await openChat()
        _ = HermesHostFixture.configuration { request in request.url?.path == "/api/chat/image-upload" ? .park : nil }
        HermesHostFixture.onPark = { Task { @MainActor in chat.model.cancelAttachmentUpload() } }
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        await chat.model.uploadAttachment(data: photo, filename: "photo.jpg", previewData: photo)

        let sent = await chat.model.sendMessage("Look")
        XCTAssertFalse(sent)
        XCTAssertFalse(chat.model.isSendingAttachments)
        XCTAssertEqual(chat.writes("prompt.submit"), [])
        XCTAssertEqual(chat.model.pendingAttachments.map(\.name), ["photo.jpg"])
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertEqual(chat.model.sendErrorMessage, "Upload cancelled. Your message and attachments are still here.")
    }

    /// #508: a lost answer to the prompt keeps the text and files, marks the submission
    /// unresolved on disk, and holds Send while the chat reattaches; nothing is sent again.
    /// The reattach releases the hold and the mark and leaves the draft. A draft reopened
    /// with the mark holds Send the same way until the chat attaches.
    func testALostAcknowledgmentHoldsSendUntilTheReattachAndNeverResends() async throws {
        let chat = await openChat()
        chat.host.always("file.attach", .init(result: .object([
            "attached": .bool(true), "path": .string("/home/u/.hermes/attachments/a-notes.txt"),
            "ref_text": .string("@file:/home/u/.hermes/attachments/a-notes.txt")
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("something new")])))
        await chat.model.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        let key = try XCTUnwrap(chat.model.hermesDraftKey)
        chat.drafts.setDraft("Read this", for: key)

        let sent = await chat.model.sendMessage("Read this")
        XCTAssertFalse(sent)
        XCTAssertTrue(chat.model.isHermesSubmissionUncertain)
        let again = await chat.model.sendMessage("Read this")
        XCTAssertFalse(again, "Send waits for the reattach")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
        XCTAssertEqual(chat.writes("file.attach").count, 1)
        XCTAssertEqual(chat.model.pendingAttachments.map(\.name), ["notes.txt"])
        let copies = await chat.copies.count
        XCTAssertEqual(copies, 1)
        let marked = await chat.drafts.draft(for: key)
        XCTAssertEqual(marked?.botSubmissionUncertain, true)
        XCTAssertEqual(marked?.text, "Read this")

        // Joins the reattach the lost answer started.
        await chat.turn.activate()
        await chat.model.submissionMarkRelease?.value
        XCTAssertFalse(chat.model.isHermesSubmissionUncertain)
        let released = await chat.drafts.draft(for: key)
        XCTAssertEqual(released?.botSubmissionUncertain, false)
        XCTAssertEqual(released?.text, "Read this")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1, "reattaching only reads")

        chat.model.suspendStreamForNavigation()
        chat.model.restoreSubmissionMark(true)
        XCTAssertTrue(chat.model.isHermesSubmissionUncertain, "a reopened mark holds Send")
        await chat.model.reconnectStreamIfNeeded()
        XCTAssertFalse(chat.model.isHermesSubmissionUncertain)
    }

    /// Queue carries the files too; when the host runs the queued prompt, its row shows them
    /// as chips.
    func testAQueuedPromptWithFilesShowsChipsWhenItsTurnStarts() async throws {
        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("file.attach", .init(result: .object([
            "attached": .bool(true), "path": .string("/home/u/.hermes/attachments/\(Self.uuid)-notes.txt"),
            "ref_text": .string("@file:/home/u/.hermes/attachments/\(Self.uuid)-notes.txt")
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        await chat.model.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")

        let result = await chat.model.submitStreamingMessage("Then this", behavior: .queue)
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.model.pendingAttachments, [])
        chat.receive(event(2, "message.complete", ["status": .string("complete")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        chat.receive(event(4, "message.start"))
        let row = try XCTUnwrap(chat.model.messages.last)
        XCTAssertEqual(row.content, "Then this")
        XCTAssertEqual(row.attachments?.map(\.name), ["notes.txt"])
    }

    // MARK: Steer and limits

    /// Steer and Stop and send never carry files. With files staged on a Hermes session,
    /// Steer drops out of the send button and a Steer default queues them; Stop and send
    /// stays, goes text-only and leaves them staged.
    func testStagedFilesDropSteerAndStopAndSendLeavesThemStaged() async {
        let steer = ChatComposerSendButton(isWaitingForStream: true, hasText: true, hasQuotes: false,
                                           defaultBehavior: .steer, stagedFilesDropSteer: true)
        XCTAssertEqual(steer.choices, [.queue, .interrupt])
        XCTAssertEqual(steer.runningBehavior, .queue)
        let interrupt = ChatComposerSendButton(isWaitingForStream: true, hasText: true, hasQuotes: false,
                                               defaultBehavior: .interrupt, stagedFilesDropSteer: true)
        XCTAssertEqual(interrupt.runningBehavior, .interrupt)
        let webui = ChatComposerSendButton(isWaitingForStream: true, hasText: true, hasQuotes: false, defaultBehavior: .steer)
        XCTAssertEqual(webui.choices, [.steer, .queue, .interrupt], "webui steers carry their files (#856)")

        let chat = await openChat()
        chat.receive(event(1, "message.start"))
        chat.host.always("file.attach", .init(result: .object([
            "attached": .bool(true), "path": .string("/a/notes.txt"), "ref_text": .string("@file:/a/notes.txt")
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        chat.host.always("session.redirect", .init(result: .object(["status": .string("redirected")])))
        await chat.model.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        _ = await chat.model.submitStreamingMessage("Use these", behavior: .steer)
        XCTAssertEqual(chat.writes("session.steer"), [])
        XCTAssertEqual(chat.writes("prompt.submit").map { $0["text"] }, [.string("Use these\n\n@file:/a/notes.txt")])

        await chat.model.uploadAttachment(data: Data("more".utf8), filename: "more.txt")
        let result = await chat.model.submitStreamingMessage("Stop and look", behavior: .interrupt)
        XCTAssertEqual(result, .executed(message: nil))
        XCTAssertEqual(chat.writes("session.redirect").map { $0["text"] }, [.string("Stop and look")])
        XCTAssertEqual(chat.writes("file.attach").count, 1, "Stop and send uploads nothing")
        XCTAssertEqual(chat.model.pendingAttachments.map(\.name), ["more.txt"])
    }

    /// A Hermes send clears a staging error, so the status line shows its upload and Cancel.
    func testASendClearsAStaleStagingError() async {
        let chat = await openChat()
        _ = HermesHostFixture.configuration { request in request.url?.path == "/api/chat/image-upload" ? .park : nil }
        HermesHostFixture.onPark = { Task { @MainActor in
            XCTAssertNil(chat.model.uploadAttachmentErrorMessage)
            XCTAssertTrue(chat.model.isSendingAttachments)
            chat.model.cancelAttachmentUpload()
        } }
        await chat.model.uploadAttachment(data: photo, filename: "photo.jpg", previewData: photo)
        await chat.model.uploadAttachment(data: Data(), filename: "empty.txt")
        XCTAssertEqual(chat.model.uploadAttachmentErrorMessage, "Use up to 8 attachments, 25 MB each and 50 MB total.")

        let sent = await chat.model.sendMessage("Look")
        XCTAssertFalse(sent)
        XCTAssertEqual(chat.model.sendErrorMessage, "Upload cancelled. Your message and attachments are still here.")
    }

    /// Bot Chat's limits: eight files. The ninth is refused with the Bot message.
    func testStagingStopsAtEightFiles() async {
        let chat = await openChat()
        for index in 1...9 {
            await chat.model.uploadAttachment(data: Data("note \(index)".utf8), filename: "note\(index).txt")
        }
        XCTAssertEqual(chat.model.pendingAttachments.count, 8)
        XCTAssertEqual(chat.model.uploadAttachmentErrorMessage, "Use up to 8 attachments, 25 MB each and 50 MB total.")
    }

    /// Imports that stage at once share the 50 MB total: of three 20 MB files, one is refused.
    func testOverlappingImportsShareTheTotalLimit() async {
        let chat = await openChat()
        let file = Data(repeating: 0x61, count: 20 * 1024 * 1024)
        let imports = ["a.txt", "b.txt", "c.txt"].map { name in
            Task { await chat.model.uploadAttachment(data: file, filename: name) }
        }
        var staged = 0
        for task in imports { if await task.value != nil { staged += 1 } }
        XCTAssertEqual(staged, 2)
        XCTAssertEqual(chat.model.pendingAttachments.count, 2)
        XCTAssertEqual(chat.model.uploadAttachmentErrorMessage, "Use up to 8 attachments, 25 MB each and 50 MB total.")
    }

    // MARK: Transcript

    /// The rule keeps text without references as it is, and reads references only as whole
    /// blocks, wherever they are, in each of `file.attach`'s quotings.
    func testTheHermesReferenceRuleReadsOnlyWholeReferenceBlocks() {
        let typed = "See @file:src/app.swift line 3\n\n--- not a footer"
        XCTAssertEqual(MessageAttachment.hermesReferences(in: typed).text, typed)
        XCTAssertEqual(MessageAttachment.hermesReferences(in: typed).attachments, [])

        let merged = "First\n\n@file:'/h/a b.md'\n\nSecond\n\n@file:`/h/\(Self.uuid)-c (1).csv`"
        let shown = MessageAttachment.hermesReferences(in: merged)
        XCTAssertEqual(shown.text, "First\n\nSecond")
        XCTAssertEqual(shown.attachments.map(\.name), ["a b.md", "c (1).csv"])

        let expanded = "Only files\n\n@file:\"/h/x y.txt\"\n\n--- Attached Context ---\n\n📄 @file:\"/h/x y.txt\"\nsecret text"
        XCTAssertEqual(MessageAttachment.hermesReferences(in: expanded).text, "Only files")
        XCTAssertEqual(MessageAttachment.hermesReferences(in: expanded).attachments.map(\.name), ["x y.txt"])

        let warned = "Read @folder:src\n\n--- Context Warnings ---\n- @folder:src: path is outside the allowed workspace"
        XCTAssertEqual(MessageAttachment.hermesReferences(in: warned).text, "Read @folder:src", "a footer with no @file: goes too")
    }

    /// After a rebuild the user row shows the typed text and one chip per reference: the
    /// image pair, a plain and a quoted `@file:` token. The host's context footer and every
    /// host path are gone from the text, each chip keeps its path for the download (#1030)
    /// under its display name, and ↑ recalls only the typed text. The saved row is the
    /// shape `scripts/local-hermes` stored at the pin for such a prompt, its paths shortened.
    func testTheTranscriptShowsChipsAndNoHostPathsAfterARebuild() async throws {
        let quoted = "@file:`/home/u/.hermes/attachments/\(Self.uuid)-Q3 report.pdf`"
        let stored = "Compare these\n\n"
            + "[The user attached an image: dashboard_20261004_031500_ab12cd34_photo.jpg]\n"
            + "[Examine it with the vision_analyze tool using image_url: \(Self.storedImage)]\n\n"
            + "@file:/home/u/.hermes/attachments/\(Self.uuid)-notes.txt\n\n"
            + quoted + "\n\n"
            + "--- Context Warnings ---\n- \(quoted): path is outside the allowed workspace"
        let chat = await openChat(history: [
            .object(["id": .number(1), "role": .string("user"), "content": .string(stored), "timestamp": .number(1_790_000_000)]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string("Both look fine."),
                     "timestamp": .number(1_790_000_010)])
        ])
        let row = try XCTUnwrap(chat.model.messages.first)
        XCTAssertEqual(row.content, "Compare these")
        XCTAssertEqual(row.attachments?.map(\.name), ["photo.jpg", "notes.txt", "Q3 report.pdf"])
        XCTAssertEqual(row.attachments?.map(\.isImage), [true, false, false])
        XCTAssertEqual(row.attachments?.map(\.path), [Self.storedImage,
                                                      "/home/u/.hermes/attachments/\(Self.uuid)-notes.txt",
                                                      "/home/u/.hermes/attachments/\(Self.uuid)-Q3 report.pdf"])
        XCTAssertFalse(chat.model.messages.contains { $0.content?.contains("/home/u") == true })
        XCTAssertEqual(chat.model.lastSentText, "Compare these")
    }

    /// A staged photo has no server path and the chat no webui session: its preview shows
    /// the local copy instead of asking for a session.
    func testAPathlessPreviewShowsTheLocalCopy() async throws {
        let chat = await openChat()
        await chat.model.uploadAttachment(data: photo, filename: "photo.jpg", previewData: photo)
        let staged = try XCTUnwrap(chat.model.pendingAttachments.first)
        let preview = ChatAttachmentPreviewViewModel(session: SessionSummary(profile: "default"),
                                                     server: URL(string: "https://hermes.example")!,
                                                     item: ChatAttachmentPreviewItem(pending: staged))
        await preview.load()
        guard case .image(let image)? = preview.preview else {
            return XCTFail("Expected the local image, got \(String(describing: preview.preview)) \(preview.errorMessage ?? "")")
        }
        XCTAssertEqual(image.data, staged.thumbnailData)
        XCTAssertNil(preview.errorMessage)
    }

    // MARK: Downloading (#1030)

    /// A chip's thumbnail downloads from the host by its path, under the session's
    /// Profile and stored key, so the host resolves it against the session.
    func testAThumbnailDownloadsThroughTheSessionsProfileAndStoredKey() async throws {
        let chat = await openChat()
        var query: [URLQueryItem]?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/fs/download" else { return nil }
            query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            return .json(200, .string("bytes"))
        }
        let data = await chat.model.attachmentImageData(path: Self.storedImage)
        XCTAssertNotNil(data)
        XCTAssertEqual(query, [URLQueryItem(name: "path", value: Self.storedImage),
                               URLQueryItem(name: "profile", value: "default"),
                               URLQueryItem(name: "session_id", value: "tip")])
    }

    /// A download still in flight when the chat reattaches is dropped, not shown.
    func testADownloadThatOutlivesItsAttachIsDropped() async throws {
        let chat = await openChat()
        _ = HermesHostFixture.configuration { request in request.url?.path == "/api/fs/download" ? .park : nil }
        let attempt = chat.turn.engine.generation
        HermesHostFixture.onPark = {
            Task { @MainActor in
                chat.turn.recoverAfterLostAnswer()
                HermesHostFixture.releaseParked(.json(200, .string("bytes")))
            }
        }
        do {
            _ = try await chat.model.hermesAttachmentData(path: Self.storedImage)
            XCTFail("a result from an older attach is dropped")
        } catch {}
        XCTAssertNotEqual(chat.turn.engine.generation, attempt)
    }

    /// Thumbnails are cached per connection and Profile: neither shows the other's.
    func testTheThumbnailNamespaceSeparatesConnectionsAndProfiles() {
        let other = BotConnection(id: UUID(), name: "Mac", address: Self.connection.address,
                                  username: "user", password: "fixture")
        func namespace(_ connection: BotConnection, _ profile: String) -> String {
            let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: connection,
                                            target: .session(profile: profile, key: "tip"),
                                            wire: BotClient(http: BotSocketHost().connection(connection)))
            return HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true }).attachmentCacheNamespace
        }
        let base = namespace(Self.connection, "default")
        XCTAssertEqual(base, namespace(Self.connection, "default"))
        XCTAssertNotEqual(base, namespace(other, "default"))
        XCTAssertNotEqual(base, namespace(Self.connection, "work"))
    }

    // MARK: Workspace (#1112)

    /// The chat's workspace is its Profile, stored key, and the folder and terminal backend
    /// `session.info` names; a later report moving the folder moves it, and its files download
    /// on the chat's connection by their relative path. Before any report names a folder there is none.
    func testTheWorkspaceFollowsSessionInfoAndReadsOnTheChatsConnection() async throws {
        let chat = await openChat()
        XCTAssertNil(chat.model.hermesWorkspace, "no session.info has named a folder")

        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        XCTAssertEqual(chat.model.hermesWorkspace, HermesWorkspaceContext(
            server: URL(string: "https://hermes.example")!, profile: "default", storedKey: "tip",
            cwd: "/work/app", terminalBackend: "local"))

        chat.receive(event(2, "session.info", ["cwd": .string("/work/moved"), "terminal_backend": .string("docker")]))
        XCTAssertEqual(chat.model.hermesWorkspace?.cwd, "/work/moved")
        XCTAssertEqual(chat.model.hermesWorkspace?.isLocal, false)

        var query: [URLQueryItem]?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/fs/download" else { return nil }
            query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            return .json(200, .string("bytes"))
        }
        _ = try await XCTUnwrap(chat.model.hermesWorkspaceFiles).rawFileData(path: "out/report.pdf")
        XCTAssertEqual(query, [URLQueryItem(name: "path", value: "out/report.pdf"),
                               URLQueryItem(name: "profile", value: "default"),
                               URLQueryItem(name: "session_id", value: "tip")])
    }

    /// The chat owns its repository's Git writes (#1115): none goes out while a turn runs, and a
    /// client made for a folder the chat has since left writes nothing at all.
    func testGitWritesWaitForTheTurnAndStopAtAFolderMove() async throws {
        let chat = await openChat()
        chat.receive(event(1, "session.info", ["cwd": .string("/work/app"), "terminal_backend": .string("local")]))
        let git = try XCTUnwrap(chat.model.hermesWorkspaceGit)
        _ = HermesHostFixture.configuration { HermesGitHost.repositoryReply($0, root: "/work/app") }
        var refusals: [String] = []

        chat.receive(event(2, "message.start"))
        do { _ = try await git.push() } catch { refusals.append(error.localizedDescription) }
        chat.receive(event(3, "message.complete", ["status": .string("complete")]))
        chat.receive(event(4, "session.info", ["cwd": .string("/work/moved"), "terminal_backend": .string("local")]))
        do { _ = try await git.push() } catch { refusals.append(error.localizedDescription) }

        XCTAssertEqual(refusals, [String(localized: "Wait for the active response to finish before changing this repository."),
                                  BotFailure.stale.localizedDescription])
        XCTAssertEqual(HermesHostFixture.requests.filter { $0.url?.path.hasPrefix("/api/git/") == true }, [])
    }

    /// A MEDIA reference's inline audio, video or file in a reply downloads from the host by
    /// the path the reply wrote, under the session's Profile and stored key, so the host
    /// resolves it against the session; webui's `/api/media` is never asked.
    func testInlineTranscriptMediaDownloadsFromTheHost() async throws {
        let chat = await openChat()
        var query: [URLQueryItem]?
        _ = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/fs/download" else { return nil }
            query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            return .json(200, .string("audio"))
        }

        let data = await chat.model.transcriptMediaData(for: TranscriptMediaReference(rawReference: "/tmp/report.wav"))

        XCTAssertEqual(data, Data(#""audio""#.utf8))
        XCTAssertEqual(query, [URLQueryItem(name: "path", value: "/tmp/report.wav"),
                               URLQueryItem(name: "profile", value: "default"),
                               URLQueryItem(name: "session_id", value: "tip")])
        XCTAssertFalse(HermesHostFixture.requests.contains { $0.url?.path == "/api/media" })
    }

    /// A MEDIA file's export downloads all of it, past the 25 MB that stops a MEDIA image's
    /// thumbnail, on the same session's Profile and stored key.
    func testInlineTranscriptMediaFileExportHasNoPreviewCap() async throws {
        let chat = await openChat()
        let large = String(repeating: "a", count: BotArtifactBuffer.maximumBytes)
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/fs/download" ? .json(200, .string(large)) : nil
        }

        let export = await chat.model.transcriptMediaData(for: TranscriptMediaReference(rawReference: "/tmp/archive.zip"))
        let thumbnail = await chat.model.transcriptMediaThumbnailData(for: TranscriptMediaReference(rawReference: "/tmp/huge.png"))

        XCTAssertEqual(export?.count, BotArtifactBuffer.maximumBytes + 2)
        XCTAssertNil(thumbnail)
        let downloads = HermesHostFixture.requests.filter { $0.url?.path == "/api/fs/download" }
        XCTAssertEqual(downloads.first.flatMap { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } },
                       [URLQueryItem(name: "path", value: "/tmp/archive.zip"), URLQueryItem(name: "profile", value: "default"),
                        URLQueryItem(name: "session_id", value: "tip")])
        XCTAssertEqual(downloads.count, 2)
    }

    // MARK: Fixture

    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let uuid = "0F6A3C1E-8D2B-4F7A-9C3D-5E6F7A8B9C0D"
    private static let storedImage = "/home/u/.hermes/images/dashboard_20261004_031500_ab12cd34_photo.jpg"

    private var photo: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// A Hermes chat attached to an idle session whose saved transcript is `history`, the rows
    /// of its transcript page (#1047).
    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let drafts: ChatDraftStore
        let copies: BotAttachmentCopies
        let client: BotClient

        /// One of the runtime's event frames.
        @MainActor func receive(_ frame: BotJSON) { client.onEvent?(frame) }

        /// The params of every `method` call the chat sent.
        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    private func openChat(history: [BotJSON] = []) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let copies = BotAttachmentCopies()
        let drafts = ChatDraftStore(persistence: BotMemoryDrafts(), attachmentStore: copies, debounceDuration: .seconds(60))
        let client = BotClient(http: host.connection(Self.connection))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/sessions/tip/messages" ? .json(200, .object(["messages": .array(history)])) : nil
        }
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftAttachmentStore: copies, draftStore: drafts, backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn, host: host, drafts: drafts, copies: copies, client: client)
    }
}
