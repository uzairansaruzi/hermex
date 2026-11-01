import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class ChatAttachmentCoordinatorTests: APIClientTestCase {
    private var delegateSpies: [ChatAttachmentCoordinatorDelegateSpy] = []

    override func tearDown() {
        DeferredUploadMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testEleventhAttachmentIsRefusedBeforeSavingOrUploading() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            return apiTestJSONResponse(#"{"path":"/uploads/file","mime":"text/plain"}"#, for: request)
        }
        let store = RecordingAttachmentStore()
        let coordinator = makeCoordinator(client: client, attachmentStore: store)
        for index in 0..<10 {
            let result = await coordinator.uploadAttachment(data: Data([1]), filename: "file-\(index).txt")
            XCTAssertEqual(result?.name, "file-\(index).txt")
        }
        let before = coordinator.pendingAttachments
        let refused = await coordinator.uploadAttachment(data: Data([2]), filename: "eleventh.txt")
        XCTAssertNil(refused, "The eleventh attachment must be refused without replacing an active attachment")
        XCTAssertEqual(coordinator.pendingAttachments, before)
        XCTAssertEqual(requests, 10, "Refusal must happen before network upload")
        let saves = await store.savedNames()
        XCTAssertEqual(saves.count, 10, "Refusal must happen before durable staging")
    }

    func testUploadSuccessAddsPendingAttachmentAndPreparesLocalPreview() async throws {
        let imageData = try XCTUnwrap(Self.imageData())
        var uploadedFilename: String?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadedFilename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "photo.png",
                  "path": "/tmp/workspace/photo.png",
                  "size": \(imageData.count),
                  "mime": "image/png",
                  "is_image": true
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        await coordinator.uploadAttachment(data: imageData, filename: "/tmp/photo.png", previewData: imageData)

        XCTAssertEqual(uploadedFilename, "photo.png")
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertFalse(coordinator.isUploadingAttachment)
        let attachment = try XCTUnwrap(coordinator.pendingAttachments.first)
        XCTAssertEqual(attachment.name, "photo.png")
        XCTAssertEqual(attachment.path, "/tmp/workspace/photo.png")
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.size, imageData.count)
        XCTAssertTrue(attachment.isImage)
        XCTAssertNotNil(attachment.thumbnailData)

        let preparation = coordinator.prepareForSend(localMessageID: "local-message")

        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertEqual(preparation.attachments.count, 1)
        XCTAssertEqual(preparation.messageAttachments.first?.path, "/tmp/workspace/photo.png")
        XCTAssertEqual(preparation.apiPayloads?.count, 1)
        XCTAssertNotNil(coordinator.localAttachmentPreviews["local-message"]?["/tmp/workspace/photo.png"])
    }

    func testUploadFailurePreservesExistingPendingAttachment() async throws {
        var uploadCount = 0
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/upload")
            uploadCount += 1

            if uploadCount == 1 {
                return apiTestJSONResponse(
                    """
                    {
                      "filename": "notes.txt",
                      "path": "/tmp/workspace/notes.txt",
                      "size": 5,
                      "mime": "text/plain",
                      "is_image": false
                    }
                    """,
                    for: request
                )
            }

            return apiTestJSONResponse(#"{"error":"Upload failed."}"#, for: request)
        }
        let coordinator = makeCoordinator(client: client)

        await coordinator.uploadAttachment(data: Data("notes".utf8), filename: "notes.txt")
        await coordinator.uploadAttachment(data: Data("large".utf8), filename: "large.bin")

        XCTAssertEqual(uploadCount, 2)
        XCTAssertEqual(coordinator.pendingAttachments.count, 1)
        XCTAssertEqual(coordinator.pendingAttachments.first?.name, "notes.txt")
        XCTAssertEqual(coordinator.uploadAttachmentErrorMessage, "Upload failed.")
    }

    func testDraftCopyFailureStopsBeforeNetworkUpload() async {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse(#"{"error":"unexpected upload"}"#, for: request)
        }
        let store = RecordingAttachmentStore(saveError: CocoaError(.fileWriteOutOfSpace))
        let coordinator = makeCoordinator(client: client, attachmentStore: store)

        let uploaded = await coordinator.uploadAttachment(
            data: Data("notes".utf8),
            filename: "notes.txt"
        )

        XCTAssertNil(uploaded)
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertEqual(
            coordinator.uploadAttachmentErrorMessage,
            "Could not save the attachment on this device."
        )
    }

    func testConcurrentUploadsKeepUploadingStateUntilAllUploadsFinish() async throws {
        let firstUploadStarted = expectation(description: "first upload started")
        let uploadState = DeferredUploadState()

        let client = makeDeferredUploadClient { request, protocolClient in
            XCTAssertEqual(request.url?.path, "/api/upload")
            let filename = try Self.multipartFilename(from: request)
            let uploadIndex = uploadState.nextUploadIndex()

            let response = apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 4,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )

            if uploadIndex == 1 {
                uploadState.setFirstUploadCompletion {
                    protocolClient.complete(with: response)
                }
                firstUploadStarted.fulfill()
                return
            }

            protocolClient.complete(with: response)
        }
        let coordinator = makeCoordinator(client: client)

        let firstUpload = Task {
            await coordinator.uploadAttachment(data: Data("one".utf8), filename: "one.txt")
        }
        await fulfillment(of: [firstUploadStarted], timeout: 2)
        XCTAssertTrue(coordinator.isUploadingAttachment)

        let secondUpload = Task {
            await coordinator.uploadAttachment(data: Data("two".utf8), filename: "two.txt")
        }
        await secondUpload.value

        XCTAssertTrue(coordinator.isUploadingAttachment)
        let finishFirst = try XCTUnwrap(
            uploadState.firstUploadCompletion(),
            "Expected the first upload completion to be deferred."
        )
        finishFirst()
        await firstUpload.value

        XCTAssertFalse(coordinator.isUploadingAttachment)
        XCTAssertEqual(coordinator.pendingAttachments.map(\.name).sorted(), ["one.txt", "two.txt"])
    }

    func testTranscriptSameServerRemoteMediaUsesAuthenticatedSession() async throws {
        let mediaData = Data([0x01, 0x02, 0x03])
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/generated/media/image.png?variant=full"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "authenticated")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(thumbnail, mediaData)
    }

    func testTranscriptLocalMediaIncludesSessionIDOnMediaEndpoint() async throws {
        let mediaData = try XCTUnwrap(Self.imageData())
        let mediaPath = "/Users/hermes/.hermes/browser_screenshots/example.png"
        let sessionID = "session-abc"
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/media")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(query["session_id"], sessionID)
            XCTAssertEqual(query["path"], mediaPath)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let thumbnail = await coordinator.transcriptMediaThumbnailData(
            for: TranscriptMediaReference(rawReference: mediaPath)
        )

        XCTAssertNotNil(thumbnail)
    }

    func testTranscriptExternalRemoteVideoUsesPublicMediaSession() async throws {
        let mediaData = Data("video-bytes".utf8)
        let remoteURL = try XCTUnwrap(URL(string: "https://cdn.example.test/generated/movie.mp4"))
        let client = makeAuthenticatedMediaClient { request in
            XCTAssertEqual(request.url, remoteURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Test-Session"), "public")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (response, mediaData)
        }
        let coordinator = makeCoordinator(client: client)

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: remoteURL.absoluteString)
        )

        XCTAssertEqual(data, mediaData)
    }

    func testTranscriptLocalAudioWithoutSessionDoesNotRequestMediaEndpoint() async {
        var requestCount = 0
        let client = makeAuthenticatedMediaClient { request in
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("unexpected".utf8))
        }
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegate.attachmentSessionID = nil
        delegateSpies.append(delegate)
        coordinator.delegate = delegate

        let data = await coordinator.transcriptMediaData(
            for: TranscriptMediaReference(rawReference: "/tmp/generated/clip.mp3")
        )

        XCTAssertNil(data)
        XCTAssertEqual(requestCount, 0)
    }

    func testUploadCarriesDraftFileNameIntoPendingAttachment() async throws {
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let store = RecordingAttachmentStore()
        let coordinator = makeCoordinator(client: client, attachmentStore: store)

        let uploaded = await coordinator.uploadAttachment(
            data: Data("notes".utf8),
            filename: "notes.txt"
        )

        XCTAssertEqual(uploaded?.draftFileName, "saved-1-notes.txt")
        XCTAssertEqual(coordinator.pendingAttachments.first?.draftFileName, "saved-1-notes.txt")
        let savedNames = await store.savedNames()
        XCTAssertEqual(savedNames, ["saved-1-notes.txt"])
    }

    func testStandaloneUploadNeverCarriesADraftFileName() async throws {
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "audio/m4a",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        let uploaded = await coordinator.uploadStandaloneAttachment(
            data: Data("audio".utf8),
            filename: "clip.m4a"
        )

        XCTAssertNil(uploaded?.draftFileName)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
    }

    func testReuploadDraftAttachmentPreservesDraftIdentity() async throws {
        let record = ChatDraftAttachment(
            id: UUID(),
            name: "notes.txt",
            mime: "text/plain",
            size: 5,
            isImage: false,
            file: "abc-notes.txt"
        )
        let client = makeClient { request in
            let filename = try Self.multipartFilename(from: request)
            return apiTestJSONResponse(
                """
                {
                  "filename": "\(filename)",
                  "path": "/tmp/workspace/\(filename)",
                  "size": 5,
                  "mime": "text/plain",
                  "is_image": false
                }
                """,
                for: request
            )
        }
        let coordinator = makeCoordinator(client: client)

        let restored = await coordinator.reuploadDraftAttachment(
            data: Data("notes".utf8),
            draftAttachment: record
        )

        XCTAssertEqual(restored?.id, record.id)
        XCTAssertEqual(restored?.draftFileName, "abc-notes.txt")
        XCTAssertEqual(restored?.path, "/tmp/workspace/notes.txt")
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertEqual(coordinator.pendingAttachments.map(\.id), [record.id])
    }

    func testReuploadDraftAttachmentFailureStaysQuiet() async throws {
        let record = ChatDraftAttachment(
            id: UUID(),
            name: "notes.txt",
            mime: "text/plain",
            size: 5,
            isImage: false,
            file: "abc-notes.txt"
        )
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error":"Upload failed."}"#, for: request)
        }
        let coordinator = ChatAttachmentCoordinator(client: client)
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegateSpies.append(delegate)
        coordinator.delegate = delegate

        let restored = await coordinator.reuploadDraftAttachment(
            data: Data("notes".utf8),
            draftAttachment: record
        )

        // Restore failures must not surface a per-item banner or delegate
        // error; the caller reports in aggregate and keeps the draft record.
        XCTAssertNil(restored)
        XCTAssertTrue(coordinator.pendingAttachments.isEmpty)
        XCTAssertNil(coordinator.uploadAttachmentErrorMessage)
        XCTAssertTrue(delegate.failedErrors.isEmpty)
    }

    func testPerFileExactLimitSucceedsAndOneByteOverDoesNotSaveOrUpload() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            XCTAssertEqual(try Self.multipartFilename(from: request), "exact.bin")
            return apiTestJSONResponse(#"{"path":"/uploads/exact","mime":"application/octet-stream"}"#, for: request)
        }
        let files = RecordingAttachmentStore()
        let coordinator = makeCoordinator(client: client, attachmentStore: files)
        let exact = await coordinator.uploadAttachment(data: Data(repeating: 1, count: 20 * 1024 * 1024), filename: "exact.bin")
        let over = await coordinator.uploadAttachment(data: Data(repeating: 1, count: 20 * 1024 * 1024 + 1), filename: "over.bin")
        XCTAssertEqual(exact?.path, "/uploads/exact")
        XCTAssertNil(over)
        XCTAssertEqual(requests, 1)
        let saved = await files.savedNames()
        XCTAssertEqual(saved, ["saved-1-exact.bin"])
        XCTAssertEqual(coordinator.pendingAttachments.map(\.name), ["exact.bin"])
    }

    func testConcurrentTenthUploadReservesItsSlotBeforeNetworkCompletion() async throws {
        let started = expectation(description: "tenth upload started")
        let state = DeferredUploadState()
        let client = makeDeferredUploadClient { request, protocolClient in
            XCTAssertEqual(try Self.multipartFilename(from: request), "tenth")
            let response = apiTestJSONResponse(#"{"path":"/uploads/tenth","mime":"text/plain"}"#, for: request)
            state.setFirstUploadCompletion { protocolClient.complete(with: response) }
            started.fulfill()
        }
        let files = RecordingAttachmentStore()
        let coordinator = makeCoordinator(client: client, attachmentStore: files)
        coordinator.appendPendingAttachments((0..<9).map { index in
            PendingAttachment(name: "existing-\(index)", path: "/uploads/\(index)", mime: "text/plain", size: nil, isImage: false)
        })
        let tenth = Task { await coordinator.uploadAttachment(data: Data([1]), filename: "tenth") }
        await fulfillment(of: [started], timeout: 2)
        let refused = await coordinator.uploadAttachment(data: Data([2]), filename: "eleventh")
        XCTAssertNil(refused)
        XCTAssertEqual(coordinator.pendingAttachments.count, 9)
        let finish = try XCTUnwrap(state.firstUploadCompletion())
        finish()
        let result = await tenth.value
        XCTAssertEqual(result?.name, "tenth")
        XCTAssertEqual(coordinator.pendingAttachments.count, 10)
        let saves = await files.savedNames()
        XCTAssertEqual(saves, ["saved-1-tenth"])
    }

    func testRemovalReleasesSlotForAnotherComposerOnSameDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let drafts = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), attachmentStore: files)
        var requests = 0
        let client = makeClient { request in
            requests += 1
            return apiTestJSONResponse(#"{"path":"/uploads/file","mime":"text/plain"}"#, for: request)
        }
        let first = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        let second = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        let key = ChatDraftKey(serverID: "server", context: .newChat)
        first.protectDraft(key)
        second.protectDraft(key)
        for index in 0..<10 {
            _ = await first.uploadAttachment(data: Data([1]), filename: "file-\(index).txt")
        }
        XCTAssertEqual(first.pendingAttachments.count, 10)
        let removed = try XCTUnwrap(first.pendingAttachments.first)
        first.removePendingAttachment(id: removed.id)
        await first.deleteDraftCopy(named: try XCTUnwrap(removed.draftFileName), attachmentID: removed.id)
        let replacement = await second.uploadAttachment(data: Data([2]), filename: "replacement.txt")
        XCTAssertEqual(replacement?.name, "replacement.txt")
        XCTAssertEqual(first.pendingAttachments.count, 9)
        XCTAssertEqual(second.pendingAttachments.map(\.name), ["replacement.txt"])
        XCTAssertEqual(requests, 11)
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory.count, 10)
        withExtendedLifetime(first) {}
    }

    func testBudgetRefusalHasNoNetworkOrNewFileSideEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let existing = try await files.save(data: Data(repeating: 1, count: 4), suggestedFilename: "live")
        let drafts = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), attachmentStore: files, retainedByteLimit: 4)
        let live = drafts.makeAttachmentLease()
        live.files.insert(existing)
        var requests = 0
        let client = makeClient { request in
            requests += 1
            return apiTestJSONResponse(#"{"path":"/unexpected"}"#, for: request)
        }
        let coordinator = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        let result = await coordinator.uploadAttachment(data: Data([2]), filename: "refused")
        withExtendedLifetime(live) {}
        XCTAssertNil(result)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(coordinator.pendingAttachments.count, 0)
        XCTAssertEqual(coordinator.uploadAttachmentErrorMessage, "Attachment storage is busy. Try again shortly.")
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory, [existing: 4])
    }

    func testRetainedRestoreAndStandaloneVoiceAreExemptFromBothAdmissionCaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let file = try await files.save(data: Data([1, 2, 3, 4]), suggestedFilename: "retained")
        let drafts = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), attachmentStore: files, retainedByteLimit: 1)
        var filenames: [String] = []
        let client = makeClient { request in
            filenames.append(try Self.multipartFilename(from: request))
            return apiTestJSONResponse(#"{"path":"/uploads/restored","mime":"text/plain"}"#, for: request)
        }
        let coordinator = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        coordinator.appendPendingAttachments((0..<10).map { index in
            PendingAttachment(name: "existing-\(index)", path: "/uploads/\(index)", mime: "text/plain", size: nil, isImage: false)
        })
        let record = ChatDraftAttachment(id: UUID(), name: "retained", mime: "text/plain", size: nil, isImage: false, file: file)
        let restored = await coordinator.reuploadDraftAttachment(data: Data([1, 2, 3, 4]), draftAttachment: record)
        let voice = await coordinator.uploadStandaloneAttachment(data: Data([5]), filename: "voice.m4a")
        XCTAssertEqual(restored?.id, record.id)
        XCTAssertEqual(restored?.draftFileName, file)
        XCTAssertEqual(voice?.name, "voice.m4a")
        XCTAssertNil(voice?.draftFileName)
        XCTAssertEqual(coordinator.pendingAttachments.count, 11)
        XCTAssertEqual(filenames, ["retained", "voice.m4a"])
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory, [file: 4])
    }

    func testQueueAndSendKeepCopiesProtectedUntilOwnerReleasesThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let file = try await files.save(data: Data([1, 2, 3, 4]), suggestedFilename: "retained")
        let drafts = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), attachmentStore: files, retainedByteLimit: 4)
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let record = ChatDraftAttachment(id: UUID(), name: "retained", mime: "text/plain", size: nil, isImage: false, file: file)
        drafts.setAttachments([record], for: key)
        let client = makeClient { request in apiTestJSONResponse(#"{"path":"/uploads/retained"}"#, for: request) }
        var coordinator: ChatAttachmentCoordinator? = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        let pending = PendingAttachment(id: record.id, name: record.name, path: "/uploads/retained", mime: record.mime, size: nil, isImage: false, draftFileName: file)
        coordinator?.appendPendingAttachments([pending])
        let queued = coordinator?.consumePendingAttachments() ?? []
        let incoming = drafts.makeAttachmentLease()
        do {
            _ = try await drafts.stageAttachment(data: Data([1]), filename: "queued-pressure", lease: incoming)
            XCTFail("Queued copies must be protected")
        } catch {}
        coordinator?.restorePendingAttachments(queued)
        let send = coordinator?.prepareForSend(localMessageID: "send")
        XCTAssertEqual(send?.attachments.map(\.id), [record.id])
        do {
            _ = try await drafts.stageAttachment(data: Data([1]), filename: "send-pressure", lease: incoming)
            XCTFail("In-flight send copies must be protected")
        } catch {}
        coordinator = nil
        let staged = try await drafts.stageAttachment(data: Data([1]), filename: "inactive", lease: incoming)
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory, [staged: 1], "An inactive draft becomes eligible when its live owner is gone")
    }

    func testExplicitCleanupKeepsSharedReferencesWithinAndAcrossDrafts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let file = try await files.save(data: Data([1]), suggestedFilename: "shared")
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let drafts = ChatDraftStore(persistence: persistence, attachmentStore: files)
        let a = ChatDraftKey(serverID: "a", context: .newChat)
        let b = ChatDraftKey(serverID: "b", context: .newChat)
        let first = PendingAttachment(name: "first", path: "/uploads/a", mime: "text/plain", size: nil, isImage: false, draftFileName: file)
        let second = PendingAttachment(name: "second", path: "/uploads/b", mime: "text/plain", size: nil, isImage: false, draftFileName: file)
        drafts.setAttachments([first, second].map(ChatDraftAttachment.init(pending:)), for: a)
        drafts.setAttachments([ChatDraftAttachment(pending: second)], for: b)
        let client = makeClient { request in apiTestJSONResponse(#"{"path":"/unused"}"#, for: request) }
        let coordinator = makeCoordinator(client: client, attachmentStore: files, draftStore: drafts)
        coordinator.protectDraft(a)
        coordinator.appendPendingAttachments([first, second])
        coordinator.removePendingAttachment(id: first.id)
        await coordinator.deleteDraftCopy(named: file, attachmentID: first.id)
        let afterFirst = await persistence.load()
        XCTAssertEqual(afterFirst[a]?.attachments.map(\.id), [second.id])
        XCTAssertEqual(afterFirst[b]?.attachments.map(\.id), [second.id])
        coordinator.removePendingAttachment(id: second.id)
        await coordinator.deleteDraftCopy(named: file, attachmentID: second.id)
        let sharedBytes = try await files.data(named: file)
        XCTAssertEqual(sharedBytes, Data([1]))
        await drafts.discardDraft(for: b)
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory, [:])
    }

    private func makeCoordinator(
        client: APIClient,
        attachmentStore: (any ChatDraftAttachmentStoring)? = nil,
        draftStore: ChatDraftStore? = nil
    ) -> ChatAttachmentCoordinator {
        let coordinator = ChatAttachmentCoordinator(
            client: client,
            draftAttachmentStore: attachmentStore ?? RecordingAttachmentStore(),
            draftStore: draftStore
        )
        let delegate = ChatAttachmentCoordinatorDelegateSpy()
        delegateSpies.append(delegate)
        coordinator.delegate = delegate
        return coordinator
    }

    private func makeAuthenticatedMediaClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let authenticatedConfiguration = URLSessionConfiguration.ephemeral
        authenticatedConfiguration.protocolClasses = [MockURLProtocol.self]
        authenticatedConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "authenticated"]

        let publicConfiguration = URLSessionConfiguration.ephemeral
        publicConfiguration.protocolClasses = [MockURLProtocol.self]
        publicConfiguration.httpAdditionalHeaders = ["X-Hermes-Test-Session": "public"]

        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: authenticatedConfiguration),
            publicMediaSession: URLSession(configuration: publicConfiguration)
        )
    }

    private func makeDeferredUploadClient(
        handler: @escaping (URLRequest, DeferredUploadMockURLProtocol) throws -> Void
    ) -> APIClient {
        DeferredUploadMockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredUploadMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    private static func imageData() -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    private static func multipartFilename(from request: URLRequest) throws -> String {
        let data = try XCTUnwrap(apiTestBodyData(from: request))
        let marker = Data("filename=\"".utf8)
        let quote = Data("\"".utf8)
        let markerRange = try XCTUnwrap(data.range(of: marker))
        let filenameStart = markerRange.upperBound
        let filenameEnd = try XCTUnwrap(data[filenameStart...].range(of: quote)).lowerBound
        return String(decoding: data[filenameStart..<filenameEnd], as: UTF8.self)
    }
}

private actor RecordingAttachmentStore: ChatDraftAttachmentStoring {
    private let saveError: Error?
    private var saves: [String] = []
    private var deletes: [String] = []

    init(saveError: Error? = nil) {
        self.saveError = saveError
    }

    func save(data: Data, suggestedFilename: String) async throws -> String {
        if let saveError {
            throw saveError
        }
        let fileName = "saved-\(saves.count + 1)-\(URL(fileURLWithPath: suggestedFilename).lastPathComponent)"
        saves.append(fileName)
        return fileName
    }

    func data(named fileName: String) async throws -> Data {
        Data()
    }

    func fileURL(named fileName: String) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }

    func delete(named fileName: String) async {
        deletes.append(fileName)
    }

    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}

    func savedNames() -> [String] {
        saves
    }

    func deletedNames() -> [String] {
        deletes
    }
}

private final class DeferredUploadMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, DeferredUploadMockURLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            try requestHandler(request, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    func complete(with response: (HTTPURLResponse, Data)) {
        client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DeferredUploadState {
    private let lock = NSLock()
    private var uploadCount = 0
    private var firstCompletion: (() -> Void)?

    func nextUploadIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        uploadCount += 1
        return uploadCount
    }

    func setFirstUploadCompletion(_ completion: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        firstCompletion = completion
    }

    func firstUploadCompletion() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return firstCompletion
    }
}

@MainActor
private final class ChatAttachmentCoordinatorDelegateSpy: ChatAttachmentCoordinatorDelegate {
    var attachmentSessionID: String? = "session-abc"
    var attachmentIsViewingCachedData = false
    private(set) var failedErrors: [Error] = []

    func attachmentCoordinatorWillUpload() {}

    func attachmentCoordinatorDidFail(_ error: Error) {
        failedErrors.append(error)
    }
}
