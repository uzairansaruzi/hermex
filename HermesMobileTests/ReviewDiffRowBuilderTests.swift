import XCTest
@testable import HermesMobile

final class ReviewDiffRowBuilderTests: XCTestCase {
    private func file(_ path: String, oldPath: String? = nil, status: String = "M", additions: Int? = nil) throws -> GitFile {
        var json: [String: Any] = ["path": path, "status": status, "unstaged": true]
        if let oldPath { json["old_path"] = oldPath }
        if let additions { json["additions"] = additions }
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitFile.self, from: data)
    }

    private func diff(_ text: String, binary: Bool? = nil, tooLarge: Bool? = nil) throws -> GitDiff {
        var json: [String: Any] = ["diff": text]
        if let binary { json["binary"] = binary }
        if let tooLarge { json["too_large"] = tooLarge }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitDiff.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testLoadedDiffBuildsHeaderHunkAndLineRowsWithStableIDs() throws {
        let raw = "@@ -1,3 +1,3 @@\n context\n-old value\n+new value\n\\ No newline at end of file"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("a/b.swift"), state: .loaded(try diff(raw))))

        XCTAssertEqual(rows.map(\.id), ["a/b.swift:header", "a/b.swift:hunk:0", "a/b.swift:line:0:0", "a/b.swift:line:0:1", "a/b.swift:line:0:2", "a/b.swift:line:0:3"])
        XCTAssertEqual(rows.map(\.fileID), Array(repeating: "a/b.swift", count: 6))

        let header = try XCTUnwrap(rows[0].fileHeader)
        XCTAssertEqual(header.path, "a/b.swift")
        XCTAssertNil(header.previousPath)
        XCTAssertEqual(header.additions, 1, "Counts fall back to the hunk when the file has none.")
        XCTAssertEqual(header.deletions, 1)

        XCTAssertEqual(rows[1].kind, .hunk("Lines 1-3"))
        let context = try XCTUnwrap(rows[2].line)
        XCTAssertEqual(context.change, .context)
        XCTAssertEqual(context.content, "context", "The diff prefix character is dropped.")
        XCTAssertEqual(context.oldLineNumber, 1)
        XCTAssertEqual(context.newLineNumber, 1)
        XCTAssertEqual(rows[3].line?.change, .deletion)
        XCTAssertEqual(rows[4].line?.change, .addition)
        XCTAssertEqual(rows[5].line?.content, "\\ No newline at end of file", "Markers keep their text.")
    }

    func testPairedLinesCarryWordDiffRanges() throws {
        let raw = "@@ -1,1 +1,1 @@\n-let value = compute(alpha)\n+let value = compute(beta)"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("x.swift"), state: .loaded(try diff(raw))))

        XCTAssertEqual(rows[2].line?.wordDiffRanges, [20..<25])
        XCTAssertEqual(rows[3].line?.wordDiffRanges, [20..<24])
    }

    func testTabsExpandToSpacesForTheCharacterGrid() throws {
        let raw = "@@ -1,1 +1,1 @@\n+\tindented"
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: try file("x.swift"), state: .loaded(try diff(raw))))
        XCTAssertEqual(rows[2].line?.content, "    indented")
    }

    func testRenameShowsPreviousPathAndFileCountsWin() throws {
        let renamed = try file("new.swift", oldPath: "old.swift", status: "R", additions: 7)
        let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: renamed, state: .loaded(try diff("@@ -1 +1 @@\n-a\n+b"))))
        let header = try XCTUnwrap(rows[0].fileHeader)
        XCTAssertEqual(header.previousPath, "old.swift")
        XCTAssertEqual(header.displayPath, "old.swift → new.swift")
        XCTAssertEqual(header.changeKind, .renamed)
        XCTAssertEqual(header.additions, 7, "Server counts win over the parsed hunk.")
    }

    func testNonRenderableStatesBecomeOneNoticeRow() throws {
        let plain = try file("x.swift")
        let cases: [(ReviewDiffFileState, String)] = [
            (.loading, "Loading…"),
            (.failed("Boom"), "Boom"),
            (.loaded(try diff("", binary: true)), "Binary file changed"),
            (.loaded(try diff("", tooLarge: true)), "Diff too large to show."),
            (.loaded(try diff("")), "No Changes")
        ]
        for (state, notice) in cases {
            let rows = ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: plain, state: state))
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[1].id, "x.swift:notice")
            XCTAssertEqual(rows[1].kind, .notice(notice))
        }
    }

    func testMultipleFilesConcatenateInOrder() throws {
        let rows = ReviewDiffRowBuilder.rows(for: [
            ReviewDiffFileInput(file: try file("one.swift"), state: .loading),
            ReviewDiffFileInput(file: try file("two.swift"), state: .loaded(try diff("@@ -1 +1 @@\n-a\n+b")))
        ])
        XCTAssertEqual(rows.filter(\.isFileHeader).map(\.fileID), ["one.swift", "two.swift"])
        XCTAssertEqual(rows.count, 2 + 4)
    }

    // MARK: - Loader

    /// Counts per-file builds of loaded diffs; placeholder rows are not counted.
    private final class BuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = 0
        var loadedBuilds: Int { lock.withLock { loaded } }

        func rows(for input: ReviewDiffFileInput) -> [ReviewDiffRow] {
            if case .loaded = input.state { lock.withLock { loaded += 1 } }
            return ReviewDiffRowBuilder.rows(for: input)
        }
    }

    private func loadedDiff(for file: GitFile) throws -> ReviewDiffLoader.FileResult {
        let raw = "@@ -1,2 +1,2 @@\n context\n-let \(file.id) = old\n+let \(file.id) = new"
        return ReviewDiffLoader.FileResult(fileID: file.id, state: .loaded(try diff(raw)), error: nil)
    }

    @MainActor
    func testLoaderBuildsEachLandedFileOnceAndBatchesPublishes() async throws {
        let files = try (0..<10).map { try file("f\($0).swift") }
        let results = try Dictionary(uniqueKeysWithValues: files.map { ($0.id, try loadedDiff(for: $0)) })
        let counter = BuildCounter()
        var published: [[ReviewDiffRow]] = []

        await ReviewDiffLoader.load(
            files: files,
            firstFile: files[7],
            maxConcurrent: 4,
            // An interval longer than the test, so only the batch size and the last answer publish.
            coalescing: ReviewDiffLoader.Coalescing(interval: .seconds(3600), batch: 4),
            fetch: { results[$0.id] },
            buildRows: { counter.rows(for: $0) },
            isCurrent: { true },
            publish: { published.append($0) },
            onError: { XCTFail("Unexpected error \($0)") }
        )

        XCTAssertEqual(counter.loadedBuilds, files.count, "Each file parses and word-diffs once, not once per later answer.")
        // Loading placeholders, the first answer, answers 5 and 9 (batches of four), and the last answer.
        XCTAssertEqual(published.count, 5)
        XCTAssertEqual(published.first, ReviewDiffRowBuilder.rows(for: files.map { ReviewDiffFileInput(file: $0, state: .loading) }))
        let expected = ReviewDiffRowBuilder.rows(for: files.map { ReviewDiffFileInput(file: $0, state: results[$0.id]!.state) })
        XCTAssertEqual(published.last, expected, "The final rows match a full build, in display order.")
    }

    @MainActor
    func testLoaderPublishesAPendingAnswerWithoutWaitingForTheNextOne() async throws {
        let files = try ["a.swift", "b.swift", "c.swift"].map { try file($0) }
        let results = try Dictionary(uniqueKeysWithValues: files.map { ($0.id, try loadedDiff(for: $0)) })
        let (gate, openGate) = AsyncStream<Void>.makeStream()
        let bothEarlyFilesShown = expectation(description: "a and b painted while c loads")

        let load = Task { @MainActor in
            await ReviewDiffLoader.load(
                files: files,
                firstFile: nil,
                maxConcurrent: 3,
                // The interval never elapses by itself; the trailing flush is what paints the second answer.
                coalescing: ReviewDiffLoader.Coalescing(interval: .seconds(3600), batch: 4, sleep: { _ in }),
                fetch: { file in
                    if file.id == "c.swift" { for await _ in gate { break } }
                    return results[file.id]
                },
                isCurrent: { true },
                publish: { rows in
                    let loadingFiles = Set(rows.filter { $0.kind == .notice(String(localized: "Loading…")) }.map(\.fileID))
                    if loadingFiles == ["c.swift"] { bothEarlyFilesShown.fulfill() }
                },
                onError: { XCTFail("Unexpected error \($0)") }
            )
        }

        await fulfillment(of: [bothEarlyFilesShown], timeout: 5)
        openGate.yield()
        openGate.finish()
        await load.value
    }

    /// Records flush sleeps. The first waits for the test's gate; later ones sleep for real
    /// and end when the load cancels them.
    private final class FlushSleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [Duration] = []
        let firstGate: AsyncStream<Void>
        let secondScheduled: XCTestExpectation

        init(firstGate: AsyncStream<Void>, secondScheduled: XCTestExpectation) {
            self.firstGate = firstGate
            self.secondScheduled = secondScheduled
        }

        var recorded: [Duration] { lock.withLock { delays } }

        func sleep(for delay: Duration) async throws {
            let index = lock.withLock { delays.append(delay); return delays.count }
            if index == 1 {
                for await _ in firstGate { break }
                return
            }
            if index == 2 { secondScheduled.fulfill() }
            try await Task.sleep(for: delay)
        }
    }

    @MainActor
    func testLoaderRestartsTheFlushIntervalAfterABatchPublish() async throws {
        let files = try ["a", "b", "c", "d", "e"].map { try file("\($0).swift") }
        let results = try Dictionary(uniqueKeysWithValues: files.map { ($0.id, try loadedDiff(for: $0)) })
        let (firstFlushGate, openFirstFlush) = AsyncStream<Void>.makeStream()
        let (lastFileGate, openLastFile) = AsyncStream<Void>.makeStream()
        let sleeps = FlushSleeps(firstGate: firstFlushGate, secondScheduled: expectation(description: "d gets its own flush"))
        var published: [[ReviewDiffRow]] = []

        // One fetch at a time: a paints, b waits on flush 1, c fills the batch and paints,
        // d must wait a fresh interval instead of riding flush 1, and e is the last answer.
        let load = Task { @MainActor in
            await ReviewDiffLoader.load(
                files: files,
                firstFile: nil,
                maxConcurrent: 1,
                coalescing: ReviewDiffLoader.Coalescing(interval: .seconds(3600), batch: 2, sleep: { try await sleeps.sleep(for: $0) }),
                fetch: { file in
                    if file.id == "e.swift" { for await _ in lastFileGate { break } }
                    return results[file.id]
                },
                isCurrent: { true },
                publish: { published.append($0) },
                onError: { XCTFail("Unexpected error \($0)") }
            )
        }

        await fulfillment(of: [sleeps.secondScheduled], timeout: 5)
        let delays = sleeps.recorded
        XCTAssertEqual(delays.count, 2)
        XCTAssertGreaterThan(delays[1], .seconds(3599), "The interval restarts at the batch publish.")

        // The stale flush 1 publishes nothing, whichever order it and e land in.
        openFirstFlush.yield()
        openFirstFlush.finish()
        openLastFile.yield()
        openLastFile.finish()
        await load.value
        // Loading placeholders, a, the batch at c, and the last answer.
        XCTAssertEqual(published.count, 4)
    }
}
