import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatDraftStoreTests: XCTestCase {
    func testDraftsAreIsolatedByServerAndContext() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let serverA = URL(string: "https://one.example.com")!
        let serverB = URL(string: "https://two.example.com")!
        let firstChat = ChatDraftKey.session(server: serverA, sessionID: "chat-1")
        let secondChat = ChatDraftKey.session(server: serverA, sessionID: "chat-2")
        let otherServerChat = ChatDraftKey.session(server: serverB, sessionID: "chat-1")
        let newChat = ChatDraftKey.newChat(server: serverA)

        store.setDraft("First", for: firstChat)
        store.setDraft("Second", for: secondChat)
        store.setDraft("Other server", for: otherServerChat)
        store.setDraft("New chat", for: newChat)
        try await store.flush()

        let restoredStore = ChatDraftStore(
            persistence: persistence,
            debounceDuration: .seconds(10)
        )
        let restoredFirstChat = await restoredStore.draft(for: firstChat)
        let restoredSecondChat = await restoredStore.draft(for: secondChat)
        let restoredOtherServerChat = await restoredStore.draft(for: otherServerChat)
        let restoredNewChat = await restoredStore.draft(for: newChat)
        XCTAssertEqual(restoredFirstChat?.text, "First")
        XCTAssertEqual(restoredSecondChat?.text, "Second")
        XCTAssertEqual(restoredOtherServerChat?.text, "Other server")
        XCTAssertEqual(restoredNewChat?.text, "New chat")
    }

    func testTypingDuringHydrationWinsOverPersistedText() async throws {
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let persistence = BlockingChatDraftPersistence(initialDrafts: [key: ChatDraft(text: "Persisted")])
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))

        let hydration = Task { await store.draft(for: key) }
        await persistence.waitUntilLoadStarts()
        store.setDraft("Typed while loading", for: key)
        await persistence.releaseLoad()

        let hydratedDraft = await hydration.value
        XCTAssertEqual(hydratedDraft?.text, "Typed while loading")
        try await store.flush()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(persistedDrafts[key]?.text, "Typed while loading")
    }

    func testDebouncedEditsFlushAsOneLatestWrite() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("a", for: key)
        store.setDraft("ab", for: key)
        store.setDraft("abc", for: key)
        try await store.flush()

        let writeCount = await persistence.writeCount()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(persistedDrafts[key]?.text, "abc")
    }

    func testFlushLandsAStillDebouncedWrite() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("Typed before backgrounding", for: key)
        try await store.flush()

        let writeCount = await persistence.writeCount()
        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(persistedDrafts[key]?.text, "Typed before backgrounding")
    }

    func testNewChatDraftMovesToCreatedSession() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let server = URL(string: "https://example.com")!
        let newChat = ChatDraftKey.newChat(server: server)
        let createdChat = ChatDraftKey.session(server: server, sessionID: "created-chat")

        store.setDraft("Carry this forward", for: newChat)
        XCTAssertEqual(
            store.moveDraft(from: newChat, to: createdChat).text,
            "Carry this forward"
        )
        try await store.flush()

        let restoredNewChat = await store.draft(for: newChat)
        let restoredCreatedChat = await store.draft(for: createdChat)
        XCTAssertNil(restoredNewChat)
        XCTAssertEqual(restoredCreatedChat?.text, "Carry this forward")
    }

    func testAbandonedCreatedChatDraftReturnsToNewChat() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let server = URL(string: "https://example.com")!
        let newChat = ChatDraftKey.newChat(server: server)
        let createdChat = ChatDraftKey.session(server: server, sessionID: "created-chat")

        store.setDraft("Started before creation", for: newChat)
        _ = store.moveDraft(from: newChat, to: createdChat)
        store.setDraft("Typed after creation", for: createdChat)

        XCTAssertEqual(
            store.restoreAbandonedNewChatDraft(
                from: createdChat,
                to: newChat,
                didStartConversation: false
            )?.text,
            "Typed after creation"
        )
        let abandonedSessionDraft = await store.draft(for: createdChat)
        let restoredNewChatDraft = await store.draft(for: newChat)
        XCTAssertNil(abandonedSessionDraft)
        XCTAssertEqual(restoredNewChatDraft?.text, "Typed after creation")

        _ = store.moveDraft(from: newChat, to: createdChat)
        store.setDraft("Follow-up for the started chat", for: createdChat)

        XCTAssertNil(
            store.restoreAbandonedNewChatDraft(
                from: createdChat,
                to: newChat,
                didStartConversation: true
            )
        )
        let startedSessionDraft = await store.draft(for: createdChat)
        let startedNewChatDraft = await store.draft(for: newChat)
        XCTAssertEqual(startedSessionDraft?.text, "Follow-up for the started chat")
        XCTAssertNil(startedNewChatDraft)
    }

    func testAbandonedCreatedChatDraftCarriesAttachmentsAndSettingsBackToNewChat() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let server = URL(string: "https://example.com")!
        let newChat = ChatDraftKey.newChat(server: server)
        let createdChat = ChatDraftKey.session(server: server, sessionID: "created-chat")
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(
            modelID: "model-x",
            modelProviderID: "provider-y",
            reasoningEffort: "high",
            profileName: "work",
            workspacePath: "/repo"
        )

        store.setDraft("Draft with picks", for: newChat)
        _ = store.moveDraft(from: newChat, to: createdChat)
        store.setAttachments([attachment], for: createdChat)
        store.setSettings(settings, for: createdChat)

        let restored = store.restoreAbandonedNewChatDraft(
            from: createdChat,
            to: newChat,
            didStartConversation: false
        )

        XCTAssertEqual(restored?.text, "Draft with picks")
        XCTAssertEqual(restored?.attachments, [attachment])
        XCTAssertEqual(restored?.settings, settings)
        let abandonedSessionDraft = await store.draft(for: createdChat)
        let restoredNewChatDraft = await store.draft(for: newChat)
        XCTAssertNil(abandonedSessionDraft)
        XCTAssertEqual(restoredNewChatDraft?.attachments, [attachment])
        XCTAssertEqual(restoredNewChatDraft?.settings, settings)
    }

    func testSubmissionFailureRestoresExactSnapshotAndSuccessClearsIt() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let submitted = "  Preserve spacing\nexactly  "

        store.setDraft(submitted, for: key)
        let restored = store.resolveSubmission(
            submittedText: submitted,
            currentText: "",
            didStart: false,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(restored, submitted)
        let restoredDraft = await store.draft(for: key)
        XCTAssertEqual(restoredDraft?.text, submitted)

        let cleared = store.resolveSubmission(
            submittedText: submitted,
            currentText: "",
            didStart: true,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(cleared, "")
        let clearedDraft = await store.draft(for: key)
        XCTAssertNil(clearedDraft)
    }

    func testFailedSubmissionKeepsAttachmentsStaged() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let attachment = Self.sampleAttachment()

        store.setDraft("Prompt", for: key)
        store.setAttachments([attachment], for: key)
        let restored = store.resolveSubmission(
            submittedText: "Prompt",
            currentText: "",
            didStart: false,
            draftWasEdited: false,
            for: key
        )

        XCTAssertEqual(restored, "Prompt")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Prompt")
        XCTAssertEqual(draft?.attachments, [attachment])
    }

    func testAcceptedSubmissionClearsContentButRetainsSettings() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x", workspacePath: "/repo")

        store.setDraft("Prompt", for: key)
        store.setAttachments([attachment], for: key)
        store.setSettings(settings, for: key)
        let result = store.resolveSubmission(
            submittedText: "Prompt",
            currentText: "",
            didStart: true,
            draftWasEdited: false,
            for: key
        )

        XCTAssertEqual(result, "")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft, ChatDraft(text: "", attachments: [], settings: settings))
    }

    func testTextEnteredDuringSendIsNeverClearedOrReplaced() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("New text", for: key)
        XCTAssertEqual(
            store.resolveSubmission(
                submittedText: "Submitted text",
                currentText: "New text",
                didStart: true,
                draftWasEdited: true,
                for: key
            ),
            "New text"
        )
        XCTAssertEqual(
            store.resolveSubmission(
                submittedText: "Submitted text",
                currentText: "New text",
                didStart: false,
                draftWasEdited: true,
                for: key
            ),
            "New text"
        )
        let currentDraft = await store.draft(for: key)
        XCTAssertEqual(currentDraft?.text, "New text")

        store.clearDraft(for: key)
        let editedBackToEmpty = store.resolveSubmission(
            submittedText: "Submitted text",
            currentText: "",
            didStart: false,
            draftWasEdited: true,
            for: key
        )
        XCTAssertEqual(editedBackToEmpty, "")
        let emptyDraft = await store.draft(for: key)
        XCTAssertNil(emptyDraft)
    }

    func testAcceptedSubmissionWhileEditedKeepsNewTextButStillClearsAttachments() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let attachment = Self.sampleAttachment()

        store.setDraft("Submitted text", for: key)
        store.setAttachments([attachment], for: key)
        // The composer binding writes every edit through, so by the time the
        // send resolves the store already holds the newer text.
        store.setDraft("New text", for: key)

        let result = store.resolveSubmission(
            submittedText: "Submitted text",
            currentText: "New text",
            didStart: true,
            draftWasEdited: true,
            for: key
        )

        XCTAssertEqual(result, "New text")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "New text")
        XCTAssertEqual(draft?.attachments, [])
    }

    func testNewComposerRevisionIsNotClearedEvenWhenTextMatchesConsumedInput() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setDraft("/status", for: key)
        let retained = store.resolveConsumedInput(
            submittedText: "/status",
            currentText: "/status",
            draftWasEdited: true,
            for: key
        )
        XCTAssertEqual(retained, "/status")
        let retainedDraft = await store.draft(for: key)
        XCTAssertEqual(retainedDraft?.text, "/status")

        store.setDraft("/status", for: key)
        let cleared = store.resolveConsumedInput(
            submittedText: "/status",
            currentText: "/status",
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(cleared, "")
        let clearedDraft = await store.draft(for: key)
        XCTAssertNil(clearedDraft)
    }

    func testConsumedInputClearsTextButRetainsAttachmentsAndSettings() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x")

        store.setDraft("/queue follow-up", for: key)
        store.setAttachments([attachment], for: key)
        store.setSettings(settings, for: key)
        let cleared = store.resolveConsumedInput(
            submittedText: "/queue follow-up",
            currentText: "/queue follow-up",
            draftWasEdited: false,
            for: key
        )

        XCTAssertEqual(cleared, "")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "")
        XCTAssertEqual(draft?.attachments, [attachment])
        XCTAssertEqual(draft?.settings, settings)
    }

    func testAttachmentAndSettingsUpdatesDoNotDisturbEachOtherOrText() async {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x", reasoningEffort: "low")

        store.setDraft("Keep me", for: key)
        store.setAttachments([attachment], for: key)
        store.setSettings(settings, for: key)

        var draft = await store.draft(for: key)
        XCTAssertEqual(draft, ChatDraft(text: "Keep me", attachments: [attachment], settings: settings))

        store.setDraft("Keep me edited", for: key)
        draft = await store.draft(for: key)
        XCTAssertEqual(draft, ChatDraft(text: "Keep me edited", attachments: [attachment], settings: settings))

        store.setAttachments([], for: key)
        draft = await store.draft(for: key)
        XCTAssertEqual(draft, ChatDraft(text: "Keep me edited", attachments: [], settings: settings))
    }

    func testSettingsOnlyDraftPersists() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        store.setSettings(ChatDraftSettings(workspacePath: "/repo"), for: key)
        try await store.flush()

        let persistedDrafts = await persistence.latestDrafts()
        XCTAssertEqual(persistedDrafts[key]?.settings?.workspacePath, "/repo")
        XCTAssertEqual(persistedDrafts[key]?.text, "")
        XCTAssertEqual(persistedDrafts[key]?.attachments, [])
    }

    func testLoadSweepsOrphanedAttachmentFilesKeepingReferencedOnes() async {
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let referenced = Self.sampleAttachment(file: "referenced-copy.jpg")
        let persistence = RecordingChatDraftPersistence(
            initialDrafts: [key: ChatDraft(text: "Body", attachments: [referenced])]
        )
        let attachmentStore = RecordingChatDraftAttachmentStore()
        let store = ChatDraftStore(
            persistence: persistence,
            attachmentStore: attachmentStore,
            debounceDuration: .seconds(10),
            attachmentSweepMaxAge: 60
        )

        _ = await store.draft(for: key)

        let sweep = await attachmentStore.waitForSweep()
        XCTAssertEqual(sweep?.referenced, ["referenced-copy.jpg"])
        XCTAssertEqual(sweep?.maxAge, 60)
    }

    func testDiscardDraftDeletesItsAttachmentCopiesAndKeepsOtherDrafts() async {
        let server = URL(string: "https://one.example")!
        let firstKey = ChatDraftKey.session(server: server, sessionID: "session-1")
        let secondKey = ChatDraftKey.session(server: server, sessionID: "session-2")
        let persistence = RecordingChatDraftPersistence(initialDrafts: [
            firstKey: ChatDraft(
                text: "discard me",
                attachments: [Self.sampleAttachment(file: "first.txt")]
            ),
            secondKey: ChatDraft(
                text: "keep me",
                attachments: [Self.sampleAttachment(file: "second.txt")]
            )
        ])
        let attachmentStore = RecordingChatDraftAttachmentStore()
        let store = ChatDraftStore(
            persistence: persistence,
            attachmentStore: attachmentStore,
            debounceDuration: .zero
        )

        await store.discardDraft(for: firstKey)
        try? await store.flush()

        let firstDraft = await store.draft(for: firstKey)
        let secondDraft = await store.draft(for: secondKey)
        let deletedNames = await attachmentStore.deletedNames()
        XCTAssertNil(firstDraft)
        XCTAssertEqual(secondDraft?.text, "keep me")
        XCTAssertEqual(deletedNames, ["first.txt"])
    }

    func testDiscardDraftsForServerDeletesOnlyThatServersCopies() async {
        let firstServer = URL(string: "https://one.example")!
        let secondServer = URL(string: "https://two.example")!
        let firstKey = ChatDraftKey.session(server: firstServer, sessionID: "session-1")
        let secondKey = ChatDraftKey.session(server: secondServer, sessionID: "session-2")
        let persistence = RecordingChatDraftPersistence(initialDrafts: [
            firstKey: ChatDraft(attachments: [Self.sampleAttachment(file: "first.txt")]),
            secondKey: ChatDraft(attachments: [Self.sampleAttachment(file: "second.txt")])
        ])
        let attachmentStore = RecordingChatDraftAttachmentStore()
        let store = ChatDraftStore(
            persistence: persistence,
            attachmentStore: attachmentStore,
            debounceDuration: .zero
        )

        await store.discardDrafts(for: firstServer)
        try? await store.flush()

        let firstDraft = await store.draft(for: firstKey)
        let secondDraft = await store.draft(for: secondKey)
        let deletedNames = await attachmentStore.deletedNames()
        XCTAssertNil(firstDraft)
        XCTAssertEqual(secondDraft?.attachments.first?.file, "second.txt")
        XCTAssertEqual(deletedNames, ["first.txt"])
    }

    // MARK: - Send reconciliation

    /// The bug this guards: a send used to discard every record the draft held,
    /// deleting durable copies for attachments it never carried.
    func testSendConsumesOnlyTheAttachmentsStagedInTheComposer() {
        let staged = makeAttachmentRecord(name: "carried.txt", file: "a-carried.txt")
        let awaitingRetry = makeAttachmentRecord(name: "retry.txt", file: "b-retry.txt")
        let notYetRestored = makeAttachmentRecord(name: "restoring.txt", file: "c-restoring.txt")

        let outcome = ChatDraftSendReconciliation.outcome(
            draftRecords: [staged, awaitingRetry, notYetRestored],
            stagedAttachmentIDs: [staged.id]
        )

        XCTAssertEqual(outcome.consumed.map(\.id), [staged.id])
        XCTAssertEqual(outcome.retained.map(\.id), [awaitingRetry.id, notYetRestored.id])
    }

    /// Sending while a restore has staged nothing yet must not consume — and so
    /// must not delete the local copies of — any record.
    func testSendDuringAnUnstartedRestoreConsumesNothing() {
        let records = [
            makeAttachmentRecord(name: "one.txt", file: "a-one.txt"),
            makeAttachmentRecord(name: "two.txt", file: "b-two.txt")
        ]

        let outcome = ChatDraftSendReconciliation.outcome(
            draftRecords: records,
            stagedAttachmentIDs: []
        )

        XCTAssertTrue(outcome.consumed.isEmpty)
        XCTAssertEqual(outcome.retained.map(\.id), records.map(\.id))
    }

    func testSendConsumesEveryRecordWhenAllAreStaged() {
        let records = [
            makeAttachmentRecord(name: "one.txt", file: "a-one.txt"),
            makeAttachmentRecord(name: "two.txt", file: "b-two.txt")
        ]

        let outcome = ChatDraftSendReconciliation.outcome(
            draftRecords: records,
            stagedAttachmentIDs: Set(records.map(\.id))
        )

        XCTAssertEqual(outcome.consumed.map(\.id), records.map(\.id))
        XCTAssertTrue(outcome.retained.isEmpty)
    }

    /// A staged attachment the draft never recorded (its durable copy failed to
    /// write) contributes nothing to either side.
    func testSendIgnoresStagedAttachmentsWithNoDraftRecord() {
        let recorded = makeAttachmentRecord(name: "recorded.txt", file: "a-recorded.txt")

        let outcome = ChatDraftSendReconciliation.outcome(
            draftRecords: [recorded],
            stagedAttachmentIDs: [recorded.id, UUID()]
        )

        XCTAssertEqual(outcome.consumed.map(\.id), [recorded.id])
        XCTAssertTrue(outcome.retained.isEmpty)
    }

    private func makeAttachmentRecord(name: String, file: String?) -> ChatDraftAttachment {
        ChatDraftAttachment(
            id: UUID(),
            name: name,
            mime: "text/plain",
            size: 5,
            isImage: false,
            file: file
        )
    }

    func testFilePersistenceUsesVersionedLossyDecoding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let fileURL = directory
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = """
        {
          "version": 1,
          "drafts": [
            {
              "serverID": "https://example.com",
              "context": "session",
              "sessionID": "valid-chat",
              "text": "Keep this",
              "futureField": true
            },
            {
              "serverID": 42,
              "context": "session",
              "sessionID": "invalid-chat",
              "text": "Ignore this"
            },
            {
              "serverID": "https://example.com",
              "context": "future-context",
              "text": "Ignore this too"
            }
          ],
          "futureDocumentField": "ignored"
        }
        """
        try Data(document.utf8).write(to: fileURL, options: [.atomic])

        let drafts = await persistence.load()

        XCTAssertEqual(
            drafts[
                ChatDraftKey(
                    serverID: "https://example.com",
                    context: .session("valid-chat")
                )
            ]?.text,
            "Keep this"
        )
        XCTAssertEqual(drafts.count, 1)
    }

    func testFilePersistenceRoundTripsAttachmentsAndSettings() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )
        let draft = ChatDraft(
            text: "Body",
            attachments: [
                Self.sampleAttachment(),
                Self.sampleAttachment(file: nil)
            ],
            settings: ChatDraftSettings(
                modelID: "model-x",
                modelProviderID: "provider-y",
                reasoningEffort: "high",
                profileName: "work",
                workspacePath: "/repo"
            )
        )

        try await persistence.write([key: draft])

        let loaded = await persistence.load()
        XCTAssertEqual(loaded[key], draft)
    }

    func testFilePersistenceDropsMalformedAttachmentButKeepsDraft() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let fileURL = directory
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let goodID = UUID().uuidString
        let document = """
        {
          "version": 2,
          "drafts": [
            {
              "serverID": "https://example.com",
              "context": "session",
              "sessionID": "chat-1",
              "text": "Keep this",
              "attachments": [
                {
                  "id": "\(goodID)",
                  "name": "photo.jpg",
                  "mime": "image/jpeg",
                  "size": 123,
                  "isImage": true,
                  "file": "abc-photo.jpg"
                },
                { "id": 42, "name": "broken" },
                "not an object"
              ]
            }
          ]
        }
        """
        try Data(document.utf8).write(to: fileURL, options: [.atomic])

        let drafts = await persistence.load()
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        let draft = try XCTUnwrap(drafts[key])
        XCTAssertEqual(draft.text, "Keep this")
        XCTAssertEqual(draft.attachments.count, 1)
        XCTAssertEqual(draft.attachments.first?.id.uuidString, goodID)
        XCTAssertEqual(draft.attachments.first?.file, "abc-photo.jpg")
    }

    func testFilePersistenceSanitizesAttachmentFileNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let fileURL = directory
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = """
        {
          "version": 2,
          "drafts": [
            {
              "serverID": "https://example.com",
              "context": "session",
              "sessionID": "chat-1",
              "text": "",
              "attachments": [
                {
                  "id": "\(UUID().uuidString)",
                  "name": "photo.jpg",
                  "mime": "image/jpeg",
                  "file": "../drafts.json"
                }
              ]
            }
          ]
        }
        """
        try Data(document.utf8).write(to: fileURL, options: [.atomic])

        let drafts = await persistence.load()
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .session("chat-1")
        )

        // A traversal attempt degrades the record to metadata-only; the
        // attachment itself (and its name) still round-trips.
        let attachment = try XCTUnwrap(drafts[key]?.attachments.first)
        XCTAssertEqual(attachment.name, "photo.jpg")
        XCTAssertNil(attachment.file)
    }

    func testFilePersistenceIgnoresFutureDocumentVersions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let fileURL = directory
            .appendingPathComponent("ChatDrafts", isDirectory: true)
            .appendingPathComponent("drafts.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = """
        {
          "version": 99,
          "drafts": [
            {
              "serverID": "https://example.com",
              "context": "session",
              "sessionID": "chat-1",
              "text": "From the future"
            }
          ]
        }
        """
        try Data(document.utf8).write(to: fileURL, options: [.atomic])

        let drafts = await persistence.load()
        XCTAssertTrue(drafts.isEmpty)
    }

    func testFilePersistenceWritesAtomicallyWithFileProtection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let key = ChatDraftKey(
            serverID: "https://example.com",
            context: .newChat
        )

        try await persistence.write([key: ChatDraft(text: "Protected prompt")])

        let restoredDrafts = await persistence.load()
        XCTAssertEqual(restoredDrafts[key]?.text, "Protected prompt")
        #if os(iOS)
        XCTAssertEqual(
            ChatDraftFilePersistence.fileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    private static func sampleAttachment(
        file: String? = "copy-photo.jpg"
    ) -> ChatDraftAttachment {
        ChatDraftAttachment(
            id: UUID(),
            name: "photo.jpg",
            mime: "image/jpeg",
            size: 123,
            isImage: true,
            file: file
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private actor RecordingChatDraftPersistence: ChatDraftPersisting {
    private var drafts: [ChatDraftKey: ChatDraft]
    private var writes = 0

    init(initialDrafts: [ChatDraftKey: ChatDraft] = [:]) {
        drafts = initialDrafts
    }

    func load() async -> [ChatDraftKey: ChatDraft] {
        drafts
    }

    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {
        self.drafts = drafts
        writes += 1
    }

    func latestDrafts() -> [ChatDraftKey: ChatDraft] {
        drafts
    }

    func writeCount() -> Int {
        writes
    }
}

private actor BlockingChatDraftPersistence: ChatDraftPersisting {
    private let initialDrafts: [ChatDraftKey: ChatDraft]
    private var latest: [ChatDraftKey: ChatDraft]
    private var loadStarted = false
    private var loadStartContinuation: CheckedContinuation<Void, Never>?
    private var loadReleaseContinuation: CheckedContinuation<Void, Never>?

    init(initialDrafts: [ChatDraftKey: ChatDraft]) {
        self.initialDrafts = initialDrafts
        latest = initialDrafts
    }

    func load() async -> [ChatDraftKey: ChatDraft] {
        loadStarted = true
        loadStartContinuation?.resume()
        loadStartContinuation = nil
        await withCheckedContinuation { continuation in
            loadReleaseContinuation = continuation
        }
        return initialDrafts
    }

    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {
        latest = drafts
    }

    func waitUntilLoadStarts() async {
        guard !loadStarted else { return }
        await withCheckedContinuation { continuation in
            loadStartContinuation = continuation
        }
    }

    func releaseLoad() {
        loadReleaseContinuation?.resume()
        loadReleaseContinuation = nil
    }

    func latestDrafts() -> [ChatDraftKey: ChatDraft] {
        latest
    }
}

private actor RecordingChatDraftAttachmentStore: ChatDraftAttachmentStoring {
    private var sweeps: [(referenced: Set<String>, maxAge: TimeInterval)] = []
    private var sweepContinuations: [CheckedContinuation<Void, Never>] = []
    private var deletes: [String] = []

    func save(data: Data, suggestedFilename: String) async throws -> String {
        suggestedFilename
    }

    func data(named fileName: String) async throws -> Data {
        Data()
    }

    func delete(named fileName: String) async {
        deletes.append(fileName)
    }

    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {
        sweeps.append((fileNames, maxAge))
        let continuations = sweepContinuations
        sweepContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForSweep() async -> (referenced: Set<String>, maxAge: TimeInterval)? {
        if let first = sweeps.first {
            return first
        }
        await withCheckedContinuation { continuation in
            sweepContinuations.append(continuation)
        }
        return sweeps.first
    }

    func deletedNames() -> [String] {
        deletes
    }
}
