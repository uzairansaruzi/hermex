import XCTest
@testable import HermesMobile

/// Chat link destinations that name a workspace file, resolved to the workspace-relative
/// path and position the source viewer opens.
final class FileReferenceTests: XCTestCase {
    private let root = "/Users/hermes/projects/app"

    private func parse(_ destination: String, root: String? = nil) -> FileReference? {
        FileReference.parse(destination, workspaceRoot: root ?? self.root)
    }

    // MARK: - Accepted syntaxes

    func testFileURLWithLineAndColumnSuffix() {
        let reference = parse("file:///Users/hermes/projects/app/Sources/ChatView.swift:12:3")
        XCTAssertEqual(reference, FileReference(path: "Sources/ChatView.swift", line: 12, column: 3))
        XCTAssertEqual(reference?.label, "ChatView.swift:12:3")
    }

    func testFileURLWithGitHubStyleFragment() {
        XCTAssertEqual(
            parse("file:///Users/hermes/projects/app/README.md#L8C2"),
            FileReference(path: "README.md", line: 8, column: 2)
        )
        XCTAssertEqual(parse("file:///Users/hermes/projects/app/README.md#l8"), FileReference(path: "README.md", line: 8, column: nil))
    }

    func testAbsolutePathUnderWorkspace() {
        XCTAssertEqual(
            parse("/Users/hermes/projects/app/Sources/Main.swift:40"),
            FileReference(path: "Sources/Main.swift", line: 40, column: nil)
        )
    }

    func testDotRelativePaths() {
        XCTAssertEqual(parse("./Package.swift"), FileReference(path: "Package.swift", line: nil, column: nil))
        XCTAssertEqual(parse("./Sources/../Tests/AppTests.swift:2"), FileReference(path: "Tests/AppTests.swift", line: 2, column: nil))
    }

    func testTildeExpandsToTheHomeTheWorkspaceSitsIn() {
        XCTAssertEqual(parse("~/projects/app/docs/guide.md"), FileReference(path: "docs/guide.md", line: nil, column: nil))
        XCTAssertEqual(
            parse("~/app/main.py", root: "/home/hermes/app"),
            FileReference(path: "main.py", line: nil, column: nil)
        )
    }

    func testPercentEncodedAndQueryDestinations() {
        XCTAssertEqual(parse("./docs/release%20notes.md?x=1#L3"), FileReference(path: "docs/release notes.md", line: 3, column: nil))
        XCTAssertEqual(parse("<file:///Users/hermes/projects/app/a%20b.txt>"), FileReference(path: "a b.txt", line: nil, column: nil))
    }

    func testWorkspaceRootToleratesTrailingSlashAndWhitespace() {
        XCTAssertEqual(parse("./a.swift", root: " /Users/hermes/projects/app/ "), FileReference(path: "a.swift", line: nil, column: nil))
    }

    func testZeroPositionsAreDropped() {
        XCTAssertEqual(parse("./a.swift:0"), FileReference(path: "a.swift", line: nil, column: nil))
        XCTAssertEqual(parse("./a.swift:5:0"), FileReference(path: "a.swift", line: 5, column: nil))
    }

    /// The transcript renderer builds a `URL` from the link destination and the chat
    /// handler reads back `absoluteString`, which percent-encodes spaces and keeps
    /// positions and fragments; the parser must accept what comes out of that trip.
    func testSurvivesTheURLRoundTripTheTranscriptRendererApplies() throws {
        let cases: [(destination: String, expected: FileReference)] = [
            ("./docs/release notes.md:3", FileReference(path: "docs/release notes.md", line: 3, column: nil)),
            ("~/projects/app/docs/guide.md#L4C2", FileReference(path: "docs/guide.md", line: 4, column: 2)),
            ("/Users/hermes/projects/app/Sources/Main.swift:40:7", FileReference(path: "Sources/Main.swift", line: 40, column: 7)),
            ("file:///Users/hermes/projects/app/a%20b.txt#L9", FileReference(path: "a b.txt", line: 9, column: nil)),
        ]
        for (destination, expected) in cases {
            let url = try XCTUnwrap(URL(string: destination), destination)
            XCTAssertEqual(parse(url.absoluteString), expected, destination)
        }
    }

    // MARK: - Rejections

    func testRejectsTraversalOutOfTheWorkspace() {
        XCTAssertNil(parse("../secrets.env"))
        XCTAssertNil(parse("./src/../../other/file.swift"))
        XCTAssertNil(parse("file:///Users/hermes/projects/app/../app2/file.swift"))
        XCTAssertNil(parse("/Users/hermes/projects/app-other/file.swift"))
        XCTAssertNil(parse("~/other/file.swift"))
    }

    func testRejectsTheWorkspaceItselfAndTheFilesystemRoot() {
        XCTAssertNil(parse("/Users/hermes/projects/app"))
        XCTAssertNil(parse("./"))
        XCTAssertNil(parse("/"))
    }

    func testRejectsWebAndBareRelativeLinks() {
        XCTAssertNil(parse("https://example.com/Users/hermes/projects/app/a.swift"))
        XCTAssertNil(parse("mailto:hermes@example.com"))
        XCTAssertNil(parse("Sources/Main.swift:12"))
        XCTAssertNil(parse("README.md"))
    }

    func testRejectsTildeWhenTheWorkspaceIsNotUnderAHome() {
        XCTAssertNil(parse("~/app/a.swift", root: "/srv/app"))
    }

    func testRejectsWithoutAWorkspaceRoot() {
        XCTAssertNil(parse("./a.swift", root: ""))
        XCTAssertNil(FileReference.parse("./a.swift", workspaceRoot: nil))
        XCTAssertNil(parse("./a.swift", root: "relative/root"))
    }
}
