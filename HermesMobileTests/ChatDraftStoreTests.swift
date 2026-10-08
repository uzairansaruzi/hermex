import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class ChatDraftStoreTests: XCTestCase {
    func testLateRejectedAttachmentsMergeWithoutReplacingNewerDraftWork() async {
        let store = ChatDraftStore(persistence: RecordingChatDraftPersistence(), debounceDuration: .seconds(10))
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("sealed"))
        let rejected = Self.sampleAttachment(file: "rejected.jpg")
        let newer = Self.sampleAttachment(file: "newer.jpg")
        store.setDraft("Newer work", for: key)
        store.setAttachments([newer], for: key)
        store.retainRejectedAttachments([rejected, newer], for: key)
        store.retainRejectedAttachments([rejected], for: key)
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.text, "Newer work")
        XCTAssertEqual(draft?.attachments, [newer, rejected])
    }

    func testRotatedRejectionPreservesSubmittedAndConcurrentContent() async {
        let store = ChatDraftStore(persistence: RecordingChatDraftPersistence(), debounceDuration: .seconds(10))
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("sealed"))
        let submitted = ComposerDraftContent(text: "  Submitted  ", quotes: [ComposerQuote(text: "Original")])
        let current = ComposerDraftContent(text: "New edits", quotes: [ComposerQuote(text: "New quote")])
        let result = store.resolveSubmission(submitted: submitted, current: current, didStart: false,
                                             draftWasEdited: true, preserveRejectedSubmission: true, for: key)
        XCTAssertEqual(result.text, "  Submitted  \n\nNew edits")
        XCTAssertEqual(result.quotes, submitted.quotes + current.quotes)
        let durable = await store.draft(for: key)
        XCTAssertEqual(durable?.text, result.text)
        XCTAssertEqual(durable?.quotes, result.quotes)
        let clearedWhileSending = store.resolveSubmission(submitted: submitted, current: .empty, didStart: false,
                                                          draftWasEdited: true, preserveRejectedSubmission: true, for: key)
        XCTAssertEqual(clearedWhileSending, submitted)
    }

    func testQuotesAreOrderedAndIsolatedByServerAndSession() async throws {
        let persistence = RecordingChatDraftPersistence()
        let store = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let first = ChatDraftKey.session(
            server: URL(string: "https://one.example")!,
            sessionID: "shared"
        )
        let second = ChatDraftKey.session(
            server: URL(string: "https://two.example")!,
            sessionID: "shared"
        )
        let otherSession = ChatDraftKey.session(
            server: URL(string: "https://one.example")!,
            sessionID: "other"
        )
        let repeated = ComposerQuote(text: "Same passage")
        let firstQuotes = [repeated, ComposerQuote(text: "Same passage")]
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x", workspacePath: "/repo")

        store.setDraft("Keep text", for: first)
        store.setAttachments([attachment], for: first)
        store.setSettings(settings, for: first)
        store.setQuotes(firstQuotes, for: first)
        store.setQuotes([ComposerQuote(text: "Other server")], for: second)
        store.setQuotes([ComposerQuote(text: "Other session")], for: otherSession)
        try await store.flush()

        let restored = ChatDraftStore(persistence: persistence, debounceDuration: .seconds(10))
        let restoredFirst = await restored.draft(for: first)
        let restoredSecond = await restored.draft(for: second)
        let restoredOtherSession = await restored.draft(for: otherSession)
        XCTAssertEqual(restoredFirst?.quotes, firstQuotes)
        XCTAssertEqual(restoredFirst?.text, "Keep text")
        XCTAssertEqual(restoredFirst?.attachments, [attachment])
        XCTAssertEqual(restoredFirst?.settings, settings)
        XCTAssertEqual(restoredSecond?.quotes.map(\.text), ["Other server"])
        XCTAssertEqual(restoredOtherSession?.quotes.map(\.text), ["Other session"])
    }

    func testFailedQuoteSubmissionRestoresSnapshotAndAnInFlightEditWins() async {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("chat-1"))
        let submitted = ComposerDraftContent(
            text: "Question",
            quotes: [ComposerQuote(text: "Original quote")]
        )
        store.setContent(submitted, for: key)

        let restored = store.resolveSubmission(
            submitted: submitted,
            current: .empty,
            didStart: false,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(restored, submitted)
        let restoredDraft = await store.draft(for: key)
        XCTAssertEqual(restoredDraft?.quotes, submitted.quotes)

        let edited = ComposerDraftContent(
            text: "Typed while sending",
            quotes: submitted.quotes + [ComposerQuote(text: "New quote")]
        )
        store.setContent(edited, for: key)
        let retained = store.resolveSubmission(
            submitted: submitted,
            current: edited,
            didStart: true,
            draftWasEdited: true,
            for: key
        )
        XCTAssertEqual(retained, edited)
        let editedDraft = await store.draft(for: key)
        XCTAssertEqual(editedDraft?.quotes, edited.quotes)
    }

    func testSuccessfulQuoteSubmissionConsumesSnapshotAndAttachmentsButKeepsSettings() async {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("chat-1"))
        let submitted = ComposerDraftContent(
            text: "Question",
            quotes: [ComposerQuote(text: "Quoted passage")]
        )
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x", workspacePath: "/repo")
        store.setContent(submitted, for: key)
        store.setAttachments([attachment], for: key)
        store.setSettings(settings, for: key)

        let resolved = store.resolveSubmission(
            submitted: submitted,
            current: .empty,
            didStart: true,
            draftWasEdited: false,
            for: key
        )

        XCTAssertEqual(resolved, .empty)
        let stored = await store.draft(for: key)
        assertDraftContentEqual(stored, ChatDraft(settings: settings))
    }

    func testActiveStreamConsumptionClearsQuoteSnapshotUnlessComposerRevisionChanged() async {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("chat-1"))
        let submitted = ComposerDraftContent(
            text: "Follow up",
            quotes: [ComposerQuote(text: "Original passage")]
        )
        let attachment = Self.sampleAttachment()
        let settings = ChatDraftSettings(modelID: "model-x")
        store.setContent(submitted, for: key)
        store.setAttachments([attachment], for: key)
        store.setSettings(settings, for: key)

        let consumed = store.resolveConsumedInput(
            submitted: submitted,
            current: submitted,
            draftWasEdited: false,
            for: key
        )
        XCTAssertEqual(consumed, .empty)
        var stored = await store.draft(for: key)
        assertDraftContentEqual(stored, ChatDraft(attachments: [attachment], settings: settings))

        store.setContent(submitted, for: key)
        let revised = ComposerDraftContent(
            text: submitted.text,
            quotes: submitted.quotes + [ComposerQuote(text: "Appended while sending")]
        )
        store.setContent(revised, for: key)
        let retained = store.resolveConsumedInput(
            submitted: submitted,
            current: revised,
            draftWasEdited: true,
            for: key
        )

        XCTAssertEqual(retained, revised)
        stored = await store.draft(for: key)
        XCTAssertEqual(stored?.text, revised.text)
        XCTAssertEqual(stored?.quotes, revised.quotes)
        XCTAssertEqual(stored?.attachments, [attachment])
        XCTAssertEqual(stored?.settings, settings)
    }

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

        let quotes = [ComposerQuote(text: "Carry this quote forward")]
        store.setContent(
            ComposerDraftContent(text: "Carry this forward", quotes: quotes),
            for: newChat
        )
        let movedDraft = store.moveDraft(from: newChat, to: createdChat)
        XCTAssertEqual(movedDraft.text, "Carry this forward")
        XCTAssertEqual(movedDraft.quotes, quotes)
        try await store.flush()

        let restoredNewChat = await store.draft(for: newChat)
        let restoredCreatedChat = await store.draft(for: createdChat)
        XCTAssertNil(restoredNewChat)
        XCTAssertEqual(restoredCreatedChat?.text, "Carry this forward")
        XCTAssertEqual(restoredCreatedChat?.quotes, quotes)
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
        assertDraftContentEqual(draft, ChatDraft(text: "", attachments: [], settings: settings))
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
        assertDraftContentEqual(draft, ChatDraft(text: "Keep me", attachments: [attachment], settings: settings))

        store.setDraft("Keep me edited", for: key)
        draft = await store.draft(for: key)
        assertDraftContentEqual(draft, ChatDraft(text: "Keep me edited", attachments: [attachment], settings: settings))

        store.setAttachments([], for: key)
        draft = await store.draft(for: key)
        assertDraftContentEqual(draft, ChatDraft(text: "Keep me edited", attachments: [], settings: settings))
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

    // MARK: - Parking queued messages (#857)

    /// Files without a durable copy go back to the composer but aren't
    /// recorded: nothing could restore them on reopen.
    func testQueuedMessagesMergeIntoEmptyDraft() async {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("chat-1"))
        let photo = makeQueuedFile("photo.jpg", draftFileName: "a-photo.jpg")
        let noCopy = makeQueuedFile("voice.m4a", draftFileName: nil)

        let parked = store.parkQueuedMessages([
            QueuedSlashMessage(text: "a", attachments: []),
            QueuedSlashMessage(text: "b", attachments: [photo, noCopy])
        ], for: key)

        let expected = ChatDraft(text: "a\n\nb", attachments: [
            ChatDraftAttachment(id: photo.id, name: "photo.jpg", mime: "text/plain", size: 5, isImage: false, file: "a-photo.jpg")
        ])
        assertDraftContentEqual(parked, expected)
        let stored = await store.draft(for: key)
        assertDraftContentEqual(stored, expected)
    }

    /// Queued texts were typed first, so the draft's own text goes last. A
    /// queued text already carries its quotes as Markdown; the draft's own
    /// quotes stay quotes.
    func testQueuedMessagesMergeBeforeExistingDraftText() async throws {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://one.example", context: .session("chat-1"))
        let otherServer = ChatDraftKey(serverID: "https://two.example", context: .session("chat-1"))
        let quote = ComposerQuote(text: "Quoted passage")
        let own = makeAttachmentRecord(name: "own.txt", file: "a-own.txt")
        let ownAgain = makeQueuedFile("own.txt", draftFileName: "a-own.txt", id: own.id)
        let queued = makeQueuedFile("queued.txt", draftFileName: "b-queued.txt")
        store.setContent(ComposerDraftContent(text: "typed later", quotes: [quote]), for: key)
        store.setAttachments([own], for: key)
        store.setDraft("other server", for: otherServer)

        let parked = try XCTUnwrap(store.parkQueuedMessages([
            QueuedSlashMessage(text: "> Earlier quote\n\nfirst", attachments: [ownAgain]),
            QueuedSlashMessage(text: "second", attachments: [queued])
        ], for: key))

        XCTAssertEqual(parked.text, "> Earlier quote\n\nfirst\n\nsecond\n\ntyped later")
        XCTAssertEqual(parked.quotes, [quote])
        XCTAssertEqual(parked.attachments.map(\.id), [own.id, queued.id])
        XCTAssertEqual(parked.attachments.map(\.file), ["a-own.txt", "b-queued.txt"])
        let stored = await store.draft(for: key)
        XCTAssertEqual(stored, parked)
        let untouched = await store.draft(for: otherServer)
        assertDraftContentEqual(untouched, ChatDraft(text: "other server"))
    }

    /// On iPad the chat stays on screen while its session is deleted from the
    /// sidebar, so it parks its queue after the delete discarded its draft.
    /// That must not bring back a draft nobody can open.
    func testParkingAfterSessionDeleteLeavesNoDraft() async {
        let store = ChatDraftStore(
            persistence: RecordingChatDraftPersistence(),
            debounceDuration: .seconds(10)
        )
        let key = ChatDraftKey(serverID: "https://example.com", context: .session("chat-1"))
        store.setDraft("typed", for: key)
        await store.discardDraft(for: key)

        let parked = store.parkQueuedMessages([
            QueuedSlashMessage(text: "queued", attachments: [makeQueuedFile("photo.jpg", draftFileName: "a-photo.jpg")])
        ], for: key)

        XCTAssertNil(parked)
        let stored = await store.draft(for: key)
        XCTAssertNil(stored)
    }

    private func makeQueuedFile(_ name: String, draftFileName: String?, id: UUID = UUID()) -> PendingAttachment {
        PendingAttachment(
            id: id,
            name: name,
            path: "/tmp/workspace/\(name)",
            mime: "text/plain",
            size: 5,
            isImage: false,
            draftFileName: draftFileName
        )
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
            quotes: [
                ComposerQuote(text: "First line\nSecond line"),
                ComposerQuote(text: "Repeated"),
                ComposerQuote(text: "Repeated")
            ],
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

    func testRetentionEvictsOldestAcrossServersAndContextsWithoutLosingContent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ChatDraftAttachmentStore(directoryURL: directory)
        let oldFile = try await files.save(data: Data(repeating: 1, count: 4), suggestedFilename: "old")
        let newerFile = try await files.save(data: Data(repeating: 2, count: 4), suggestedFilename: "new")
        let first = ChatDraftKey(serverID: "server-one", context: .newChat)
        let second = ChatDraftKey(serverID: "server-two", context: .session("session"))
        let quote = ComposerQuote(text: "Keep this quote")
        let settings = ChatDraftSettings(modelID: "chosen")
        let old = ChatDraft(text: "Keep text", quotes: [quote], attachments: [Self.sampleAttachment(file: oldFile)], settings: settings, lastUsedAt: Date(timeIntervalSince1970: 1))
        let newer = ChatDraft(text: "Other server", attachments: [Self.sampleAttachment(file: newerFile)], lastUsedAt: Date(timeIntervalSince1970: 2))
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        try await persistence.write([first: old, second: newer])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 10)
        let lease = store.makeAttachmentLease()
        let staged = try await store.stageAttachment(data: Data(repeating: 3, count: 3), filename: "incoming", lease: lease)
        let remaining = try await files.retainedFileBytes()
        XCTAssertEqual(remaining, [newerFile: 4, staged: 3], "Only the oldest physical copy is needed")
        let relaunched = await ChatDraftFilePersistence(directoryURL: directory).load()
        XCTAssertEqual(relaunched[first]?.text, "Keep text")
        XCTAssertEqual(relaunched[first]?.quotes, [quote])
        XCTAssertEqual(relaunched[first]?.settings, settings)
        XCTAssertEqual(relaunched[first]?.attachments, [])
        XCTAssertEqual(relaunched[second], newer)
    }

    func testRetentionExactBoundaryAndProtectedOverLimitRefusal() async throws {
        let files = RetentionTestFiles(bytes: ["live": 4])
        let key = ChatDraftKey(serverID: "server", context: .newChat)
        let original = ChatDraft(text: "unchanged", attachments: [Self.sampleAttachment(file: "live")])
        let persistence = RetentionTestPersistence(drafts: [key: original])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 8)
        let lease = store.makeAttachmentLease(key: key)
        let admitted = try await store.stageAttachment(data: Data(repeating: 1, count: 4), filename: "exact", lease: lease)
        XCTAssertEqual(admitted, "new-1")
        await assertRetentionThrows(try await store.stageAttachment(data: Data([1]), filename: "over", lease: lease))
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory, ["live": 4, "new-1": 4])
        let saves = await files.saveCount
        XCTAssertEqual(saves, 1)
        let restored = await store.draft(for: key)
        XCTAssertEqual(restored, original)
    }

    func testSharedCopyUsesNewestReferenceAndAnyProtectedReferencePreventsEviction() async throws {
        let files = RetentionTestFiles(bytes: ["shared": 4, "middle": 4])
        let a = ChatDraftKey(serverID: "a", context: .newChat)
        let b = ChatDraftKey(serverID: "b", context: .session("shared"))
        let c = ChatDraftKey(serverID: "c", context: .newChat)
        let persistence = RetentionTestPersistence(drafts: [
            a: ChatDraft(text: "a", attachments: [Self.sampleAttachment(file: "shared")], lastUsedAt: Date(timeIntervalSince1970: 1)),
            b: ChatDraft(text: "b", attachments: [Self.sampleAttachment(file: "shared")], lastUsedAt: Date(timeIntervalSince1970: 3)),
            c: ChatDraft(text: "c", attachments: [Self.sampleAttachment(file: "middle")], lastUsedAt: Date(timeIntervalSince1970: 2))
        ])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 8)
        let incoming = store.makeAttachmentLease()
        _ = try await store.stageAttachment(data: Data(repeating: 1, count: 4), filename: "one", lease: incoming)
        let firstDeletes = await files.deleted
        XCTAssertEqual(firstDeletes, ["middle"], "A shared file takes the newest reference's recency")
        let protected = store.makeAttachmentLease(key: a)
        await assertRetentionThrows(try await store.stageAttachment(data: Data([1]), filename: "refused", lease: incoming))
        withExtendedLifetime(protected) {}
        protected.key = nil
        _ = try await store.stageAttachment(data: Data([1]), filename: "two", lease: incoming)
        let final = await persistence.load()
        XCTAssertEqual(final[a]?.attachments, [])
        XCTAssertEqual(final[b]?.attachments, [])
        let deletes = await files.deleted
        XCTAssertEqual(deletes, ["middle", "shared"])
    }

    func testRetentionRecencySurvivesRelaunchAndEnumerationDoesNotRefreshIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = ChatDraftKey(serverID: "a", context: .newChat)
        let b = ChatDraftKey(serverID: "b", context: .newChat)
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        try await persistence.write([
            a: ChatDraft(text: "a", attachments: [Self.sampleAttachment(file: "a")], lastUsedAt: Date(timeIntervalSince1970: 1)),
            b: ChatDraft(text: "b", attachments: [Self.sampleAttachment(file: "b")], lastUsedAt: Date(timeIntervalSince1970: 2))
        ])
        let store = ChatDraftStore(persistence: persistence)
        await store.markUsed(a)
        try await store.flush()
        let reopened = ChatDraftStore(persistence: persistence, attachmentStore: RetentionTestFiles(bytes: ["a": 4, "b": 4]), retainedByteLimit: 8)
        let before = await reopened.draft(for: b)
        _ = await reopened.draft(for: b)
        let after = await reopened.draft(for: b)
        XCTAssertEqual(before?.lastUsedAt, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(after, before)
        let lease = reopened.makeAttachmentLease()
        _ = try await reopened.stageAttachment(data: Data([1]), filename: "new", lease: lease)
        let result = await persistence.load()
        XCTAssertEqual(result[a]?.attachments.map(\.file), ["a"])
        XCTAssertEqual(result[b]?.attachments, [])
    }

    func testOldAndMalformedRecencyDocumentsStayVersionFourAndUseStableTieBreak() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("ChatDrafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"version":4,"drafts":[{"serverID":"a","context":"newChat","text":"old","lastUsedAt":"invalid","attachments":[{"id":"11111111-1111-1111-1111-111111111111","name":"a","mime":"text/plain","file":"a"}]},{"serverID":"b","context":"newChat","text":"legacy","attachments":[{"id":"22222222-2222-2222-2222-222222222222","name":"b","mime":"text/plain","file":"b"}]}]}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("drafts.json"))
        let persistence = ChatDraftFilePersistence(directoryURL: directory)
        let files = RetentionTestFiles(bytes: ["a": 4, "b": 4])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 8)
        let lease = store.makeAttachmentLease()
        _ = try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease)
        let deletes = await files.deleted
        XCTAssertEqual(deletes, ["a"])
        let result = await persistence.load()
        XCTAssertEqual(result[ChatDraftKey(serverID: "a", context: .newChat)]?.text, "old")
        XCTAssertEqual(result[ChatDraftKey(serverID: "b", context: .newChat)]?.attachments.map(\.file), ["b"])
        let data = try Data(contentsOf: folder.appendingPathComponent("drafts.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 4)
    }

    func testPersistenceFailureDoesNotDeleteOrStageAndPreservesOriginalDraft() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let original = ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "old")])
        let persistence = RetentionTestPersistence(drafts: [key: original], failWrites: true)
        let files = RetentionTestFiles(bytes: ["old": 4])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease()
        await assertRetentionThrows(try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease))
        let deletes = await files.deleted
        let saves = await files.saveCount
        let draft = await store.draft(for: key)
        XCTAssertEqual(deletes, [])
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(draft, original)
    }

    func testPressureReclaimsOnlyNeededOrphansAndProtectsLiveCopies() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let original = ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "referenced")])
        let persistence = RetentionTestPersistence(drafts: [key: original])
        let files = RetentionTestFiles(bytes: ["orphan-a": 2, "orphan-b": 2, "live": 2, "referenced": 2])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 8)
        let live = store.makeAttachmentLease()
        live.files.insert("live")
        let incoming = store.makeAttachmentLease()
        let staged = try await store.stageAttachment(data: Data([1, 2]), filename: "new", lease: incoming)
        let inventory = try await files.retainedFileBytes()
        let deleted = await files.deleted
        let restored = await store.draft(for: key)
        XCTAssertEqual(deleted, ["orphan-a"])
        XCTAssertEqual(inventory, ["orphan-b": 2, "live": 2, "referenced": 2, staged: 2])
        XCTAssertEqual(restored, original)
        withExtendedLifetime(live) {}
    }

    func testPartialDeletionCommitsRecordsBeforeFilesAndRefusesIfBytesRemain() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let persistence = RetentionTestPersistence(drafts: [key: ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "a"), Self.sampleAttachment(file: "b")])])
        let files = RetentionTestFiles(bytes: ["a": 2, "b": 2], undeletable: ["b"])
        await files.setDeletionObserver { file in
            let persisted = await persistence.load()
            XCTAssertFalse(persisted.values.contains { $0.attachments.contains { $0.file == file } })
        }
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease()
        await assertRetentionThrows(try await store.stageAttachment(data: Data(repeating: 1, count: 4), filename: "new", lease: lease))
        let inventory = try await files.retainedFileBytes()
        let saves = await files.saveCount
        XCTAssertEqual(inventory, ["b": 2])
        XCTAssertEqual(saves, 0)
        let relaunched = ChatDraftStore(persistence: persistence, attachmentStore: files)
        let restored = await relaunched.draft(for: key)
        XCTAssertEqual(restored?.text, "keep")
        XCTAssertEqual(restored?.attachments, [])
    }

    func testComposerOpeningDuringCommitCancelsEvictionAndRepairsRecords() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let original = ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "old")])
        let persistence = RetentionTestPersistence(drafts: [key: original], blockFirstWrite: true)
        let files = RetentionTestFiles(bytes: ["old": 4])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease()
        let admission = Task { try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease) }
        await persistence.waitForWrite()
        let composer = store.makeAttachmentLease(key: key)
        await persistence.releaseWrite()
        await assertRetentionThrows(try await admission.value)
        withExtendedLifetime(composer) {}
        let persisted = await persistence.load()
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(persisted[key], original)
        XCTAssertEqual(inventory, ["old": 4])
    }

    func testEditDuringCommitWinsWithoutDeletingItsAttachment() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let persistence = RetentionTestPersistence(drafts: [key: ChatDraft(text: "before", attachments: [Self.sampleAttachment(file: "old")])], blockFirstWrite: true)
        let files = RetentionTestFiles(bytes: ["old": 4])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease()
        let admission = Task { try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease) }
        await persistence.waitForWrite()
        store.setDraft("edited during commit", for: key)
        await persistence.releaseWrite()
        await assertRetentionThrows(try await admission.value)
        try await store.flush()
        let persisted = await persistence.load()
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(persisted[key]?.text, "edited during commit")
        XCTAssertEqual(persisted[key]?.attachments.map(\.file), ["old"])
        XCTAssertEqual(inventory, ["old": 4])
    }

    func testConcurrentAdmissionCannotOvershootAndRuntimeFilesRemainProtected() async throws {
        let files = RetentionTestFiles(bytes: [:])
        let store = ChatDraftStore(persistence: RetentionTestPersistence(drafts: [:]), attachmentStore: files, retainedByteLimit: 4)
        let first = store.makeAttachmentLease()
        let second = store.makeAttachmentLease()
        async let a: Bool = retentionAdmissionSucceeded(store, lease: first)
        async let b: Bool = retentionAdmissionSucceeded(store, lease: second)
        let results = await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(inventory.values.reduce(0, +), 4)
        let saves = await files.saveCount
        XCTAssertEqual(saves, 1)
    }

    func testCountReservationsComposeAcrossWindowsAndRetainedRestoreRecords() async throws {
        let key = ChatDraftKey(serverID: "a", context: .session("open"))
        let existing = (0..<9).map { Self.sampleAttachment(file: "saved-\($0)") }
        let files = RetentionTestFiles(bytes: [:])
        let persistence = RetentionTestPersistence(drafts: [key: ChatDraft(text: "keep", attachments: existing)])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files)
        let firstWindow = store.makeAttachmentLease(key: key)
        let secondWindow = store.makeAttachmentLease(key: key)
        _ = try await store.stageAttachment(data: Data([1]), filename: "tenth", lease: firstWindow)
        await assertRetentionThrows(try await store.stageAttachment(data: Data([2]), filename: "eleventh", lease: secondWindow))
        let saves = await files.saveCount
        XCTAssertEqual(saves, 1, "The other window's in-flight slot counts before it reaches the draft document")
        let draft = await store.draft(for: key)
        XCTAssertEqual(draft?.attachments, existing)
        XCTAssertEqual(draft?.text, "keep")
    }

    func testOverLimitMigratedDraftIsUnchangedOnLoadAndNewAdmissionRefuses() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let original = ChatDraft(text: "keep", attachments: (0..<11).map { Self.sampleAttachment(file: "saved-\($0)") })
        let persistence = RetentionTestPersistence(drafts: [key: original])
        let files = RetentionTestFiles(bytes: ["saved-0": 9])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease(key: key)
        let loaded = await store.draft(for: key)
        XCTAssertEqual(loaded, original)
        await assertRetentionThrows(try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease))
        let after = await store.draft(for: key)
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(after, original)
        XCTAssertEqual(inventory, ["saved-0": 9])
    }

    func testMovingNewChatTransfersProtectionAndOldestStripItemWinsRecencyTie() async throws {
        let newChat = ChatDraftKey(serverID: "a", context: .newChat)
        let session = ChatDraftKey(serverID: "a", context: .session("created"))
        let original = ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "z-first"), Self.sampleAttachment(file: "a-second")])
        let files = RetentionTestFiles(bytes: ["z-first": 4, "a-second": 4])
        let persistence = RetentionTestPersistence(drafts: [newChat: original])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 8)
        var composer: ChatDraftAttachmentLease? = store.makeAttachmentLease(key: newChat)
        _ = await store.draft(for: newChat)
        let moved = store.moveDraft(from: newChat, to: session)
        XCTAssertEqual(composer?.key, session)
        XCTAssertEqual(moved.attachments, original.attachments)
        let incoming = store.makeAttachmentLease()
        await assertRetentionThrows(try await store.stageAttachment(data: Data([1]), filename: "protected", lease: incoming))
        composer = nil
        _ = try await store.stageAttachment(data: Data([1]), filename: "inactive", lease: incoming)
        let deletes = await files.deleted
        XCTAssertEqual(deletes, ["z-first"], "Stage order wins over a random generated filename within the same draft")
        let result = await store.draft(for: session)
        XCTAssertEqual(result?.attachments.map(\.file), ["a-second"])
        XCTAssertEqual(result?.text, "keep")
    }

    func testCancellationDuringCommitRepairsRecordsWithoutDeletingFiles() async throws {
        let key = ChatDraftKey(serverID: "a", context: .newChat)
        let original = ChatDraft(text: "keep", attachments: [Self.sampleAttachment(file: "old")])
        let persistence = RetentionTestPersistence(drafts: [key: original], blockFirstWrite: true)
        let files = RetentionTestFiles(bytes: ["old": 4])
        let store = ChatDraftStore(persistence: persistence, attachmentStore: files, retainedByteLimit: 4)
        let lease = store.makeAttachmentLease()
        let admission = Task { try await store.stageAttachment(data: Data([1]), filename: "new", lease: lease) }
        await persistence.waitForWrite()
        admission.cancel()
        await persistence.releaseWrite()
        do {
            _ = try await admission.value
            XCTFail("Cancelled admission must fail")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        let restored = await persistence.load()
        let inventory = try await files.retainedFileBytes()
        XCTAssertEqual(restored[key], original)
        XCTAssertEqual(inventory, ["old": 4])
        XCTAssertEqual(lease.slotIDs, [])
    }

    private func assertDraftContentEqual(_ actual: ChatDraft?, _ expected: ChatDraft?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.text, expected?.text, file: file, line: line)
        XCTAssertEqual(actual?.quotes, expected?.quotes, file: file, line: line)
        XCTAssertEqual(actual?.attachments, expected?.attachments, file: file, line: line)
        XCTAssertEqual(actual?.settings, expected?.settings, file: file, line: line)
        XCTAssertEqual(actual?.botSubmissionUncertain, expected?.botSubmissionUncertain, file: file, line: line)
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

    func fileURL(named fileName: String) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
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

@MainActor
private func retentionAdmissionSucceeded(_ store: ChatDraftStore, lease: ChatDraftAttachmentLease) async -> Bool {
    do {
        _ = try await store.stageAttachment(data: Data(repeating: 1, count: 4), filename: "incoming", lease: lease)
        return true
    } catch { return false }
}

private actor RetentionTestFiles: ChatDraftAttachmentStoring {
    private var bytes: [String: Int]
    private let undeletable: Set<String>
    private var deletionObserver: (@Sendable (String) async -> Void)?
    private(set) var saveCount = 0
    private(set) var deleted: [String] = []
    init(bytes: [String: Int], undeletable: Set<String> = []) {
        self.bytes = bytes
        self.undeletable = undeletable
    }
    func setDeletionObserver(_ observer: @escaping @Sendable (String) async -> Void) { deletionObserver = observer }
    func retainedFileBytes() async throws -> [String: Int] { bytes }
    func save(data: Data, suggestedFilename: String) async throws -> String {
        saveCount += 1
        let file = "new-\(saveCount)"
        bytes[file] = data.count
        return file
    }
    func data(named fileName: String) async throws -> Data { Data(repeating: 0, count: bytes[fileName] ?? 0) }
    func fileURL(named fileName: String) async throws -> URL { throw CocoaError(.fileNoSuchFile) }
    func delete(named fileName: String) async {
        await deletionObserver?(fileName)
        deleted.append(fileName)
        if !undeletable.contains(fileName) { bytes[fileName] = nil }
    }
    func sweep(keepingReferenced fileNames: Set<String>, olderThan maxAge: TimeInterval) async {}
}

private actor RetentionTestPersistence: ChatDraftPersisting {
    private var drafts: [ChatDraftKey: ChatDraft]
    private let failWrites: Bool
    private var blockFirstWrite: Bool
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(drafts: [ChatDraftKey: ChatDraft], failWrites: Bool = false, blockFirstWrite: Bool = false) {
        self.drafts = drafts
        self.failWrites = failWrites
        self.blockFirstWrite = blockFirstWrite
    }
    func load() async -> [ChatDraftKey: ChatDraft] { drafts }
    func write(_ drafts: [ChatDraftKey: ChatDraft]) async throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        if blockFirstWrite {
            blockFirstWrite = false
            started = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        self.drafts = drafts
    }
    func waitForWrite() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseWrite() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private func assertRetentionThrows<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected retention admission to fail", file: file, line: line)
    } catch {}
}
