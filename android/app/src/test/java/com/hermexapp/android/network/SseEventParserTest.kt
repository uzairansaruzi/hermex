package com.hermexapp.android.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Event names and payloads mirror the iOS `SSEEventDecoder` (upstream `api/streaming.py`). */
class SseEventParserTest {

    @Test
    fun `token events carry text`() {
        val event = SseEventParser.parse("token", """{"text": "Hello"}""")
        assertEquals(SseEvent.Token("Hello"), event)
    }

    @Test
    fun `reasoning events carry text`() {
        assertEquals(SseEvent.Reasoning("hmm"), SseEventParser.parse("reasoning", """{"text": "hmm"}"""))
    }

    @Test
    fun `interim assistant carries already_streamed`() {
        val event = SseEventParser.parse(
            "interim_assistant",
            """{"text": "partial answer", "already_streamed": true}""",
        ) as SseEvent.InterimAssistant
        assertEquals("partial answer", event.text)
        assertEquals(true, event.alreadyStreamed)
    }

    @Test
    fun `tool events resolve a stable id from the alias fields`() {
        val started = SseEventParser.parse(
            "tool",
            """{"name": "bash", "preview": "ls -la", "tool_call_id": "call_9"}""",
        ) as SseEvent.ToolStarted
        assertEquals("bash", started.tool.name)
        assertEquals("call_9", started.tool.stableId)

        val completed = SseEventParser.parse(
            "tool_complete",
            """{"name": "bash", "duration": 1.25, "is_error": false, "tid": "t1"}""",
        ) as SseEvent.ToolCompleted
        assertEquals(1.25, completed.tool.duration!!, 0.0001)
        assertEquals("t1", completed.tool.stableId)
    }

    @Test
    fun `title done cancel and stream_end map to their events`() {
        val title = SseEventParser.parse("title", """{"session_id": "s", "title": "New title"}""")
        assertEquals(SseEvent.Title("s", "New title"), title)

        val done = SseEventParser.parse("done", """{"session": {"session_id": "s"}, "usage": {}}""")
        assertTrue((done as SseEvent.Done).session != null)

        assertEquals(SseEvent.Cancelled, SseEventParser.parse("cancel", ""))
        assertEquals(SseEvent.StreamEnd, SseEventParser.parse("stream_end", ""))
    }

    @Test
    fun `error events prefer error then message`() {
        assertEquals(
            SseEvent.Error("boom"),
            SseEventParser.parse("error", """{"error": "boom"}"""),
        )
        assertEquals(
            SseEvent.Error("fallback"),
            SseEventParser.parse("error", """{"message": "fallback"}"""),
        )
    }

    @Test
    fun `unknown event types are ignored, never fatal`() {
        assertEquals(SseEvent.Ignored, SseEventParser.parse("some_future_event", """{"x": 1}"""))
    }

    @Test
    fun `malformed payloads degrade to safe defaults`() {
        assertEquals(SseEvent.Token(""), SseEventParser.parse("token", "not json"))
        val done = SseEventParser.parse("done", "<garbage>") as SseEvent.Done
        assertNull(done.session)
    }
}
