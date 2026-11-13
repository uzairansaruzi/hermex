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

    private func rows(_ files: [GitFile], _ state: ReviewDiffFileState) -> [ReviewDiffRow] {
        ReviewDiffRowBuilder.rows(for: files.map { ReviewDiffFileInput(file: $0, state: state) })
    }

    /// Folds `files` would get once each loads a small diff.
    private func foldsOnceLoaded(_ files: [GitFile], initialFile: GitFile?) throws -> Set<String> {
        var defaults = ReviewDiffDefaultCollapse(files: files, initialFile: initialFile)
        var collapsed: Set<String> = []
        defaults.apply(try files.flatMap { try loadedRows($0, changed: 2) }, to: &collapsed)
        return collapsed
    }

    func testMultiFileReviewFoldsGeneratedFilesAndLargeChanges() throws {
        let files = [
            file("web/package-lock.json"),
            file("src/__snapshots__/view.test.ts.snap"),
            file("node_modules/left-pad/index.js"),
            file("build/Generator.swift"),
            file("src/App.swift"),
            file("src/Big.swift", additions: 300, deletions: 101),
            file("src/AtLimit.swift", additions: 300, deletions: 100)
        ]

        XCTAssertEqual(try foldsOnceLoaded(files, initialFile: nil), [
            "web/package-lock.json", "src/__snapshots__/view.test.ts.snap", "node_modules/left-pad/index.js",
            "src/Big.swift"
        ])
    }

    func testTappedFileAndSingleFileReviewStayExpanded() throws {
        let lockfile = file("yarn.lock")
        let huge = file("src/Huge.swift", additions: 5000, deletions: 0)

        XCTAssertEqual(try foldsOnceLoaded([lockfile, huge], initialFile: lockfile), ["src/Huge.swift"])
        XCTAssertEqual(try foldsOnceLoaded([huge], initialFile: nil), [])
    }

    func testMissingCountsWaitForLoadedRowsAndCountOnlyChangedLines() throws {
        let large = file("src/Large.swift", additions: nil, deletions: nil)
        let contextHeavy = file("src/Context.swift", additions: nil, deletions: 3)
        var defaults = ReviewDiffDefaultCollapse(files: [large, contextHeavy], initialFile: nil)
        var collapsed: Set<String> = []

        defaults.apply(rows([large, contextHeavy], .loading), to: &collapsed)
        XCTAssertEqual(collapsed, [], "A loading placeholder's zero counts decide nothing.")

        defaults.apply(try loadedRows(large, changed: 401) + loadedRows(contextHeavy, changed: 400, context: 600), to: &collapsed)
        XCTAssertEqual(collapsed, ["src/Large.swift"])
    }

    func testUserExpansionSurvivesLoadAndRefresh() throws {
        let source = file("src/App.swift")
        let measured = file("src/Large.swift", additions: nil, deletions: nil)
        let lockfile = file("Cargo.lock")
        let files = [source, measured, lockfile]
        var defaults = ReviewDiffDefaultCollapse(files: files, initialFile: source)
        var collapsed: Set<String> = []
        defaults.apply(rows(files, .loading), to: &collapsed)
        // The user folds and reopens the not-yet-measured file while it loads.
        defaults.settle("src/Large.swift")

        let loaded = try loadedRows(source, changed: 2) + loadedRows(measured, changed: 900) + loadedRows(lockfile, changed: 900)
        defaults.apply(loaded, to: &collapsed)
        XCTAssertEqual(collapsed, ["Cargo.lock"])
        // ...then opens the folded lockfile and refreshes.
        defaults.settle("Cargo.lock")
        collapsed.remove("Cargo.lock")
        defaults.apply(rows(files, .loading), to: &collapsed)
        defaults.apply(loaded, to: &collapsed)

        XCTAssertEqual(collapsed, [])
    }

    /// Loading, failed, binary and too-large notices read in the open: a default fold steps
    /// aside for them on every load and refresh, and comes back with the next real diff.
    func testNoticesLiftOnlyADefaultFold() throws {
        let lockfile = file("Gemfile.lock")
        let snapshot = file("ui/__snapshots__/a.snap")
        let files = [lockfile, snapshot]
        var defaults = ReviewDiffDefaultCollapse(files: files, initialFile: nil)
        var collapsed: Set<String> = []
        // The user folds the snapshot before anything loads: an explicit choice.
        defaults.settle("ui/__snapshots__/a.snap")
        collapsed.insert("ui/__snapshots__/a.snap")

        defaults.apply(rows(files, .loading), to: &collapsed)
        XCTAssertEqual(collapsed, ["ui/__snapshots__/a.snap"], "Loading… reads in the open; the user's fold stays.")
        let loaded = try loadedRows(lockfile, changed: 12) + loadedRows(snapshot, changed: 12)
        defaults.apply(loaded, to: &collapsed)
        XCTAssertEqual(collapsed, ["Gemfile.lock", "ui/__snapshots__/a.snap"])

        // A refresh shows Loading… again, then fails.
        defaults.apply(rows(files, .loading), to: &collapsed)
        XCTAssertEqual(collapsed, ["ui/__snapshots__/a.snap"])
        defaults.apply(rows(files, .failed("Boom")), to: &collapsed)
        XCTAssertEqual(collapsed, ["ui/__snapshots__/a.snap"], "The failure reads in the open.")

        defaults.apply(loaded, to: &collapsed)
        XCTAssertEqual(collapsed, ["Gemfile.lock", "ui/__snapshots__/a.snap"], "A successful refresh folds it again.")
    }
}
