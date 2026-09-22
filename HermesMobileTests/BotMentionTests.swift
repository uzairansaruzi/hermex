import XCTest
import UIKit
@testable import HermesMobile

final class BotMentionTests: XCTestCase {
    private func bot(_ id: String, title: String? = nil, display: String? = nil) -> BotProfile {
        var row: [String: BotJSON] = ["name": .string(id)]
        if let title { row["ui_meta"] = .object(["hermes-bots": .object(["title": .string(title)])]) }
        if let display { row["display_name"] = .string(display) }
        return BotProfile(.object(row))!
    }

    func testNameFormsAndReservedTokens() {
        XCTAssertEqual(BotMentions.nameForms("  Research + Buddy!  "), ["research-buddy", "researchbuddy"])
        XCTAssertEqual(BotMentions.nameForms("A_B-2"), ["a_b-2"])
        for name in ["all", "EVERYONE", "user", "default", "Hermes", "_helper", "🤖"] {
            XCTAssertTrue(BotMentions.nameForms(name).isEmpty, name)
        }
        XCTAssertEqual(BotMentions.nameForms("-Helper-"), ["helper"])
    }

    func testFriendlyNamesAndMissingMetadata() {
        let mentions = BotMentions(roster: [bot("research", title: "Research Buddy", display: "Scholar"), bot("plain")], excluding: "dev")
        XCTAssertEqual(mentions.completions(query: "").map(\.tag), ["research-buddy", "plain"])
        XCTAssertEqual(mentions.resolve("@researchbuddy @scholar @plain").map(\.id), ["research", "plain"])
        XCTAssertEqual(mentions.completions(query: "RESEARCH").map(\.id), ["research"])
        XCTAssertEqual(mentions.completions(query: "plain").map(\.id), ["plain"])
        XCTAssertTrue(mentions.completions(query: "buddy").isEmpty)
        XCTAssertEqual(BotMentions(roster: [bot("research", display: "Scholar")], excluding: "dev")
            .completions(query: "sch").map(\.tag), ["scholar"])
    }

    func testAmbiguousFormsStayDroppedEvenWithThreeOwners() {
        let mentions = BotMentions(roster: [bot("one", title: "Same Name"), bot("two", display: "Same Name"),
                                            bot("three", title: "Same Name")], excluding: "dev")
        XCTAssertTrue(mentions.resolve("@same-name @samename").isEmpty)
        XCTAssertEqual(mentions.completions(query: "").map(\.tag), ["one", "two", "three"])
        for completion in mentions.completions(query: "") {
            XCTAssertEqual(mentions.resolve("@" + completion.tag).map(\.id), [completion.id])
        }
        XCTAssertEqual(mentions.resolve("@one @two @three").map(\.id), ["one", "two", "three"])
        let handleCollision = BotMentions(roster: [bot("one"), bot("two", title: "One")], excluding: "dev")
        XCTAssertTrue(handleCollision.resolve("@one").isEmpty)
        XCTAssertEqual(handleCollision.completions(query: "").map(\.tag), ["two"])
    }

    func testOpenBotExcludedAndRenamedDefaultRetainsHermesAlias() {
        let roster = [bot("default", title: "Chief of Staff"), bot("dev", title: "Hermes")]
        let mentions = BotMentions(roster: roster, excluding: "dev")
        XCTAssertEqual(mentions.resolve("@hermes @default @chief-of-staff @chiefofstaff @dev").map(\.id), ["default"])
        XCTAssertEqual(mentions.completions(query: "hermes").map(\.tag), ["chief-of-staff"])
        let fromDefault = BotMentions(roster: roster, excluding: "default")
        XCTAssertTrue(fromDefault.resolve("@hermes @chief-of-staff").isEmpty)
        XCTAssertEqual(fromDefault.completions(query: "").map(\.tag), ["dev"])
        XCTAssertEqual(BotMentions(roster: [bot("default")], excluding: "dev").completions(query: "").map(\.tag), ["hermes"])
    }

    func testCodeEmailUnknownAndRepeatedMentions() {
        let mentions = BotMentions(roster: [bot("research")], excluding: "dev")
        let ignored = "user@research.com `@research`\n```swift\n@research\n``` @unknown"
        XCTAssertTrue(mentions.annotation(for: ignored).isEmpty)
        XCTAssertEqual(mentions.resolve(ignored + "\n@RESEARCH please @research").map(\.id), ["research"])
    }

    func testExactAnnotationBytesAndMentionOrder() {
        let mentions = BotMentions(roster: [bot("research", title: "Research Buddy"), bot("default")], excluding: "dev")
        let suffix = ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool (agents on other connected machines are reachable too — the Desktop relays it); never forward the user’s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
        let prefix = "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: "
        let first = "@research = agent profile \"research\" (\"Research Buddy\")"
        let second = "@hermes = agent profile \"default\""
        XCTAssertEqual(Array(mentions.annotation(for: "@research").utf8), Array((prefix + first + suffix).utf8))
        XCTAssertEqual(Array(mentions.annotation(for: "@hermes @research @hermes").utf8), Array((prefix + second + "; " + first + suffix).utf8))
    }

    func testCompletionLimitPrefixAndConnectionLocalRoster() {
        let roster = (0..<12).map { bot("bot-\($0)", title: "Helper \($0)") }
        XCTAssertEqual(BotMentions(roster: roster, excluding: "bot-0").completions(query: "").count, 8)
        XCTAssertEqual(BotMentions(roster: roster, excluding: "bot-0").completions(query: "bot-11").map(\.tag), ["helper-11"])
        let first = BotMentions(roster: [bot("same", title: "First")], excluding: "dev")
        let second = BotMentions(roster: [bot("same", title: "Second")], excluding: "dev")
        XCTAssertTrue(first.resolve("@second").isEmpty)
        XCTAssertTrue(second.resolve("@first").isEmpty)
    }

    func testCaretCompletionPreservesSurroundingTextAndUTF16Selection() throws {
        let draft = "🤖 Ask @res about this"
        let caret = ("🤖 Ask @res" as NSString).length
        let trigger = try XCTUnwrap(BotMentionTrigger.detect(in: draft, selection: NSRange(location: caret, length: 0)))
        XCTAssertEqual(trigger.query, "res")
        let result = trigger.applying(tag: "research", to: draft)
        XCTAssertEqual(result.draft, "🤖 Ask @research about this")
        XCTAssertEqual(result.selection, NSRange(location: ("🤖 Ask @research " as NSString).length, length: 0))
        XCTAssertNotNil(BotMentionTrigger.detect(in: "@", selection: NSRange(location: 1, length: 0)))
        for text in ["mail@research", "(@research", "@research ", "@name@connection"] {
            XCTAssertNil(BotMentionTrigger.detect(in: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        }
        XCTAssertNil(BotMentionTrigger.detect(in: "@res", selection: NSRange(location: 1, length: 2)))
        XCTAssertNil(BotMentionTrigger.detect(in: "@res", selection: NSRange(location: 99, length: 0)))
    }

    func testAuthoredNoteLikeTextIsPreserved() {
        let mentions = BotMentions(roster: [bot("research")], excluding: "dev")
        let original = "@research explain this\n\n[@mentions resolved from the Bot Mode roster: my own example]"
        XCTAssertEqual(BotMentions.displayText(original), original)
        XCTAssertEqual(BotMentions.displayText(original + mentions.annotation(for: "@research")), original)
        let malformed = mentions.annotation(for: "@research")
            .replacingOccurrences(of: "@research = agent profile", with: "something else")
        XCTAssertEqual(BotMentions.displayText(original + malformed), original + malformed)
    }

    func testTrailingAnnotationHiddenOnlyFromUserPresentation() {
        let mentions = BotMentions(roster: [bot("research", title: "Research [team]")], excluding: "dev")
        let original = " @research please  "
        let sent = original + mentions.annotation(for: original)
        XCTAssertEqual(BotMentions.displayText(sent), original)
        XCTAssertEqual(BotMentions.displayText(sent + "\nmore user text"), sent + "\nmore user text")
        let projected = BotTranscriptProjection.project(history: [
            .object(["role": .string("user"), "text": .string(sent)]),
            .object(["role": .string("assistant"), "text": .string(sent)])
        ], root: "root")
        XCTAssertEqual(projected.messages.map(\.content), [original, sent])
    }
}

@MainActor final class BotMentionSendingTests: XCTestCase {
    func testEveryPromptModeAnnotatesTransportAndHidesLiveAndResumedNote() async throws {
        let target = BotProfile(.object(["name": .string("default"), "display_name": .string("Chief")]))!
        for mode in BotPromptMode.allCases {
            let wire = BotFixtureWire()
            wire.running = mode != .send
            let model = make(wire, roster: [target])
            await model.recover()
            let original = "@chief summarize"
            model.editDraft(original)
            let sent = original + model.mentions.annotation(for: original)
            await model.submit(try XCTUnwrap(model.preparePrompt(mode)))
            let calls = wire.calls.filter { $0.0 == mode.method }
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.1["text"], .string(sent))
            if mode == .send || mode == .queue { XCTAssertEqual(calls.first?.1["queued"], .bool(true)) }
            XCTAssertEqual(model.draft, "")
            model.suspend()
            wire.history = [.object(["role": .string("user"), "text": .string(sent)])]
            wire.inflight = .object(["user": .string(sent)])
            await model.recover()
            XCTAssertEqual(model.messages.first?.content, original)
            // History already lists the prompt, so the live row yields to it.
            XCTAssertTrue(model.liveMessages.isEmpty)
            model.suspend()
        }
    }

    func testStaleActionCannotSendAndFailureKeepsUnannotatedDraft() async throws {
        let target = BotProfile(.object(["name": .string("default")]))!
        let wire = BotFixtureWire()
        let model = make(wire, roster: [target])
        await model.recover()
        model.editDraft("@hermes hello")
        let stale = try XCTUnwrap(model.preparePrompt(.send))
        model.suspend()
        await model.recover()
        await model.submit(stale)
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        wire.submitFailure = .rejected(4002)
        await model.send()
        XCTAssertEqual(model.draft, "@hermes hello")
        model.suspend()
    }

    func testAttachmentsKeepReferencesAndResolveOnlyTheTypedDraft() async throws {
        let target = BotProfile(.object(["name": .string("default")]))!
        let fileBot = BotProfile(.object(["name": .string("file")]))!
        let wire = BotFixtureWire()
        let model = make(wire, roster: [target, fileBot])
        await model.recover()
        await model.attachments.stage(data: Data("hello".utf8), filename: "note.txt")
        wire.attachFile = { _ in
            .object(["attached": .bool(true), "path": .string("/attachments/note.txt"),
                     "ref_text": .string("@file:/attachments/note.txt")])
        }
        model.editDraft("@hermes read this")
        await model.send()
        let sent = try XCTUnwrap(wire.calls.first { $0.0 == "prompt.submit" }?.1["text"]?.text)
        XCTAssertTrue(sent.contains("@file:/attachments/note.txt"))
        XCTAssertTrue(sent.hasSuffix(model.mentions.annotation(for: "@hermes read this")))
        XCTAssertFalse(sent.contains("agent profile \"file\""))
        model.suspend()
    }

    private func make(_ wire: BotFixtureWire, roster: [BotProfile]) -> BotConversation {
        BotConversation(server: URL(string: "https://webui.example")!,
                        connection: BotConnection(id: UUID(), name: "Test", address: URL(string: "https://bot.example")!, username: "test", password: "test"),
                        profile: BotProfile(.object(["name": .string("inbox-triage")]))!, roster: roster,
                        wire: wire, drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
                        attachmentCopies: BotAttachmentCopies())
    }
}

@MainActor final class BotMentionChipTests: XCTestCase {
    private func bot(_ name: String = "helper", title: String = "Inbox Triage") -> BotProfile {
        BotProfile(.object(["name": .string(name), "ui_meta": .object([
            "hermes-bots": .object(["title": .string(title), "color": .string("#ffffff")])
        ])]))!
    }

    private func catalog(_ roster: [BotProfile]? = nil, avatars: [String: UIImage] = [:]) -> ComposerChipCatalog {
        ComposerChipCatalog(skills: [], bots: BotMentions(roster: roster ?? [bot()], excluding: "dev").chipReferences(avatars: avatars))
    }

    func testSelectionTypedAndRestoredMentionsUseTheSameChips() throws {
        let selected = try XCTUnwrap(BotMentionTrigger.detect(in: "@in", selection: NSRange(location: 3, length: 0)))
            .applying(tag: "inbox-triage", to: "@in")
        let tokens = ComposerChipTokenizer.tokens(in: selected.draft, catalog: catalog())
        XCTAssertEqual(tokens.map(\.source), ["@inbox-triage"])
        XCTAssertEqual(tokens.first?.label, "Inbox Triage")
        XCTAssertEqual(ComposerChipTokenizer.tokens(in: "@HELPER hello", catalog: catalog()).first?.label, "Inbox Triage")
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@helper", catalog: catalog()).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@help ", catalog: catalog()).isEmpty)
        XCTAssertNil(tokens.first?.filePath)
        XCTAssertEqual(ComposerChipTokenizer.spokenText(in: selected.draft, tokens: tokens), "Inbox Triage ")
    }

    func testCodeEmailAmbiguityAndForeignConnectionStayPlainText() {
        let source = "🤖 `@helper` ```\n@helper\n``` mail@helper @unknown @helper now"
        let tokens = ComposerChipTokenizer.tokens(in: source, catalog: catalog())
        XCTAssertEqual(tokens.map(\.source), ["@helper"])
        XCTAssertEqual(tokens.first?.range, (source as NSString).range(of: "@helper", options: .backwards))
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@inbox-triage ", catalog: catalog([bot(), bot("other")])).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@helper@connection ", catalog: catalog()).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@inbox-triage ", catalog: catalog([bot(title: "Other Host")])).isEmpty)
        XCTAssertTrue(ComposerChipTokenizer.tokens(in: "@dev ", catalog: catalog([bot("dev")])).isEmpty)
    }

    func testEditorPreservesTextSelectionAndAtomicBackspace() throws {
        let editor = ComposerChipTextView(frame: CGRect(x: 0, y: 0, width: 350, height: 100))
        editor.font = .preferredFont(forTextStyle: .body)
        editor.chipBots = BotMentions(roster: [bot()], excluding: "dev").chipReferences(avatars: [:])
        let source = "🤖 Ask @helper "
        editor.replaceDocument(with: source)
        XCTAssertEqual(editor.sourceText, source)
        XCTAssertEqual(editor.renderedTokens.count, 1)
        let token = try XCTUnwrap(editor.renderedTokens.first)
        let displayRange = editor.attributedText.composerDisplayRange(forSourceRange: token.range)
        XCTAssertEqual(displayRange.length, 1)
        XCTAssertEqual(editor.attributedText.composerSourceText(in: displayRange), "@helper")
        XCTAssertEqual(editor.attributedText.composerSourceRange(forDisplayRange: displayRange), token.range)
        editor.sourceSelection = NSRange(location: (source as NSString).length, length: 0)
        editor.deleteBackward()
        editor.refreshChipsIfNeeded()
        XCTAssertEqual(editor.sourceText, "🤖 Ask @helper")
        XCTAssertEqual(editor.renderedTokens.count, 1)
        editor.deleteBackward()
        editor.refreshChipsIfNeeded()
        XCTAssertEqual(editor.sourceText, "🤖 Ask ")
        XCTAssertTrue(editor.renderedTokens.isEmpty)
    }

    func testRosterOrAvatarRefreshUpdatesTheChipWithoutChangingTheDraft() throws {
        let editor = ComposerChipTextView(frame: CGRect(x: 0, y: 0, width: 350, height: 100))
        editor.font = .preferredFont(forTextStyle: .body)
        let first = image(.red)
        editor.chipBots = BotMentions(roster: [bot()], excluding: "dev").chipReferences(avatars: ["helper": first])
        editor.replaceDocument(with: "@helper hello")
        let before = try XCTUnwrap(editor.renderedTokens.first)
        editor.chipBots = BotMentions(roster: [bot(title: "New Name")], excluding: "dev").chipReferences(avatars: ["helper": image(.blue)])
        editor.refreshChipsIfNeeded()
        XCTAssertEqual(editor.sourceText, "@helper hello")
        XCTAssertEqual(editor.renderedTokens.first?.label, "New Name")
        XCTAssertNotEqual(editor.renderedTokens.first?.icon, before.icon)
        editor.chipBots = [:]
        editor.refreshChipsIfNeeded()
        XCTAssertEqual(editor.sourceText, "@helper hello")
        XCTAssertTrue(editor.renderedTokens.isEmpty)
    }

    func testChipRendererCachesImagesWithoutSharingDifferentBotAvatars() {
        let first = ComposerChipIcon.bot(ComposerBotReference(profile: bot(), avatar: image(.red)))
        let second = ComposerChipIcon.bot(ComposerBotReference(profile: bot(), avatar: image(.blue)))
        let metrics = ComposerChipMetrics(editorFont: .preferredFont(forTextStyle: .body))
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        func render(_ icon: ComposerChipIcon) -> UIImage {
            ComposerChipRenderer.image(label: "Inbox Triage", icon: icon, metrics: metrics, traits: traits, isRightToLeft: false)
        }
        XCTAssertTrue(render(first) === render(first))
        XCTAssertNotEqual(render(first).pngData(), render(second).pngData())
        let fallback = render(.bot(ComposerBotReference(profile: bot(), avatar: nil)))
        XCTAssertEqual(fallback.size.width, render(.symbol("person")).size.width)
        XCTAssertNotEqual(fallback.pngData(), render(first).pngData())
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}
