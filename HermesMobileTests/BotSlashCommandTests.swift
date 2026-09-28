import XCTest
@testable import HermesMobile

/// The Bot composer's `/` panel: what the trigger opens on, what the host's
/// catalog is read as, and what a chosen row actually sends.
@MainActor final class BotSlashCommandTests: XCTestCase {
    private let server = URL(string: "https://webui.example")!
    private var connection: BotConnection {
        BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                      username: "user", password: "fixture")
    }
    private var profile: BotProfile { BotProfile(.object(["name": .string("inbox-triage")]))! }

    private func make(_ wire: BotFixtureWire) -> BotConversation {
        BotConversation(server: server, connection: connection, profile: profile, wire: wire,
                        drafts: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)))
    }

    /// `commands.catalog` as 0.21.2 answers it: skill keys in `skills`, every
    /// entry's description in `pairs`, commands in `canon` and `commands`.
    private func catalogReply(
        skills: [String: BotJSON] = ["/work": .object(["origin": .string("user"), "usage": .number(3)]),
                                     "/write-tests": .object(["origin": .string("bundled")])],
        pairs: [BotJSON] = [.array([.string("/model"), .string("Switch model")]),
                            .array([.string("/work"), .string("Do focused work")]),
                            .array([.string("/write-tests"), .string("Add tests")])],
        canon: [String: BotJSON] = ["/model": .string("/model"), "/m": .string("/model")],
        commands: [String: BotJSON] = ["/model": .object(["argument_mode": .string("options")])]
    ) -> BotJSON {
        .object([
            "skills": .object(skills), "pairs": .array(pairs), "canon": .object(canon),
            "commands": .object(commands), "categories": .array([]),
            "skill_count": .number(Double(skills.count)), "warning": .string(""),
            // A field this app has never heard of must not cost it the catalog.
            "future_field": .object(["nested": .bool(true)])
        ])
    }

    // MARK: - Trigger

    func testTriggerOnlyOpensOnASlashThatStartsTheDraft() {
        XCTAssertEqual(BotSlashTrigger.detect(in: "/wo", selection: NSRange(location: 3, length: 0))?.query, "wo")
        XCTAssertEqual(BotSlashTrigger.detect(in: "/", selection: NSRange(location: 1, length: 0))?.query, "")
        XCTAssertNil(BotSlashTrigger.detect(in: "check the /tmp folder", selection: NSRange(location: 14, length: 0)))
        XCTAssertNil(BotSlashTrigger.detect(in: "hello", selection: NSRange(location: 5, length: 0)))
    }

    /// Past the first space the user is writing the skill's argument, so the
    /// panel closes instead of holding an empty box open for the rest of the line.
    func testTriggerClosesOnceTheArgumentStarts() {
        XCTAssertNil(BotSlashTrigger.detect(in: "/work fix the leak", selection: NSRange(location: 18, length: 0)))
        XCTAssertNil(BotSlashTrigger.detect(in: "/work ", selection: NSRange(location: 6, length: 0)))
    }

    func testAcceptingARowReplacesOnlyTheTriggerAndKeepsTheRest() {
        let trigger = BotSlashTrigger.detect(in: "/wo done", selection: NSRange(location: 3, length: 0))
        let result = trigger?.applying("/work ", to: "/wo done")
        XCTAssertEqual(result?.draft, "/work done")
        XCTAssertEqual(result?.selection, NSRange(location: 6, length: 0))
    }

    // MARK: - Catalog decode

    func testCatalogReadsSkillsWithTheirDescriptions() {
        let skills = BotSlashCatalog.skills(from: catalogReply())
        XCTAssertEqual(skills.map(\.name), ["work", "write-tests"])
        XCTAssertEqual(skills.first?.description, "Do focused work")
        XCTAssertEqual(skills.first?.category, "user")
        XCTAssertEqual(skills.last?.category, "bundled")
        XCTAssertEqual(skills.last?.description, "Add tests")
    }

    /// `command.dispatch` resolves quick, plugin and registry commands ahead of
    /// skills, and a quick command can run a shell command on the host. A skill
    /// key that collides with one is never offered.
    func testCatalogDropsSkillsShadowedByACommand() {
        let reply = catalogReply(
            skills: ["/work": .object([:]), "/deploy": .object([:]), "/m": .object([:])],
            pairs: [.array([.string("/deploy"), .string("exec: ./deploy.sh")])],
            canon: ["/deploy": .string("/deploy"), "/m": .string("/model")],
            commands: [:])
        XCTAssertEqual(BotSlashCatalog.skills(from: reply).map(\.name), ["work"])
    }

    func testCatalogToleratesAMissingOrMalformedReply() {
        XCTAssertTrue(BotSlashCatalog.skills(from: .object([:])).isEmpty)
        XCTAssertTrue(BotSlashCatalog.skills(from: .object(["skills": .string("nope")])).isEmpty)
        let ragged = BotJSON.object([
            "skills": .object(["/work": .null, "no-slash": .object([:]), "/two words": .object([:]), "/": .object([:])]),
            "pairs": .array([.string("not a row"), .array([.string("/work")])])
        ])
        XCTAssertEqual(BotSlashCatalog.skills(from: ragged).map(\.name), ["work"])
        XCTAssertNil(BotSlashCatalog.skills(from: ragged).first?.description)
    }

    // MARK: - Ranking

    /// The panel ranks through the same `SlashCommandRanker` the Sessions panel
    /// uses, so a name prefix still beats a word boundary, which beats a
    /// description hit.
    func testRankingMatchesTheSessionsPanel() {
        let skills = [
            SkillSlashSuggestion(name: "review-notes", category: nil, description: "Tidy meeting notes"),
            SkillSlashSuggestion(name: "code-review", category: nil, description: "Read a diff"),
            SkillSlashSuggestion(name: "triage", category: nil, description: "Review the inbox")
        ]
        XCTAssertEqual(SlashSkillFormatter.matching("review", in: skills).map(\.name),
                       ["review-notes", "code-review", "triage"])
        XCTAssertEqual(SlashSkillFormatter.matching("nothing-here", in: skills).map(\.name), [])
    }

    // MARK: - Fetching

    func testCatalogIsReadOncePerConversation() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        await model.loadSlashCatalog()
        XCTAssertEqual(model.slashSkills.map(\.name), ["work", "write-tests"])
        XCTAssertEqual(wire.calls.filter { $0.0 == "commands.catalog" }.count, 1)
        // Skill discovery is bound to the live session's Profile and workspace.
        XCTAssertEqual(wire.calls.first { $0.0 == "commands.catalog" }?.1, ["session_id": .string("runtime")])
        model.suspend()
    }

    /// A reply for a conversation that has moved on is dropped rather than
    /// installed under the new generation's identity.
    func testStaleCatalogReplyIsDiscarded() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        let model = make(wire)
        await model.recover()
        wire.beforeDispatch = { [weak model] method in
            if method == "commands.catalog" { model?.suspend() }
        }
        await model.loadSlashCatalog()
        XCTAssertTrue(model.slashSkills.isEmpty)
    }

    func testFailedCatalogLeavesTheComposerUsable() async {
        let wire = BotFixtureWire()
        wire.catalogFailure = .transport
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        XCTAssertTrue(model.slashSkills.isEmpty)
        XCTAssertTrue(model.mayEditDraft)
        XCTAssertTrue(model.maySend)
        XCTAssertNil(model.errorMessage)
        model.editDraft("/work fix the leak")
        await model.send()
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "prompt.submit" })?.1["text"]?.text, "/work fix the leak")
        model.suspend()
    }

    // MARK: - Sending

    func testSkillInvocationIsExpandedByTheHostBeforeSending() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        wire.dispatch = .object([
            "type": .string("skill"), "message": .string("<skill work>\nfix the leak"),
            "name": .string("work"), "display": .string("/work fix the leak")
        ])
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        model.editDraft("/work fix the leak")
        await model.send()
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "command.dispatch" })?.1,
                       ["name": .string("work"), "arg": .string("fix the leak"), "session_id": .string("runtime")])
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "prompt.submit" })?.1["text"]?.text, "<skill work>\nfix the leak")
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.errorMessage)
        model.suspend()
    }

    func testProseAndUnknownNamesAreSentAsTypedWithoutDispatch() async {
        for draft in ["just a message", "/not-a-skill do it", "look at /work later"] {
            let wire = BotFixtureWire()
            wire.catalog = catalogReply()
            let model = make(wire)
            await model.recover()
            await model.loadSlashCatalog()
            model.editDraft(draft)
            await model.send()
            XCTAssertFalse(wire.calls.contains { $0.0 == "command.dispatch" }, draft)
            XCTAssertEqual(wire.calls.last(where: { $0.0 == "prompt.submit" })?.1["text"]?.text, draft, draft)
            model.suspend()
        }
    }

    /// A dispatch that fails, or answers with anything but a skill, must not
    /// silently send the typed line as prose or drop the connection.
    func testFailedExpansionKeepsTheDraftAndTheConnection() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        wire.dispatchFailure = .rejected(4018)
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        model.editDraft("/work fix the leak")
        await model.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertEqual(model.draft, "/work fix the leak")
        XCTAssertEqual(model.connectionState, .connected)
        XCTAssertTrue(model.maySend)
        XCTAssertNotNil(model.errorMessage)
        model.suspend()
    }

    func testANonSkillDispatchReplyIsRefused() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        wire.dispatch = .object(["type": .string("exec"), "output": .string("ran something")])
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        model.editDraft("/work fix the leak")
        await model.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertEqual(model.draft, "/work fix the leak")
        XCTAssertNotNil(model.errorMessage)
        model.suspend()
    }

    /// The cached catalog is a snapshot. A command added to the host since the read
    /// shadows the skill — `command.dispatch` resolves quick commands first, and a
    /// quick command can run a shell command — so the send re-reads before dispatching.
    func testACommandAddedSinceTheCatalogReadBlocksTheDispatch() async {
        let wire = BotFixtureWire()
        wire.catalogQueue = [
            catalogReply(skills: ["/deploy": .object([:])], pairs: [], canon: [:], commands: [:]),
            catalogReply(skills: ["/deploy": .object([:])], pairs: [], canon: ["/deploy": .string("/deploy")], commands: [:])
        ]
        wire.catalog = catalogReply()
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        XCTAssertEqual(model.slashSkills.map(\.name), ["deploy"])
        model.editDraft("/deploy staging")
        await model.send()
        XCTAssertFalse(wire.calls.contains { $0.0 == "command.dispatch" })
        XCTAssertFalse(wire.calls.contains { $0.0 == "prompt.submit" })
        XCTAssertEqual(model.draft, "/deploy staging")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.slashSkills.isEmpty, "The fresh read also refreshes the panel")
        model.suspend()
    }

    /// Steer and Redirect add guidance to work already running; the host expands
    /// no invocation there, so the typed line goes as written.
    func testSteeringNeverDispatchesASkill() async {
        let wire = BotFixtureWire()
        wire.catalog = catalogReply()
        wire.running = true
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        model.editDraft("/work fix the leak")
        guard let action = model.preparePrompt(.steer) else { return XCTFail("Steer should be available") }
        await model.submit(action)
        XCTAssertFalse(wire.calls.contains { $0.0 == "command.dispatch" })
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "session.steer" })?.1["text"]?.text, "/work fix the leak")
        model.suspend()
    }

    /// The panel inserts the slug, because that is what the composer's chip catalog
    /// is keyed by; the send path resolves it back to the host's own key.
    func testASlugCompletionStillDispatchesTheHostsKey() async {
        let wire = BotFixtureWire()
        let catalog = catalogReply(
            skills: ["/Weekly_Report": .object([:])],
            pairs: [.array([.string("/Weekly_Report"), .string("Write the weekly report")])],
            canon: [:], commands: [:])
        wire.catalog = catalog
        wire.dispatch = .object(["type": .string("skill"), "message": .string("<expanded>")])
        let model = make(wire)
        await model.recover()
        await model.loadSlashCatalog()
        let skill = try? XCTUnwrap(model.slashSkills.first)
        XCTAssertEqual(skill?.name, "Weekly_Report")
        XCTAssertEqual(skill?.slashName, "weekly-report")
        model.editDraft("/weekly-report for September")
        await model.send()
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "command.dispatch" })?.1["name"]?.text, "Weekly_Report")
        XCTAssertEqual(wire.calls.last(where: { $0.0 == "prompt.submit" })?.1["text"]?.text, "<expanded>")
        model.suspend()
    }

    // MARK: - Draft parsing

    func testInvocationReadsTheOpeningNameAndArgument() {
        XCTAssertEqual(BotSlashCatalog.invocation(in: "  /work fix the leak "),
                       BotSlashInvocation(name: "work", argument: "fix the leak"))
        XCTAssertEqual(BotSlashCatalog.invocation(in: "/work"), BotSlashInvocation(name: "work", argument: ""))
        XCTAssertEqual(BotSlashCatalog.invocation(in: "/work\nfix it"),
                       BotSlashInvocation(name: "work", argument: "fix it"))
        XCTAssertNil(BotSlashCatalog.invocation(in: "/"))
        XCTAssertNil(BotSlashCatalog.invocation(in: "hello /work"))
    }
}
