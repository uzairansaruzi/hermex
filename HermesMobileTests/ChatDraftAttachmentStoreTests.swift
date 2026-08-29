import Foundation
import XCTest
@testable import HermesMobile

final class ChatDraftAttachmentStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)
        let bytes = Data("attachment bytes".utf8)

        let fileName = try await store.save(data: bytes, suggestedFilename: "photo.jpg")

        XCTAssertTrue(fileName.hasSuffix("-photo.jpg"))
        let roundTripped = try await store.data(named: fileName)
        XCTAssertEqual(roundTripped, bytes)
        #if os(iOS)
        XCTAssertEqual(
            ChatDraftAttachmentStore.fileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    func testSaveSanitizesSuggestedFilenames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)

        let fileName = try await store.save(
            data: Data("bytes".utf8),
            suggestedFilename: "/tmp/somewhere/notes.txt"
        )

        XCTAssertTrue(fileName.hasSuffix("-notes.txt"))
        XCTAssertEqual(fileName, URL(fileURLWithPath: fileName).lastPathComponent)
        // The file must live inside the store's attachments directory.
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("ChatDrafts/Attachments", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(contents.map(\.lastPathComponent), [fileName])
    }

    func testSaveGeneratesUniqueNamesForCollidingSuggestions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)

        let first = try await store.save(data: Data("one".utf8), suggestedFilename: "photo.jpg")
        let second = try await store.save(data: Data("two".utf8), suggestedFilename: "photo.jpg")

        XCTAssertNotEqual(first, second)
        let firstData = try await store.data(named: first)
        let secondData = try await store.data(named: second)
        XCTAssertEqual(firstData, Data("one".utf8))
        XCTAssertEqual(secondData, Data("two".utf8))
    }

    func testLoadRejectsTraversalFileNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)
        let outside = try await store.save(data: Data("real".utf8), suggestedFilename: "real.txt")

        await XCTAssertThrowsErrorAsync(try await store.data(named: "../\(outside)"))
        await XCTAssertThrowsErrorAsync(try await store.data(named: ".."))
        await XCTAssertThrowsErrorAsync(try await store.data(named: "nested/\(outside)"))
    }

    func testDeleteRemovesFilesAndToleratesMissingOnes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)
        let fileName = try await store.save(data: Data("bytes".utf8), suggestedFilename: "photo.jpg")

        await store.delete(named: fileName)

        await XCTAssertThrowsErrorAsync(try await store.data(named: fileName))
        // Deleting twice (or a never-written name) is a no-op, not an error.
        await store.delete(named: fileName)
        await store.delete(named: "never-written.jpg")
        // Traversal attempts never reach outside the directory.
        await store.delete(named: "../drafts.json")
    }

    func testSweepDeletesOnlyUnreferencedFilesOlderThanTheGrace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)
        let referenced = try await store.save(data: Data("keep".utf8), suggestedFilename: "keep.jpg")
        let orphan = try await store.save(data: Data("drop".utf8), suggestedFilename: "drop.jpg")

        // Within the grace window, nothing is collected — even true orphans.
        await store.sweep(keepingReferenced: [], olderThan: 24 * 60 * 60)
        let survivingOrphan = try await store.data(named: orphan)
        XCTAssertEqual(survivingOrphan, Data("drop".utf8))

        // Past the grace window, orphans go; referenced files stay.
        await store.sweep(keepingReferenced: [referenced], olderThan: 0)
        await XCTAssertThrowsErrorAsync(try await store.data(named: orphan))
        let keptData = try await store.data(named: referenced)
        XCTAssertEqual(keptData, Data("keep".utf8))
    }

    // MARK: - Read-failure classification

    /// A record is only dropped from a draft when its copy is genuinely gone.
    func testAMissingFileIsClassifiedUnrecoverable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)
        _ = try await store.save(data: Data("bytes".utf8), suggestedFilename: "photo.jpg")

        do {
            _ = try await store.data(named: "never-written.jpg")
            XCTFail("Expected a read failure for a missing file")
        } catch {
            XCTAssertEqual(ChatDraftAttachmentReadFailure.classify(error), .unrecoverable)
        }
    }

    /// A name that cannot resolve never will, so it is not worth retrying.
    func testAnInvalidFileNameIsClassifiedUnrecoverable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftAttachmentStore(directoryURL: directory)

        do {
            _ = try await store.data(named: "../escape.jpg")
            XCTFail("Expected a read failure for a traversal name")
        } catch {
            XCTAssertEqual(ChatDraftAttachmentReadFailure.classify(error), .unrecoverable)
        }
    }

    /// The case that matters: a copy that is present but unreadable right now
    /// (data protection before first unlock, a transient I/O error) must be
    /// retried, not reported as permanently lost and swept away.
    func testAnUnreadableButPresentFileIsClassifiedTransient() {
        let protectionFailure = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError
        )
        XCTAssertEqual(ChatDraftAttachmentReadFailure.classify(protectionFailure), .transient)

        let ioFailure = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        XCTAssertEqual(ChatDraftAttachmentReadFailure.classify(ioFailure), .transient)

        XCTAssertEqual(ChatDraftAttachmentReadFailure.classify(CancellationError()), .transient)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDraftAttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// `XCTAssertThrowsError` for async expressions.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error but succeeded. \(message)", file: file, line: line)
    } catch {
        // Expected.
    }
}
