import Foundation
import Testing
@testable import WatchShared

@Suite struct WatchGlanceProjectionTests {
    // MARK: Memory

    /// The shape of a real USER.md: bold labels and `§` lines between entries.
    @Test func memorySplitsOnDelimiterLinesIntoEntries() {
        let raw = "**Name:** Aaryan Guglani (goes by Aaryan)\n§\n**Email:** guglaniaaryan@gmail.com\r\n§\r\n**Timezone:** GMT+5:30\n§\n"
        #expect(WatchMemoryProjection.entries(in: raw) == [
            "**Name:** Aaryan Guglani (goes by Aaryan)",
            "**Email:** guglaniaaryan@gmail.com",
            "**Timezone:** GMT+5:30",
        ])
    }

    @Test func memoryKeepsAnInlineSectionSignAndContentWithoutDelimiters() {
        #expect(WatchMemoryProjection.entries(in: "See AGENTS.md § Working with the server.") == ["See AGENTS.md § Working with the server."])
        #expect(WatchMemoryProjection.entries(in: "  \n§\n  ").isEmpty)
    }

    @Test func memoryWristEntriesNormalizeListsAndClipLongEntries() {
        let long = String(repeating: "word ", count: 200)
        let shaped = WatchMemoryProjection.wristEntries(from: "**Stack:**\n- SwiftUI\n- watchOS\n§\n\(long)")
        #expect(shaped.entries.first == "**Stack:**\n• SwiftUI\n• watchOS")
        #expect(shaped.entries[1].count <= WatchMemoryProjection.maximumEntryCharacters)
        #expect(shaped.entries[1].hasSuffix("…"))
        #expect(shaped.isTruncated)
    }

    @Test func memoryWireContentRoundTripsThroughTheWatchSplit() {
        let entries = ["**Name:** Aaryan", "Likes `swift`"]
        #expect(WatchMemoryProjection.entries(in: WatchMemoryProjection.wireContent(entries)) == entries)
    }

    @Test func memoryCapsTheEntryCount() {
        let raw = (1...60).map { "Fact \($0)" }.joined(separator: "\n§\n")
        let shaped = WatchMemoryProjection.wristEntries(from: raw)
        #expect(shaped.entries.count == WatchMemoryProjection.maximumEntries)
        #expect(shaped.isTruncated)
    }

    // MARK: Clipping

    @Test func clippingNeverLeavesAnUnclosedBoldMarker() throws {
        let clipped = try #require(WatchTranscriptProjection.clippedMarkdown("Plain words then **a bold phrase that runs long**", max: 30))
        #expect(clipped.components(separatedBy: "**").count % 2 == 1)
        #expect(clipped.hasSuffix("…"))
    }

    // MARK: Line breaking

    @Test func emailsAndURLsGetBreakOpportunitiesInsteadOfHyphens() {
        let zwsp = "\u{200B}"
        #expect(WatchTextBreaking.breakable("guglaniaaryan@gmail.com") == "guglaniaaryan@\(zwsp)gmail\(zwsp).com")
        #expect(WatchTextBreaking.breakable("Email: a@b.co") == "Email: a@\(zwsp)b\(zwsp).co")
        #expect(WatchTextBreaking.breakable("see /Users/me/Developer/hermex").contains("/\(zwsp)Developer"))
    }

    @Test func ordinaryProseIsLeftAlone() {
        #expect(WatchTextBreaking.breakable("Aaryan Guglani (goes by Aaryan).") == "Aaryan Guglani (goes by Aaryan).")
        #expect(WatchTextBreaking.breakable("GMT+5:30 well-known") == "GMT+5:30 well-known")
        // Removing the break opportunities gives back the original text.
        let email = "guglaniaaryan@gmail.com"
        #expect(WatchTextBreaking.breakable(email).replacingOccurrences(of: "\u{200B}", with: "") == email)
    }

    // MARK: Kanban

    @Test func kanbanCardRoundTripsThroughItsWireSummary() {
        let card = WatchKanbanCard(
            id: "card-1",
            title: "Ship\nthe  watch",
            status: "Running",
            assignee: "default",
            priority: 3,
            body: "First line\n- item",
            tenant: "studio",
            commentCount: 2,
            linkCount: 1,
            ageSeconds: 3_700,
            skills: ["swiftui", "watch"]
        )
        #expect(card.title == "Ship the  watch")
        #expect(card.status == "running")
        #expect(card.staleness == .critical)
        let decoded = WatchKanbanCard(id: "card-1", wireSummary: card.wireSummary)
        #expect(decoded == card)
    }

    @Test func kanbanCardToleratesTheOlderFiveLineSummary() {
        let decoded = WatchKanbanCard(id: "c", wireSummary: "Ship it\nrunning\ndefault\n2\n**Body**")
        #expect(decoded.title == "Ship it")
        #expect(decoded.status == "running")
        #expect(decoded.assignee == "default")
        #expect(decoded.priority == 2)
        #expect(decoded.body == "**Body**")
        #expect(decoded.tenant == nil)
        #expect(decoded.skills == nil)
    }

    @Test func kanbanCardToleratesTheOlderTwoLineSummary() {
        let decoded = WatchKanbanCard(id: "c", wireSummary: "Title\ntodo")
        #expect(decoded.title == "Title")
        #expect(decoded.status == "todo")
        #expect(decoded.assignee == nil)
        #expect(decoded.priority == nil)
        #expect(decoded.body == nil)
    }

    /// Mirrors the iPhone: ordinary moves plus Done, never into Running or
    /// Blocked, nothing for an archived Card.
    @Test func kanbanMovePolicyMatchesTheIPhone() {
        #expect(WatchKanbanStatus.moveDestinations(from: "todo") == ["triage", "ready", "done"])
        #expect(WatchKanbanStatus.moveDestinations(from: "running") == ["triage", "todo", "ready", "done"])
        #expect(WatchKanbanStatus.moveDestinations(from: "done") == ["triage", "todo", "ready"])
        #expect(WatchKanbanStatus.moveDestinations(from: "archived").isEmpty)
        #expect(!WatchKanbanStatus.moveDestinations(from: "todo").contains("running"))
        #expect(!WatchKanbanStatus.moveDestinations(from: "todo").contains("blocked"))
        #expect(WatchKanbanStatus.moveDestinations(from: "todo", policy: .hermes) == ["triage", "ready"])
        #expect(WatchKanbanStatus.moveDestinations(from: "review", policy: .hermes) == ["triage", "ready", "done"])
        #expect(WatchKanbanStatus.moveDestinations(from: "scheduled", policy: .hermes) == ["triage", "ready"])
        #expect(WatchKanbanStatus.moveDestinations(from: "ready", policy: .hermes) == ["triage"])
        #expect(WatchKanbanStatus.moveDestinations(from: "done", policy: .hermes) == ["triage", "ready"])
        #expect(WatchKanbanStatus.moveDestinations(from: "archived", policy: .hermes).isEmpty)
        #expect(!WatchKanbanStatus.allowsDestination("todo", policy: .hermes))
        #expect(!WatchKanbanStatus.allowsDestination("review", policy: .hermes))
        #expect(WatchKanbanStatus.allowsDestination("done", policy: .hermes))
        #expect(WatchKanbanStatus.createDestinations(policy: .hermes) == ["triage", "ready"])
        #expect(WatchKanbanStatus.createDestinations() == ["triage", "todo", "ready"])
        #expect(WatchKanbanStatus.needsRunningExitConfirmation(from: "running"))
        #expect(!WatchKanbanStatus.needsRunningExitConfirmation(from: "ready"))
        #expect(WatchKanbanStatus.title("todo") == "To Do")
    }

    @Test func kanbanBoardChromeRoundTripsAndParsesTheGlanceQuery() {
        let chrome = WatchKanbanBoardChrome(
            name: "Default",
            slug: "default",
            columns: WatchKanbanStatus.boardOrder,
            boards: [WatchKanbanBoardChrome.Choice(slug: "default", name: "Default")]
        )
        let decoded = WatchKanbanBoardChrome(wireSummary: chrome.wireSummary)
        #expect(decoded == chrome)
        #expect(decoded?.resolvedMovePolicy == .webui)
        #expect(WatchKanbanBoardChrome(wireSummary: "{}") == nil)
        var hermes = chrome
        hermes.movePolicy = WatchKanbanMovePolicy.hermes.rawValue
        let hermesDecoded = WatchKanbanBoardChrome(wireSummary: hermes.wireSummary)
        #expect(hermesDecoded?.resolvedMovePolicy == .hermes)
        let legacy = #"{"boards":[],"columns":["triage","todo"],"name":"Kanban","slug":"default"}"#
        let legacyChrome = WatchKanbanBoardChrome(wireSummary: legacy)
        #expect(legacyChrome?.movePolicy == nil)
        #expect(legacyChrome?.resolvedMovePolicy == .webui)
        let unknown = #"{"boards":[],"columns":["triage"],"movePolicy":"later","name":"Kanban","slug":"x"}"#
        #expect(WatchKanbanBoardChrome(wireSummary: unknown)?.resolvedMovePolicy == .webui)

        let plain = WatchGlanceQuery.kanbanRequest(from: WatchGlanceQuery.kanban)
        #expect(plain?.slug == nil)
        #expect(plain?.includeArchived == false)
        #expect(plain?.onlyMine == false)
        let filtered = WatchGlanceQuery.kanbanRequest(from: WatchGlanceQuery.kanban(slug: "ops", includeArchived: true, onlyMine: true))
        #expect(filtered?.slug == "ops")
        #expect(filtered?.includeArchived == true)
        #expect(filtered?.onlyMine == true)
        #expect(WatchGlanceQuery.kanbanRequest(from: "web-search") == nil)
    }

    // MARK: Task runs

    @Test func taskRunOutputDropsFrontMatterAndTerminalColour() {
        let content = "---\nmodel: sol\n---\n# Prompt\nDo it\n## Response\n\u{1B}[32mAll green\u{1B}[0m\n"
        #expect(WatchTaskRunProjection.responseBody(content) == "All green")
        #expect(WatchTaskRunProjection.responseBody("No heading here") == "No heading here")
    }

    @Test func complicationTapIsTheRecordLink() {
        #expect(WatchComplicationLink.isRecord(WatchComplicationLink.record))
        #expect(WatchComplicationLink.isRecord(URL(string: "hermex-watch://board")!) == false)
    }

    @Test func replyNoticeKeepsTheLatestAssistantWordsAndFitsANotification() {
        let blocks = [
            WatchPhoneTranscriptPage.Block(id: "u", role: .user, text: "Status?"),
            WatchPhoneTranscriptPage.Block(id: "a", role: .assistant, text: "The garage door is closed."),
        ]
        let body = WatchReplyNotice.assistantText(in: blocks)
        #expect(body == "The garage door is closed.")
        let info = WatchReplyNotice.userInfo(body: body ?? "", sessionID: "s1")
        #expect(WatchReplyNotice.body(in: info) == "The garage door is closed.")
        let long = String(repeating: "word ", count: 80)
        #expect(WatchReplyNotice.clip(long).count == WatchReplyNotice.maximumBodyCharacters)
        #expect(WatchReplyNotice.clip(long).hasSuffix("…"))
        #expect(WatchReplyNotice.body(in: ["kind": "other"]) == nil)
    }
}
