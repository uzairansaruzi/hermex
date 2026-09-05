import XCTest
@testable import HermesMobile

/// Standard `![alt](path)` images in an assistant message become transcript media when
/// they name a raster image on the server's filesystem. Containment is the server's job:
/// `/api/media` owns the allow-list, and chat images live in its attachment store rather
/// than in any workspace.
final class TranscriptMarkdownImageTests: XCTestCase {
    private let workspace = "/Users/hermes/projects/app"

    func testResolvesAnAbsoluteWorkspaceImage() throws {
        let segments = TranscriptMediaParser.segments(
            in: "Here it is: ![Login screen](/Users/hermes/projects/app/shots/login.png) done",
            workspaceRoot: workspace
        )

        let media = try XCTUnwrap(mediaReferences(in: segments).first)
        XCTAssertEqual(media.rawReference, "/Users/hermes/projects/app/shots/login.png")
        XCTAssertEqual(media.altText, "Login screen")
        XCTAssertEqual(media.accessibilityName, "Login screen")
        XCTAssertEqual(segments.first, .text("Here it is: "))
        XCTAssertEqual(segments.last, .text(" done"))
    }

    func testResolvesRelativeAndHomeRelativeImages() throws {
        for destination in ["./shots/login.png", "../app/shots/login.png", "~/projects/app/shots/login.png"] {
            let segments = TranscriptMediaParser.segments(
                in: "![](\(destination))",
                workspaceRoot: workspace
            )

            let media = try XCTUnwrap(mediaReferences(in: segments).first, destination)
            XCTAssertEqual(media.rawReference, "/Users/hermes/projects/app/shots/login.png", destination)
        }
    }

    func testFallsBackToFileNameWithoutAltText() throws {
        let segments = TranscriptMediaParser.segments(
            in: "![](/Users/hermes/projects/app/shots/login.png)",
            workspaceRoot: workspace
        )

        let media = try XCTUnwrap(mediaReferences(in: segments).first)
        XCTAssertNil(media.altText)
        XCTAssertEqual(media.accessibilityName, "login.png")
    }

    func testIgnoresTitleAndAngleBrackets() throws {
        let titled = TranscriptMediaParser.segments(
            in: "![Shot](/Users/hermes/projects/app/a.png \"After the fix\")",
            workspaceRoot: workspace
        )
        XCTAssertEqual(try XCTUnwrap(mediaReferences(in: titled).first).rawReference, "/Users/hermes/projects/app/a.png")

        let bracketed = TranscriptMediaParser.segments(
            in: "![Shot](</Users/hermes/projects/app/my shot.png>)",
            workspaceRoot: workspace
        )
        XCTAssertEqual(
            try XCTUnwrap(mediaReferences(in: bracketed).first).rawReference,
            "/Users/hermes/projects/app/my shot.png"
        )
    }

    /// The server keeps chat images in its own attachment store, outside every workspace,
    /// so an image outside the workspace is the normal case rather than an attack. The
    /// phone normalizes the path and `/api/media` decides what it will serve.
    func testResolvesImagesOutsideTheWorkspace() throws {
        let attachment = TranscriptMediaParser.segments(
            in: "![Image](file:///Users/hermes/.hermes/webui/attachments/abc/image_1788.jpg)",
            workspaceRoot: workspace
        )
        XCTAssertEqual(
            try XCTUnwrap(mediaReferences(in: attachment).first).rawReference,
            "/Users/hermes/.hermes/webui/attachments/abc/image_1788.jpg"
        )

        let screenshot = TranscriptMediaParser.segments(
            in: "![](/tmp/shot.png)",
            workspaceRoot: workspace
        )
        XCTAssertEqual(
            try XCTUnwrap(mediaReferences(in: screenshot).first).rawReference,
            "/tmp/shot.png"
        )
    }

    func testTraversalIsNormalizedRatherThanCarriedThrough() throws {
        let segments = TranscriptMediaParser.segments(
            in: "![x](./../other/../shots/login.png)",
            workspaceRoot: workspace
        )

        XCTAssertEqual(
            try XCTUnwrap(mediaReferences(in: segments).first).rawReference,
            "/Users/hermes/projects/shots/login.png"
        )
    }

    func testAbsoluteImagesResolveWithoutAWorkspaceRoot() throws {
        let segments = TranscriptMediaParser.segments(in: "![x](/tmp/shot.png)")

        XCTAssertEqual(try XCTUnwrap(mediaReferences(in: segments).first).rawReference, "/tmp/shot.png")
    }

    func testRelativeImagesNeedAWorkspaceRoot() {
        let markdown = "![x](./shots/login.png)"

        XCTAssertEqual(TranscriptMediaParser.segments(in: markdown), [.text(markdown)])
    }

    func testLeavesRemoteAndBareRelativeImagesToTheMarkdownRenderer() {
        let untouched = [
            "![badge](https://img.example.test/badge.svg)",
            "![x](shots/login.png)",
            "![notes](/Users/hermes/projects/app/notes.txt)"
        ]

        for markdown in untouched {
            let segments = TranscriptMediaParser.segments(in: markdown, workspaceRoot: workspace)
            XCTAssertEqual(segments, [.text(markdown)], markdown)
        }
    }

    /// CommonMark allows nested and escaped delimiters, and macOS hands out duplicate
    /// names like `build (1)`, so cutting at the first `)` would blank exactly the images
    /// this is meant to show.
    func testHandlesNestedAndEscapedDelimiters() throws {
        let nested = TranscriptMediaParser.segments(
            in: "![Build (1)](/tmp/build(1)/shot.png) after",
            workspaceRoot: workspace
        )
        let nestedMedia = try XCTUnwrap(mediaReferences(in: nested).first)
        XCTAssertEqual(nestedMedia.rawReference, "/tmp/build(1)/shot.png")
        XCTAssertEqual(nestedMedia.altText, "Build (1)")
        XCTAssertEqual(nested.last, .text(" after"))

        let escaped = TranscriptMediaParser.segments(
            in: #"![x](/tmp/a\)b.png)"#,
            workspaceRoot: workspace
        )
        XCTAssertEqual(
            try XCTUnwrap(mediaReferences(in: escaped).first).rawReference,
            "/tmp/a)b.png"
        )
    }

    func testUnclosedDelimitersStayOrdinaryMarkdown() {
        for markdown in ["![x(/tmp/shot.png)", "![x](/tmp/shot.png"] {
            XCTAssertEqual(
                TranscriptMediaParser.segments(in: markdown, workspaceRoot: workspace),
                [.text(markdown)],
                markdown
            )
        }
    }

    func testSkipsImagesInCode() {
        let fenced = """
        ```md
        ![x](/Users/hermes/projects/app/shots/login.png)
        ```
        """
        XCTAssertTrue(mediaReferences(in: TranscriptMediaParser.segments(in: fenced, workspaceRoot: workspace)).isEmpty)

        let inline = "Write `![x](/Users/hermes/projects/app/shots/login.png)` in the doc"
        XCTAssertTrue(mediaReferences(in: TranscriptMediaParser.segments(in: inline, workspaceRoot: workspace)).isEmpty)
    }

    func testMediaPathToleratesATrailingSlashOnTheRoot() {
        XCTAssertEqual(
            FileReference.absoluteMediaPath("./shots/login.png", workspaceRoot: "/Users/hermes/projects/app/"),
            "/Users/hermes/projects/app/shots/login.png"
        )
    }

    private func mediaReferences(in segments: [TranscriptMediaSegment]) -> [TranscriptMediaReference] {
        segments.compactMap { segment in
            if case let .media(reference) = segment { return reference }
            return nil
        }
    }
}
