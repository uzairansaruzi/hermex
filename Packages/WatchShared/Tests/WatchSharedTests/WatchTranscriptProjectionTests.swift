import Foundation
import Testing
@testable import WatchShared

@Suite struct WatchTranscriptProjectionTests {
    @Test func splitsCodeFencesImagesAndStripsAttachedFiles() {
        let message = WatchPhoneMessageHint(
            id: "m1",
            role: .assistant,
            text: """
            Intro
            ```swift
            print("hi")
            ```
            ![shot](/tmp/workspace/shot.png)
            See MEDIA:other.jpg later

            [Attached files: /tmp/workspace/clip.m4a]
            """,
            attachments: [
                WatchPhoneAttachmentHint(name: "clip.m4a", path: "/tmp/workspace/clip.m4a", mime: "audio/m4a", isImage: false),
                WatchPhoneAttachmentHint(name: "extra.png", path: "/tmp/workspace/extra.png", mime: "image/png", isImage: true),
            ]
        )

        let blocks = WatchTranscriptProjection.blocks(for: message)
        #expect(blocks.contains(where: { if case .text(let role, let text) = $0.kind { return role == .assistant && text.contains("Intro") } else { return false } }))
        #expect(blocks.contains(where: { if case .code(let language, let text, false) = $0.kind { return language == "swift" && text.contains("print") } else { return false } }))
        #expect(blocks.contains(where: { if case .image(let path, _, let alt) = $0.kind { return path == "/tmp/workspace/shot.png" && alt == "shot" } else { return false } }))
        #expect(blocks.contains(where: { if case .image(let path, _, _) = $0.kind { return path == "other.jpg" } else { return false } }))
        #expect(blocks.contains(where: { if case .unsupported("audio", let summary) = $0.kind { return summary == "clip.m4a" } else { return false } }))
        #expect(blocks.contains(where: { if case .image(let path, _, _) = $0.kind { return path == "/tmp/workspace/extra.png" } else { return false } }))
        #expect(blocks.contains(where: { if case .text(_, let text) = $0.kind { return text.contains("[Attached files:") } else { return false } }) == false)
    }

    @Test func toolResultIsASingleToolRow() {
        let message = WatchPhoneMessageHint(
            id: "t1",
            role: .user,
            text: String(repeating: "x", count: 400),
            tools: [WatchPhoneToolHint(title: "bash", state: "done", summary: nil)],
            isToolResult: true
        )
        let blocks = WatchTranscriptProjection.blocks(for: message)
        #expect(blocks.count == 1)
        guard case .tool(let title, let state, let summary) = blocks[0].kind else {
            Issue.record("expected a tool block")
            return
        }
        #expect(title == "bash")
        #expect(state == "done")
        #expect((summary?.count ?? 0) <= WatchTranscriptProjection.maximumToolSummaryCharacters)
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test func longReplyIsShortenedInsteadOfRejected() {
        let message = WatchPhoneMessageHint(
            id: "m1",
            role: .assistant,
            text: String(repeating: "a", count: 21_000)
        )
        let blocks = WatchTranscriptProjection.blocks(for: message)
        #expect(blocks.count == 1)
        guard case .text(_, let text) = blocks[0].kind else {
            Issue.record("expected text")
            return
        }
        #expect(text.count <= WatchTranscriptProjection.maximumMessageCharacters)
        #expect(text.hasSuffix("…"))
        #expect(text.utf8.count <= 16_384)
    }

    @Test func assistantToolCallsPrecedeText() {
        let message = WatchPhoneMessageHint(
            id: "a1",
            role: .assistant,
            text: "Done.",
            tools: [WatchPhoneToolHint(title: "read", state: "called", summary: "README.md")]
        )
        let blocks = WatchTranscriptProjection.blocks(for: message)
        #expect(blocks.count == 2)
        guard case .tool(let title, let state, let summary) = blocks[0].kind else {
            Issue.record("expected a tool block first")
            return
        }
        #expect(title == "read")
        #expect(state == "called")
        #expect(summary == "README.md")
        guard case .text(let role, let text) = blocks[1].kind else {
            Issue.record("expected assistant text")
            return
        }
        #expect(role == .assistant)
        #expect(text == "Done.")
    }

    @Test func synthesizedPhotoCaptionMatchesIOSComposer() {
        let uploaded = WatchChatAttachment(
            name: "watch-photo.jpg",
            path: "/tmp/workspace/watch-photo.jpg",
            mime: "image/jpeg",
            size: 12,
            isImage: true
        )
        #expect(
            WatchTranscriptProjection.chatMessageText(draft: "", attachments: [uploaded])
            == "I've uploaded 1 file(s): /tmp/workspace/watch-photo.jpg"
        )
        #expect(
            WatchTranscriptProjection.chatMessageText(draft: "look", attachments: [uploaded])
            == "look\n\n[Attached files: /tmp/workspace/watch-photo.jpg]"
        )
    }

    // MARK: - Wrist Markdown

    private func assistantText(_ raw: String) -> String {
        let blocks = WatchTranscriptProjection.blocks(
            for: WatchPhoneMessageHint(id: "md", role: .assistant, text: raw)
        )
        for block in blocks {
            if case .text(_, let text) = block.kind { return text }
        }
        Issue.record("expected a text block")
        return ""
    }

    @Test func headingsKeepTheirLevelAndLoseTheirHashes() {
        let text = assistantText("### Verified configuration\nIt works.")
        #expect(text.hasPrefix("### Verified configuration"))

        let lines = WatchTranscriptProjection.wristLines(in: text)
        #expect(lines.first == .heading(level: 3, text: "Verified configuration"))
        #expect(lines.last == .paragraph(text: "It works."))
    }

    @Test func closedAtxHeadingAndThematicBreakAreNormalized() {
        let lines = WatchTranscriptProjection.wristLines(
            in: WatchTranscriptProjection.wristMarkdown("## Setup ##\n\n---\n\nDone")
        )
        #expect(lines.contains(.heading(level: 2, text: "Setup")))
        #expect(lines.contains(.paragraph(text: "Done")))
        #expect(lines.contains(where: { if case .paragraph(let t) = $0 { return t.contains("---") } else { return false } }) == false)
    }

    @Test func boldBareURLBecomesAReadableLink() {
        let text = assistantText("Open **https://aaryans-mac-mini.taild36793.ts.net/** on your iPhone.")
        #expect(text == "Open **[aaryans-mac-mini…ts.net](https://aaryans-mac-mini.taild36793.ts.net/)** on your iPhone.")
        #expect(text.contains("taild36793.ts.net/**") == false)
    }

    @Test func longURLWithAPathKeepsTheHostAndSaysThereIsMore() {
        #expect(
            WatchTranscriptProjection.shortURLLabel("https://get-hermes.ai/api-docs/sessions?page=2")
            == "get-hermes.ai/…"
        )
        #expect(WatchTranscriptProjection.shortURLLabel("https://www.example.com") == "example.com")
        #expect(WatchTranscriptProjection.shortURLLabel("mailto:someone@example.com").count <= 28)
    }

    @Test func markdownLinkShowsItsLabelAndKeepsItsDestination() {
        let text = assistantText("See [the API docs](https://get-hermes.ai/api-docs/) for more.")
        #expect(text == "See [the API docs](https://get-hermes.ai/api-docs/) for more.")

        let bare = assistantText("See [https://get-hermes.ai/api-docs/](https://get-hermes.ai/api-docs/).")
        #expect(bare == "See [get-hermes.ai/…](https://get-hermes.ai/api-docs/).")
    }

    @Test func listsBecomeBulletsAndKeepOrderedNumbers() {
        let text = assistantText("""
        - first
        * second
          - nested
        - [ ] todo
        - [x] done

        1. one
        2) two
        """)
        let lines = WatchTranscriptProjection.wristLines(in: text)
        #expect(lines.contains(.bullet(depth: 0, text: "first")))
        #expect(lines.contains(.bullet(depth: 0, text: "second")))
        #expect(lines.contains(.bullet(depth: 1, text: "nested")))
        #expect(lines.contains(.bullet(depth: 0, text: "☐ todo")))
        #expect(lines.contains(.bullet(depth: 0, text: "☑ done")))
        #expect(lines.contains(.ordered(number: "1", text: "one")))
        #expect(lines.contains(.ordered(number: "2", text: "two")))
    }

    @Test func blockquotesKeepOneMarkerForTheWatchBar() {
        let text = assistantText(">> careful here")
        #expect(text == "> careful here")
        #expect(WatchTranscriptProjection.wristLines(in: text) == [.quote(text: "careful here")])
    }

    @Test func inlineCodeIsVerbatimAndURLsInsideItAreLeftAlone() {
        let text = assistantText("Run `curl https://aaryans-mac-mini.taild36793.ts.net/health` now.")
        #expect(text == "Run `curl https://aaryans-mac-mini.taild36793.ts.net/health` now.")
    }

    @Test func softWrappedParagraphsFoldIntoOneLine() {
        let text = assistantText("The server is\nreachable over\nthe tailnet.")
        #expect(text == "The server is reachable over the tailnet.")
    }

    @Test func untaggedAndPlainTextFencesDropTheirLabel() {
        #expect(WatchTranscriptProjection.displayLanguage(nil) == nil)
        #expect(WatchTranscriptProjection.displayLanguage("text") == nil)
        #expect(WatchTranscriptProjection.displayLanguage("TXT") == nil)
        #expect(WatchTranscriptProjection.displayLanguage("swift") == "swift")

        let blocks = WatchTranscriptProjection.blocks(
            for: WatchPhoneMessageHint(id: "f", role: .assistant, text: "```text\nhttps://example.com\n```")
        )
        guard case .code(let language, _, _) = blocks[0].kind else {
            Issue.record("expected code")
            return
        }
        #expect(language == nil)
    }

    private func codeBlock(_ raw: String) -> (text: String, isTruncated: Bool) {
        let blocks = WatchTranscriptProjection.blocks(
            for: WatchPhoneMessageHint(id: "f", role: .assistant, text: raw)
        )
        for block in blocks {
            if case .code(_, let text, let isTruncated) = block.kind { return (text, isTruncated) }
        }
        Issue.record("expected a code block")
        return ("", false)
    }

    @Test func aURLInsideACodeFenceNeverBreaksMidHostname() {
        let block = codeBlock("```text\nhttps://aaryans-mac-mini.taild36793.ts.net (tailnet only)\n```")
        #expect(block.text == "aaryans-mac-mini…net (tailnet only)")
        #expect(block.isTruncated)

        let longest = block.text
            .split(whereSeparator: \.isWhitespace)
            .map(\.count)
            .max() ?? 0
        #expect(longest <= WatchTranscriptProjection.maximumCodeTokenCharacters)
    }

    @Test func aURLInsideCodeKeepsItsIndentAndSurroundingPunctuation() {
        let block = codeBlock("```sh\necho hi\n  curl \"https://get-hermes.ai/api-docs/sessions?page=2\" | jq\n```")
        #expect(block.text == "echo hi\n  curl \"get-hermes.ai/…\" | jq")
        #expect(block.isTruncated)
    }

    @Test func overWideCodeLinesAreClippedAndFlagged() {
        let block = codeBlock("```swift\nlet value = \(String(repeating: "abcde ", count: 20))\n```")
        #expect(block.isTruncated)
        #expect(block.text.count == WatchTranscriptProjection.maximumCodeLineCharacters)
        #expect(block.text.hasSuffix("…"))
    }

    @Test func ordinaryCodeIsLeftExactlyAsItWas() {
        let block = codeBlock("```swift\nlet x = 1\nprint(x)\n```")
        #expect(block.text == "let x = 1\nprint(x)")
        #expect(block.isTruncated == false)
    }

    @Test func clippedReplyNeverLeavesADanglingLink() {
        let filler = String(repeating: "word ", count: 150)
        let text = assistantText(filler + "[the API docs](https://get-hermes.ai/api-docs/sessions)")
        #expect(text.count <= WatchTranscriptProjection.maximumMessageCharacters)
        #expect(text.contains("](") == false)
        #expect(text.contains("[") == false)
        #expect(text.hasSuffix("…"))
    }

    @Test func unclippedTextKeepsALoneBracketOrBacktick() {
        #expect(assistantText("Check array[0] and the ` char.") == "Check array[0] and the ` char.")
    }

    @Test func plainTextIsWhatTheWatchSpeaks() {
        let text = assistantText("""
        ### Verified configuration

        Open **https://aaryans-mac-mini.taild36793.ts.net/** on your iPhone.

        - `brew services` is running
        """)
        let spoken = WatchTranscriptProjection.plainText(text)
        #expect(spoken.contains("#") == false)
        #expect(spoken.contains("*") == false)
        #expect(spoken.contains("`") == false)
        #expect(spoken.contains("Verified configuration"))
        #expect(spoken.contains("aaryans-mac-mini…ts.net"))
        #expect(spoken.contains("brew services is running"))
    }

    @Test func truncatesLongCode() {
        let message = WatchPhoneMessageHint(
            id: "c1",
            role: .assistant,
            text: "```\n\(String(repeating: "a", count: 2_000))\n```"
        )
        let blocks = WatchTranscriptProjection.blocks(for: message)
        guard case .code(_, let text, true) = blocks[0].kind else {
            Issue.record("expected truncated code")
            return
        }
        #expect(text.count <= WatchTranscriptProjection.maximumCodeCharacters)
        #expect(text.hasSuffix("…"))
    }
}
