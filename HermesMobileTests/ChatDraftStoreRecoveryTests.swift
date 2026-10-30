import XCTest
@testable import HermesMobile

/// A drafts file that exists but cannot be read (locked device, transient I/O)
/// must never be replaced by the empty in-memory state: the store keeps retrying
/// the read and refuses writes until one succeeds, so the intact file survives.
@MainActor
final class ChatDraftStoreRecoveryTests: XCTestCase {
    func testAnUnreadableDraftsFileIsNeverClobberedAndRecoversOnTheNextRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-recovery-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("ChatDrafts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = folder.appendingPathComponent("drafts.json")
        let savedJSON = #"{"version":4,"drafts":[{"serverID":"a","context":"newChat","text":"saved on disk","lastUsedAt":null,"attachments":[]}]}"#
        try Data(savedJSON.utf8).write(to: fileURL)
        let savedKey = ChatDraftKey(serverID: "a", context: .newChat)
        let typedKey = ChatDraftKey(serverID: "b", context: .newChat)

        let store = ChatDraftStore(persistence: ChatDraftFilePersistence(directoryURL: directory))

        // The locked-device window: the file is there but reads fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        XCTAssertNil(await store.draft(for: savedKey), "the unreadable file reads as nothing")
        store.setDraft("typed while locked", for: typedKey)
        do {
            try await store.flush()
            XCTFail("A store whose file is unreadable must refuse to write over it")
        } catch {
            // The refusal is the fix: the on-disk bytes stay authoritative.
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), Data(savedJSON.utf8),
                       "the refused write left the saved drafts untouched")

        // Reads succeed again: the retry merges the saved draft with the typed one.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let recovered = await store.draft(for: savedKey)
        XCTAssertEqual(recovered?.text, "saved on disk")
        try await store.flush()
        let persisted = await ChatDraftFilePersistence(directoryURL: directory).load()
        XCTAssertEqual(persisted[typedKey]?.text, "typed while locked")
        XCTAssertEqual(persisted[savedKey]?.text, "saved on disk")
    }
}
