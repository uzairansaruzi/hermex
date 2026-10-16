import XCTest
@testable import HermesMobile

final class SharedDraftStoreTests: XCTestCase {
    func testDraftTextCombinesTextAndURLsInOrder() {
        let draft = HermesShareDraft.draftText(
            textSnippets: [
                "  Summarize this page  ",
                "\nSummarize this page\n",
                "Key quote",
                "https://example.com/article"
            ],
            urls: [
                URL(string: "https://example.com/article")!,
                URL(string: "https://example.com/article")!,
                URL(string: "https://example.com/notes")!
            ]
        )

        XCTAssertEqual(
            draft,
            """
            Summarize this page

            Key quote

            https://example.com/article

            https://example.com/notes
            """
        )
    }

    func testComposerDraftAddsTrailingNewlineForFollowupInput() {
        XCTAssertEqual(
            HermesShareDraft.composerDraft(from: "  https://example.com/article  "),
            "https://example.com/article\n"
        )
        XCTAssertEqual(HermesShareDraft.composerDraft(from: " \n\t "), "")
    }

    func testShareOpenURLRecognizesOnlyHermesShareLinks() {
        let scheme = HermesShareDraft.urlScheme

        XCTAssertTrue(HermesShareDraft.isShareOpenURL(URL(string: "\(scheme)://share")!))
        XCTAssertFalse(HermesShareDraft.isShareOpenURL(URL(string: "\(scheme)://settings")!))
        XCTAssertFalse(HermesShareDraft.isShareOpenURL(URL(string: "https://example.com/share")!))
    }

    func testPendingDraftStorageLoadsAndClearsDraft() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(
            "  Draft from Safari  ",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let draft = try HermesShareDraft.loadPendingDraft(from: directory)
        XCTAssertEqual(draft, "Draft from Safari")
        XCTAssertNil(try HermesShareDraft.loadPendingDraft(from: directory))
    }

    func testPendingImportStorageLoadsAttachmentAndClearsStagedFiles() throws {
        let directory = try temporaryDirectory()
        let attachmentData = Data("pdf bytes".utf8)

        try HermesShareDraft.savePendingImport(
            draft: "  Review this  ",
            attachments: [
                SharedAttachmentImport(
                    filename: "/private/tmp/report.pdf",
                    typeIdentifier: "com.adobe.pdf",
                    data: attachmentData
                )
            ],
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "Review this")
        XCTAssertEqual(sharedImport.attachments.count, 1)
        XCTAssertEqual(sharedImport.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(sharedImport.attachments.first?.typeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(sharedImport.attachments.first?.data, attachmentData)
        XCTAssertNil(try HermesShareDraft.loadPendingImport(from: directory))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(HermesShareDraft.pendingAttachmentsDirectoryName).path
            )
        )
    }

    // Reserving runs on the main actor during share handoff, so staged files
    // are mapped there and only paged in when the upload reads them.
    func testReservedAttachmentsAreMappedFromStagedFiles() throws {
        let directory = try temporaryDirectory()
        let attachmentData = Data(repeating: 0x42, count: 1_024 * 1_024)

        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: [
                SharedAttachmentImport(filename: "scan.pdf", typeIdentifier: "com.adobe.pdf", data: attachmentData)
            ],
            in: directory
        )

        let reservation = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: directory))
        let attachment = try XCTUnwrap(reservation.sharedImport.attachments.first)

        XCTAssertTrue(isFileBacked(attachment.data), "staged files must be mapped, not read into memory")

        // The app consumes the reservation before uploading, so the first read
        // of the mapped bytes happens after their staged file is removed.
        try HermesShareDraft.consume(reservation, from: directory)
        XCTAssertEqual(attachment.data, attachmentData, "the mapping outlives the consumed reservation")
    }

    func testPendingImportSupportsAttachmentOnlyShare() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingImport(
            draft: " \n ",
            attachments: [
                SharedAttachmentImport(
                    filename: "photo.jpg",
                    typeIdentifier: "public.jpeg",
                    data: Data([0x01, 0x02, 0x03])
                )
            ],
            in: directory
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "")
        XCTAssertEqual(sharedImport.attachments.first?.filename, "photo.jpg")
        XCTAssertEqual(sharedImport.attachments.first?.data, Data([0x01, 0x02, 0x03]))
    }

    func testPendingImportCapsAttachmentsAtSharedLimit() throws {
        let directory = try temporaryDirectory()
        let attachments = (0..<(HermesShareDraft.maximumSharedAttachmentCount + 1)).map { index in
            SharedAttachmentImport(
                filename: "file-\(index).txt",
                typeIdentifier: "public.plain-text",
                data: Data("file-\(index)".utf8)
            )
        }

        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: attachments,
            in: directory
        )

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.attachments.count, HermesShareDraft.maximumSharedAttachmentCount)
        XCTAssertEqual(sharedImport.attachments.first?.filename, "file-0.txt")
        XCTAssertEqual(sharedImport.attachments.last?.filename, "file-9.txt")
    }

    func testInboxKeepsTwoSharesAndReservesThemOldestFirst() throws {
        let directory = try temporaryDirectory()
        let firstDate = Date(timeIntervalSince1970: 1_800_000_010)
        let secondDate = Date(timeIntervalSince1970: 1_800_000_020)

        try HermesShareDraft.savePendingDraft("First share", in: directory, now: firstDate)
        try HermesShareDraft.savePendingDraft("Second share", in: directory, now: secondDate)
        XCTAssertTrue(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))

        let first = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate)
        )
        XCTAssertEqual(first.sharedImport.draft, "First share")
        XCTAssertEqual(first.createdAt, firstDate)
        XCTAssertTrue(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))
        try HermesShareDraft.consume(first, from: directory)

        let second = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate)
        )
        XCTAssertEqual(second.sharedImport.draft, "Second share")
        XCTAssertEqual(second.createdAt, secondDate)
        try HermesShareDraft.consume(second, from: directory)

        XCTAssertFalse(try HermesShareDraft.hasPendingImport(in: directory, now: secondDate))
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory, now: secondDate))
    }

    func testInboxDeduplicatesRepeatedPendingContent() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_030)
        )
        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_040)
        )

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        try HermesShareDraft.savePendingDraft(
            "Repeated share",
            in: directory,
            now: Date(timeIntervalSince1970: 1_800_000_050)
        )
        try HermesShareDraft.consume(reservation, from: directory)

        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory))
    }

    func testReleasedReservationCanBeReservedAgain() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Route me later", in: directory)

        let first = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        try HermesShareDraft.release(first, in: directory)

        let second = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertNotEqual(second.reservationID, first.reservationID)
        XCTAssertEqual(second.sharedImport, first.sharedImport)
    }

    func testExpiredReservationReturnsToInboxWithNewOwnership() throws {
        let directory = try temporaryDirectory()
        let reservationDate = Date(timeIntervalSince1970: 1_800_000_050)
        try HermesShareDraft.savePendingDraft("Recover me", in: directory, now: reservationDate)

        let expired = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory, now: reservationDate)
        )
        let recovered = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(
                from: directory,
                now: reservationDate.addingTimeInterval(HermesShareDraft.reservationLifetime + 1)
            )
        )

        XCTAssertEqual(recovered.itemID, expired.itemID)
        XCTAssertNotEqual(recovered.reservationID, expired.reservationID)
        XCTAssertThrowsError(try HermesShareDraft.consume(expired, from: directory))
        try HermesShareDraft.consume(recovered, from: directory)
    }

    func testMissingAttachmentOnlyItemDoesNotBlockLaterShare() throws {
        let directory = try temporaryDirectory()
        let attachmentDate = Date(timeIntervalSince1970: 1_800_000_060)
        try HermesShareDraft.savePendingImport(
            draft: "",
            attachments: [
                SharedAttachmentImport(
                    filename: "missing.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("gone".utf8)
                )
            ],
            in: directory,
            now: attachmentDate
        )
        try HermesShareDraft.savePendingDraft(
            "Still valid",
            in: directory,
            now: attachmentDate.addingTimeInterval(1)
        )

        for fileURL in try attachmentFileURLs(in: directory) {
            try FileManager.default.removeItem(at: fileURL)
        }

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(reservation.sharedImport.draft, "Still valid")
        try HermesShareDraft.consume(reservation, from: directory)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: directory))
    }

    func testMissingAttachmentDoesNotDiscardRemainingSharedContent() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingImport(
            draft: "Review what remains",
            attachments: [
                SharedAttachmentImport(
                    filename: "first.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("first".utf8)
                ),
                SharedAttachmentImport(
                    filename: "second.txt",
                    typeIdentifier: "public.plain-text",
                    data: Data("second".utf8)
                )
            ],
            in: directory
        )

        let attachmentFiles = try attachmentFileURLs(in: directory)
        XCTAssertEqual(attachmentFiles.count, 2)
        try FileManager.default.removeItem(at: attachmentFiles[0])

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )
        XCTAssertEqual(reservation.sharedImport.draft, "Review what remains")
        XCTAssertEqual(reservation.sharedImport.attachments.count, 1)
        try HermesShareDraft.consume(reservation, from: directory)
    }

    func testFailedInboxPreparationDoesNotOverwriteExistingFile() throws {
        let parent = try temporaryDirectory()
        let fileURL = parent.appendingPathComponent("not-a-directory")
        let originalData = Data("keep me".utf8)
        try originalData.write(to: fileURL)

        XCTAssertThrowsError(
            try HermesShareDraft.savePendingDraft("Unsaved share", in: fileURL)
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
    }

    func testPendingImportDecodesLegacyDraftOnlyPayload() throws {
        let directory = try temporaryDirectory()
        let payloadURL = directory.appendingPathComponent(HermesShareDraft.pendingDraftFileName)
        let legacyPayload = """
        {
          "draft": "Legacy note",
          "createdAt": 1800000002
        }
        """
        try Data(legacyPayload.utf8).write(to: payloadURL)

        let sharedImport = try XCTUnwrap(try HermesShareDraft.loadPendingImport(from: directory))

        XCTAssertEqual(sharedImport.draft, "Legacy note")
        XCTAssertTrue(sharedImport.attachments.isEmpty)
    }

    func testMalformedLegacyPayloadDoesNotBlockTransactionalInbox() throws {
        let directory = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Valid new share", in: directory)

        let legacyPayloadURL = directory.appendingPathComponent(HermesShareDraft.pendingDraftFileName)
        try Data("not json".utf8).write(to: legacyPayloadURL)
        let legacyAttachmentsURL = directory.appendingPathComponent(
            HermesShareDraft.pendingAttachmentsDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyAttachmentsURL, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: legacyAttachmentsURL.appendingPathComponent("orphan.txt"))

        let reservation = try XCTUnwrap(
            try HermesShareDraft.reserveNextPendingImport(from: directory)
        )

        XCTAssertEqual(reservation.sharedImport.draft, "Valid new share")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPayloadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAttachmentsURL.path))
    }

    func testEmptyPendingDraftIsNotWritten() throws {
        let directory = try temporaryDirectory()

        try HermesShareDraft.savePendingDraft(" \n ", in: directory)

        XCTAssertNil(try HermesShareDraft.loadPendingDraft(from: directory))
    }

    // MARK: - On a Hermes server (#1181)

    private let hermes = URL(string: "https://studio.example:9119")!
    private let webui = URL(string: "https://webui.example")!

    private func account(_ server: URL, _ kind: ServerKind) -> ServerAccount {
        ServerAccount(id: server.absoluteString, urlString: server.absoluteString, displayName: "", initials: "",
                      headerLogoColorHex: HeaderLogoColor.defaultHex, createdAt: Date(timeIntervalSince1970: 0),
                      updatedAt: Date(timeIntervalSince1970: 0), kind: kind)
    }

    private func reservation(_ draft: String, _ attachments: [SharedAttachmentImport] = []) -> SharedImportReservation {
        SharedImportReservation(itemID: UUID().uuidString, reservationID: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 0),
                                sharedImport: SharedImport(draft: draft, attachments: attachments))
    }

    /// A Hermes home has no Open Next banner: each queued share is reserved as the one before it
    /// is routed. A webui session list keeps the next one waiting for Open Next.
    func testQueuedSharesOpenOneAfterAnotherOnlyOnAHermesHome() throws {
        let servers = [account(hermes, .hermes), account(webui, .webui)]
        func queue(_ active: URL) throws -> (SharedImportQueue, URL) {
            let directory = try temporaryDirectory()
            try HermesShareDraft.savePendingDraft("First", in: directory, now: Date(timeIntervalSince1970: 1_800_000_010))
            try HermesShareDraft.savePendingDraft("Second", in: directory, now: Date(timeIntervalSince1970: 1_800_000_020))
            var queue = SharedImportQueue()
            queue.reserveNext(in: directory, active: active, servers: servers)
            return (queue, directory)
        }

        var (onHermes, hermesInbox) = try queue(hermes)
        let first = try XCTUnwrap(onHermes.pending)
        XCTAssertEqual(first.sharedImport.draft, "First")
        onHermes.consume(first, in: hermesInbox, active: hermes, servers: servers)
        let second = try XCTUnwrap(onHermes.pending, "The next share opens once the first is routed")
        XCTAssertEqual(second.sharedImport.draft, "Second")
        onHermes.consume(second, in: hermesInbox, active: hermes, servers: servers)
        XCTAssertNil(onHermes.pending)
        XCTAssertFalse(onHermes.hasWaiting)

        var (onWebui, webuiInbox) = try queue(webui)
        onWebui.consume(try XCTUnwrap(onWebui.pending), in: webuiInbox, active: webui, servers: servers)
        XCTAssertNil(onWebui.pending, "A webui list offers the next share in its banner")
        XCTAssertTrue(onWebui.hasWaiting)
        onWebui.openNext(in: webuiInbox, active: webui, servers: servers)
        XCTAssertEqual(onWebui.pending?.sharedImport.draft, "Second")
    }

    @MainActor
    func testTheHermesSessionsListOpensAShareAsANewSessionOnceItCan() throws {
        let connection = BotConnection(id: UUID(), name: "Host", address: hermes, username: "me", password: "secret")
        let entry = HermesSessionListEntry(server: hermes, connection: connection, profile: nil)
        let photo = SharedAttachmentImport(filename: "photo.jpg", typeIdentifier: "public.jpeg", data: Data([1, 2, 3]))
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        let share = reservation("  Read this  ", [photo, pdf])

        XCTAssertNil(share.hermesOpening(on: entry, listed: nil, isLive: true), "Waits for New Session's Profile")
        XCTAssertNil(share.hermesOpening(on: entry, listed: "default", isLive: false),
                     "Waits for the list's live read of the host, as a Shortcut's new session does")
        guard case .chat(let chat)? = share.hermesOpening(on: entry, listed: "default", isLive: true) else {
            return XCTFail("A share opens a new session")
        }
        XCTAssertEqual(chat.target, .new(profile: "default"))
        XCTAssertEqual(chat.server, hermes)
        XCTAssertEqual(chat.connection, connection)
        XCTAssertFalse(chat.autoStartsVoiceInput)

        guard case .chat(let filesOnly)? = reservation("", [pdf]).hermesOpening(on: entry, listed: "dev", isLive: true) else {
            return XCTFail("A file alone opens a new session")
        }
        XCTAssertEqual(filesOnly.target, .new(profile: "dev"))

        XCTAssertEqual(reservation(" \n ").hermesOpening(on: entry, listed: "default", isLive: true), .nothing,
                       "An empty share is consumed without a chat")
    }

    @MainActor
    private func newSession(_ profile: String = "default") -> (chat: HermesSessionChat, key: ChatDraftKey) {
        let connection = BotConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000001181")!, name: "Host",
                                       address: hermes, username: "me", password: "secret")
        let entry = HermesSessionListEntry(server: hermes, connection: connection, profile: nil)
        guard case .chat(let chat)? = reservation("x").hermesOpening(on: entry, listed: profile, isLive: true) else {
            preconditionFailure("A share opens a new session")
        }
        return (chat, .hermesSession(server: hermes, connectionID: connection.id, profile: profile, key: nil))
    }

    /// A store that writes to disk only on `flush`, as a share's move must.
    @MainActor
    private func drafts(_ disk: BotMemoryDrafts, _ copies: any ChatDraftAttachmentStoring) -> ChatDraftStore {
        ChatDraftStore(persistence: disk, attachmentStore: copies, debounceDuration: .seconds(3600))
    }

    @MainActor
    func testAShareIsOnDiskInItsNewSessionsDraftBeforeItIsConsumed() async throws {
        let disk = BotMemoryDrafts()
        let copies = BotAttachmentCopies()
        let (chat, key) = newSession()
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))

        try await reservation("  Read this  ", [pdf]).moveIntoDraft(of: chat, drafts: drafts(disk, copies))

        // The next New Session in this Profile, even after a relaunch, restores the share from disk.
        let restored = await drafts(disk, copies).draft(for: key)
        XCTAssertEqual(restored?.text, "Read this\n")
        XCTAssertEqual(restored?.attachments.map(\.name), ["notes.pdf"])
        XCTAssertEqual(restored?.attachments.first?.mime, "application/pdf")
        let file = try XCTUnwrap(restored?.attachments.first?.file)
        let copy = try await copies.data(named: file)
        XCTAssertEqual(copy, Data([4, 5]))
    }

    @MainActor
    func testAShareCutShortLeavesTheDraftAsItWas() async throws {
        let disk = BotMemoryDrafts()
        let copies = PausingCopies()
        let store = drafts(disk, copies)
        let (chat, key) = newSession()
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        let saving = expectation(description: "The first file's copy is being written")
        await copies.onSave { saving.fulfill() }

        let move = Task { try await reservation("Read this", [pdf, pdf]).moveIntoDraft(of: chat, drafts: store) }
        await fulfillment(of: [saving], timeout: 5)
        move.cancel()
        await copies.resume()

        do {
            try await move.value
            XCTFail("A move cut short throws, so the share is not consumed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let draft = await store.draft(for: key)
        XCTAssertNil(draft, "The draft is unchanged")
        let onDisk = await disk.values
        XCTAssertTrue(onDisk.isEmpty)
        let kept = await copies.count
        XCTAssertEqual(kept, 0, "No copy is left behind")
    }

    @MainActor
    func testALaterShareAddsToTheUnsentOneBeforeIt() async throws {
        let disk = BotMemoryDrafts()
        let copies = BotAttachmentCopies()
        let (chat, key) = newSession()
        let a = SharedAttachmentImport(filename: "a.pdf", typeIdentifier: "com.adobe.pdf", data: Data([1]))
        let b = SharedAttachmentImport(filename: "b.txt", typeIdentifier: "public.plain-text", data: Data([2]))

        try await reservation("Share A", [a]).moveIntoDraft(of: chat, drafts: drafts(disk, copies))
        // The user backs out without sending, then shares again into the same Profile.
        try await reservation("Share B", [b]).moveIntoDraft(of: newSession().chat, drafts: drafts(disk, copies))

        let draft = await drafts(disk, copies).draft(for: key)
        XCTAssertEqual(draft?.text, "Share A\n\nShare B\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["a.pdf", "b.txt"])
    }

    /// A share waiting in a fresh app-group inbox, reserved as `ContentView` reserves it.
    private func inboxShare(_ draft: String, _ attachments: [SharedAttachmentImport]) throws
        -> (inbox: URL, share: SharedImportReservation) {
        let inbox = try temporaryDirectory()
        try HermesShareDraft.savePendingImport(draft: draft, attachments: attachments, in: inbox)
        return (inbox, try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: inbox)))
    }

    @MainActor
    func testAFileTheDraftCantTakeKeepsTheWholeShareQueued() async throws {
        let bytes = Data("pdf bytes".utf8)
        let (inbox, share) = try inboxShare("One more", [
            SharedAttachmentImport(filename: "ninth.pdf", typeIdentifier: "com.adobe.pdf", data: bytes)
        ])
        let copies = BotAttachmentCopies()
        let store = drafts(BotMemoryDrafts(), copies)
        let (chat, key) = newSession()
        let full = (1...8).map {
            ChatDraftAttachment(id: UUID(), name: "\($0).pdf", mime: "application/pdf", size: 1, isImage: false, file: "staged-\($0)")
        }
        store.setDraft("Unsent", for: key)
        store.setAttachments(full, for: key)
        var routed = 0

        do {
            try await share.transfer(into: chat, drafts: store, route: { _ in routed += 1 })
            XCTFail("A share the draft can't take whole is not moved")
        } catch {
            XCTAssertEqual(error as? BotAttachmentFailure, .limit)
        }
        try HermesShareDraft.release(share, in: inbox)

        XCTAssertEqual(routed, 0, "It is never let go")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Unsent")
        XCTAssertEqual(draft?.attachments, full)
        let kept = await copies.count
        XCTAssertEqual(kept, 0)
        // Released, as when the list goes before the user discards it, it comes back whole.
        let again = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: inbox))
        XCTAssertEqual(again.itemID, share.itemID)
        XCTAssertEqual(again.sharedImport.attachments.map(\.data), [bytes])
    }

    @MainActor
    func testAShareRetriedWhileItsWriteIsInFlightIsAddedAndConsumedOnce() async throws {
        let (inbox, share) = try inboxShare("Read this", [
            SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5])),
            SharedAttachmentImport(filename: "notes.txt", typeIdentifier: "public.plain-text", data: Data([6]))
        ])
        let disk = PausingDrafts()
        let copies = BotAttachmentCopies()
        let store = ChatDraftStore(persistence: disk, attachmentStore: copies, debounceDuration: .seconds(3600))
        let (chat, key) = newSession()
        let consumed = Tally()
        let consume: (SharedImportReservation) -> Void = {
            if (try? HermesShareDraft.consume($0, from: inbox)) != nil { consumed.count += 1 }
        }

        await disk.pauseNextWrite()
        let first = Task { try await share.transfer(into: chat, drafts: store, route: consume) }
        await disk.waitUntilPaused()
        // The list leaves while the draft is being written, and on its return tries the same share again.
        first.cancel()
        let retry = Task { try await share.transfer(into: self.newSession().chat, drafts: store, route: consume) }
        await disk.resume()
        try await first.value
        try await retry.value

        XCTAssertEqual(consumed.count, 1, "The first move is let go though its list left; the retry finds it done")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Read this\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["notes.pdf", "notes.txt"])
        let saved = await copies.count
        XCTAssertEqual(saved, 2)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: inbox))
    }

    @MainActor
    func testAShareReplayedAfterTheAppQuitBeforeConsumingIsAddedOnce() async throws {
        let (inbox, share) = try inboxShare("Read this", [
            SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        ])
        let directory = try temporaryDirectory()
        let copies = BotAttachmentCopies()
        func launch() -> ChatDraftStore {
            ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory), attachmentStore: copies,
                           debounceDuration: .seconds(3600))
        }
        let (chat, key) = newSession()

        // The draft is written, then the app quits before the share is consumed.
        try await share.transfer(into: chat, drafts: launch(), route: { _ in })
        // On relaunch its reservation expires back into the inbox and it is offered again.
        let replay = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(
            from: inbox, now: Date().addingTimeInterval(HermesShareDraft.reservationLifetime + 60)))
        XCTAssertEqual(replay.itemID, share.itemID)
        XCTAssertEqual(replay.occurrenceID, share.occurrenceID)
        let relaunched = launch()
        var consumed = 0
        try await replay.transfer(into: newSession().chat, drafts: relaunched, route: {
            if (try? HermesShareDraft.consume($0, from: inbox)) != nil { consumed += 1 }
        })

        XCTAssertEqual(consumed, 1)
        let draft = await relaunched.draft(for: key)
        XCTAssertEqual(draft?.text, "Read this\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["notes.pdf"])
        let saved = await copies.count
        XCTAssertEqual(saved, 1)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: inbox))
    }

    /// The inbox names a share by its content, so sharing the same thing again after the first was
    /// consumed repeats its item id; the draft, edited since, still takes the new share (#1197).
    @MainActor
    func testTheSameContentSharedAgainAfterConsumptionIsAddedAgain() async throws {
        let inbox = try temporaryDirectory()
        let pdf = SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        func share(at seconds: TimeInterval) throws -> SharedImportReservation {
            let now = Date(timeIntervalSince1970: seconds)
            try HermesShareDraft.savePendingImport(draft: "Read this", attachments: [pdf], in: inbox, now: now)
            return try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(from: inbox, now: now))
        }
        let store = drafts(BotMemoryDrafts(), BotAttachmentCopies())
        let (chat, key) = newSession()
        let consume: (SharedImportReservation) -> Void = { try? HermesShareDraft.consume($0, from: inbox) }

        let first = try share(at: 1_800_000_010)
        try await first.transfer(into: chat, drafts: store, route: consume)
        // The user rewrites the text and removes the file without sending.
        store.setDraft("Something else", for: key)
        store.setAttachments([], for: key)

        let second = try share(at: 1_800_000_020)
        XCTAssertEqual(second.itemID, first.itemID)
        XCTAssertNotEqual(second.occurrenceID, first.occurrenceID)
        try await second.transfer(into: newSession().chat, drafts: store, route: consume)

        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Something else\n\nRead this\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["notes.pdf"])
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: inbox))
    }

    @MainActor
    func testAComposerSnapshotDuringAShareKeepsTheSharedFile() async throws {
        let disk = PausingDrafts()
        let store = ChatDraftStore(persistence: disk, attachmentStore: BotAttachmentCopies(), debounceDuration: .seconds(3600))
        let (_, key) = newSession()
        let picked = ChatDraftAttachment(id: UUID(), name: "picked.png", mime: "image/png", size: 1, isImage: true, file: "picked")

        await disk.pauseNextWrite()
        let move = Task {
            try await store.appendShare("item", text: "Read this\n", files: [(Data([4, 5]), "notes.pdf", "application/pdf", false)],
                                        to: key, maximumFileBytes: 1024)
        }
        await disk.waitUntilPaused()
        // A composer open on this draft since before the share finishes staging a picked file.
        store.setAttachments([picked], replacing: [], for: key)
        await disk.resume()
        try await move.value

        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.attachments.map(\.name), ["picked.png", "notes.pdf"])
        try await store.flush()
        let onDisk = await disk.values[key]
        XCTAssertEqual(onDisk?.attachments.map(\.name), ["picked.png", "notes.pdf"])
    }

    @MainActor
    func testAShareWhoseFileIsDroppedDuringItsWriteIsTakenBackAndNotLetGo() async throws {
        let disk = PausingDrafts()
        let copies = BotAttachmentCopies()
        let store = ChatDraftStore(persistence: disk, attachmentStore: copies, debounceDuration: .seconds(3600))
        let (_, key) = newSession()
        let own = ChatDraftAttachment(id: UUID(), name: "own.png", mime: "image/png", size: 1, isImage: true, file: "own")
        store.setDraft("Unsent", for: key)
        store.setAttachments([own], for: key)

        await disk.pauseNextWrite()
        let move = Task {
            try await store.appendShare("item", text: "Read this\n", files: [(Data([4, 5]), "notes.pdf", "application/pdf", false)],
                                        to: key, maximumFileBytes: 1024)
        }
        await disk.waitUntilPaused()
        // A write that replaces every record, such as a send clearing what it carried, lands meanwhile.
        store.setAttachments([], for: key)
        await disk.resume()

        do {
            try await move.value
            XCTFail("A share that lost a file is not let go")
        } catch {
            XCTAssertEqual(error as? ChatDraftStorageError, .unavailable)
        }
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Unsent", "The share's text is taken back")
        XCTAssertEqual(draft?.attachments, [], "The write made meanwhile stays")
        XCTAssertEqual(draft?.sharedImportIDs, [], "So the share moves again on its next try")
        let kept = await copies.count
        XCTAssertEqual(kept, 0)
    }

    /// An inbox on a Hermes home whose oldest share has a file Hermes can't take, then a text share,
    /// with the first reserved and claimed for its move, as `ContentView` and the list do (#1196).
    @MainActor
    private func blockedInbox() throws -> (inbox: URL, shares: QueueBox, failed: SharedImportReservation) {
        let inbox = try temporaryDirectory()
        let disk = SharedAttachmentImport(filename: "setup.dmg", typeIdentifier: "com.apple.disk-image-udif", data: Data([7]))
        try HermesShareDraft.savePendingImport(draft: "", attachments: [disk], in: inbox,
                                               now: Date(timeIntervalSince1970: 1_800_000_010))
        try HermesShareDraft.savePendingDraft("Later", in: inbox, now: Date(timeIntervalSince1970: 1_800_000_020))
        let shares = QueueBox()
        shares.queue.reserveNext(in: inbox, active: hermes, servers: [account(hermes, .hermes)])
        let failed = try XCTUnwrap(shares.queue.pending)
        XCTAssertTrue(shares.queue.claim(failed))
        return (inbox, shares, failed)
    }

    /// A share Hermes can't take holds the queue only until the user discards it: Discard deletes
    /// that share alone and the next one opens.
    @MainActor
    func testDiscardingAShareHermesCantTakeOpensTheNextOne() async throws {
        let servers = [account(hermes, .hermes)]
        let (inbox, shares, failed) = try blockedInbox()
        let store = drafts(BotMemoryDrafts(), BotAttachmentCopies())
        let (chat, key) = newSession()

        do {
            try await failed.transfer(into: chat, drafts: store, route: { _ in XCTFail("It is never let go") })
            XCTFail("A file type Hermes can't take is not moved")
        } catch {
            XCTAssertEqual(error as? BotAttachmentFailure, .type)
        }
        shares.queue.reserveNext(in: inbox, active: hermes, servers: servers)
        XCTAssertNil(shares.queue.pending, "Nothing else opens while the alert is up")

        // Discard Share.
        shares.queue.consume(failed, in: inbox, active: hermes, servers: servers)
        let next = try XCTUnwrap(shares.queue.pending)
        XCTAssertEqual(next.sharedImport.draft, "Later")
        XCTAssertTrue(shares.queue.claim(next))
        try await next.transfer(into: chat, drafts: store, route: { shares.queue.consume($0, in: inbox, active: hermes, servers: servers) })
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Later\n")
        XCTAssertNil(shares.queue.pending)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: inbox), "Both shares are gone")
    }

    /// The list going before the user discards a share Hermes can't take (a server switch, a
    /// Shortcut's chat) keeps it queued with its files: only Discard deletes it.
    @MainActor
    func testAFailedShareTheUserDidNotDiscardStaysQueued() throws {
        let (inbox, shares, failed) = try blockedInbox()

        shares.queue.release(failed, in: inbox)
        shares.queue.reserveNext(in: inbox, active: hermes, servers: [account(hermes, .hermes)])
        let again = try XCTUnwrap(shares.queue.pending)
        XCTAssertEqual(again.itemID, failed.itemID)
        XCTAssertEqual(again.sharedImport.attachments.map(\.data), [Data([7])])
    }

    @MainActor
    func testAShareWhoseTextIsTypedOverDuringItsWriteComesBackWholeAfterAQuit() async throws {
        let (inbox, share) = try inboxShare("Read this", [
            SharedAttachmentImport(filename: "notes.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
        ])
        let disk = PausingDrafts()
        let copies = BotAttachmentCopies()
        func launch() -> ChatDraftStore {
            ChatDraftStore(persistence: disk, attachmentStore: copies, debounceDuration: .seconds(3600))
        }
        let store = launch()
        let (chat, key) = newSession()
        let routed = Tally()

        await disk.pauseNextWrite()
        let move = Task {
            try await share.transfer(into: chat, drafts: store, route: { _ in routed.count += 1 })
        }
        await disk.waitUntilPaused()
        // A composer open on this draft since before the share types over its text (#1198).
        store.setContent(ComposerDraftContent(text: "Typed", quotes: []), for: key)
        await disk.resume()
        do {
            try await move.value
            XCTFail("A share whose text was lost is not let go")
        } catch {
            XCTAssertEqual(error as? ChatDraftStorageError, .unavailable)
        }
        XCTAssertEqual(routed.count, 0)

        // The app quits before any later save; on relaunch its reservation expires and the share
        // comes back with its file.
        let relaunched = launch()
        let replay = try XCTUnwrap(try HermesShareDraft.reserveNextPendingImport(
            from: inbox, now: Date().addingTimeInterval(HermesShareDraft.reservationLifetime + 60)))
        try await replay.transfer(into: newSession().chat, drafts: relaunched, route: { _ in routed.count += 1 })
        XCTAssertEqual(routed.count, 1)
        let draft = await relaunched.draft(for: key)
        XCTAssertEqual(draft?.text, "Typed\n\nRead this\n")
        XCTAssertEqual(draft?.attachments.map(\.name), ["notes.pdf"])
        let file = try XCTUnwrap(draft?.attachments.first?.file)
        let copy = try await copies.data(named: file)
        XCTAssertEqual(copy, Data([4, 5]))
    }

    @MainActor
    func testATextShareTakenBackIsTakenBackOnDiskBeforeItIsQueued() async throws {
        let disk = PausingDrafts()
        let store = ChatDraftStore(persistence: disk, attachmentStore: BotAttachmentCopies(), debounceDuration: .seconds(3600))
        let (_, key) = newSession()

        await disk.pauseNextWrite()
        let move = Task { try await store.appendShare("item", text: "Read this\n", files: [], to: key, maximumFileBytes: 1024) }
        await disk.waitUntilPaused()
        store.setContent(ComposerDraftContent(text: "Typed", quotes: []), for: key)
        await disk.resume()
        do {
            try await move.value
            XCTFail("A share whose text was lost is not let go")
        } catch {
            XCTAssertEqual(error as? ChatDraftStorageError, .unavailable)
        }

        // With no later save, a replay must not find the share already in the draft.
        let onDisk = await disk.values[key]
        XCTAssertEqual(onDisk?.text, "Typed")
        XCTAssertEqual(onDisk?.sharedImportIDs, [])
    }

    @MainActor
    func testAShareThatNoLongerFitsWhenItLandsIsQueued() async throws {
        let copies = PausingCopies()
        let store = drafts(BotMemoryDrafts(), copies)
        let (chat, key) = newSession()
        func staged(_ n: Int) -> ChatDraftAttachment {
            ChatDraftAttachment(id: UUID(), name: "\(n).pdf", mime: "application/pdf", size: 1, isImage: false, file: "staged-\(n)")
        }
        let seven = (1...7).map(staged)
        store.setAttachments(seven, for: key)
        let saving = expectation(description: "The share's copy is being written")
        await copies.onSave { saving.fulfill() }

        let move = Task {
            try await self.reservation("", [
                SharedAttachmentImport(filename: "ninth.pdf", typeIdentifier: "com.adobe.pdf", data: Data([4, 5]))
            ]).transfer(into: chat, drafts: store, route: { _ in XCTFail("It is never let go") })
        }
        await fulfillment(of: [saving], timeout: 5)
        // A composer open on this draft adds an eighth file meanwhile.
        let eight = seven + [staged(8)]
        store.setAttachments(eight, replacing: seven, for: key)
        await copies.resume()

        do {
            try await move.value
            XCTFail("A share past Hermes's limits is not moved")
        } catch {
            XCTAssertEqual(error as? BotAttachmentFailure, .limit)
        }
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.attachments, eight)
        let kept = await copies.count
        XCTAssertEqual(kept, 0)
    }

    @MainActor
    func testAFileOverHermessSizeLimitKeepsTheShareQueuedWithTheLimitReason() async throws {
        let copies = BotAttachmentCopies()
        let store = drafts(BotMemoryDrafts(), copies)
        let (chat, key) = newSession()
        let large = SharedAttachmentImport(filename: "scan.pdf", typeIdentifier: "com.adobe.pdf",
                                           data: Data(count: 30 * 1024 * 1024))

        do {
            try await reservation("Read this", [large]).transfer(
                into: chat, drafts: store, route: { _ in XCTFail("It is never let go") })
            XCTFail("A file over 25 MB is not moved")
        } catch {
            XCTAssertEqual(error as? BotAttachmentFailure, .limit)
        }
        let draft = await store.draft(for: key)
        XCTAssertNil(draft)
        let kept = await copies.count
        XCTAssertEqual(kept, 0)
    }

    /// A share moving into one Hermes server's draft is offered to no home until that move ends,
    /// so switching servers mid-write can't open it into a second server's draft: the first
    /// server's draft takes it and it is consumed once.
    @MainActor
    func testAShareMovingIntoOneServersDraftIsNotOpenedOnAnother() async throws {
        let other = URL(string: "https://other.example:9119")!
        let servers = [account(hermes, .hermes), account(other, .hermes)]
        let inbox = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Read this", in: inbox)
        let shares = QueueBox()
        shares.queue.reserveNext(in: inbox, active: hermes, servers: servers)
        let share = try XCTUnwrap(shares.queue.pending)
        let disk = PausingDrafts()
        let store = ChatDraftStore(persistence: disk, attachmentStore: BotAttachmentCopies(), debounceDuration: .seconds(3600))
        let (chat, key) = newSession()
        let routed = Tally()

        XCTAssertTrue(shares.queue.claim(share))
        await disk.pauseNextWrite()
        let move = Task {
            try await share.transfer(into: chat, drafts: store, route: {
                routed.count += 1
                shares.queue.consume($0, in: inbox, active: other, servers: servers)
            })
        }
        await disk.waitUntilPaused()
        // The user switches to the other server while the draft is being written.
        move.cancel()
        shares.queue.reserveNext(in: inbox, active: other, servers: servers)
        XCTAssertNil(shares.queue.pending, "The other server's home is offered nothing while the move runs")
        XCTAssertFalse(shares.queue.claim(share), "Nor can it start a second move")
        await disk.resume()
        try await move.value

        XCTAssertEqual(routed.count, 1)
        XCTAssertNil(shares.queue.pending)
        XCTAssertNil(try HermesShareDraft.reserveNextPendingImport(from: inbox), "The share is consumed")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Read this\n")
    }

    /// A move cut short before the draft took the share frees it for any home at once; one the
    /// draft couldn't take is queued again for the next home to reserve.
    func testAShareWhoseMoveEndsOutsideTheDraftIsOfferedAgain() throws {
        let other = URL(string: "https://other.example:9119")!
        let servers = [account(hermes, .hermes), account(other, .hermes)]
        let inbox = try temporaryDirectory()
        try HermesShareDraft.savePendingDraft("Read this", in: inbox)
        var queue = SharedImportQueue()
        queue.reserveNext(in: inbox, active: hermes, servers: servers)
        let share = try XCTUnwrap(queue.pending)

        XCTAssertTrue(queue.claim(share))
        XCTAssertNil(queue.pending)
        queue.abandon(share)
        XCTAssertEqual(queue.pending?.reservationID, share.reservationID, "Any server's home may open it again")

        XCTAssertTrue(queue.claim(share))
        queue.release(share, in: inbox)
        queue.reserveNext(in: inbox, active: other, servers: servers)
        XCTAssertEqual(queue.pending?.itemID, share.itemID, "The other server's home takes the released share")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func attachmentFileURLs(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        return enumerator.compactMap { element in
            guard
                let url = element as? URL,
                url.pathExtension != "json",
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
    }
}

/// Draft copies whose next write waits for `resume`, so a test can cut a share's move short.
private actor PausingCopies: ChatDraftAttachmentStoring {
    private let copies = BotAttachmentCopies()
    private var saved: (() -> Void)?
    private var paused: CheckedContinuation<Void, Never>?
    private var isResumed = false
    var count: Int { get async { await copies.count } }

    func onSave(_ saved: @escaping () -> Void) { self.saved = saved }
    func resume() {
        isResumed = true
        paused?.resume()
        paused = nil
    }

    func save(data: Data, suggestedFilename: String) async throws -> String {
        saved?()
        saved = nil
        if !isResumed { await withCheckedContinuation { paused = $0 } }
        return await copies.save(data: data, suggestedFilename: suggestedFilename)
    }
    func retainedFileBytes() async throws -> [String: Int] { try await copies.retainedFileBytes() }
    func data(named fileName: String) async throws -> Data { try await copies.data(named: fileName) }
    func fileURL(named fileName: String) async throws -> URL { try await copies.fileURL(named: fileName) }
    func delete(named fileName: String) async { await copies.delete(named: fileName) }
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}
}

@MainActor private final class QueueBox {
    var queue = SharedImportQueue()
}

@MainActor private final class Tally {
    var count = 0
}

/// Draft persistence whose next write, once armed, waits for `resume`, so a test can act while
/// a share's write is in flight.
private actor PausingDrafts: ChatDraftPersisting {
    private(set) var values: [ChatDraftKey: ChatDraft] = [:]
    private var pausesNextWrite = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    func pauseNextWrite() { pausesNextWrite = true }
    func waitUntilPaused() async {
        guard paused == nil else { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resume() {
        paused?.resume()
        paused = nil
    }

    func load() -> [ChatDraftKey: ChatDraft] { values }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) async {
        if pausesNextWrite {
            pausesNextWrite = false
            pauseWaiter?.resume()
            pauseWaiter = nil
            await withCheckedContinuation { paused = $0 }
        }
        values = drafts
    }
}
