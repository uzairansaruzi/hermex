import XCTest
@testable import HermesMobile

/// A chat's review progress across reopened reviews (#1384), driven as `GitDiffView` drives it:
/// open a review, land the loader's rows and patches, toggle, close, open again.
@MainActor
final class ReviewProgressStoreTests: XCTestCase {
    private func file(_ path: String) -> GitFile {
        GitFile(path: path, status: "M", staged: false, unstaged: true, untracked: false, conflict: false,
                additions: 1, deletions: 1)
    }

    private func text(_ patch: String) throws -> ReviewDiffFileState {
        try loaded(["diff": "@@ -1 +1 @@\n\(patch)"])
    }

    private func loaded(_ json: [String: Any]) throws -> ReviewDiffFileState {
        .loaded(try JSONDecoder().decode(GitDiff.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    private func open(_ files: [GitFile], tapped: GitFile? = nil, in scope: String = "repo",
                      store: ReviewProgressStore) -> ReviewDiffProgress {
        ReviewDiffProgress(files: files, initialFile: tapped, store: store, scope: scope)
    }

    /// Lands every file's answer at once, as the loader's last publish does; a file missing from
    /// `states` is still loading.
    private func land(_ review: inout ReviewDiffProgress, _ files: [GitFile], _ states: [String: ReviewDiffFileState]) {
        let inputs = files.map { ReviewDiffFileInput(file: $0, state: states[$0.id] ?? .loading) }
        var patches: [String: Int] = [:]
        for input in inputs { patches[input.file.id] = ReviewDiffProgress.patch(for: input.file, state: input.state) }
        review.apply(ReviewDiffRowBuilder.rows(for: inputs), patches: patches)
    }

    private func status(_ files: [GitFile]?, isGit: Bool = true, truncated: Bool?) -> GitStatus {
        GitStatus(isGit: isGit, branch: "main", upstream: nil, ahead: nil, behind: nil, totals: nil, files: files,
                  truncated: truncated)
    }

    func testReopeningRestoresFoldsAndShowsViewedMarksOnceTheirPatchLoads() throws {
        let store = ReviewProgressStore()
        let source = file("src/App.swift"), notes = file("notes.md"), lockfile = file("Cargo.lock")
        let files = [source, notes, lockfile]
        let answers = [source.id: try text("+a"), notes.id: try text("+b"), lockfile.id: try text("+c")]
        var first = open(files, store: store)
        land(&first, files, answers)
        first.toggleViewed(source.id)
        first.toggleFile(notes.id)
        first.toggleFile(lockfile.id)

        var reopened = open(files, store: store)
        XCTAssertEqual(reopened.collapsedFileIDs, [source.id, notes.id])
        XCTAssertEqual(reopened.viewedFileIDs, [], "A viewed mark waits for its patch to load.")
        land(&reopened, files, answers)
        XCTAssertEqual(reopened.viewedFileIDs, [source.id])
        XCTAssertEqual(reopened.collapsedFileIDs, [source.id, notes.id], "The opened lockfile beats its default fold.")

        reopened.toggleViewed(source.id)
        XCTAssertEqual(reopened.collapsedFileIDs, [source.id, notes.id], "Un-viewing leaves the file folded (#399).")
    }

    func testAChangedPatchReopensUnviewedAndOpenWhileAnUnchangedOneKeepsItsManualExpansion() throws {
        let store = ReviewProgressStore()
        let edited = file("Edited.swift"), kept = file("Kept.swift")
        let files = [edited, kept]
        var first = open(files, store: store)
        land(&first, files, [edited.id: try text("+one"), kept.id: try text("+same")])
        first.toggleViewed(edited.id)
        first.toggleViewed(kept.id)
        first.toggleFile(kept.id)

        var reopened = open(files, store: store)
        land(&reopened, files, [edited.id: try text("+two"), kept.id: try text("+same")])
        XCTAssertEqual(reopened.viewedFileIDs, [kept.id])
        XCTAssertEqual(reopened.collapsedFileIDs, [])
        XCTAssertEqual(open(files, store: store).collapsedFileIDs, [], "The next review opens it before it loads.")
    }

    func testOnlyALoadedTextPatchCanBeMarkedOrInvalidated() throws {
        let store = ReviewProgressStore()
        let source = file("A.swift"), image = file("logo.png")
        let files = [source, image]
        let binary = try loaded(["diff": "", "binary": true])
        var first = open(files, store: store)
        land(&first, files, [:])
        first.toggleViewed(source.id)
        land(&first, files, [source.id: try text("+a"), image.id: binary])
        first.toggleViewed(image.id)
        XCTAssertEqual(first.viewedFileIDs, [source.id, image.id], "This review still shows both marks.")

        var reopened = open(files, store: store)
        land(&reopened, files, [source.id: try text("+a"), image.id: binary])
        XCTAssertEqual(reopened.viewedFileIDs, [], "Neither mark was made against a loaded text patch.")
        reopened.toggleViewed(source.id)

        var refreshed = open(files, store: store)
        land(&refreshed, files, [source.id: try text("+a"), image.id: binary])
        land(&refreshed, files, [source.id: .failed("Boom"), image.id: binary])
        XCTAssertEqual(refreshed.viewedFileIDs, [], "A failed refresh can't leave a restored mark looking verified.")
        land(&refreshed, files, [source.id: try text("+a"), image.id: binary])
        XCTAssertEqual(refreshed.viewedFileIDs, [source.id], "...or clear the mark.")
    }

    func testATurnsSubsetKeepsProgressOnTheFilesOutsideIt() throws {
        let store = ReviewProgressStore()
        let a = file("A.swift"), b = file("B.swift")
        let answers = [a.id: try text("+a"), b.id: try text("+b")]
        var changes = open([a, b], store: store)
        land(&changes, [a, b], answers)
        changes.toggleViewed(a.id)
        var turn = open([b], tapped: b, store: store)
        land(&turn, [b], answers)
        turn.toggleViewed(b.id)

        var reopened = open([a, b], store: store)
        land(&reopened, [a, b], answers)
        XCTAssertEqual(reopened.viewedFileIDs, [a.id, b.id])
    }

    func testOnlyACompleteSuccessfulStatusForgetsFilesItNoLongerLists() throws {
        let store = ReviewProgressStore()
        let a = file("A.swift"), b = file("B.swift")
        var review = open([a, b], store: store)
        review.toggleFile(a.id)
        review.toggleFile(b.id)

        for unproven in [nil, status([a], truncated: true), status([a], truncated: nil), status(nil, truncated: false),
                         status([], isGit: false, truncated: false)] {
            store.prune(to: unproven, in: "repo")
        }
        XCTAssertEqual(open([a, b], store: store).collapsedFileIDs, [a.id, b.id])

        store.prune(to: status([a], truncated: false), in: "repo")
        XCTAssertEqual(open([a, b], store: store).collapsedFileIDs, [a.id])
    }

    func testTheTappedFileOpensWithoutForgettingItsFold() {
        let store = ReviewProgressStore()
        let a = file("A.swift"), b = file("B.swift")
        var review = open([a, b], store: store)
        review.toggleFile(a.id)

        XCTAssertEqual(open([a, b], tapped: a, store: store).collapsedFileIDs, [])
        XCTAssertEqual(open([a, b], store: store).collapsedFileIDs, [a.id])
    }

    func testFoldersAndServersKeepSeparateProgress() throws {
        let store = ReviewProgressStore()
        let a = file("A.swift")
        var here = open([a], in: "server-1|folder", store: store)
        land(&here, [a], [a.id: try text("+a")])
        here.toggleViewed(a.id)

        var there = open([a], in: "server-2|folder", store: store)
        land(&there, [a], [a.id: try text("+a")])
        XCTAssertEqual(there.viewedFileIDs, [])
        XCTAssertEqual(there.collapsedFileIDs, [])
    }
}
