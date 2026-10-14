import XCTest
import Observation
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

    func testFileReferencesAreNotMentionsButPunctuatedMentionsAre() {
        let mentions = BotMentions(roster: [bot("docs"), bot("research")], excluding: "dev")
        for path in ["@docs/plan.md", "@docs/", "@docs.md", "@docs\\plan.md", "@docs-v2/x", "@research.swift"] {
            XCTAssertTrue(mentions.annotation(for: "see \(path) please").isEmpty, path)
        }
        XCTAssertEqual(mentions.resolve("@docs, look at @research.").map(\.id), ["docs", "research"])
        XCTAssertEqual(mentions.resolve("ask @research: then (@docs) @docs!").map(\.id), ["research", "docs"])
        XCTAssertEqual(mentions.resolve("@docs? @research's notes").map(\.id), ["docs", "research"])
        XCTAssertEqual(mentions.resolve("open @docs/plan.md then ask @docs...").map(\.id), ["docs"])
        XCTAssertTrue(mentions.resolve("me@docs.io").isEmpty)
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
        let projected = HermesTranscriptProjection.project([
            .object(["id": .number(1), "role": .string("user"), "content": .string(sent)]),
            .object(["id": .number(2), "role": .string("assistant"), "content": .string(sent)])
        ], root: "root")
        XCTAssertEqual(projected.messages.map(\.content), [original, sent])
    }
}

/// `@`mentions in a bot's Bot Chat opened in the main chat (#1145). The host delivers them only
/// there (`tools/bot_mode_dm.py`), so a session sends `@` text as typed. Over #901's
/// socket-level host, whose `profiles.list` is this connection's roster.
@MainActor final class HermesChatMentionTests: XCTestCase {
    private static let server = URL(string: "https://hermes.example")!
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")
    private static let roster: BotJSON = .object(["profiles": .array([
        .object(["name": .string("default")]),
        .object(["name": .string("helper"), "ui_meta": .object(["hermes-bots": .object(["title": .string("Inbox Triage")])])])
    ])])
    /// The same roster, both bots with pictures.
    private static let pictured: BotJSON = .object(["profiles": .array(["default", "helper"].map {
        .object(["name": .string($0), "has_avatar": .bool(true)])
    })])

    /// Every prompt mode sends the typed text with Desktop's identification note after it, while
    /// the chat shows the typed text: the optimistic row, and the queued prompt's receipt.
    func testEveryPromptModeAnnotatesTheSendAndShowsTheTypedText() async throws {
        let chat = await openChat(target: .canonicalChat(profile: "default"))
        XCTAssertEqual(chat.turn.mentions?.completions(query: "").map(\.profile.id), ["helper"],
                       "this connection's other bots, never the open one")
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("@inbox-triage sort today")
        let sent = try XCTUnwrap(chat.writes("prompt.submit").last?["text"]?.text)
        XCTAssertTrue(sent.hasPrefix("@inbox-triage sort today\n\n[@mentions resolved from the Bot Mode roster"))
        XCTAssertTrue(sent.contains("@helper = agent profile \"helper\" (\"Inbox Triage\")"))
        XCTAssertEqual(BotMentions.displayText(sent), "@inbox-triage sort today")
        XCTAssertEqual(chat.model.messages.last?.content, "@inbox-triage sort today")

        chat.host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        chat.host.always("session.steer", .init(result: .object(["status": .string("queued")])))
        chat.host.always("session.redirect", .init(result: .object(["status": .string("queued")])))
        for mode in [BotPromptMode.queue, .steer, .redirect] {
            _ = try await chat.turn.submit("@helper \(mode)", mode: mode)
            let method = mode.call(runtime: "", text: "").method
            let text = try XCTUnwrap(chat.writes(method).last?["text"]?.text)
            XCTAssertEqual(BotMentions.displayText(text), "@helper \(mode)")
            XCTAssertNotEqual(text, "@helper \(mode)", "\(mode) carries the note")
        }
        XCTAssertEqual(chat.turn.queuedPrompt?.contains("[@mentions"), false, "the receipt shows what was typed")
    }

    /// A restored prompt with an attachment hides its note: the host adds its context footer
    /// after the note (`agent/context_references.py`), so the footer and reference lines go
    /// first and the file stays a chip. A note the user typed that only looks like one stays.
    func testARestoredPromptHidesTheNoteBeforeTheHostsContextFooter() throws {
        let helper = try XCTUnwrap(BotProfile(Self.roster["profiles"].list?[1] ?? .null))
        let note = BotMentions(roster: [helper], excluding: "default").annotation(for: "@helper look")
        let sent = "@helper look\n\n@file:`/work/plan.md`"
        let footers = ["\n\n--- Attached Context ---\n\n📄 @file:plan.md (12 tokens)\n# Plan",
                       "\n\n--- Context Warnings ---\n- @file:`/work/plan.md`: file not found",
                       "\n\n--- Context Warnings ---\n- too large\n\n--- Attached Context ---\n\n# Plan"]
        for footer in footers {
            let shown = HermesChatTurnCoordinator.displayed(ChatMessage(role: "user", content: sent + note + footer,
                                                                        timestamp: nil, messageId: nil))
            XCTAssertEqual(shown.content, "@helper look", footer)
            XCTAssertEqual(shown.attachments?.map(\.name), ["plan.md"], footer)
        }

        let typed = note.replacingOccurrences(of: "@helper = agent profile \"helper\" (\"Inbox Triage\")", with: "my notes")
        let shown = HermesChatTurnCoordinator.displayed(ChatMessage(role: "user", content: sent + typed + footers[0],
                                                                    timestamp: nil, messageId: nil))
        XCTAssertEqual(shown.content, "@helper look" + typed)
        XCTAssertEqual(shown.attachments?.map(\.name), ["plan.md"])
    }

    /// A file's reference stays in the prompt, and the note resolves only what was typed: the
    /// `@file:` reference never mentions a bot named "file".
    func testAttachmentsKeepTheirReferenceAndOnlyTheTypedTextIsResolved() async throws {
        let roster: BotJSON = .object(["profiles": .array(["default", "helper", "file"].map { .object(["name": .string($0)]) })])
        let chat = await openChat(target: .canonicalChat(profile: "default"), roster: roster)
        let ref = "@file:/work/attachments/note.txt"
        chat.host.always("file.attach", .init(result: .object([
            "attached": .bool(true), "path": .string("/work/attachments/note.txt"), "ref_text": .string(ref)
        ])))
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        await chat.model.uploadAttachment(data: Data("hello".utf8), filename: "note.txt")
        _ = await chat.model.sendMessage("@helper read this")
        let sent = try XCTUnwrap(chat.writes("prompt.submit").last?["text"]?.text)
        XCTAssertTrue(sent.hasPrefix("@helper read this\n\n" + ref))
        let note = try XCTUnwrap(chat.turn.mentions).annotation(for: "@helper read this")
        XCTAssertFalse(note.isEmpty)
        XCTAssertTrue(sent.hasSuffix(note))
        XCTAssertFalse(sent.contains("agent profile \"file\""))
    }

    /// A session sends `@` text exactly as typed: only a Bot Chat's host delivers a mention.
    func testASessionSendsMentionsAsTyped() async throws {
        let chat = await openChat(target: .session(profile: "default", key: "tip"))
        XCTAssertNil(chat.turn.mentions)
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("@inbox-triage sort today")
        XCTAssertEqual(chat.writes("prompt.submit").last?["text"], .string("@inbox-triage sort today"))
    }

    /// A Bot Chat opened straight from its row, never through the Bots inbox, loads the roster's
    /// pictures itself, for its pill and its `@` panel. A session loads none.
    func testABotChatLoadsItsRostersPictures() async throws {
        let chat = await openChat(target: .canonicalChat(profile: "default"), roster: Self.pictured)
        await waitUntil("the pictures") { chat.turn.settings.avatars.count == 2 }
        XCTAssertEqual(chat.turn.settings.avatars.keys.sorted(), ["default", "helper"])
        XCTAssertEqual(chat.writes("profiles.get_asset").compactMap { $0["name"]?.text }, ["default", "helper"])

        let session = await openChat(target: .session(profile: "default", key: "tip"), roster: Self.pictured)
        XCTAssertEqual(session.writes("profiles.get_asset"), [])
        XCTAssertTrue(session.turn.settings.avatars.isEmpty)
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    /// An idle chat on runtime `runtime` at tip `tip`, once its `roster` has been read.
    private func openChat(target: ConversationTarget, roster: BotJSON = HermesChatMentionTests.roster) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: .object([
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(false),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ])))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        host.always("profiles.list", .init(result: roster))
        host.always("profiles.get_asset", .init(result: .object(["found": .bool(true), "data": .string(botAvatarDataURL(side: 4))])))
        let client = BotClient(http: host.connection(Self.connection))
        _ = HermesHostFixture.configuration { request in
            request.url?.path == "/api/sessions/tip/messages" ? .json(200, .object(["messages": .array([])])) : nil
        }
        let engine = HermesConversation(server: Self.server, connection: Self.connection, target: target, wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let copies = BotAttachmentCopies()
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: Self.server, streamingScrollCoalescingDelayNanoseconds: 0,
            draftAttachmentStore: copies,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), attachmentStore: copies, debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        await waitUntil("the roster") { turn.settings.profiles.count == roster["profiles"].list?.count }
        return Chat(model: model, turn: turn, host: host)
    }

    /// Waits on observation, never a clock, until `condition` holds.
    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            let changed = XCTestExpectation(description: description)
            withObservationTracking { _ = condition() } onChange: { changed.fulfill() }
            guard await XCTWaiter().fulfillment(of: [changed], timeout: 5) == .completed else {
                return XCTFail("Nothing changed while waiting for: \(description)", file: file, line: line)
            }
        }
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
