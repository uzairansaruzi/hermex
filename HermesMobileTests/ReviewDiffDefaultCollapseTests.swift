import XCTest
@testable import HermesMobile

final class ReviewDiffDefaultCollapseTests: XCTestCase {
    private func file(_ path: String, additions: Int? = 1, deletions: Int? = 1) -> GitFile {
        GitFile(path: path, status: "M", staged: false, unstaged: true, untracked: false, conflict: false,
                additions: additions, deletions: deletions)
    }

    /// A loaded diff with `changed` added lines surrounded by `context` unchanged lines.
    private func loadedRows(_ file: GitFile, changed: Int, context: Int = 0) throws -> [ReviewDiffRow] {
        let body = Array(repeating: " same", count: context) + Array(repeating: "+new", count: changed)
        let raw = "@@ -1,\(context) +1,\(context + changed) @@\n" + body.joined(separator: "\n")
        let json: [String: Any] = ["diff": raw]
        let diff = try JSONDecoder().decode(GitDiff.self, from: JSONSerialization.data(withJSONObject: json))
        return ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: file, state: .loaded(diff)))
    }

    private func rows(_ file: GitFile, _ state: ReviewDiffFileState) -> [ReviewDiffRow] {
        ReviewDiffRowBuilder.rows(for: ReviewDiffFileInput(file: file, state: state))
    }

    func testMultiFileReviewStartsGeneratedFilesAndLargeChangesFolded() {
        let files = [
            file("web/package-lock.json"),
            file("src/__snapshots__/view.test.ts.snap"),
            file("node_modules/left-pad/index.js"),
            file("build/Generator.swift"),
            file("src/App.swift"),
            file("src/Big.swift", additions: 300, deletions: 101),
            file("src/AtLimit.swift", additions: 300, deletions: 100)
        ]

        let defaults = ReviewDiffDefaultCollapse(files: files, initialFile: nil)

        XCTAssertEqual(defaults.initiallyCollapsedFileIDs, [
            "web/package-lock.json", "src/__snapshots__/view.test.ts.snap", "node_modules/left-pad/index.js",
            "src/Big.swift"
        ])
    }

    func testTappedFileAndSingleFileReviewStartExpanded() {
        let lockfile = file("yarn.lock")
        let huge = file("src/Huge.swift", additions: 5000, deletions: 0)

        let tapped = ReviewDiffDefaultCollapse(files: [lockfile, huge], initialFile: lockfile)
        XCTAssertEqual(tapped.initiallyCollapsedFileIDs, ["src/Huge.swift"])

        let single = ReviewDiffDefaultCollapse(files: [huge], initialFile: nil)
        XCTAssertEqual(single.initiallyCollapsedFileIDs, [])
    }

    func testMissingCountsWaitForLoadedRowsAndCountOnlyChangedLines() throws {
        let large = file("src/Large.swift", additions: nil, deletions: nil)
        let contextHeavy = file("src/Context.swift", additions: nil, deletions: 3)
        var defaults = ReviewDiffDefaultCollapse(files: [large, contextHeavy], initialFile: nil)
        var collapsed = defaults.initiallyCollapsedFileIDs
        XCTAssertEqual(collapsed, [])

        defaults.apply(rows(large, .loading) + rows(contextHeavy, .loading), to: &collapsed)
        XCTAssertEqual(collapsed, [], "A loading placeholder's zero counts decide nothing.")

        defaults.apply(try loadedRows(large, changed: 401) + loadedRows(contextHeavy, changed: 400, context: 600), to: &collapsed)
        XCTAssertEqual(collapsed, ["src/Large.swift"])
    }

    func testUserExpansionBeforeLoadSurvivesLoadAndRefresh() throws {
        let source = file("src/App.swift")
        let measured = file("src/Large.swift", additions: nil, deletions: nil)
        let lockfile = file("Cargo.lock")
        var defaults = ReviewDiffDefaultCollapse(files: [source, measured, lockfile], initialFile: source)
        var collapsed = defaults.initiallyCollapsedFileIDs
        XCTAssertEqual(collapsed, ["Cargo.lock"])

        // The user opens the lockfile while everything is still loading.
        defaults.settle("Cargo.lock")
        collapsed.remove("Cargo.lock")
        // ...and folds and reopens the not-yet-measured file.
        defaults.settle("src/Large.swift")

        let loaded = try loadedRows(source, changed: 2) + loadedRows(measured, changed: 900) + loadedRows(lockfile, changed: 900)
        defaults.apply(loaded, to: &collapsed)
        defaults.apply(rows(source, .loading) + rows(measured, .loading) + rows(lockfile, .loading), to: &collapsed)
        defaults.apply(loaded, to: &collapsed)

        XCTAssertEqual(collapsed, [])
    }

    func testNoticeUnfoldsOnlyADefaultFoldAndLeavesItOpenForALaterLoad() throws {
        let lockfile = file("Gemfile.lock")
        let snapshot = file("ui/__snapshots__/a.snap")
        var defaults = ReviewDiffDefaultCollapse(files: [lockfile, snapshot], initialFile: nil)
        var collapsed = defaults.initiallyCollapsedFileIDs
        // The user expands the snapshot and folds it again: an explicit choice.
        defaults.settle("ui/__snapshots__/a.snap")

        defaults.apply(rows(lockfile, .failed("Boom")) + rows(snapshot, .failed("Boom")), to: &collapsed)
        XCTAssertEqual(collapsed, ["ui/__snapshots__/a.snap"], "The failure reads in the open; the user's fold stays.")

        defaults.apply(try loadedRows(lockfile, changed: 12) + loadedRows(snapshot, changed: 12), to: &collapsed)
        XCTAssertEqual(collapsed, ["Gemfile.lock", "ui/__snapshots__/a.snap"], "A successful refresh applies the default.")
    }
}
