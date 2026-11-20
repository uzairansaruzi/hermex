import XCTest
import Observation
@testable import HermesMobile

@MainActor final class HermesTranscriptPagingTests: XCTestCase {
    func testOpeningReadsTheNewestPageWithTheExactQuery() async throws {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        let read = try XCTUnwrap(HermesHostFixture.requests.first { $0.url?.path == Self.path })
        XCTAssertEqual(read.httpMethod, "GET")
        XCTAssertEqual(read.url?.query, "profile=default&order=latest&limit=100&offset=0&include_compacted=true")
        XCTAssertEqual(chat.host.transcriptReads(since: 0), [false, false], "both resumes omit the transcript")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello."])
        XCTAssertEqual(chat.model.messages.map(\.messageId), ["tip/row-1", "tip/row-2"])
        XCTAssertEqual(chat.model.messages.map(\.rowID), [1, 2])
        XCTAssertFalse(chat.model.hasOlderMessages, "a short page is the whole session")
    }

    func testLoadingEarlierPagesToTheFirstRowWithoutDuplicates() async {
        let chat = await openChat(pages: [
            0: (101...200).map(alternating),
            100: (3...102).map(alternating),
            198: (1...2).map(alternating)
        ])
        XCTAssertEqual(chat.model.messages.count, 100)
        XCTAssertTrue(chat.model.hasOlderMessages)
        let shown = renderID(of: "tip/row-101", in: chat.model)

        let first = await chat.model.loadOlderMessages()
        XCTAssertTrue(first)
        XCTAssertTrue(chat.model.hasOlderMessages, "a full page")
        XCTAssertEqual(renderID(of: "tip/row-101", in: chat.model), shown, "the rows on screen keep their place")

        let second = await chat.model.loadOlderMessages()
        XCTAssertTrue(second)
        XCTAssertFalse(chat.model.hasOlderMessages, "a short page reached the first row")
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), Array(1...200))
        XCTAssertEqual(chat.pages.offsets, [0, 100, 198])
        let done = await chat.model.loadOlderMessages()
        XCTAssertFalse(done)
        XCTAssertEqual(chat.pages.offsets, [0, 100, 198], "nothing more is read")
    }

    func testToolRowsPairWithTheirCallsAndShowTheFullOutput() async throws {
        let output = "{\"output\": \"a.txt\\nb.txt\\nc.txt\", \"exit_code\": 0, \"error\": null}"
        let chat = await openChat(pages: [0: [
            row(1, "user", "List the files"),
            row(2, "assistant", "Let me check.", ["reasoning": .string("Look first."), "tool_calls": .array([
                call("call_2", "terminal", "{\"command\": \"ls\"}")
            ])]),
            row(3, "tool", output, ["tool_call_id": .string("call_2"), "tool_name": .string("terminal")]),
            row(4, "assistant", "Three files."),
            row(5, "assistant", "", [
                "tool_calls": .array([call("call_5", "tool_call", "{\"name\": \"GITHUB_CREATE_ISSUE\"}")]),
                "tool_call_labels": .object(["call_5": .array([.object([
                    "text": .string("GitHub · create issue"), "name": .string("GITHUB_CREATE_ISSUE")
                ])])])
            ]),
            row(6, "tool", "{\"ok\": true}", ["tool_call_id": .string("call_5"), "tool_name": .string("tool_call")]),
            row(7, "assistant", "Filed.")
        ]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["List the files", "Let me check.", "Three files.", "Filed."],
                       "a reply with only a call is no message")
        let groups = chat.model.completedToolCallGroups
        XCTAssertEqual(groups.map(\.anchorMessageID), ["tip/row-4", "tip/row-7"])
        XCTAssertEqual(groups.map { $0.toolCalls.map(\.name) }, [["terminal"], ["GitHub · create issue"]])
        XCTAssertEqual(groups.first?.toolCalls.first?.preview, output)
        XCTAssertEqual(groups.first?.toolCalls.first?.args, ["command": .string("ls")])
        XCTAssertEqual(groups.flatMap(\.toolCalls).map(\.isCompleted), [true, true])
        XCTAssertEqual(chat.model.completedReasoningGroups.map(\.anchorMessageID), ["tip/row-2"])
        XCTAssertEqual(chat.model.completedReasoningGroups.map(\.text), ["Look first."])
    }

    func testDisplayKinds() async {
        let steer = "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nUse tabs\n[/OUT-OF-BAND USER MESSAGE]"
        let chat = await openChat(pages: [0: [
            row(1, "user", "Format the file"),
            row(2, "user", "Seed instructions", ["display_kind": .string("hidden")]),
            row(3, "user", steer, ["display_kind": .string("steer")]),
            row(4, "user", "[System: The model was switched to fast.]", ["display_kind": .string("model_switch")]),
            row(5, "user", "[ASYNC DELEGATION COMPLETE]\n--- RESULT ---\nAll done", [
                "display_kind": .string("async_delegation_complete"),
                "display_metadata": .object(["task_count": .number(1)])
            ]),
            row(6, "assistant", "Your request was not processed. Send it again if you still want me to carry it out.",
                ["display_kind": .string("failed_turn")]),
            row(7, "assistant", "Shown as it is.", ["display_kind": .string("a_kind_from_the_future")])
        ]])
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 3, 5, 6, 7])
        XCTAssertEqual(chat.model.messages.map(\.role), ["user", "user", "delegation_completion", "assistant", "assistant"])
        XCTAssertEqual(chat.model.messages[1].content, "Use tabs")
        XCTAssertTrue(chat.model.messages[1].isSteerMessage)
        XCTAssertEqual(chat.model.messages[2].displayKind, "async_delegation_complete")
        XCTAssertEqual(chat.model.messages[2].displayMetadata, ["task_count": .number(1)])
        XCTAssertEqual(chat.model.messages[3].displayKind, "failed_turn")
        XCTAssertEqual(chat.model.messages[4].content, "Shown as it is.")
    }

    func testCodexColumnsAreNeverRead() async {
        let chat = await openChat(pages: [0: [
            row(1, "user", "Summarize"),
            row(2, "assistant", "raw canonical text", [
                "codex_message_items": .string("[{\"type\": \"message\", \"role\": \"assistant\", \"content\": [{\"type\": \"output_text\", \"text\": \"raw provider text\"}]}]"),
                "codex_reasoning_items": .string("[{\"type\": \"reasoning\", \"summary\": \"raw provider reasoning\"}]"),
                "reasoning": .string("raw stored reasoning"),
                "display_content": .string("The summary."),
                "display_reasoning": .string("Projected thought.")
            ])
        ]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["Summarize", "The summary."])
        XCTAssertEqual(chat.model.completedReasoningGroups.map(\.text), ["Projected thought."])
    }

    func testASkillTurnShowsTheTypedLine() async {
        let skill = "[IMPORTANT: The user has invoked the \"demo-skill\" skill, indicating they want you to follow its "
            + "instructions. The full skill content is loaded below.]\n\n---\nname: demo-skill\n---\nSay hello.\n\n"
            + "[Skill directory: <skills>/demo-skill]"
        let instructed = skill + "\n\nThe user has provided the following instruction alongside the skill invocation: "
            + "do it\n\n[Runtime note: Reply briefly.]"
        let bundle = "[IMPORTANT: The user has invoked the \"/clean /work\" stacked skill bundle, loading 2 skills "
            + "together. Treat every skill below as active guidance for this turn.]\n\nSkills loaded: clean, work\n\n"
            + "User instruction: tidy the logs\n\n[Loaded as part of the stacked skill invocation \"clean\".]\n\nClean up."
        let chat = await openChat(pages: [0: [
            row(1, "user", instructed), row(2, "assistant", "Hello."), row(3, "user", skill), row(4, "user", bundle)
        ]])
        XCTAssertEqual(chat.model.messages.map(\.content), ["/demo-skill do it", "Hello.", "/demo-skill", "/clean /work tidy the logs"])
        XCTAssertEqual(chat.model.messages.map(\.displayKind), ["skill_invocation", nil, "skill_invocation", "skill_invocation"])
    }

    func testACronRunPromptReadsAsItsSkillAndTask() throws {
        let skill = "[IMPORTANT: The user has invoked the \"unslop\" skill, indicating they want you to follow its "
            + "instructions. The full skill content is loaded below.]\n\n---\nname: unslop\n---\nCut filler.\n\n"
            + "The user has provided the following instruction alongside the skill invocation: "
        let notice = "[IMPORTANT: The following skill(s) were listed for this job but could not be found and were "
            + "skipped: gone. Start your response with a brief notice so the user is aware, e.g.: "
            + "'⚠️ Skill(s) not found and skipped: gone']"
        let messages = HermesTranscriptProjection.project([
            row(1, "user", Self.cronHint + "Triage new mail.\nLabel billing."),
            row(2, "user", skill + Self.cronHint + "Rewrite the changelog.\nKeep links."),
            row(3, "user", notice + "\n\nThe user has provided the following instruction alongside the skill invocation: "
                + Self.cronHint + "Triage."),
            row(4, "user", notice + "\n" + skill + Self.cronHint + "Rewrite.\nKeep links.")
        ], root: "cron_job_20261031_090000").messages

        let prompts = try messages.map { try XCTUnwrap(CronRunPrompt($0), $0.content ?? "") }
        XCTAssertEqual(prompts.map(\.skills), [[], ["unslop"], [], ["unslop"]])
        XCTAssertEqual(prompts.map(\.body), ["Triage new mail.\nLabel billing.", "Rewrite the changelog. Keep links.",
                                             "Triage.", "Rewrite.\nKeep links."])
    }

    func testOnlyARowOpeningOnAClosedCronHintIsACronRunPrompt() {
        let texts = ["Triage new mail.", String(Self.cronHint.dropLast(3)) + " Triage.", "Run this: " + Self.cronHint + "Triage."]
        for text in texts {
            XCTAssertNil(CronRunPrompt(ChatMessage(role: "user", content: text, timestamp: nil, messageId: "m")), text)
        }
    }

    func testOnlyACronSessionOrLineageIsACronRun() {
        func chat(_ key: String, root: String? = nil) -> HermesSessionChat {
            HermesSessionChat(server: Self.connection.address, connection: Self.connection,
                              target: .session(profile: "default", key: key), lineageRoot: root)
        }
        XCTAssertTrue(chat("cron_8f2c_20261031_090000").isCronRun)
        XCTAssertTrue(chat("20261031_093000_a1b2", root: "cron_8f2c_20261031_090000").isCronRun)
        XCTAssertFalse(chat("20261031_093000_a1b2", root: "20261031_090000_8f2c").isCronRun)
    }

    private static let cronHint = "[IMPORTANT: You are running as a scheduled cron job. DELIVERY: Your final response "
        + "will be automatically delivered to the user — do NOT use send_message or try to deliver the output yourself. "
        + "Just produce your report/output as your final response and the system handles the rest. SILENT: If there is "
        + "genuinely nothing new to report, respond with exactly \"[SILENT]\" (nothing else) to suppress delivery. "
        + "[SILENT] is a literal ASCII control token — never translate or rephrase it, whatever language the rest of "
        + "your answer uses. Never combine [SILENT] with content — either report your findings normally, or say [SILENT] "
        + "and nothing more. FAILURE: If a delegated child fails and this cron run must be recorded as failed, put "
        + "[CRON_FAILURE] on the first line by itself, then explain the child failure on following lines. RECURSION: "
        + "This is a run of an EXISTING scheduled job — execute the task now. NEVER create or update a cron job because "
        + "of recurring or future-schedule language in the task prompt below; treat phrasing like \"each Monday\" or "
        + "\"every day at 9\" as context for this run, not as a request to schedule another job.]\n\n"

    func testCompactedTurnsSitAboveTheCompactionCard() async throws {
        let summary = "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below.\n"
            + "## Historical Task Snapshot\nThe user asked for the logs.\n\n"
            + "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
        let compacted: [String: BotJSON] = ["active": .number(0), "compacted": .number(1)]
        let chat = await openChat(pages: [0: [
            row(29, "user", "First question"),
            row(4, "assistant", "First answer.", compacted),
            row(5, "user", "Second question", compacted),
            row(6, "assistant", "Second answer.", compacted),
            row(32, "assistant", summary, ["display_kind": .string("hidden"), "_compressed_summary": .bool(true)]),
            row(33, "user", "Third question"),
            row(34, "assistant", "Third answer.")
        ]])
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [29, 4, 5, 6, 33, 34])
        let card = try XCTUnwrap(chat.model.compressionReferenceCard)
        XCTAssertEqual(card.referenceText, "## Historical Task Snapshot\nThe user asked for the logs.")
        XCTAssertEqual(card.afterRenderID, renderID(of: "tip/row-6", in: chat.model), "after the last compacted turn")
    }

    func testAFinishedTurnTakesItsSavedRowsInPlace() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Earlier"), row(2, "assistant", "Earlier answer.")]])
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = await chat.model.sendMessage("Run it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Done.")]))
        chat.receive(event(3, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "persisted_turn": .object([
                                                       "row_ids": .array([.number(3), .number(4)]), "complete": .bool(true),
                                                       "user_row_id": .number(3), "final_assistant_row_id": .number(4)
                                                   ])]))
        chat.model.flushPendingStreamingContent()
        let positions = chat.model.displayedTranscriptMessages.map(\.renderID)
        chat.pages.set(0, [row(1, "user", "Earlier"), row(2, "assistant", "Earlier answer."),
                           row(3, "user", "Run it"), row(4, "assistant", "Done.")])
        chat.receive(event(4, "session.info", ["running": .bool(false)]))
        await waitUntil("saved rows") { chat.model.messages.last?.rowID == 4 }
        XCTAssertEqual(chat.model.messages.map(\.messageId), ["tip/row-1", "tip/row-2", "tip/row-3", "tip/row-4"])
        XCTAssertEqual(chat.model.messages.map(\.content), ["Earlier", "Earlier answer.", "Run it", "Done."])
        XCTAssertEqual(chat.model.displayedTranscriptMessages.map(\.renderID), positions, "no row moves")
        XCTAssertEqual(chat.writes("prompt.submit").count, 1)
    }

    func testTheChatsOwnRowsKeepTheirPlace() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Earlier"), row(2, "assistant", "Earlier answer.")]])
        chat.host.always("prompt.submit", .init(result: .object(["status": .string("streaming")])))
        _ = chat.model.appendLocalNoticeMessage("Goal: ship the release")
        _ = await chat.model.sendMessage("Run it")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "persisted_turn": .object([
                                                       "row_ids": .array([.number(3), .number(4)]), "complete": .bool(true),
                                                       "user_row_id": .number(3), "final_assistant_row_id": .number(4)
                                                   ])]))
        let positions = chat.model.displayedTranscriptMessages.map(\.renderID)
        chat.pages.set(0, [row(1, "user", "Earlier"), row(2, "assistant", "Earlier answer."),
                           row(3, "user", "Run it"), row(4, "assistant", "Done.")])
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        await waitUntil("saved rows") { chat.model.messages.contains { $0.rowID == 4 } }
        XCTAssertEqual(chat.model.messages.map(\.content), ["Earlier", "Earlier answer.", "Goal: ship the release", "Run it", "Done."])
        XCTAssertEqual(chat.model.displayedTranscriptMessages.map(\.renderID), positions, "no row moves")
    }

    func testLoadingEarlierAfterAnUnreadTurnReadsTheNewestRowsFirst() async {
        let chat = await openChat(pages: [0: (101...200).map(alternating)])
        _ = chat.model.appendLocalNoticeMessage("Goal: ship the release")
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(3, "session.info", ["running": .bool(false)]))
        chat.pages.set(0, (201...300).map(alternating))
        chat.pages.set(100, (101...200).map(alternating))
        chat.pages.set(200, (1...100).map(alternating))
        chat.pages.set(300, [])
        let shown = renderID(of: "tip/row-101", in: chat.model)

        let first = await chat.model.loadOlderMessages()
        XCTAssertTrue(first)
        XCTAssertTrue(chat.model.hasOlderMessages, "a full page")
        XCTAssertEqual(chat.pages.offsets, [0, 0, 100, 200], "the newest rows back to the rows held, then the page before them")
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), Array(1...300))
        XCTAssertEqual(chat.model.messages.count, 301, "each saved row once and the notice, without the streamed reply")
        XCTAssertEqual(renderID(of: "tip/row-101", in: chat.model), shown, "the rows on screen keep their place")
        let notice = chat.model.messages.firstIndex { $0.content == "Goal: ship the release" }
        XCTAssertEqual(notice.map { chat.model.messages[$0 - 1].rowID }, 200, "the notice stays after the row it followed")

        let done = await chat.model.loadOlderMessages()
        XCTAssertFalse(done)
        XCTAssertFalse(chat.model.hasOlderMessages, "an empty page is the first row")
        XCTAssertEqual(chat.pages.offsets, [0, 0, 100, 200, 300])
    }

    func testAnOlderPageThatAddsNothingRecountsNextTime() async {
        let chat = await openChat(pages: [0: (101...200).map(alternating)])
        chat.pages.set(0, (201...300).map(alternating))
        chat.pages.set(100, (101...200).map(alternating))
        chat.pages.set(200, (1...100).map(alternating))

        let stuck = await chat.model.loadOlderMessages()
        XCTAssertFalse(stuck)
        XCTAssertTrue(chat.model.hasOlderMessages, "a full page that met the rows held is no start")

        let loaded = await chat.model.loadOlderMessages()
        XCTAssertTrue(loaded)
        XCTAssertEqual(chat.pages.offsets, [0, 100, 0, 100, 200])
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), Array(1...300))
    }

    func testLoadingEarlierMidTurnSkipsTheRunningTurnsRows() async {
        let chat = await openChat(pages: [0: (101...200).map(alternating)])
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Working")]))
        chat.pages.set(0, (251...350).map(alternating))
        chat.pages.set(100, (151...250).map(alternating))
        chat.pages.set(250, (1...100).map(alternating))

        let loaded = await chat.model.loadOlderMessages()
        XCTAssertTrue(loaded)
        XCTAssertEqual(chat.pages.offsets, [0, 0, 100, 250])
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), Array(1...200))
        XCTAssertEqual(chat.model.messages.last?.content, "Working", "the running turn shows as it streams")
    }

    func testAGapReReadsTheNewestPage() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Part")]))
        chat.pages.set(0, [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Next")])
        let snapshot = resume(running: true, inflight: ["user": .string("Next"), "assistant": .string("Partial reply")])
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6)))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.receive(event(5, "message.delta", ["text": .string("lost the middle")]))
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.pages.offsets, [0, 0], "one newest-page read for the gap")
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Next", "Partial reply"])

        chat.receive(event(7, "message.delta", ["text": .string(" and more")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.messages.last?.content, "Partial reply and more")
    }

    func testAGapAfterMoreThanAPageKeepsTheRowsHeld() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "message.delta", ["text": .string("Part")]))
        let tools = (4...123).map { row($0, "tool", "output \($0)") }
        chat.pages.set(0, Array(tools.suffix(100)))
        chat.pages.set(100, [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Next")] + tools.prefix(20))
        let snapshot = resume(running: true, inflight: ["user": .string("Next"), "assistant": .string("Partial reply")])
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6)))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.receive(event(5, "message.delta", ["text": .string("lost the middle")]))
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.pages.offsets, [0, 0, 100])
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi", "Hello.", "Next", "Partial reply"])
        XCTAssertEqual(chat.model.completedToolCallGroups.flatMap(\.toolCalls).map(\.id), (4...123).map { "tip/row-\($0)" })
        XCTAssertFalse(chat.model.hasOlderMessages)
    }

    func testAGapMidToolAnchorsTheSavedCardsToTheRunningReply() async throws {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        await rebuildMidTool(chat)
        let reply = try XCTUnwrap(chat.model.streamingAssistantMessageID)
        XCTAssertEqual(chat.model.completedToolCallGroups.map(\.anchorMessageID), [reply])
        XCTAssertEqual(chat.model.completedReasoningGroups.map(\.anchorMessageID), [reply])
        XCTAssertTrue(chat.model.displayedTranscriptMessages.contains { $0.message.messageId == reply },
                      "the empty reply row shows, holding the cards")

        chat.receive(event(7, "tool.start", ["tool_id": .string("tool-2"), "name": .string("terminal")]))
        chat.receive(event(8, "message.delta", ["text": .string("Done.")]))
        chat.model.flushPendingStreamingContent()
        XCTAssertEqual(chat.model.toolCallAnchorMessageID, reply)
        XCTAssertEqual(chat.model.messages.last?.messageId, reply)
        XCTAssertEqual(chat.model.messages.last?.content, "Done.")
    }

    func testARebuiltTurnWithoutAFullReceiptReReadsItsRowsAtItsEnd() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        await rebuildMidTool(chat)
        let settled = midToolRows + [
            row(6, "user", "[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]\nUse tabs\n[/OUT-OF-BAND USER MESSAGE]",
                ["display_kind": .string("steer")]),
            row(7, "assistant", "Done.")
        ]
        chat.pages.set(0, settled)
        chat.receive(event(7, "message.complete", ["status": .string("complete"), "text": .string("Done."),
                                                   "persisted_turn": .object([
                                                       "row_ids": .array((3...7).map { .number(Double($0)) }),
                                                       "complete": .bool(false), "user_row_id": .number(3),
                                                       "final_assistant_row_id": .number(7)
                                                   ])]))
        chat.receive(event(8, "session.info", ["running": .bool(false)]))
        await waitUntil("saved rows") { chat.model.messages.last?.rowID == 7 }
        XCTAssertEqual(chat.model.messages.compactMap(\.rowID), [1, 2, 3, 6, 7])
        XCTAssertEqual(chat.model.completedToolCallGroups.map(\.anchorMessageID), ["tip/row-6"], "above the steer")
        XCTAssertEqual(chat.model.completedReasoningGroups.map(\.anchorMessageID), ["tip/row-6"])
    }

    func testARebuiltTurnStoppedMidToolSettlesAtTheNextTurnsEnd() async {
        let chat = await openChat(pages: [0: [row(1, "user", "Hi"), row(2, "assistant", "Hello.")]])
        await rebuildMidTool(chat)
        chat.receive(event(7, "message.complete", ["status": .string("interrupted")]))
        chat.receive(event(8, "session.info", ["running": .bool(false)]))

        chat.receive(event(9, "session.info", ["running": .bool(true), "turn_started_at": .number(1_790_000_006)]))
        chat.receive(event(10, "message.start"))
        chat.pages.set(0, midToolRows + [row(6, "user", "Again"), row(7, "assistant", "Done.")])
        chat.receive(event(11, "message.complete", ["status": .string("complete"), "text": .string("Done.")]))
        chat.receive(event(12, "session.info", ["running": .bool(false)]))
        await waitUntil("saved rows") { chat.model.messages.last?.rowID == 7 }
        XCTAssertEqual(chat.model.completedToolCallGroups.map(\.anchorMessageID), ["tip/row-6"])
    }

    private var midToolRows: [BotJSON] {
        [row(1, "user", "Hi"), row(2, "assistant", "Hello."), row(3, "user", "Next"),
         row(4, "assistant", "", ["reasoning": .string("Look first."),
                                  "tool_calls": .array([call("call_4", "terminal", "{\"command\": \"sleep 180\"}")])]),
         row(5, "tool", "{\"output\": \"\"}", ["tool_call_id": .string("call_4"), "tool_name": .string("terminal")])]
    }

    private func rebuildMidTool(_ chat: Chat) async {
        chat.receive(event(1, "message.start"))
        chat.receive(event(2, "tool.start", ["tool_id": .string("call_4"), "name": .string("terminal")]))
        chat.pages.set(0, midToolRows)
        let snapshot = resume(running: true, inflight: ["user": .string("Next")], startedAt: 1_790_000_003)
        chat.host.next("session.events.since", .init(result: BotFixtureWire.replay(latest: 6)))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.host.next("session.resume", .init(result: snapshot))
        chat.receive(event(5, "tool.complete", ["tool_id": .string("call_4"), "name": .string("terminal")]))
        await waitUntil("rebuilt") { chat.turn.engine.connectionState == .connected }
    }

    func testAFailedReadShowsTheLoadErrorAndTheRetryReadsAgain() async {
        let chat = await openChat(pages: [:])
        XCTAssertEqual(chat.model.messages, [])
        XCTAssertNotNil(chat.model.errorMessage, "the chat's load error, with its retry")

        chat.pages.set(0, [row(1, "user", "Hi")])
        await chat.model.loadMessages()
        XCTAssertEqual(chat.model.messages.map(\.content), ["Hi"])
        XCTAssertNil(chat.model.errorMessage)
        XCTAssertEqual(chat.pages.offsets, [0, 0])
    }

    private static let path = "/api/sessions/tip/messages"
    private static let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "http://hermes.local:9120")!,
                                                  username: "user", password: "fixture")

    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private var pages: [Int: [BotJSON]]
        private var asked: [Int] = []

        init(_ pages: [Int: [BotJSON]]) { self.pages = pages }

        var offsets: [Int] { lock.withLock { asked } }
        func set(_ offset: Int, _ rows: [BotJSON]) { lock.withLock { pages[offset] = rows } }

        func answer(_ request: URLRequest) -> HermesHostFixture.Reply? {
            guard request.url?.path == HermesTranscriptPagingTests.path,
                  let query = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })?.queryItems,
                  let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) else { return nil }
            return lock.withLock {
                asked.append(offset)
                guard let rows = pages[offset] else { return .json(500, .object(["detail": .string("unavailable")])) }
                return .json(200, .object([
                    "session_id": .string("tip"), "profile": .string("default"), "messages": .array(rows),
                    "pagination": .object(["limit": .number(100), "offset": .number(Double(offset)),
                                           "order": .string("latest"), "returned": .number(Double(rows.count))])
                ]))
            }
        }
    }

    private struct Chat {
        let model: ChatViewModel
        let turn: HermesChatTurnCoordinator
        let host: BotSocketHost
        let client: BotClient
        let pages: Pages

        @MainActor func receive(_ frame: BotJSON) { client.onEvent?(frame) }

        func writes(_ method: String) -> [[String: BotJSON]] {
            host.requests.filter { $0["method"].text == method }.compactMap { $0["params"].fields }
        }
    }

    private func openChat(pages: [Int: [BotJSON]]) async -> Chat {
        addTeardownBlock { HermesHostFixture.reset() }
        let host = BotSocketHost()
        host.always("session.resume", .init(result: resume(running: false)))
        host.always("session.events.since", .init(result: BotFixtureWire.replay(latest: 0)))
        let client = BotClient(http: host.connection(Self.connection))
        let script = Pages(pages)
        _ = HermesHostFixture.configuration { script.answer($0) }
        let engine = HermesConversation(server: URL(string: "https://hermes.example")!, connection: Self.connection,
                                        target: .session(profile: "default", key: "tip"), wire: client)
        let turn = HermesChatTurnCoordinator(engine: engine, isNetworkAvailable: { true })
        let model = ChatViewModel(
            session: SessionSummary(profile: "default"), server: URL(string: "https://hermes.example")!,
            streamingScrollCoalescingDelayNanoseconds: 0,
            draftStore: ChatDraftStore(persistence: BotMemoryDrafts(), debounceDuration: .seconds(60)),
            backend: .hermes(turn)
        )
        await model.loadMessages()
        XCTAssertEqual(engine.connectionState, .connected)
        return Chat(model: model, turn: turn, host: host, client: client, pages: script)
    }

    private func row(_ id: Int, _ role: String, _ content: String, _ extra: [String: BotJSON] = [:]) -> BotJSON {
        var fields: [String: BotJSON] = [
            "id": .number(Double(id)), "session_id": .string("tip"), "role": .string(role), "content": .string(content),
            "timestamp": .number(1_790_000_000 + Double(id)), "active": .number(1), "compacted": .number(0),
            "tool_call_id": .null, "tool_calls": .null, "display_kind": .null, "display_metadata": .null
        ]
        fields.merge(extra) { $1 }
        return .object(fields)
    }

    private func alternating(_ id: Int) -> BotJSON {
        id.isMultiple(of: 2) ? row(id, "assistant", "Answer \(id)") : row(id, "user", "Question \(id)")
    }

    private func call(_ id: String, _ name: String, _ arguments: String) -> BotJSON {
        .object(["id": .string(id), "type": .string("function"),
                 "function": .object(["name": .string(name), "arguments": .string(arguments)])])
    }

    private func renderID(of messageID: String, in model: ChatViewModel) -> String? {
        model.displayedTranscriptMessages.first { $0.message.messageId == messageID }?.renderID
    }

    private func event(_ seq: Int, _ type: String, _ payload: [String: BotJSON] = [:]) -> BotJSON {
        .object(["session_id": .string("runtime"), "seq": .number(Double(seq)), "type": .string(type),
                 "payload": .object(payload)])
    }

    private func resume(running: Bool, inflight: [String: BotJSON]? = nil, startedAt: Double = 1_790_000_000) -> BotJSON {
        var reply: [String: BotJSON] = [
            "session_id": .string("runtime"), "session_key": .string("tip"), "running": .bool(running),
            "messages": .array([]), "info": .object(["profile_name": .string("default")])
        ]
        if running { reply["turn_started_at"] = .number(startedAt) }
        if var inflight {
            inflight["started_at"] = .number(startedAt)
            reply["inflight"] = .object(inflight)
        }
        return .object(reply)
    }
}
