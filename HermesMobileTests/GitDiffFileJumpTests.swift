import XCTest
@testable import HermesMobile

@MainActor
final class GitDiffFileJumpTests: XCTestCase {
    private func file(_ path: String) -> GitFile {
        GitFile(path: path, status: "M", staged: false, unstaged: true, untracked: false, conflict: false, additions: 1, deletions: 0)
    }

    /// Lands every file's text answer, as the loader's last publish does.
    private func land(_ review: inout ReviewDiffProgress, _ files: [GitFile]) throws {
        var inputs: [ReviewDiffFileInput] = []
        var patches: [String: Int] = [:]
        for file in files {
            let diff = try JSONDecoder().decode(GitDiff.self, from: Data(#"{"diff": "@@ -1 +1 @@\n+\#(file.id)"}"#.utf8))
            let input = ReviewDiffFileInput(file: file, state: .loaded(diff))
            inputs.append(input)
            patches[file.id] = ReviewDiffProgress.patch(for: file, state: input.state)
        }
        review.apply(ReviewDiffRowBuilder.rows(for: inputs), patches: patches)
    }

    /// A jump lands on the file's header with its diff open, and picking it again scrolls again.
    /// A default-folded lockfile stays open through later loads and reopened reviews of the same
    /// range, and a viewed file keeps its mark. A branch review's jump stays out of the
    /// uncommitted review's progress, keyed as `GitDiffView` keys it (#1386).
    func testJumpOpensAFoldedFileForGoodKeepsItsViewedMarkAndScrollsAgainOnEveryPick() throws {
        let git = HermesGitHost.client { HermesGitHost.repositoryReply($0) }
        let branch = git.progressScope(.branch, base: "1a2b3c")
        let store = ReviewProgressStore()
        let source = file("App.swift"), lockfile = file("Cargo.lock")
        func open(in scope: String) throws -> ReviewDiffProgress {
            var review = ReviewDiffProgress(files: [source, lockfile], initialFile: nil, store: store, scope: scope)
            try land(&review, [source, lockfile])
            return review
        }
        var review = try open(in: branch)
        review.toggleViewed(source.id)
        XCTAssertEqual(review.collapsedFileIDs, [source.id, lockfile.id])

        let first = GitDiffView.jump(to: lockfile.id, review: &review)
        let second = GitDiffView.jump(to: lockfile.id, review: &review)
        _ = GitDiffView.jump(to: source.id, review: &review)
        try land(&review, [source, lockfile])

        XCTAssertEqual(review.collapsedFileIDs, [], "A later load doesn't refold the lockfile.")
        XCTAssertEqual(review.viewedFileIDs, [source.id])
        XCTAssertEqual(first.anchor, .fileHeader(lockfile.id))
        XCTAssertNotEqual(first.token, second.token, "The same file picked twice scrolls again.")
        let reopened = try open(in: branch)
        XCTAssertEqual(reopened.collapsedFileIDs, [])
        XCTAssertEqual(reopened.viewedFileIDs, [source.id])
        XCTAssertEqual(try open(in: git.progressScope(.uncommitted, base: nil)).collapsedFileIDs, [lockfile.id])
    }

    /// Search matches the folder as well as the name, in any case.
    func testSearchMatchesFolderOrNameIgnoringCase() {
        let files = [file("README.md"), file("HermesMobile/Features/Chat/ChatView.swift"), file("docs/chat.md"), file("Package.swift")]

        XCTAssertEqual(GitDiffFileJumpList.files(files, matching: "CHAT").map(\.id), ["HermesMobile/Features/Chat/ChatView.swift", "docs/chat.md"])
        XCTAssertEqual(GitDiffFileJumpList.files(files, matching: "features/").map(\.id), ["HermesMobile/Features/Chat/ChatView.swift"])
        XCTAssertEqual(GitDiffFileJumpList.files(files, matching: "  ").count, 4, "A blank query lists every file.")
    }
}
