package com.hermex.app.data.network

import com.hermex.app.data.model.SSEEvent
import com.hermex.app.data.model.ToolStreamEvent
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SseClientTest {
    private val client = SseClient(
        okHttpClient = OkHttpClient(),
        json = Json { ignoreUnknownKeys = true }
    )

    // -------------------------------------------------------------------------
    // Token
    // -------------------------------------------------------------------------

    @Test
    fun tokenEventsDecodeTextFromJsonPayload() {
        val event = client.parseEvent("token", "{\"text\":\"hello\"}")

        assertEquals(SSEEvent.Token("hello"), event)
    }

    @Test
    fun tokenEventsDecodePlainString() {
        val event = client.parseEvent("token", "\"plain text\"")

        assertEquals(SSEEvent.Token("plain text"), event)
    }

    // -------------------------------------------------------------------------
    // Reasoning
    // -------------------------------------------------------------------------

    @Test
    fun reasoningEventsDecodeTextFromJsonPayload() {
        val event = client.parseEvent("reasoning", "{\"text\":\"thinking\"}")

        assertEquals(SSEEvent.Reasoning("thinking"), event)
    }

    // -------------------------------------------------------------------------
    // Tools
    // -------------------------------------------------------------------------

    @Test
    fun toolEventsUseServerEventNames() {
        val started = client.parseEvent("tool", "{\"tool_name\":\"terminal\",\"tool_id\":\"tool-1\"}")
        val completed = client.parseEvent("tool_complete", "{\"tool_name\":\"terminal\",\"tool_id\":\"tool-1\",\"result\":{\"ok\":true}}")

        assertTrue(started is SSEEvent.ToolStarted)
        assertEquals("terminal", (started as SSEEvent.ToolStarted).event.toolName)
        assertTrue(completed is SSEEvent.ToolCompleted)
        assertEquals("tool-1", (completed as SSEEvent.ToolCompleted).event.toolId)
    }

    @Test
    fun toolStartedAliases() {
        val byToolCall = client.parseEvent("tool_call", "{\"tool_name\":\"bash\"}")
        val byToolStarted = client.parseEvent("tool_started", "{\"tool_name\":\"bash\"}")

        assertTrue(byToolCall is SSEEvent.ToolStarted)
        assertTrue(byToolStarted is SSEEvent.ToolStarted)
    }

    @Test
    fun toolCompletedAliases() {
        val byResult = client.parseEvent("tool_result", "{\"tool_name\":\"bash\"}")
        val byCompleted = client.parseEvent("tool_completed", "{\"tool_name\":\"bash\"}")

        assertTrue(byResult is SSEEvent.ToolCompleted)
        assertTrue(byCompleted is SSEEvent.ToolCompleted)
    }

    // -------------------------------------------------------------------------
    // Title
    // -------------------------------------------------------------------------

    @Test
    fun titleEventsDecodeText() {
        val event = client.parseEvent("title", "{\"title\":\"My Session\"}")

        assertTrue(event is SSEEvent.Title)
        assertEquals("My Session", (event as SSEEvent.Title).title)
    }

    // -------------------------------------------------------------------------
    // Done (A2 regression)
    // -------------------------------------------------------------------------

    @Test
    fun doneWithUsagePayload() {
        val event = client.parseEvent(
            "done",
            """{"usage":{"input_tokens":100,"output_tokens":50}}"""
        )

        assertTrue(event is SSEEvent.Done)
        assertEquals(100L, (event as SSEEvent.Done).event.usage?.inputTokens)
    }

    @Test
    fun doneWithEmptyObjectPayload() {
        val event = client.parseEvent("done", "{}")

        assertTrue(event is SSEEvent.Done)
    }

    @Test
    fun malformedDoneProducesErrorNotNull() {
        // A2 fix: malformed done must surface as Error, not silently return null.
        val event = client.parseEvent("done", "not valid json at all {{{")

        assertTrue("Expected SSEEvent.Error but got $event", event is SSEEvent.Error)
        assertTrue((event as SSEEvent.Error).message.contains("Malformed"))
    }

    // -------------------------------------------------------------------------
    // Approval (A10 — real wire format)
    // -------------------------------------------------------------------------

    @Test
    fun approvalEventParsesNestedPayload() {
        val data = """
            {
                "pending": {
                    "approval_id": "ap-1",
                    "command": "rm -rf /tmp/test",
                    "description": "Delete test files",
                    "pattern_keys": ["file_delete", "shell_exec"]
                },
                "pending_count": 1
            }
        """.trimIndent()

        val event = client.parseEvent("approval", data)

        assertTrue("Expected ApprovalPending but got $event", event is SSEEvent.ApprovalPending)
        val response = (event as SSEEvent.ApprovalPending).response
        assertEquals("ap-1", response.pending?.approvalId)
        assertEquals("rm -rf /tmp/test", response.pending?.command)
        assertEquals(listOf("file_delete", "shell_exec"), response.displayPatternKeys)
        assertEquals(1, response.pendingCount)
    }

    @Test
    fun initialEventDetectedAsApprovalWhenNoClarificationMarkers() {
        val data = """
            {
                "pending": {
                    "approval_id": "ap-2",
                    "command": "npm install",
                    "pattern_key": "shell_exec"
                },
                "pending_count": 1
            }
        """.trimIndent()

        val event = client.parseEvent("initial", data)

        assertTrue("Expected ApprovalPending but got $event", event is SSEEvent.ApprovalPending)
        assertEquals("ap-2", (event as SSEEvent.ApprovalPending).response.pending?.approvalId)
        assertEquals(listOf("shell_exec"), event.response.displayPatternKeys)
    }

    // -------------------------------------------------------------------------
    // Clarification (A10 — real wire format)
    // -------------------------------------------------------------------------

    @Test
    fun clarifyEventParsesNestedPayload() {
        val data = """
            {
                "pending": {
                    "clarify_id": "cl-1",
                    "question": "Which database?",
                    "choices_offered": ["PostgreSQL", "MySQL", "SQLite"],
                    "session_id": "sess-42"
                },
                "pending_count": 1
            }
        """.trimIndent()

        val event = client.parseEvent("clarify", data)

        assertTrue("Expected ClarificationPending but got $event", event is SSEEvent.ClarificationPending)
        val response = (event as SSEEvent.ClarificationPending).response
        assertEquals("cl-1", response.pending?.clarifyId)
        assertEquals("Which database?", response.displayQuestion)
        assertEquals(listOf("PostgreSQL", "MySQL", "SQLite"), response.displayChoices)
    }

    @Test
    fun initialEventDetectedAsClarificationWhenQuestionPresent() {
        val data = """
            {
                "pending": {
                    "clarify_id": "cl-2",
                    "question": "What language?",
                    "choices_offered": ["Kotlin", "Java"]
                },
                "pending_count": 1
            }
        """.trimIndent()

        val event = client.parseEvent("initial", data)

        assertTrue("Expected ClarificationPending but got $event", event is SSEEvent.ClarificationPending)
        assertEquals("What language?", (event as SSEEvent.ClarificationPending).response.displayQuestion)
    }

    @Test
    fun initialEventDetectedAsClarificationByChoicesOffered() {
        // Even without "question", the presence of "choices_offered" marks it as clarification.
        val data = """{"pending": {"choices_offered": ["yes", "no"]}, "pending_count": 1}"""

        val event = client.parseEvent("initial", data)

        assertTrue("Expected ClarificationPending but got $event", event is SSEEvent.ClarificationPending)
    }

    // -------------------------------------------------------------------------
    // Interim assistant
    // -------------------------------------------------------------------------

    @Test
    fun interimAssistantEventDecodes() {
        val event = client.parseEvent("interim_assistant", """{"content":"Searching..."}""")

        assertTrue(event is SSEEvent.InterimAssistant)
        assertEquals("Searching...", (event as SSEEvent.InterimAssistant).event.content)
    }

    // -------------------------------------------------------------------------
    // Pending steer leftover
    // -------------------------------------------------------------------------

    @Test
    fun pendingSteerLeftoverEventDecodes() {
        val event = client.parseEvent("pending_steer_leftover", """{"text":"leftover text"}""")

        assertTrue(event is SSEEvent.SteerLeftover)
        assertEquals("leftover text", (event as SSEEvent.SteerLeftover).text)
    }

    // -------------------------------------------------------------------------
    // Stream end / cancel / error
    // -------------------------------------------------------------------------

    @Test
    fun streamEndEvent() {
        val event = client.parseEvent("stream_end", "end")

        assertEquals(SSEEvent.StreamEnd, event)
    }

    @Test
    fun cancelEvent() {
        val event = client.parseEvent("cancel", "cancelled")

        assertEquals(SSEEvent.Cancelled, event)
    }

    @Test
    fun errorEventExtractsMessage() {
        val event = client.parseEvent("error", "{\"error\":\"Rate limited\"}")

        assertTrue(event is SSEEvent.Error)
        assertEquals("Rate limited", (event as SSEEvent.Error).message)
    }

    // -------------------------------------------------------------------------
    // Edge cases
    // -------------------------------------------------------------------------

    @Test
    fun unknownEventTypeReturnsNull() {
        val event = client.parseEvent("unknown_future_type", "{\"data\":1}")

        assertNull(event)
    }

    @Test
    fun blankDataReturnsNull() {
        assertNull(client.parseEvent("token", ""))
        assertNull(client.parseEvent("token", "   "))
    }

    @Test
    fun commentLineReturnsNull() {
        assertNull(client.parseEvent("token", ": keep-alive"))
    }

    @Test
    fun malformedJsonForNonDoneEventReturnsNull() {
        // Non-done events with bad JSON should return null (not crash),
        // unlike done events which produce Error (A2).
        val event = client.parseEvent("tool", "not json")

        assertNull(event)
    }

    @Test
    fun nullEventTypeReturnsNull() {
        val event = client.parseEvent(null, "{\"text\":\"hello\"}")

        assertNull(event)
    }
}
